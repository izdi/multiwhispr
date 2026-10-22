import AVFoundation
import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct SettingsView: View {
    @EnvironmentObject var meetingRecording: MeetingRecordingController
    @AppStorage(MicrophoneSelection.storageKey) private var selectedMicrophoneUID = AudioInputDevice.systemDefaultUID
    @State private var microphones: [AudioInputDevice] = []
    @State private var micPermissionGranted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(AppName.displayName)
                    .font(.largeTitle.bold())

                Text("Record both sides of a call. Your microphone goes to the left channel and the other participants, taken straight from the selected apps' audio, go to the right channel. A session.json file next to the audio marks when you spoke and when others did. \(AppName.displayName) never records your screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsCard("Recording", icon: "record.circle") { recordingSection }
                SettingsCard("Who to record", icon: "person.2.wave.2") { selectionSection }
                SettingsCard("Microphone", icon: "mic") { microphoneSection }
                SettingsCard("Permissions", icon: "lock.shield") { permissionsSection }
                SettingsCard("Files", icon: "folder") { filesSection }
                SettingsCard("Build", icon: "info.circle") { BuildInfoView() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            meetingRecording.refreshRunningApplications()
            microphones = AudioInputDevice.available()
            micPermissionGranted = MicrophoneAccess.isGranted
        }
    }

    // MARK: Recording

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    meetingRecording.toggle(microphoneUID: selectedMicrophoneUID)
                } label: {
                    Label(
                        meetingRecording.isRecording ? "Stop Recording" : "Start Meeting Recording",
                        systemImage: meetingRecording.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .disabled(meetingRecording.isBusy)

                if meetingRecording.isBusy {
                    ProgressView().controlSize(.small)
                }

                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(meetingRecording.isRecording ? .red : .secondary)
            }

            if meetingRecording.isRecording {
                VStack(alignment: .leading, spacing: 6) {
                    levelRow(title: "You", level: meetingRecording.meLevel)
                    levelRow(title: "Others", level: meetingRecording.othersLevel)
                }
                Text("If the Others meter stays empty while people talk, the meeting app is not in the selection or is not playing audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = meetingRecording.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastResult = meetingRecording.lastResult, !meetingRecording.isRecording {
                HStack(spacing: 8) {
                    Text("Last recording: \(lastResult.folderURL.lastPathComponent) · \(MeetingRecordingController.formattedDuration(lastResult.metadata.duration)) · \(lastResult.metadata.segments.count) speaker segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Show in Finder") { meetingRecording.revealLastRecording() }
                        .font(.caption)
                }
            }
        }
    }

    private var statusText: String {
        if meetingRecording.isRecording {
            return "Recording · \(MeetingRecordingController.formattedDuration(meetingRecording.elapsedSeconds))"
        }
        return meetingRecording.statusMessage
    }

    private func levelRow(title: String, level: Float) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 48, alignment: .leading)
            ProgressView(value: Double(level)).progressViewStyle(.linear).frame(maxWidth: 240)
        }
    }

    // MARK: Selection

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Capture", selection: Binding(
                get: { meetingRecording.selection.source },
                set: { meetingRecording.setSource($0) }
            )) {
                ForEach(MeetingAudioSource.allCases, id: \.self) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .disabled(meetingRecording.isRecording)

            if meetingRecording.selection.source == .allApplications {
                Text("Everything other apps play is recorded as Others, including music and notifications. \(AppName.displayName)'s own sounds are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Only the checked apps are recorded, and at least one must be playing audio (for example, in the call) when you start. For Google Meet, check the browser you use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                appGroup(title: "Meeting apps", entries: MeetingAppCatalog.meetingApps)
                appGroup(title: "Browsers", entries: MeetingAppCatalog.browsers)

                let others = meetingRecording.otherRunningApplications
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Other running apps")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(others) { application in
                            appToggle(bundleIdentifier: application.bundleIdentifier, name: application.name, icon: application.icon, isRunning: true)
                        }
                    }
                }

                Button("Refresh Running Apps") { meetingRecording.refreshRunningApplications() }
                    .font(.caption)
            }
        }
    }

    private func appGroup(title: String, entries: [MeetingAppCatalogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entries) { entry in
                appToggle(
                    bundleIdentifier: entry.bundleIdentifier,
                    name: entry.name,
                    icon: nil,
                    isRunning: meetingRecording.isRunning(entry.bundleIdentifier)
                )
            }
        }
    }

    private func appToggle(bundleIdentifier: String, name: String, icon: NSImage?, isRunning: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { meetingRecording.selection.isSelected(bundleIdentifier) },
                set: { meetingRecording.setApplication(bundleIdentifier, selected: $0) }
            )) {
                HStack(spacing: 6) {
                    if let icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(name)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(meetingRecording.isRecording)

            Spacer()

            Text(isRunning ? "Running" : "Not running")
                .font(.caption)
                .foregroundStyle(isRunning ? .green : .secondary)
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Input", selection: $selectedMicrophoneUID) {
                Text("System Default").tag(AudioInputDevice.systemDefaultUID)
                ForEach(microphones) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .frame(maxWidth: 360)
            .disabled(meetingRecording.isRecording)

            Button("Refresh Microphones") { microphones = AudioInputDevice.available() }
                .font(.caption)
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your voice needs the microphone. Other participants need System Audio Recording, which macOS asks for the first time you start a recording. Screen Recording is not used.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "mic.fill").frame(width: 20).foregroundStyle(.blue)
                Text("Microphone")
                Spacer()
                if micPermissionGranted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Granted").font(.caption).foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        MicrophoneAccess.request { micPermissionGranted = $0 }
                    }
                    .font(.caption)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(meetingRecording.missingPermission == .microphone ? Color.orange : Color.clear, lineWidth: 1)
            )

            HStack {
                Image(systemName: "speaker.wave.2.fill").frame(width: 20).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Audio Recording")
                    Text(meetingRecording.systemAudioConfirmed
                         ? "Confirmed by a recording that received audio from other apps. macOS does not let apps query this permission directly."
                         : "macOS asks the first time you start a recording and does not let apps check the answer. If Others stays silent, enable \(AppName.displayName) under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if meetingRecording.systemAudioConfirmed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Granted").font(.caption).foregroundStyle(.green)
                } else {
                    Button("Open System Settings") { meetingRecording.openSystemAudioRecordingSettings() }
                        .font(.caption)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)

            if !MeetingRecordingController.isSupported {
                Text(ProcessAudioTapError.requiresNewerMacOS.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Each recording is saved in its own folder:")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("recording.wav — 16 kHz stereo PCM. Left channel is you, right channel is everyone else.")
                Text("session.json — start time, duration, captured apps, and speaker segments (\"me\" / \"others\") with start and end seconds.")
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            Text(MeetingRecordingController.recordingsDirectory().path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button("Open Recordings Folder") { meetingRecording.revealRecordingsFolder() }
                .font(.caption)

            Text("Recordings stay on this Mac. Nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct BuildInfoView: View {
    private static let dateParser = ISO8601DateFormatter()
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private var buildDate: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MultiWhisprBuildDate") as? String,
              let date = Self.dateParser.date(from: raw) else { return nil }
        return Self.dateFormatter.string(from: date)
    }

    private var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(AppName.displayName) \(version)")
            if let buildDate {
                Text("Built \(buildDate)")
            }
            Text("macOS \(macOSVersion)")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}
