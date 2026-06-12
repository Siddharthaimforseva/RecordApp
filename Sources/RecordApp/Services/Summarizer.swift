import Foundation

enum SummarizerError: LocalizedError {
    case ollamaUnreachable
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .ollamaUnreachable:
            return "Could not reach Ollama at localhost:11434. Start it with: brew services start ollama"
        case .badResponse(let detail):
            return "Ollama returned an unexpected response: \(detail)"
        }
    }
}

/// Generates summaries and minutes via a local Ollama instance. Nothing leaves the machine.
struct Summarizer {
    static let baseURL = URL(string: "http://127.0.0.1:11434")!
    static var model: String {
        UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.1:8b"
    }

    /// Characters per chunk fed to the model. Roughly 3.5k tokens, well within an
    /// 8k context alongside the prompt.
    private static let chunkSize = 14_000

    static func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    static func summary(for transcript: String, title: String) async throws -> String {
        let condensed = try await condenseIfNeeded(transcript)
        return try await generate(
            system: """
            You are an assistant that writes concise meeting summaries. \
            Write in clear prose with short paragraphs. Do not invent details \
            that are not in the transcript.
            """,
            prompt: """
            Summarize this meeting ("\(title)") in 2-4 paragraphs. Cover the purpose, \
            the main discussion points, and the outcome. The transcript labels the \
            local user as "You" and remote participants as "Others".

            Transcript:
            \(condensed)
            """)
    }

    static func minutes(for transcript: String, title: String, date: Date, duration: String) async throws -> String {
        let condensed = try await condenseIfNeeded(transcript)
        let dateLabel = date.formatted(date: .long, time: .shortened)
        return try await generate(
            system: """
            You are an assistant that writes formal minutes of meeting in Markdown. \
            Be faithful to the transcript; never invent attendees, decisions, or dates. \
            If something is unclear, omit it rather than guessing.
            """,
            prompt: """
            Write minutes of meeting in Markdown for the meeting below. Use this structure:

            # Minutes of Meeting — \(title)
            **Date:** \(dateLabel)
            **Duration:** \(duration)

            ## Attendees
            (list what can be inferred; the transcript labels the local user "You" and remote participants "Others" — use names only if mentioned in the conversation)

            ## Agenda & Discussion
            (bullet the topics discussed, with a sentence or two each)

            ## Decisions
            (bullet each decision made; write "None recorded" if there were none)

            ## Action Items
            (bullet as "- [ ] item — owner (if mentioned)"; write "None recorded" if there were none)

            Transcript:
            \(condensed)
            """)
    }

    /// Long transcripts are map-reduced: each chunk is condensed first, then the
    /// condensed notes are used in place of the raw transcript.
    private static func condenseIfNeeded(_ transcript: String) async throws -> String {
        guard transcript.count > chunkSize else { return transcript }
        let chunks = split(transcript, size: chunkSize)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let note = try await generate(
                system: "You condense meeting transcript excerpts into detailed factual notes, preserving every topic, decision, action item, name, and number mentioned.",
                prompt: """
                Condense part \(index + 1) of \(chunks.count) of a meeting transcript into \
                detailed notes. Preserve speaker attribution ("You" vs "Others"):

                \(chunk)
                """)
            notes.append(note)
        }
        return notes.joined(separator: "\n\n")
    }

    private static func split(_ text: String, size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func generate(system: String, prompt: String) async throws -> String {
        guard await isAvailable() else { throw SummarizerError.ollamaUnreachable }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": ["num_ctx": 8192, "temperature": 0.3],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw SummarizerError.badResponse(detail)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummarizerError.badResponse("missing message content")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
