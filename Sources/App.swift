import AppKit
import SwiftUI

@main
struct MultiWhisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.meetingRecording)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.meetingRecording)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var meetingRecording: MeetingRecordingController

    var body: some View {
        Image(systemName: meetingRecording.isRecording ? "person.2.wave.2.fill" : "person.2.wave.2")
    }
}

struct MenuBarView: View {
    @EnvironmentObject var meetingRecording: MeetingRecordingController
    @AppStorage(MicrophoneSelection.storageKey) private var selectedMicrophoneUID = AudioInputDevice.systemDefaultUID

    var body: some View {
        VStack(spacing: 4) {
            Text("\(AppName.displayName) v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            Divider()

            Button(meetingRecording.isRecording ? "Stop Recording" : "Start Meeting Recording") {
                meetingRecording.toggle(microphoneUID: selectedMicrophoneUID)
            }
            .disabled(meetingRecording.isBusy)

            if meetingRecording.isRecording {
                Label(
                    "Recording · \(MeetingRecordingController.formattedDuration(meetingRecording.elapsedSeconds))",
                    systemImage: "record.circle"
                )
                .foregroundStyle(.red)
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            } else {
                Text(meetingRecording.statusMessage)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            if let error = meetingRecording.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .lineLimit(3)
            }

            Divider()

            if meetingRecording.lastResult != nil {
                Button("Show Last Recording in Finder") {
                    meetingRecording.revealLastRecording()
                }
            }
            Button("Open Recordings Folder") {
                meetingRecording.revealRecordingsFolder()
            }

            Divider()

            Button("Settings…") {
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }

            Button("Quit \(AppName.displayName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }
}

enum MicrophoneSelection {
    static let storageKey = "selected_microphone_id"
}

extension Notification.Name {
    static let showSettings = Notification.Name("MultiWhispr.showSettings")
}
