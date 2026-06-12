import SwiftUI

struct SettingsView: View {
    @AppStorage("ollamaModel") private var ollamaModel: String = "llama3.1:8b"
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false

    var body: some View {
        Form {
            Section("Transcription") {
                LabeledContent("Model") {
                    Text("Whisper small.en (built-in)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Model path") {
                    Text(MeetingStore.shared.modelsURL
                        .appendingPathComponent("ggml-small.en.bin").path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("AI Summarization (Ollama)") {
                LabeledContent("Model") {
                    HStack {
                        if availableModels.isEmpty {
                            TextField("e.g. llama3.1:8b", text: $ollamaModel)
                                .frame(width: 200)
                        } else {
                            Picker("", selection: $ollamaModel) {
                                ForEach(availableModels, id: \.self) { Text($0) }
                            }
                            .frame(width: 200)
                        }
                        Button(isLoadingModels ? "Loading…" : "Refresh") {
                            Task { await loadModels() }
                        }
                        .disabled(isLoadingModels)
                    }
                }
                LabeledContent("Endpoint") {
                    Text("http://127.0.0.1:11434")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section("Storage") {
                LabeledContent("Meetings folder") {
                    HStack {
                        Text(MeetingStore.shared.meetingsURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Reveal") {
                            NSWorkspace.shared.open(MeetingStore.shared.meetingsURL)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .task { await loadModels() }
    }

    private func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return }
        availableModels = models.compactMap { $0["name"] as? String }.sorted()
        if !availableModels.contains(ollamaModel), let first = availableModels.first {
            ollamaModel = first
        }
    }
}
