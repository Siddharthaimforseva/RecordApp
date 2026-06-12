import Foundation

enum MeetingStatus: String, Codable {
    case recording
    case converting
    case transcribing
    case summarizing
    case done
    case failed

    var label: String {
        switch self {
        case .recording: return "Recording…"
        case .converting: return "Preparing audio…"
        case .transcribing: return "Transcribing…"
        case .summarizing: return "Generating summary…"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    var isProcessing: Bool {
        switch self {
        case .converting, .transcribing, .summarizing: return true
        default: return false
        }
    }
}

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var speaker: String
    var start: Double   // seconds
    var end: Double     // seconds
    var text: String

    var timestampLabel: String {
        let total = Int(start)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct Meeting: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var date: Date
    var duration: TimeInterval = 0
    var status: MeetingStatus = .recording
    var errorMessage: String?

    var durationLabel: String {
        let total = Int(duration)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
