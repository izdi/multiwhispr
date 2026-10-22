import AVFoundation
import CoreMedia
import Foundation
import os.log

private let meetingLog = OSLog(subsystem: "com.izdi.multiwhispr", category: "MeetingRecording")

enum MeetingRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case microphonePermissionMissing
    case missingInputDevice
    case failedToCreateCaptureInput(String)
    case failedToStartCaptureSession(String)
    case applicationAudioStopped(String)
    case failedToWriteAudio(String)
    case failedToWriteMetadata(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A meeting recording is already running."
        case .notRecording:
            return "No meeting recording is running."
        case .microphonePermissionMissing:
            return "Microphone access is required to record your side of the meeting."
        case .missingInputDevice:
            return "No microphone is available."
        case .failedToCreateCaptureInput(let details):
            return "Could not open the microphone: \(details)"
        case .failedToStartCaptureSession(let details):
            return "Could not start microphone capture: \(details)"
        case .applicationAudioStopped(let details):
            return "App audio capture stopped: \(details)"
        case .failedToWriteAudio(let details):
            return "Could not write the recording: \(details)"
        case .failedToWriteMetadata(let details):
            return "Could not write the recording metadata: \(details)"
        }
    }
}

struct MeetingRecordingConfiguration {
    var microphoneUID: String
    var source: MeetingAudioSource
    var bundleIdentifiers: Set<String>
    /// Display names for selected bundle identifiers, written to session.json.
    var applicationNames: [String: String]
    var outputDirectory: URL
}

struct MeetingRecordingResult {
    let folderURL: URL
    let audioURL: URL
    let metadataURL: URL
    let metadata: MeetingSessionMetadata
}

