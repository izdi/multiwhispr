import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os.log

private let tapLog = OSLog(subsystem: "com.izdi.multiwhispr", category: "ProcessAudioTap")

/// Audio from other applications, independent of the capture mechanism.
protocol ApplicationAudioCapturing: AnyObject {
    /// Selected bundle identifiers that contributed at least one audio
    /// process during the session.
    var capturedBundleIdentifiers: Set<String> { get }
    func stop()
}

enum ProcessAudioTapError: LocalizedError {
    case requiresNewerMacOS
    case noMatchingProcesses
    case coreAudio(String, OSStatus)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .requiresNewerMacOS:
            return "Recording other apps' audio requires macOS 14.2 or later."
        case .noMatchingProcesses:
            return "None of the selected apps are playing audio yet. Join the call first, or switch to capturing all apps."
        case .coreAudio(let operation, let status):
            return "\(operation) failed (Core Audio error \(status))."
        case .unsupportedFormat:
            return "The system audio tap reported an unsupported format."
        }
    }
}

/// Captures the output of selected processes with a Core Audio process tap.
///
/// Unlike ScreenCaptureKit this needs only the "System Audio Recording Only"
/// permission, never Screen Recording. The tap is wrapped in a private
/// aggregate device whose IO proc delivers the mixed audio; a listener on the
/// system process list rebuilds the tap when a selected app starts or stops
/// an audio process mid-call (browsers and Electron apps do this often).
@available(macOS 14.2, *)
final class ProcessAudioTap: ApplicationAudioCapturing {
    enum Target: Equatable {
        case bundleIdentifiers(Set<String>)
        case allExceptSelf
    }

    private struct ProcessInfo: Equatable {
        let objectID: AudioObjectID
        let bundleIdentifier: String
    }

    private struct Plan: Equatable {
        /// Process object IDs passed to the tap.
        let processObjectIDs: [AudioObjectID]
        /// True when `processObjectIDs` are excluded from a global tap.
        let excludes: Bool
        let ownerBundleIdentifiers: Set<String>
    }

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    let target: Target
    private let controlQueue = DispatchQueue(label: "com.izdi.multiwhispr.meeting.tap.control")
    private let ioQueue = DispatchQueue(label: "com.izdi.multiwhispr.meeting.tap.io", qos: .userInteractive)
    private let conversionQueue = DispatchQueue(label: "com.izdi.multiwhispr.meeting.tap.convert")

    // Guarded by `controlQueue`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var currentPlan: Plan?
    private var isRunning = false
    private var listenerInstalled = false
    private var generation: UInt64 = 0
    private let capturedLock = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    // Used only on `conversionQueue`.
    private var converter: AVAudioConverter?

    /// How the aggregate device actually lays out the tap's audio, discovered
    /// from the first IO callback of each tap generation. Used only on `ioQueue`.
    private struct IOLayout {
        let generation: UInt64
        let format: AVAudioFormat
        let bufferRange: Range<Int>
        let bytesPerFrame: Int
    }

    /// Compares frames delivered against host time so a tap whose declared
    /// sample rate is wrong gets converted at the rate it really runs at.
    private struct RateCheck {
        var generation: UInt64 = 0
        var lastHostSeconds: Double?
        var lastFrameCount = 0
        var accumulatedSeconds = 0.0
        var accumulatedFrames = 0
        var decided = false
        var measuredRate: Double?
    }

    private var ioLayout: IOLayout?
    private var rateCheck = RateCheck()
    private var loggedLayoutFailure = false

    /// Delivered on an arbitrary queue with 16 kHz mono PCM16 samples and the
    /// host-clock time of the first sample when the hardware reported one.
    var onAudio: (([Int16], CMTime?) -> Void)?
    /// Delivered on an arbitrary queue when the tap cannot continue.
    var onFailure: ((Error) -> Void)?

    var capturedBundleIdentifiers: Set<String> {
        capturedLock.withLock { $0 }
    }

