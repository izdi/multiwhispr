import AppKit
import AVFoundation
import Combine
import Foundation

struct MeetingRunningApplication: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String
    let icon: NSImage?

    var id: String { bundleIdentifier }

    static func == (lhs: MeetingRunningApplication, rhs: MeetingRunningApplication) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier && lhs.name == rhs.name
    }
}

/// Main-thread state for meeting recordings: who to capture, whether a
/// recording is running, live levels, and where the last one was saved.
/// All published properties are mutated on the main queue.
final class MeetingRecordingController: ObservableObject {
    enum MissingPermission: Equatable {
        case microphone
    }

    /// Other apps' audio needs Core Audio process taps, available from macOS 14.2.
    static var isSupported: Bool {
        MeetingRecorder.isApplicationAudioCaptureSupported
    }

    @Published private(set) var isRecording = false
    /// True while a start or stop is in flight.
    @Published private(set) var isBusy = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var meLevel: Float = 0
    @Published private(set) var othersLevel: Float = 0
    @Published private(set) var statusMessage = "Not recording"
    @Published var errorMessage: String?
    @Published private(set) var missingPermission: MissingPermission?
    @Published private(set) var lastResult: MeetingRecordingResult?
    @Published private(set) var runningApplications: [MeetingRunningApplication] = []
    @Published private(set) var selection: MeetingCaptureSelection
    /// macOS offers no API to query System Audio Recording; this is set once
    /// a recording has received non-silent audio from other apps.
    @Published private(set) var systemAudioConfirmed: Bool
    static let systemAudioConfirmedKey = "system_audio_recording_confirmed"

    private let recorder = MeetingRecorder()
    private let defaults: UserDefaults
    private var elapsedTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = MeetingCaptureSelection.load(from: defaults)
        systemAudioConfirmed = defaults.bool(forKey: Self.systemAudioConfirmedKey)

        recorder.onLevels = { [weak self] me, others in
            guard let self, self.isRecording else { return }
            self.meLevel = me
            self.othersLevel = others
        }
        recorder.onFailure = { [weak self] error, partialResult in
            self?.handleFailure(error, partialResult: partialResult)
        }
        recorder.onApplicationAudioConfirmed = { [weak self] in
            guard let self else { return }
            self.systemAudioConfirmed = true
            self.defaults.set(true, forKey: Self.systemAudioConfirmedKey)
            if self.errorMessage?.hasPrefix("No audio from other apps") == true {
                self.errorMessage = nil
            }
        }
        recorder.onApplicationAudioSilent = { [weak self] in
            guard let self, self.isRecording else { return }
            self.errorMessage = "No audio from other apps yet. If something is playing, allow \(AppName.displayName) under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then restart the recording."
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recorder.finalizeForTermination()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        elapsedTimer?.invalidate()
    }

