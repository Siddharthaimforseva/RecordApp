import SwiftUI
import AppKit

struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting

    private enum Tab: String, CaseIterable {
        case summary = "Summary"
        case minutes = "Minutes"
        case transcript = "Transcript"
    }

    @State private var tab: Tab = .summary
    @State private var editedTitle: String = ""

    private var current: Meeting {
        model.meeting(with: meeting.id) ?? meeting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { editedTitle = current.title }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Meeting title", text: $editedTitle)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .onSubmit { model.rename(meeting.id, to: editedTitle) }

            HStack(spacing: 12) {
                Label(current.date.formatted(date: .abbreviated, time: .shortened),
                      systemImage: "calendar")
                if current.duration > 0 {
                    Label(current.durationLabel, systemImage: "clock")
                }
                StatusBadge(status: current.status)
                Spacer()

                if current.status == .done || current.status == .failed {
                    Button("Regenerate") {
                        Task { await model.regenerateSummaries(for: meeting.id) }
                    }
                    .help("Re-run the AI summary and minutes from the saved transcript")
                }
                Button {
                    exportMarkdown()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(current.status != .done)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if current.status.isProcessing {
            processingView
        } else if current.status == .failed {
            failedView
        } else {
            switch tab {
            case .summary:
                markdownView(model.summary(for: current), empty: "No summary yet.")
            case .minutes:
                markdownView(model.minutes(for: current), empty: "No minutes yet.")
            case .transcript:
                transcriptView
            }
        }
    }

    private var processingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(current.status.label)
                .foregroundStyle(.secondary)
            Text("Everything runs locally — this can take a few minutes for long meetings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var failedView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(current.errorMessage ?? "Processing failed.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if !model.transcript(for: current).isEmpty {
                Button("Retry summary") {
                    Task { await model.regenerateSummaries(for: meeting.id) }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func markdownView(_ text: String?, empty: String) -> some View {
        ScrollView {
            if let text, !text.isEmpty {
                Text(LocalizedStringKey(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                Text(empty)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private var transcriptView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.transcript(for: current)) { segment in
                    HStack(alignment: .top, spacing: 8) {
                        Text(segment.timestampLabel)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(segment.speaker)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(segment.speaker == "You" ? .blue : .purple)
                            Text(segment.text)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = current.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var parts: [String] = []
        if let minutes = model.minutes(for: current) { parts.append(minutes) }
        if let summary = model.summary(for: current) {
            parts.append("## Summary\n\n" + summary)
        }
        let segments = model.transcript(for: current)
        if !segments.isEmpty {
            parts.append("## Transcript\n\n" + Transcriber.plainText(for: segments))
        }
        let document = parts.joined(separator: "\n\n---\n\n")
        try? document.write(to: url, atomically: true, encoding: .utf8)
    }
}
