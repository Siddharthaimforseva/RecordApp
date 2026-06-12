import SwiftUI

struct RecordingView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform")
                .font(.system(size: 64))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            Text(timeLabel)
                .font(.system(size: 48, weight: .medium, design: .monospaced))

            Text("Recording system audio and microphone.\nJoin your Zoom or Teams call — everything is captured locally.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop & Process", systemImage: "stop.circle.fill")
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()
        }
        .padding()
    }

    private var timeLabel: String {
        let total = Int(recorder.elapsed)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