/// Records the local microphone and other applications' audio into one
/// aligned stereo WAV file (left = you, right = others) plus a `session.json`
/// sidecar with speaker activity.
///
/// Microphone audio comes from an `AVCaptureSession`; application audio comes
/// from a Core Audio process tap on the selected apps, which needs only the
/// "System Audio Recording Only" permission. Both are converted to 16 kHz mono
/// PCM16 and placed on a shared host-clock timeline so the two channels stay
/// in sync regardless of capture latency.
final class MeetingRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let sampleRate = 16_000
    private static let drainInterval: TimeInterval = 0.25
    private static let maxSourceLag = 1.5

    /// Whether this macOS release can capture other applications' audio.
    static var isApplicationAudioCaptureSupported: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    private static let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: true
    )!
    private static let stereoFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(sampleRate),
        channels: 2,
        interleaved: true
    )!

    private final class ActiveSession {
        let folderURL: URL
        let audioURL: URL
        let metadataURL: URL
        let startedAt: Date
        let timelineStart: CMTime
        let othersSource: MeetingSessionMetadata.ChannelSource
        let applicationNames: [String: String]
        let microphoneUID: String
        var microphoneRestarts = 0
        var audioFile: AVAudioFile?
        var captureSession: AVCaptureSession?
        var applicationAudio: ApplicationAudioCapturing?
        var aligner = DualTrackAligner(sampleRate: MeetingRecorder.sampleRate)
        var detector = SpeakerActivityDetector()
        var drainTimer: DispatchSourceTimer?
        var sessionObservers: [NSObjectProtocol] = []
        var writtenFrames = 0
        var acceptsAudio = true
        var finalized = false

        init(
            folderURL: URL,
            startedAt: Date,
            timelineStart: CMTime,
            othersSource: MeetingSessionMetadata.ChannelSource,
            applicationNames: [String: String],
            microphoneUID: String
        ) {
            self.folderURL = folderURL
            audioURL = folderURL.appendingPathComponent(MeetingSessionMetadata.audioFileName)
            metadataURL = folderURL.appendingPathComponent(MeetingSessionMetadata.metadataFileName)
            self.startedAt = startedAt
            self.timelineStart = timelineStart
            self.othersSource = othersSource
            self.applicationNames = applicationNames
            self.microphoneUID = microphoneUID
        }
    }

    private static let maxMicrophoneRestarts = 3
    private static let microphoneRestartDelay: TimeInterval = 1

    private let queue = DispatchQueue(label: "com.izdi.multiwhispr.meeting.state")
    private let microphoneQueue = DispatchQueue(label: "com.izdi.multiwhispr.meeting.microphone")
    private let hostClock = CMClockGetHostTimeClock()

    /// Guarded by `queue`.
    private var session: ActiveSession?
    /// Used only on `microphoneQueue`.
    private var microphoneConverter: AVAudioConverter?

    /// Delivered on the main queue when capture fails mid-recording. Audio
    /// captured up to that point is finalized and passed along when possible.
    var onFailure: ((Error, MeetingRecordingResult?) -> Void)?
    /// Delivered on the main queue with display levels for (me, others).
    var onLevels: ((Float, Float) -> Void)?

    var isRecording: Bool {
        queue.sync { session != nil }
    }

    // MARK: - Starting

    func start(
        configuration: MeetingRecordingConfiguration,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            finish(.failure(MeetingRecorderError.microphonePermissionMissing))
            return
        }

        queue.async {
            guard self.session == nil else {
                finish(.failure(MeetingRecorderError.alreadyRecording))
                return
            }
            self.startLocked(configuration: configuration, completion: finish)
        }
    }

    private func startLocked(
        configuration: MeetingRecordingConfiguration,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let startedAt = Date()
        let folderURL: URL
        do {
            folderURL = try Self.makeSessionFolder(in: configuration.outputDirectory, startedAt: startedAt)
        } catch {
            completion(.failure(MeetingRecorderError.failedToWriteAudio(error.localizedDescription)))
            return
        }

        let active = ActiveSession(
            folderURL: folderURL,
            startedAt: startedAt,
            timelineStart: CMClockGetTime(hostClock),
            othersSource: configuration.source == .allApplications ? .systemAudio : .applications,
            applicationNames: configuration.applicationNames,
            microphoneUID: configuration.microphoneUID
        )

        do {
            active.audioFile = try AVAudioFile(
                forWriting: active.audioURL,
                settings: Self.fileSettings(for: Self.stereoFormat),
                commonFormat: Self.stereoFormat.commonFormat,
                interleaved: Self.stereoFormat.isInterleaved
            )
            active.captureSession = try makeMicrophoneSession(deviceUID: configuration.microphoneUID, for: active)
            active.applicationAudio = try makeApplicationAudio(configuration: configuration, for: active)
        } catch {
            teardownSources(of: active)
            discardFolder(of: active)
            completion(.failure(error))
            return
        }

        microphoneQueue.async { self.microphoneConverter = nil }

        active.captureSession?.startRunning()
        guard active.captureSession?.isRunning == true else {
            teardownSources(of: active)
            discardFolder(of: active)
            completion(.failure(MeetingRecorderError.failedToStartCaptureSession("Session failed to enter running state.")))
            return
        }

        session = active
        startDrainTimer(for: active)
        os_log(.info, log: meetingLog, "meeting recording started")
        completion(.success(()))
    }

    private func makeApplicationAudio(
        configuration: MeetingRecordingConfiguration,
        for active: ActiveSession
    ) throws -> ApplicationAudioCapturing {
        guard #available(macOS 14.2, *) else {
            throw ProcessAudioTapError.requiresNewerMacOS
        }

        let target: ProcessAudioTap.Target
        switch configuration.source {
        case .selectedApplications:
            target = .bundleIdentifiers(configuration.bundleIdentifiers)
        case .allApplications:
            target = .allExceptSelf
        }

        let tap = ProcessAudioTap(target: target)
        tap.onAudio = { [weak self, weak active] samples, hostTime in
            guard let self else { return }
            self.queue.async {
                guard let active, self.session === active, active.acceptsAudio else { return }
                let timestamp = hostTime.map { self.timelineSeconds(hostTime: $0, timelineStart: active.timelineStart) } ?? nil
                active.aligner.appendSecondary(samples, at: timestamp)
            }
        }
        tap.onFailure = { [weak self, weak active] error in
            guard let self else { return }
            self.queue.async {
                guard let active, self.session === active else { return }
                self.failLocked(with: MeetingRecorderError.applicationAudioStopped(error.localizedDescription))
            }
        }
        try tap.start()
        return tap
    }

    private func makeMicrophoneSession(deviceUID: String, for active: ActiveSession) throws -> AVCaptureSession {
        let device: AVCaptureDevice
        if !deviceUID.isEmpty, deviceUID != "default", let selected = AVCaptureDevice(uniqueID: deviceUID) {
            device = selected
        } else if let fallback = AVCaptureDevice.default(for: .audio) {
            device = fallback
        } else {
            throw MeetingRecorderError.missingInputDevice
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MeetingRecorderError.failedToCreateCaptureInput(error.localizedDescription)
        }

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = Self.fileSettings(for: Self.monoFormat)
        output.setSampleBufferDelegate(self, queue: microphoneQueue)

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw MeetingRecorderError.failedToCreateCaptureInput("Session rejected the microphone input.")
        }
        captureSession.addInput(input)
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            throw MeetingRecorderError.failedToStartCaptureSession("Session rejected the audio output.")
        }
        captureSession.addOutput(output)
        captureSession.commitConfiguration()

        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession,
            queue: nil
        ) { [weak self, weak active] notification in
            let details = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                ?? "Unknown runtime error"
            self?.queue.async {
                guard let self, let active, self.session === active else { return }
                self.handleMicrophoneRuntimeErrorLocked(details, for: active)
            }
        }
        active.sessionObservers.append(observer)
        return captureSession
    }

    /// A microphone drop-out (device unplugged, another app resetting audio)
    /// must not end the meeting. The microphone track is padded with silence
    /// while a restart is attempted; the other participants keep recording.
    private func handleMicrophoneRuntimeErrorLocked(_ details: String, for active: ActiveSession) {
        guard active.acceptsAudio else { return }
        os_log(.error, log: meetingLog, "microphone capture error: %{public}@", details)
        teardownMicrophone(of: active)

        guard active.microphoneRestarts < Self.maxMicrophoneRestarts else {
            os_log(.error, log: meetingLog, "microphone restart limit reached; continuing with other participants only")
            return
        }
        active.microphoneRestarts += 1
        queue.asyncAfter(deadline: .now() + Self.microphoneRestartDelay) { [weak self, weak active] in
            guard let self, let active, self.session === active, active.acceptsAudio else { return }
            do {
                let restarted = try self.makeMicrophoneSession(deviceUID: active.microphoneUID, for: active)
                self.microphoneQueue.async { self.microphoneConverter = nil }
                restarted.startRunning()
                guard restarted.isRunning else {
                    throw MeetingRecorderError.failedToStartCaptureSession("Session failed to enter running state.")
                }
                active.captureSession = restarted
                os_log(.info, log: meetingLog, "microphone capture restarted (attempt %d)", active.microphoneRestarts)
            } catch {
                os_log(.error, log: meetingLog, "microphone restart failed: %{public}@", error.localizedDescription)
                self.handleMicrophoneRuntimeErrorLocked(error.localizedDescription, for: active)
            }
        }
    }

    private func teardownMicrophone(of active: ActiveSession) {
        for observer in active.sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        active.sessionObservers.removeAll()

        if let captureSession = active.captureSession {
            for output in captureSession.outputs {
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
            active.captureSession = nil
        }
    }

    private static func makeSessionFolder(in directory: URL, startedAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let baseName = formatter.string(from: startedAt)

        var candidate = directory.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    // MARK: - Stopping

    func stop(completion: @escaping (Result<MeetingRecordingResult, Error>) -> Void) {
        queue.async {
            guard let active = self.session, !active.finalized else {
                DispatchQueue.main.async { completion(.failure(MeetingRecorderError.notRecording)) }
                return
            }
            self.stopSources(of: active)
            let result = self.finalizeLocked(active)
            self.session = nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Closes the audio file and metadata synchronously so a quit mid-meeting
    /// leaves a playable recording behind.
    func finalizeForTermination() {
        queue.sync {
            guard let active = session, !active.finalized else { return }
            stopSources(of: active)
            _ = finalizeLocked(active)
            session = nil
        }
    }

    private func failLocked(with error: Error) {
        guard let active = session, !active.finalized else { return }
        os_log(.error, log: meetingLog, "meeting recording failed: %{public}@", error.localizedDescription)
        stopSources(of: active)
        let result = try? finalizeLocked(active).get()
        session = nil
        DispatchQueue.main.async {
            self.onFailure?(error, result)
        }
    }

    private func stopSources(of active: ActiveSession) {
        active.acceptsAudio = false
        active.drainTimer?.cancel()
        active.drainTimer = nil
        teardownSources(of: active)
    }

    private func teardownSources(of active: ActiveSession) {
        teardownMicrophone(of: active)
        active.applicationAudio?.stop()
    }

    private func finalizeLocked(_ active: ActiveSession) -> Result<MeetingRecordingResult, Error> {
        guard !active.finalized else {
            return .failure(MeetingRecorderError.notRecording)
        }
        active.finalized = true

        var writeError: Error?
        let remaining = active.aligner.finish()
        do {
            try write(remaining, to: active)
        } catch {
            writeError = error
        }
        active.audioFile = nil

        let segments = active.detector.finish()
        let metadata = MeetingSessionMetadata(
            startedAt: active.startedAt,
            duration: Double(active.writtenFrames) / Double(Self.sampleRate),
            sampleRate: Self.sampleRate,
            channels: channels(for: active),
            segments: segments
        )
        active.applicationAudio = nil

        do {
            try metadata.jsonData().write(to: active.metadataURL, options: .atomic)
        } catch {
            return .failure(MeetingRecorderError.failedToWriteMetadata(error.localizedDescription))
        }

        if let writeError {
            return .failure(writeError)
        }

        os_log(.info, log: meetingLog, "meeting recording finalized: %.1fs, %d speaker segments", metadata.duration, segments.count)
        return .success(
            MeetingRecordingResult(
                folderURL: active.folderURL,
                audioURL: active.audioURL,
                metadataURL: active.metadataURL,
                metadata: metadata
            )
        )
    }

    private func channels(for active: ActiveSession) -> [MeetingSessionMetadata.Channel] {
        let me = MeetingSessionMetadata.Channel(index: 0, speaker: .me, source: .microphone, applications: nil)
        var applications: [MeetingSessionMetadata.CapturedApplication]?
        if active.othersSource == .applications {
            let captured = active.applicationAudio?.capturedBundleIdentifiers ?? []
            applications = captured.sorted().map { bundleIdentifier in
                MeetingSessionMetadata.CapturedApplication(
                    bundleIdentifier: bundleIdentifier,
                    name: active.applicationNames[bundleIdentifier] ?? bundleIdentifier
                )
            }
        }
        let others = MeetingSessionMetadata.Channel(
            index: 1,
            speaker: .others,
            source: active.othersSource,
            applications: applications
        )
        return [me, others]
    }

    private func discardFolder(of active: ActiveSession) {
        active.audioFile = nil
        try? FileManager.default.removeItem(at: active.folderURL)
    }

    // MARK: - Draining

    private func startDrainTimer(for active: ActiveSession) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval)
        timer.setEventHandler { [weak self, weak active] in
            guard let self, let active, self.session === active, active.acceptsAudio else { return }
            self.drainLocked(active)
        }
        timer.resume()
        active.drainTimer = timer
    }

    private func drainLocked(_ active: ActiveSession) {
        let now = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(hostClock), active.timelineStart))
        active.aligner.catchUp(to: now, maxLag: Self.maxSourceLag)
        let frames = active.aligner.drainInterleaved()
        guard !frames.isEmpty else { return }

        do {
            try write(frames, to: active)
        } catch {
            failLocked(with: error)
            return
        }

        active.detector.process(interleaved: frames)

        let levels = Self.displayLevels(for: frames)
        DispatchQueue.main.async {
            self.onLevels?(levels.me, levels.others)
        }
    }

    private func write(_ interleaved: [Int16], to active: ActiveSession) throws {
        let frameCount = interleaved.count / 2
        guard frameCount > 0 else { return }
        guard let audioFile = active.audioFile else {
            throw MeetingRecorderError.failedToWriteAudio("The audio file is not open.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.stereoFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.int16ChannelData else {
            throw MeetingRecorderError.failedToWriteAudio("Could not allocate the output buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        interleaved.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channelData[0].update(from: base, count: frameCount * 2)
        }
        do {
            try audioFile.write(from: buffer)
        } catch {
            throw MeetingRecorderError.failedToWriteAudio(error.localizedDescription)
        }
        active.writtenFrames += frameCount
    }

    private static func displayLevels(for interleaved: [Int16]) -> (me: Float, others: Float) {
        var meSum = 0.0
        var othersSum = 0.0
        var index = 0
        while index + 1 < interleaved.count {
            let me = Double(interleaved[index]) / 32_768
            let others = Double(interleaved[index + 1]) / 32_768
            meSum += me * me
            othersSum += others * others
            index += 2
        }
        let frames = Double(max(1, interleaved.count / 2))
        return (
            displayLevel(forRMS: Float(sqrt(meSum / frames))),
            displayLevel(forRMS: Float(sqrt(othersSum / frames)))
        )
    }

    /// Maps RMS to 0...1 so -50 dBFS is silent and -6 dBFS fills the meter.
    private static func displayLevel(forRMS rms: Float) -> Float {
        let decibels = 20 * log10f(max(rms, 0.00001))
        return min(1, max(0, (decibels + 50) / 44))
    }

    // MARK: - Timing and sample conversion

    private func timelineSeconds(hostTime: CMTime, timelineStart: CMTime) -> Double? {
        guard hostTime.isValid else { return nil }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(hostTime, timelineStart))
        return seconds.isFinite ? seconds : nil
    }

    private func timelineSeconds(
        for sampleBuffer: CMSampleBuffer,
        sourceClock: CMClock?,
        timelineStart: CMTime
    ) -> Double? {
        var timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid else { return nil }
        if let sourceClock, sourceClock != hostClock {
            timestamp = CMSyncConvertTime(timestamp, from: sourceClock, to: hostClock)
        }
        return timelineSeconds(hostTime: timestamp, timelineStart: timelineStart)
    }

    /// Converts any PCM sample buffer to 16 kHz mono PCM16 samples. The
    /// converter must only be used from the queue that owns it.
    private func monoSamples(
        from sampleBuffer: CMSampleBuffer,
        converter: inout AVAudioConverter?
    ) throws -> [Int16] {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw MeetingRecorderError.failedToWriteAudio("Audio buffer has no format description.")
        }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw MeetingRecorderError.failedToWriteAudio("Could not allocate a capture buffer.")
        }
        input.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: input.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw MeetingRecorderError.failedToWriteAudio("Could not copy audio data (OSStatus \(copyStatus)).")
        }

        let target = Self.monoFormat
        if sourceFormat == target {
            return Self.int16Samples(from: input)
        }

        if converter == nil || converter?.inputFormat != sourceFormat {
            let created = AVAudioConverter(from: sourceFormat, to: target)
            created?.downmix = true
            converter = created
        }
        guard let converter else {
            throw MeetingRecorderError.failedToWriteAudio("Could not create an audio converter.")
        }

        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw MeetingRecorderError.failedToWriteAudio("Could not allocate a conversion buffer.")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw MeetingRecorderError.failedToWriteAudio("Audio conversion failed: \(conversionError.localizedDescription)")
        }
        guard status != .error else {
            throw MeetingRecorderError.failedToWriteAudio("Audio conversion failed.")
        }
        return Self.int16Samples(from: output)
    }

    private static func int16Samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
    }

    private static func fileSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
        ]
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let samples: [Int16]
        do {
            samples = try monoSamples(from: sampleBuffer, converter: &microphoneConverter)
        } catch {
            queue.async { self.failLocked(with: error) }
            return
        }
        guard !samples.isEmpty else { return }

        queue.async {
            guard let active = self.session, active.acceptsAudio else { return }
            let timestamp = self.timelineSeconds(
                for: sampleBuffer,
                sourceClock: active.captureSession?.synchronizationClock,
                timelineStart: active.timelineStart
            )
            active.aligner.appendPrimary(samples, at: timestamp)
        }
    }
}
