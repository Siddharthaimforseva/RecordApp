import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MainSplitView(recorder: model.recorder)
    }
}

private struct MainSplitView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .alert("Something went wrong",
               isPresented: Binding(
                   get: { model.activeError != nil },
                   set: { if !$0 { model.activeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.activeError ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $model.selectedMeetingID) {
            ForEach(model.meetings) { meeting in
                MeetingRow(meeting: meeting)
                    .tag(meeting.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            model.delete(meeting)
                        }
                    }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .overlay {
            if model.meetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "mic.slash",
                    description: Text("Click Record before your next Zoom or Teams call."))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if recorder.isRecording {
            RecordingView(recorder: recorder)
        } else if let meeting = model.meeting(with: model.selectedMeetingID) {
            MeetingDetailView(meeting: meeting)
                .id(meeting.id)
        } else {
            ContentUnavailableView(
                "Select a meeting",
                systemImage: "text.bubble",
                description: Text("Pick a meeting from the sidebar, or start recording a new one."))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if recorder.isRecording {
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .help("Stop recording and process the meeting")
            } else {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Start recording system audio and microphone")
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.date, format: .dateTime.day().month().hour().minute())
                if meeting.duration > 0 {
                    Text("·")
                    Text(meeting.durationLabel)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if meeting.status != .done {
                StatusBadge(status: meeting.status)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        HStack(spacing: 4) {
            if status.isProcessing {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(status.label)
        }
        .font(.caption2)
        .foregroundStyle(status == .failed ? .red : .secondary)
    }
}
