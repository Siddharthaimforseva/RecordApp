import Foundation

enum TranscriberError: LocalizedError {
    case whisperNotFound
    case modelNotFound(String)
    case whisperFailed(String)

    var errorDescription: String? {
        switch self {
        case .whisperNotFound:
            return "whisper-cli not found. Install it with: brew install whisper-cpp"
        case .modelNotFound(let path):
            return "Whisper model not found at \(path)."
        case .whisperFailed(let detail):
            return "Transcription failed: \(detail)"
        }
    }
}

/// Wraps the whisper.cpp CLI for fully local transcription.
struct Transcriber {
    static let defaultModelName = "ggml-small.en.bin"

    /// Locations searched for the whisper-cli binary.
    private static let cliCandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
    ]

    static func findCLI() -> URL? {
        for path in cliCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Transcribes a 16 kHz mono WAV and returns timestamped segments labeled with `speaker`.
    static func transcribe(wav: URL, speaker: String, modelURL: URL) throws -> [TranscriptSegment] {
        guard let cli = findCLI() else { throw TranscriberError.whisperNotFound }
        let model = modelURL
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscriberError.modelNotFound(model.path)
        }

        let outputBase = wav.deletingPathExtension().path + "-whisper"
        let process = Process()
        process.executableURL = cli
        process.arguments = [
            "-m", model.path,
            "-f", wav.path,
            "--output-json",
            "--output-file", outputBase,
            "--no-prints",
            "--threads", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errData, encoding: .utf8) ?? "exit code \(process.terminationStatus)"
            throw TranscriberError.whisperFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let jsonURL = URL(fileURLWithPath: outputBase + ".json")
        let data = try Data(contentsOf: jsonURL)
        let output = try JSONDecoder().decode(WhisperOutput.self, from: data)

        return output.transcription.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("[") , !text.hasPrefix("(") else { return nil }
            return TranscriptSegment(
                speaker: speaker,
                start: Double(item.offsets.from) / 1000.0,
                end: Double(item.offsets.to) / 1000.0,
                text: text
            )
        }
    }

    /// Interleaves mic ("You") and system ("Others") segments by start time, merging
    /// consecutive segments from the same speaker into one block.
    static func merge(_ a: [TranscriptSegment], _ b: [TranscriptSegment]) -> [TranscriptSegment] {
        let sorted = (a + b).sorted { $0.start < $1.start }
        var merged: [TranscriptSegment] = []
        for segment in sorted {
            if var last = merged.last, last.speaker == segment.speaker,
               segment.start - last.end < 2.0 {
                last.text += " " + segment.text
                last.end = segment.end
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    static func plainText(for segments: [TranscriptSegment]) -> String {
        segments.map { "[\($0.timestampLabel)] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }
}

private struct WhisperOutput: Decodable {
    struct Item: Decodable {
        struct Offsets: Decodable {
            let from: Int
            let to: Int
        }
        let offsets: Offsets
        let text: String
    }
    let transcription: [Item]
}
