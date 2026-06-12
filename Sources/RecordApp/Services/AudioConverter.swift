import AVFoundation

enum AudioConverterError: LocalizedError {
    case conversionFailed(String)

    var errorDescription: String? {
        if case .conversionFailed(let detail) = self {
            return "Audio conversion failed: \(detail)"
        }
        return nil
    }
}

/// Converts recorded CAF audio to the 16 kHz mono 16-bit WAV that whisper.cpp expects.
enum AudioConverter {
    static func to16kMonoWav(input: URL, output: URL) throws {
        let inFile = try AVAudioFile(forReading: input)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16000,
                                            channels: 1,
                                            interleaved: true) else {
            throw AudioConverterError.conversionFailed("could not create output format")
        }
        guard let converter = AVAudioConverter(from: inFile.processingFormat, to: outFormat) else {
            throw AudioConverterError.conversionFailed("unsupported input format")
        }
        let outFile = try AVAudioFile(forWriting: output,
                                      settings: outFormat.settings,
                                      commonFormat: .pcmFormatInt16,
                                      interleaved: true)

        let inputCapacity: AVAudioFrameCount = 8192
        var reachedEnd = false
        while !reachedEnd {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192) else {
                throw AudioConverterError.conversionFailed("could not allocate buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                guard inFile.framePosition < inFile.length,
                      let inBuffer = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat,
                                                      frameCapacity: inputCapacity) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try inFile.read(into: inBuffer)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            switch status {
            case .error:
                throw AudioConverterError.conversionFailed(
                    conversionError?.localizedDescription ?? "unknown error")
            case .endOfStream:
                reachedEnd = true
            default:
                break
            }
            if outBuffer.frameLength > 0 {
                try outFile.write(from: outBuffer)
            }
        }
    }
}
