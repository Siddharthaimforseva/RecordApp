import AVFoundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to capture system audio from."
        case .microphoneDenied: return "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
        }
    }
}

/// Receives system-audio sample buffers from ScreenCaptureKit and writes them to a CAF file.
final class SystemAudioWriter: NSObject, SCStreamOutput, SCStreamDelegate {
    private let url: URL
    private var file: AVAudioFile?
    private let writeQueue = DispatchQueue(label: "recordapp.system-audio-write")

    init(url: URL) {
        self.url = url
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        writeQueue.sync {
            do {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: format.settings)
                }
                try file?.write(from: pcm)
            } catch {
                NSLog("RecordApp: failed to write system audio: \(error)")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("RecordApp: system audio stream stopped: \(error)")
    }

    func finish() {
        writeQueue.sync { file = nil }
    }
}

/// Records system audio (everything the Mac plays, e.g. Zoom/Teams participants)
/// and the microphone into two separate CAF files.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    private var stream: SCStream?
    private var systemWriter: SystemAudioWriter?
    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var timer: Timer?
    private var startedAt: Date?

    private(set) var systemAudioURL: URL?
    private(set) var micAudioURL: URL?

    func start(in directory: URL) async throws {
        guard !isRecording else { return }

        // Microphone permission first — fail fast before touching screen capture.
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw RecorderError.microphoneDenied }

        // System audio via ScreenCaptureKit. This call triggers the
        // Screen & System Audio Recording permission prompt on first run.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        // Video is required by SCStream but unused — keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let sysURL = directory.appendingPathComponent("system.caf")
        let writer = SystemAudioWriter(url: sysURL)
        let scStream = SCStream(filter: filter, configuration: config, delegate: writer)
        try scStream.addStreamOutput(writer, type: .audio,
                                     sampleHandlerQueue: DispatchQueue(label: "recordapp.system-audio"))
        try await scStream.startCapture()

        // Microphone via AVAudioEngine.
        let micURL = directory.appendingPathComponent("mic.caf")
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: micURL, settings: format.settings)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                NSLog("RecordApp: failed to write mic audio: \(error)")
            }
        }
        try engine.start()

        stream = scStream
        systemWriter = writer
        micFile = file
        systemAudioURL = sysURL
        micAudioURL = micURL
        startedAt = Date()
        elapsed = 0
        isRecording = true

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// Stops recording and returns the elapsed duration.
    func stop() async -> TimeInterval {
        guard isRecording else { return 0 }
        timer?.invalidate()
        timer = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micFile = nil

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        systemWriter?.finish()
        systemWriter = nil

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        startedAt = nil
        isRecording = false
        return duration
    }
}