    private lazy var processListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.controlQueue.async {
            self?.handleProcessListChange()
        }
    }

    private var rateListenerInstalled = false
    private lazy var aggregateRateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.controlQueue.async {
            self?.handleAggregateRateChange()
        }
    }

    private static let nominalRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(target: Target) {
        self.target = target
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() throws {
        try controlQueue.sync {
            guard !isRunning else { return }
            let plan = try makePlan()
            try build(plan)
            installProcessListListener()
            isRunning = true
            os_log(.info, log: tapLog, "process tap started with %d process objects (excludes=%{public}@)", plan.processObjectIDs.count, String(plan.excludes))
        }
    }

    func stop() {
        controlQueue.sync {
            guard isRunning || tapID != kAudioObjectUnknown || aggregateID != kAudioObjectUnknown else { return }
            isRunning = false
            generation &+= 1
            removeProcessListListener()
            teardown()
        }
    }

    // MARK: - Planning

    private func makePlan() throws -> Plan {
        let processes = Self.processInfos()
        switch target {
        case .bundleIdentifiers(let selected):
            var owners = Set<String>()
            var objectIDs: [AudioObjectID] = []
            for process in processes {
                if let owner = MeetingProcessMatcher.owner(
                    ofProcessBundleIdentifier: process.bundleIdentifier,
                    selectedBundleIdentifiers: selected
                ) {
                    owners.insert(owner)
                    objectIDs.append(process.objectID)
                }
            }
            guard !objectIDs.isEmpty else {
                throw ProcessAudioTapError.noMatchingProcesses
            }
            return Plan(processObjectIDs: objectIDs.sorted(), excludes: false, ownerBundleIdentifiers: owners)

        case .allExceptSelf:
            let ownPID = Foundation.ProcessInfo.processInfo.processIdentifier
            let ownBundleIdentifier = Bundle.main.bundleIdentifier
            var excluded = Set<AudioObjectID>()
            if let own = Self.processObject(forPID: ownPID) {
                excluded.insert(own)
            }
            for process in processes where process.bundleIdentifier == ownBundleIdentifier {
                excluded.insert(process.objectID)
            }
            return Plan(processObjectIDs: excluded.sorted(), excludes: true, ownerBundleIdentifiers: [])
        }
    }

    /// Rebuilds the tap when the set of matching processes changed. Called on
    /// `controlQueue`.
    private func handleProcessListChange() {
        guard isRunning else { return }
        let plan: Plan
        do {
            plan = try makePlan()
        } catch {
            // Every selected process is gone, keep the current tap so audio
            // resumes if one comes back; it will be rebuilt on the next change.
            return
        }
        guard plan != currentPlan else { return }

        os_log(.info, log: tapLog, "process list changed; rebuilding tap with %d process objects", plan.processObjectIDs.count)
        teardown()
        do {
            try build(plan)
        } catch {
            isRunning = false
            removeProcessListListener()
            onFailure?(error)
        }
    }

    // MARK: - Core Audio objects

    private func build(_ plan: Plan) throws {
        let description = plan.excludes
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: plan.processObjectIDs)
            : CATapDescription(stereoMixdownOfProcesses: plan.processObjectIDs)
        description.uuid = UUID()
        description.name = "MultiWhispr Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw ProcessAudioTapError.coreAudio("Creating the system audio tap", status)
        }
        tapID = newTapID

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription)
        guard status == noErr else {
            teardown()
            throw ProcessAudioTapError.coreAudio("Reading the tap format", status)
        }
        guard let format = AVAudioFormat(streamDescription: &streamDescription),
              format.commonFormat != .otherFormat, format.channelCount > 0 else {
            teardown()
            throw ProcessAudioTapError.unsupportedFormat
        }
        tapFormat = format

        let clockDeviceUID = Self.clockDeviceUID()
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MultiWhispr Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ],
            ],
        ]
        if let clockDeviceUID {
            composition[kAudioAggregateDeviceMainSubDeviceKey] = clockDeviceUID
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clockDeviceUID]]
        }

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            teardown()
            throw ProcessAudioTapError.coreAudio("Creating the capture device", status)
        }
        aggregateID = newAggregateID

        // The IO proc runs at the aggregate's rate, not necessarily at the
        // rate the tap declares: a Bluetooth headset on a call drops the clock
        // device to 16 kHz while the tap still reports 48 kHz.
        var deliveredFormat = format
        if let deviceRate = Self.nominalSampleRate(of: aggregateID), deviceRate > 0,
           abs(deviceRate - format.sampleRate) > 1,
           let adjusted = AVAudioFormat(
               commonFormat: format.commonFormat,
               sampleRate: deviceRate,
               channels: format.channelCount,
               interleaved: format.isInterleaved
           ) {
            os_log(.info, log: tapLog, "tap declares %.0f Hz but the capture device runs at %.0f Hz; using the device rate", format.sampleRate, deviceRate)
            deliveredFormat = adjusted
        }
        tapFormat = deliveredFormat
        installAggregateRateListener()

        generation &+= 1
        let currentGeneration = generation
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inputData, inputTime, _, _ in
            self?.handleIO(inputData: inputData, inputTime: inputTime, format: deliveredFormat, generation: currentGeneration)
        }
        guard status == noErr, let procID else {
            teardown()
            throw ProcessAudioTapError.coreAudio("Installing the capture callback", status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            teardown()
            throw ProcessAudioTapError.coreAudio("Starting the capture device", status)
        }

        currentPlan = plan
        capturedLock.withLock { $0.formUnion(plan.ownerBundleIdentifiers) }
    }

    /// The clock device changed rate (a headset entering or leaving call
    /// mode); rebuild so buffers are interpreted at the new rate. Called on
    /// `controlQueue`.
    private func handleAggregateRateChange() {
        guard isRunning, let plan = currentPlan, aggregateID != kAudioObjectUnknown else { return }
        let current = Self.nominalSampleRate(of: aggregateID) ?? 0
        guard let tapFormat, abs(current - tapFormat.sampleRate) > 1 else { return }
        os_log(.info, log: tapLog, "capture device rate changed to %.0f Hz; rebuilding tap", current)
        teardown()
        do {
            try build(plan)
        } catch {
            isRunning = false
            removeProcessListListener()
            onFailure?(error)
        }
    }

    private func installAggregateRateListener() {
        guard !rateListenerInstalled, aggregateID != kAudioObjectUnknown else { return }
        var address = Self.nominalRateAddress
        if AudioObjectAddPropertyListenerBlock(aggregateID, &address, controlQueue, aggregateRateListener) == noErr {
            rateListenerInstalled = true
        }
    }

    private func removeAggregateRateListener() {
        guard rateListenerInstalled, aggregateID != kAudioObjectUnknown else {
            rateListenerInstalled = false
            return
        }
        var address = Self.nominalRateAddress
        AudioObjectRemovePropertyListenerBlock(aggregateID, &address, controlQueue, aggregateRateListener)
        rateListenerInstalled = false
    }

    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Double? {
        var address = nominalRateAddress
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    private func teardown() {
        removeAggregateRateListener()
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapFormat = nil
        currentPlan = nil
    }

    private func installProcessListListener() {
        guard !listenerInstalled else { return }
        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, controlQueue, processListListener)
        if status == noErr {
            listenerInstalled = true
        } else {
            os_log(.error, log: tapLog, "could not observe the process list (status %d)", status)
        }
    }

    private func removeProcessListListener() {
        guard listenerInstalled else { return }
        var address = Self.processListAddress
        AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, controlQueue, processListListener)
        listenerInstalled = false
    }

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: - IO

    /// Runs on `ioQueue`. Copies the tap's buffers out of the HAL-owned list
    /// and hands them to the conversion queue.
    private func handleIO(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        format: AVAudioFormat,
        generation: UInt64
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let layout = resolveLayout(for: buffers, declaredFormat: format, generation: generation) else { return }
        let tapBuffers = Array(buffers[layout.bufferRange])
        guard let firstBuffer = tapBuffers.first else { return }
        let frameCount = Int(firstBuffer.mDataByteSize) / layout.bytesPerFrame
        guard frameCount > 0 else { return }

        let timestamp = inputTime.pointee
        let hostTime: CMTime? = timestamp.mFlags.contains(.hostTimeValid)
            ? CMClockMakeHostTimeFromSystemUnits(timestamp.mHostTime)
            : nil
        let copyFormat = formatAfterRateCheck(layout.format, hostTime: hostTime, frameCount: frameCount, generation: generation)

        guard let copy = AVAudioPCMBuffer(pcmFormat: copyFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        copy.frameLength = AVAudioFrameCount(frameCount)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard destination.count == tapBuffers.count else { return }
        for index in 0..<tapBuffers.count {
            guard let source = tapBuffers[index].mData, let target = destination[index].mData else { return }
            let byteCount = min(Int(tapBuffers[index].mDataByteSize), Int(destination[index].mDataByteSize))
            target.copyMemory(from: source, byteCount: byteCount)
        }

        conversionQueue.async { [weak self] in
            self?.convertAndDeliver(copy, hostTime: hostTime, generation: generation)
        }
    }

    /// Works out which buffers hold the tap and whether they are interleaved
    /// from the buffer list itself. The declared tap format has been seen to
    /// disagree with the delivered layout, which halves the audio and doubles
    /// its pitch if trusted blindly. Runs on `ioQueue`.
    private func resolveLayout(
        for buffers: UnsafeMutableAudioBufferListPointer,
        declaredFormat: AVAudioFormat,
        generation: UInt64
    ) -> IOLayout? {
        if let ioLayout, ioLayout.generation == generation {
            return ioLayout
        }
        ioLayout = nil

        let tapChannels = max(1, Int(declaredFormat.channelCount))
        let bitsPerChannel = Int(declaredFormat.streamDescription.pointee.mBitsPerChannel)
        let bytesPerSample = bitsPerChannel > 0 ? bitsPerChannel / 8 : 4

        // Sub-device streams precede tap streams in an aggregate, so walk back
        // from the end until the tap's channels are covered.
        var start = buffers.count
        var channels = 0
        while start > 0, channels < tapChannels {
            start -= 1
            channels += max(1, Int(buffers[start].mNumberChannels))
        }
        guard channels >= tapChannels, start < buffers.count else {
            logLayoutFailureOnce(buffers, declaredFormat: declaredFormat, reason: "too few channels")
            return nil
        }
        let range = start..<buffers.count
        let selected = Array(buffers[range])
        let interleaved = selected.count == 1
        guard interleaved || selected.allSatisfy({ $0.mNumberChannels == 1 }) else {
            logLayoutFailureOnce(buffers, declaredFormat: declaredFormat, reason: "mixed buffer layout")
            return nil
        }
        let channelCount = interleaved ? max(1, Int(selected[0].mNumberChannels)) : selected.count
        let bytesPerFrame = bytesPerSample * (interleaved ? channelCount : 1)
        guard let format = AVAudioFormat(
            commonFormat: declaredFormat.commonFormat == .otherFormat ? .pcmFormatFloat32 : declaredFormat.commonFormat,
            sampleRate: declaredFormat.sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: interleaved
        ) else {
            logLayoutFailureOnce(buffers, declaredFormat: declaredFormat, reason: "unsupported format")
            return nil
        }

        let sizes = selected.map { Int($0.mDataByteSize) }
        os_log(
            .info,
            log: tapLog,
            "tap declared %.0f Hz %u ch interleaved=%{public}@ bytesPerFrame=%u; IO list has %d buffers, using the last %d (channels=%{public}@ bytes=%{public}@) as %u ch interleaved=%{public}@",
            declaredFormat.sampleRate,
            declaredFormat.channelCount,
            String(declaredFormat.isInterleaved),
            declaredFormat.streamDescription.pointee.mBytesPerFrame,
            buffers.count,
            selected.count,
            selected.map { String($0.mNumberChannels) }.joined(separator: ","),
            sizes.map(String.init).joined(separator: ","),
            format.channelCount,
            String(format.isInterleaved)
        )

        let layout = IOLayout(generation: generation, format: format, bufferRange: range, bytesPerFrame: bytesPerFrame)
        ioLayout = layout
        rateCheck = RateCheck(generation: generation)
        return layout
    }

    private func logLayoutFailureOnce(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        declaredFormat: AVAudioFormat,
        reason: String
    ) {
        guard !loggedLayoutFailure else { return }
        loggedLayoutFailure = true
        os_log(
            .error,
            log: tapLog,
            "cannot map tap buffers (%{public}@): declared %u ch, IO list has %d buffers with channels=%{public}@",
            reason,
            declaredFormat.channelCount,
            buffers.count,
            buffers.map { String($0.mNumberChannels) }.joined(separator: ",")
        )
    }

    /// Measures frames per host-clock second across consecutive callbacks and,
    /// once two seconds are in, swaps in the measured rate when the declared
    /// one is off by more than 2%. Runs on `ioQueue`.
    private func formatAfterRateCheck(
        _ format: AVAudioFormat,
        hostTime: CMTime?,
        frameCount: Int,
        generation: UInt64
    ) -> AVAudioFormat {
        if rateCheck.generation != generation {
            rateCheck = RateCheck(generation: generation)
        }
        defer {
            rateCheck.lastHostSeconds = hostTime.map(CMTimeGetSeconds)
            rateCheck.lastFrameCount = frameCount
        }

        if let measured = rateCheck.measuredRate,
           let adjusted = AVAudioFormat(
               commonFormat: format.commonFormat,
               sampleRate: measured,
               channels: format.channelCount,
               interleaved: format.isInterleaved
           ) {
            return adjusted
        }
        guard !rateCheck.decided, let hostTime, let last = rateCheck.lastHostSeconds else { return format }

        let now = CMTimeGetSeconds(hostTime)
        let delta = now - last
        let nominalChunk = Double(rateCheck.lastFrameCount) / format.sampleRate
        // Only consecutive callbacks count; a pause in delivery is not drift.
        guard delta > 0, delta < nominalChunk * 4 + 0.05 else { return format }
        rateCheck.accumulatedSeconds += delta
        rateCheck.accumulatedFrames += rateCheck.lastFrameCount
        guard rateCheck.accumulatedSeconds >= 2 else { return format }

        rateCheck.decided = true
        let measured = Double(rateCheck.accumulatedFrames) / rateCheck.accumulatedSeconds
        let deviation = abs(measured - format.sampleRate) / format.sampleRate
        if deviation > 0.02 {
            os_log(.error, log: tapLog, "tap delivers %.0f frames/s but declares %.0f Hz; converting at the measured rate", measured, format.sampleRate)
            rateCheck.measuredRate = measured
        } else {
            os_log(.info, log: tapLog, "tap rate check: %.0f frames/s against declared %.0f Hz", measured, format.sampleRate)
        }
        return format
    }

    /// Runs on `conversionQueue`.
    private func convertAndDeliver(_ buffer: AVAudioPCMBuffer, hostTime: CMTime?, generation: UInt64) {
        guard controlQueue.sync(execute: { self.isRunning && self.generation == generation }) else { return }
        let target = Self.targetFormat
        let sourceFormat = buffer.format

        if converter == nil || converter?.inputFormat != sourceFormat {
            let created = AVAudioConverter(from: sourceFormat, to: target)
            created?.downmix = true
            converter = created
        }
        guard let converter else {
            onFailure?(ProcessAudioTapError.unsupportedFormat)
            return
        }

        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, status != .error else {
            os_log(.error, log: tapLog, "tap audio conversion failed: %{public}@", conversionError?.localizedDescription ?? "unknown")
            return
        }

        let frames = Int(output.frameLength)
        guard frames > 0, let channelData = output.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        onAudio?(samples, hostTime)
    }

    // MARK: - Process and device lookup

    private static func processInfos() -> [ProcessInfo] {
        var address = processListAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var objectIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objectIDs) == noErr else {
            return []
        }
        return objectIDs.compactMap { objectID in
            guard let bundleIdentifier = stringProperty(kAudioProcessPropertyBundleID, of: objectID),
                  !bundleIdentifier.isEmpty else {
                return nil
            }
            return ProcessInfo(objectID: objectID, bundleIdentifier: bundleIdentifier)
        }
    }

    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pidValue) { pidPointer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &size,
                &objectID
            )
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func streamCount(of deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    private static func transportType(of deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    /// The device that clocks the aggregate. Prefer an output-only device so
    /// the aggregate's input side carries nothing but the tap; a headset that
    /// is both input and output would otherwise add its microphone stream.
    private static func clockDeviceUID() -> String? {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultDevice = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let defaultStatus = AudioObjectGetPropertyData(systemObject, &defaultAddress, 0, nil, &size, &defaultDevice)
        let defaultOutput: AudioObjectID? = defaultStatus == noErr && defaultDevice != kAudioObjectUnknown ? defaultDevice : nil

        if let defaultOutput, streamCount(of: defaultOutput, scope: kAudioObjectPropertyScopeInput) == 0 {
            return stringProperty(kAudioDevicePropertyDeviceUID, of: defaultOutput)
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(systemObject, &devicesAddress, 0, nil, &devicesSize) == noErr, devicesSize > 0 {
            var devices = [AudioObjectID](repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(systemObject, &devicesAddress, 0, nil, &devicesSize, &devices) == noErr {
                let outputOnly = devices.first { device in
                    transportType(of: device) == kAudioDeviceTransportTypeBuiltIn
                        && streamCount(of: device, scope: kAudioObjectPropertyScopeOutput) > 0
                        && streamCount(of: device, scope: kAudioObjectPropertyScopeInput) == 0
                }
                if let outputOnly, let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: outputOnly) {
                    return uid
                }
            }
        }

        guard let defaultOutput else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, of: defaultOutput)
    }
}