    static func recordingsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("\(AppName.displayName)/Meetings", isDirectory: true)
    }

    static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    // MARK: - Selection

    var catalogEntries: [MeetingAppCatalogEntry] {
        MeetingAppCatalog.allEntries
    }

    /// Running apps that are not in the built-in catalog, so an unlisted
    /// meeting tool can still be selected.
    var otherRunningApplications: [MeetingRunningApplication] {
        let catalogIdentifiers = Set(MeetingAppCatalog.allEntries.map(\.bundleIdentifier))
        return runningApplications.filter { !catalogIdentifiers.contains($0.bundleIdentifier) }
    }

    func isRunning(_ bundleIdentifier: String) -> Bool {
        runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func setSource(_ source: MeetingAudioSource) {
        guard selection.source != source else { return }
        selection.source = source
        selection.save(to: defaults)
    }

    func setApplication(_ bundleIdentifier: String, selected: Bool) {
        var updated = selection
        updated.setSelected(selected, bundleIdentifier: bundleIdentifier)
        guard updated != selection else { return }
        selection = updated
        selection.save(to: defaults)
    }

    func refreshRunningApplications() {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        runningApplications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application -> MeetingRunningApplication? in
                guard let bundleIdentifier = application.bundleIdentifier,
                      !bundleIdentifier.isEmpty,
                      bundleIdentifier != ownBundleIdentifier,
                      seen.insert(bundleIdentifier).inserted else {
                    return nil
                }
                let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return MeetingRunningApplication(
                    bundleIdentifier: bundleIdentifier,
                    name: name.isEmpty ? bundleIdentifier : name,
                    icon: application.icon
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Recording

    func toggle(microphoneUID: String) {
        if isRecording {
            stop()
        } else {
            start(microphoneUID: microphoneUID)
        }
    }

    func start(microphoneUID: String) {
        guard !isRecording, !isBusy else { return }
        errorMessage = nil
        missingPermission = nil

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture(microphoneUID: microphoneUID)
        case .notDetermined:
            isBusy = true
            statusMessage = "Waiting for microphone access…"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBusy = false
                    if granted {
                        self.beginCapture(microphoneUID: microphoneUID)
                    } else {
                        self.reportMissingPermission(.microphone)
                    }
                }
            }
        default:
            reportMissingPermission(.microphone)
        }
    }

    private func beginCapture(microphoneUID: String) {
        guard Self.isSupported else {
            errorMessage = ProcessAudioTapError.requiresNewerMacOS.localizedDescription
            statusMessage = "Not recording"
            return
        }
        if selection.source == .selectedApplications && selection.bundleIdentifiers.isEmpty {
            errorMessage = "Select at least one app to record, or switch to capturing all apps."
            statusMessage = "Not recording"
            return
        }

        isBusy = true
        statusMessage = "Starting…"
        let configuration = MeetingRecordingConfiguration(
            microphoneUID: microphoneUID,
            source: selection.source,
            bundleIdentifiers: selection.bundleIdentifiers,
            applicationNames: applicationNames(),
            outputDirectory: Self.recordingsDirectory()
        )
        recorder.start(configuration: configuration) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            switch result {
            case .success:
                self.isRecording = true
                self.startedAt = Date()
                self.elapsedSeconds = 0
                self.statusMessage = "Recording"
                self.startElapsedTimer()
            case .failure(let error):
                self.statusMessage = "Not recording"
                self.errorMessage = error.localizedDescription
                if case .microphonePermissionMissing? = error as? MeetingRecorderError {
                    self.missingPermission = .microphone
                }
            }
        }
    }

    func stop() {
        guard isRecording, !isBusy else { return }
        isBusy = true
        statusMessage = "Saving…"
        recorder.stop { [weak self] result in
            guard let self else { return }
            self.finishRecordingState()
            switch result {
            case .success(let saved):
                self.lastResult = saved
                self.statusMessage = "Saved \(Self.formattedDuration(saved.metadata.duration)) recording"
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.statusMessage = "Not recording"
            }
        }
    }

    private func handleFailure(_ error: Error, partialResult: MeetingRecordingResult?) {
        finishRecordingState()
        if let partialResult {
            lastResult = partialResult
        }
        errorMessage = error.localizedDescription
        statusMessage = partialResult == nil ? "Not recording" : "Stopped early; partial recording saved"
    }

    private func finishRecordingState() {
        isBusy = false
        isRecording = false
        startedAt = nil
        meLevel = 0
        othersLevel = 0
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func reportMissingPermission(_ permission: MissingPermission) {
        missingPermission = permission
        statusMessage = "Not recording"
        switch permission {
        case .microphone:
            errorMessage = MeetingRecorderError.microphonePermissionMissing.localizedDescription
        }
    }

    /// Names for session.json, from the catalog first and running apps second.
    private func applicationNames() -> [String: String] {
        var names: [String: String] = [:]
        for application in runningApplications {
            names[application.bundleIdentifier] = application.name
        }
        for entry in MeetingAppCatalog.allEntries {
            names[entry.bundleIdentifier] = entry.name
        }
        return names
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.elapsedSeconds = Date().timeIntervalSince(startedAt)
        }
        // Common modes keep the clock ticking while the menu bar menu is open.
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    // MARK: - System Settings and Finder

    /// macOS lists system audio capture under Screen & System Audio Recording,
    /// in the "System Audio Recording Only" group.
    func openSystemAudioRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealLastRecording() {
        guard let lastResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastResult.audioURL, lastResult.metadataURL])
    }

    func revealRecordingsFolder() {
        let directory = Self.recordingsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}
