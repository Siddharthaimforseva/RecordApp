import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedMeetingID: Meeting.ID?
    @Published var activeError: String?

    let recorder = AudioRecorder()
    private let store = MeetingStore.shared

    var isRecording: Bool { recorder.isRecording }
    var currentRecordingID: Meeting.ID?

    init() {
        meetings = store.loadAll()
    }

    func meeting(with id: Meeting.ID?) -> Meeting? {
        meetings.first { $0.id == id }
    }

    // MARK: - Recording

    func startRecording() async {
        guard !recorder.isRecording else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        var meeting = Meeting(title: "Meeting \(formatter.string(from: Date()))",
                              date: Date(),
                              status: .recording)
        do {
            let dir = try store.createDirectory(for: meeting)
            try store.save(meeting)
            try await recorder.start(in: dir)
            meetings.insert(meeting, at: 0)
            currentRecordingID = meeting.id
            selectedMeetingID = meeting.id
        } catch {
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
            try? store.save(meeting)
            store.delete(meeting)
            activeError = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard recorder.isRecording, let id = currentRecordingID,
              var meeting = meeting(with: id) else { return }
        let duration = await recorder.stop()
        currentRecordingID = nil
        meeting.duration = duration
        update(meeting, status: .converting)

        let systemURL = recorder.systemAudioURL
        let micURL = recorder.micAudioURL
        Task {
            await process(meetingID: id, systemURL: systemURL, micURL: micURL)
        }
    }

    // MARK: - Processing pipeline

    private func process(meetingID: Meeting.ID, systemURL: URL?, micURL: URL?) async {
        guard var meeting = meeting(with: meetingID) else { return }
        do {
            // 1. Convert both recordings to 16 kHz WAV for whisper.
            let dir = store.directory(for: meeting)
            let wavs: [TrackInfo] = try await runDetached {
                var result: [TrackInfo] = []
                if let systemURL, FileManager.default.fileExists(atPath: systemURL.path) {
                    let wav = dir.appendingPathComponent("system-16k.wav")
                    try AudioConverter.to16kMonoWav(input: systemURL, output: wav)
                    result.append(TrackInfo(url: wav, speaker: "Others"))
                }
                if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
                    let wav = dir.appendingPathComponent("mic-16k.wav")
                    try AudioConverter.to16kMonoWav(input: micURL, output: wav)
                    result.append(TrackInfo(url: wav, speaker: "You"))
                }
                return result
            }

            // 2. Transcribe each track, label speakers, merge by time.
            update(meeting, status: .transcribing)
            let tracks = wavs
            let modelURL = store.modelsURL.appendingPathComponent(Transcriber.defaultModelName)
            let segments = try await runDetached {
                var all: [[TranscriptSegment]] = []
                for track in tracks {
                    all.append(try Transcriber.transcribe(wav: track.url, speaker: track.speaker, modelURL: modelURL))
                }
                return Transcriber.merge(all.first ?? [], all.count > 1 ? all[1] : [])
            }
            try store.saveTranscript(segments, for: meeting)

            guard !segments.isEmpty else {
                meeting = self.meeting(with: meetingID) ?? meeting
                meeting.status = .failed
                meeting.errorMessage = "No speech detected in the recording."
                update(meeting)
                return
            }

            // 3. Summary + minutes via local LLM.
            update(meeting, status: .summarizing)
            let transcriptText = Transcriber.plainText(for: segments)
            let summary = try await Summarizer.summary(for: transcriptText, title: meeting.title)
            try store.saveText(summary, named: "summary.md", for: meeting)
            let minutes = try await Summarizer.minutes(for: transcriptText,
                                                       title: meeting.title,
                                                       date: meeting.date,
                                                       duration: meeting.durationLabel)
            try store.saveText(minutes, named: "minutes.md", for: meeting)

            meeting = self.meeting(with: meetingID) ?? meeting
            update(meeting, status: .done)
        } catch {
            meeting = self.meeting(with: meetingID) ?? meeting
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
            update(meeting)
        }
    }

    /// Re-runs summarization (e.g. after a failure or to try a different model).
    func regenerateSummaries(for meetingID: Meeting.ID) async {
        guard var meeting = meeting(with: meetingID) else { return }
        let segments = store.loadTranscript(for: meeting)
        guard !segments.isEmpty else {
            activeError = "No transcript available to summarize."
            return
        }
        update(meeting, status: .summarizing)
        do {
            let transcriptText = Transcriber.plainText(for: segments)
            let summary = try await Summarizer.summary(for: transcriptText, title: meeting.title)
            try store.saveText(summary, named: "summary.md", for: meeting)
            let minutes = try await Summarizer.minutes(for: transcriptText,
                                                       title: meeting.title,
                                                       date: meeting.date,
                                                       duration: meeting.durationLabel)
            try store.saveText(minutes, named: "minutes.md", for: meeting)
            meeting = self.meeting(with: meetingID) ?? meeting
            update(meeting, status: .done)
        } catch {
            meeting = self.meeting(with: meetingID) ?? meeting
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
            update(meeting)
        }
    }

    // MARK: - Mutations

    func rename(_ meetingID: Meeting.ID, to title: String) {
        guard var meeting = meeting(with: meetingID), !title.isEmpty else { return }
        meeting.title = title
        update(meeting)
    }

    func delete(_ meeting: Meeting) {
        store.delete(meeting)
        meetings.removeAll { $0.id == meeting.id }
        if selectedMeetingID == meeting.id { selectedMeetingID = nil }
    }

    private func update(_ meeting: Meeting, status: MeetingStatus? = nil) {
        var updated = meeting
        if let status { updated.status = status }
        if let index = meetings.firstIndex(where: { $0.id == updated.id }) {
            meetings[index] = updated
        }
        try? store.save(updated)
    }

    // MARK: - Artifacts for the detail view

    func transcript(for meeting: Meeting) -> [TranscriptSegment] {
        store.loadTranscript(for: meeting)
    }

    func summary(for meeting: Meeting) -> String? {
        store.loadText(named: "summary.md", for: meeting)
    }

    func minutes(for meeting: Meeting) -> String? {
        store.loadText(named: "minutes.md", for: meeting)
    }
}

struct TrackInfo: Sendable {
    let url: URL
    let speaker: String
}

/// Runs throwing work off the main actor and returns its result.
private func runDetached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) {
        try work()
    }.value
}
