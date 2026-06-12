import Foundation

/// Persists meetings on disk under ~/Library/Application Support/RecordApp/meetings/<uuid>/
/// Each meeting folder contains: meta.json, system.caf, mic.caf, transcript.json,
/// summary.md, minutes.md
@MainActor
final class MeetingStore {
    static let shared = MeetingStore()

    let rootURL: URL
    let meetingsURL: URL
    let modelsURL: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = appSupport.appendingPathComponent("RecordApp", isDirectory: true)
        meetingsURL = rootURL.appendingPathComponent("meetings", isDirectory: true)
        modelsURL = rootURL.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: meetingsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
    }

    func directory(for meeting: Meeting) -> URL {
        meetingsURL.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
    }

    func createDirectory(for meeting: Meeting) throws -> URL {
        let dir = directory(for: meeting)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func loadAll() -> [Meeting] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: meetingsURL, includingPropertiesForKeys: nil) else { return [] }
        var meetings: [Meeting] = []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  var meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
            // A meeting left mid-flight by a previous run can't be resumed.
            if meeting.status != .done && meeting.status != .failed {
                meeting.status = .failed
                meeting.errorMessage = "Interrupted before processing finished."
                try? save(meeting)
            }
            meetings.append(meeting)
        }
        return meetings.sorted { $0.date > $1.date }
    }

    func save(_ meeting: Meeting) throws {
        let dir = try createDirectory(for: meeting)
        let data = try encoder.encode(meeting)
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: directory(for: meeting))
    }

    // MARK: - Artifacts

    func saveTranscript(_ segments: [TranscriptSegment], for meeting: Meeting) throws {
        let data = try encoder.encode(segments)
        try data.write(to: directory(for: meeting).appendingPathComponent("transcript.json"))
    }

    func loadTranscript(for meeting: Meeting) -> [TranscriptSegment] {
        let url = directory(for: meeting).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url),
              let segments = try? decoder.decode([TranscriptSegment].self, from: data) else { return [] }
        return segments
    }

    func saveText(_ text: String, named name: String, for meeting: Meeting) throws {
        try text.write(to: directory(for: meeting).appendingPathComponent(name),
                       atomically: true, encoding: .utf8)
    }

    func loadText(named name: String, for meeting: Meeting) -> String? {
        try? String(contentsOf: directory(for: meeting).appendingPathComponent(name), encoding: .utf8)
    }
}
