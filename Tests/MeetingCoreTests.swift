import Foundation

enum MeetingCoreTests {
    static func run() {
        testFirstChunkIsPlacedAtItsTimestamp()
        testContiguousChunksAreNotPadded()
        testGapsAreFilledWithSilence()
        testSourceRunningAheadDropsOverlap()
        testInterleavingCoversOnlySharedSpan()
        testCatchUpPadsStalledSource()
        testFinishPadsShorterTrack()

        testSilenceProducesNoSegments()
        testSingleSpeakerSegmentTiming()
        testShortBlipsAreDropped()
        testPausesMergeWithinGap()
        testSpeechFromTheFirstWindowStartsAtFirstPause()
        testOverlappingSpeakersAreBothReported()
        testSteadyBackgroundNoiseIsNotSpeech()
        testNoiseFloorAdaptsAfterLevelRises()
        testInterleavedSamplesMatchWindowRMS()

        testMetadataRoundTrip()
        testSelectionDefaultsAndPersistence()
        testSelectionNormalization()
        testProcessMatcherOwnership()
    }

    // MARK: - Aligner

    private static func testFirstChunkIsPlacedAtItsTimestamp() {
        var track = AlignedTrack(sampleRate: 1_000)
        track.append([1, 2, 3], at: 0.5)
        TestSupport.expectEqual(track.placedFrames, 503)
        let drained = track.drain(503)
        TestSupport.expectEqual(drained.prefix(500).allSatisfy { $0 == 0 }, true)
        TestSupport.expectEqual(Array(drained.suffix(3)), [1, 2, 3])
    }

    private static func testContiguousChunksAreNotPadded() {
        var track = AlignedTrack(sampleRate: 1_000, tolerance: 0.1)
        track.append([Int16](repeating: 7, count: 100), at: 0)
        // Jitter inside the tolerance is ignored.
        track.append([Int16](repeating: 8, count: 100), at: 0.12)
        track.append([Int16](repeating: 9, count: 100), at: 0.19)
        TestSupport.expectEqual(track.placedFrames, 300)
        TestSupport.expectEqual(track.drain(300).filter { $0 == 0 }.count, 0)
    }

    private static func testGapsAreFilledWithSilence() {
        var track = AlignedTrack(sampleRate: 1_000, tolerance: 0.1)
        track.append([Int16](repeating: 5, count: 100), at: 0)
        track.append([Int16](repeating: 6, count: 100), at: 1.1)
        TestSupport.expectEqual(track.placedFrames, 1_200)
        let drained = track.drain(1_200)
        TestSupport.expectEqual(drained[100..<1_100].allSatisfy { $0 == 0 }, true)
        TestSupport.expectEqual(drained[1_100], 6)
    }

    private static func testSourceRunningAheadDropsOverlap() {
        var track = AlignedTrack(sampleRate: 1_000, tolerance: 0.1)
        track.append([Int16](repeating: 1, count: 1_000), at: 0)
        // Timestamp says this chunk starts 300 ms before the frames already placed.
        track.append(Array(0..<500).map(Int16.init), at: 0.7)
        TestSupport.expectEqual(track.placedFrames, 1_200)
        let drained = track.drain(1_200)
        TestSupport.expectEqual(drained[1_000], 300)
        TestSupport.expectEqual(drained[1_199], 499)
    }

    private static func testInterleavingCoversOnlySharedSpan() {
        var aligner = DualTrackAligner(sampleRate: 1_000)
        aligner.appendPrimary([1, 2, 3, 4], at: 0)
        aligner.appendSecondary([10, 20], at: 0)
        TestSupport.expectEqual(aligner.drainInterleaved(), [1, 10, 2, 20])
        TestSupport.expectEqual(aligner.drainInterleaved(), [])
        aligner.appendSecondary([30, 40, 50], at: nil)
        TestSupport.expectEqual(aligner.drainInterleaved(), [3, 30, 4, 40])
        TestSupport.expectEqual(aligner.placedFrames, 5)
    }

    private static func testCatchUpPadsStalledSource() {
        var aligner = DualTrackAligner(sampleRate: 1_000)
        aligner.appendPrimary([Int16](repeating: 1, count: 3_000), at: 0)
        TestSupport.expect(aligner.drainInterleaved().isEmpty, "A silent source must not be assumed before the lag limit")
        aligner.catchUp(to: 3.0, maxLag: 1.5)
        let drained = aligner.drainInterleaved()
        TestSupport.expectEqual(drained.count, 3_000)
        TestSupport.expectEqual(drained.enumerated().allSatisfy { $0.offset % 2 == 0 ? $0.element == 1 : $0.element == 0 }, true)
        // Audio that resumes later lands at its own timestamp, not where padding stopped.
        aligner.appendSecondary([9], at: 2.5)
        TestSupport.expectEqual(aligner.secondary.placedFrames, 2_501)
    }

    private static func testFinishPadsShorterTrack() {
        var aligner = DualTrackAligner(sampleRate: 1_000)
        aligner.appendPrimary([1, 1, 1], at: 0)
        aligner.appendSecondary([2], at: 0)
        TestSupport.expectEqual(aligner.drainInterleaved(), [1, 2])
        TestSupport.expectEqual(aligner.finish(), [1, 0, 1, 0])
        TestSupport.expectEqual(aligner.finish(), [])
    }

    // MARK: - Speaker activity

    private static func makeDetector() -> SpeakerActivityDetector {
        SpeakerActivityDetector(configuration: SpeakerActivityDetector.Configuration())
    }

    private static func feed(_ detector: inout SpeakerActivityDetector, me: [Float], others: [Float]) {
        TestSupport.expectEqual(me.count, others.count)
        for index in me.indices {
            detector.processWindow(meRMS: me[index], othersRMS: others[index])
        }
    }

    private static func pattern(_ windows: Int, active: Range<Int>, level: Float = 0.1, floor: Float = 0) -> [Float] {
        (0..<windows).map { active.contains($0) ? level : floor }
    }

    private static func testSilenceProducesNoSegments() {
        var detector = makeDetector()
        feed(&detector, me: [Float](repeating: 0, count: 50), others: [Float](repeating: 0.001, count: 50))
        TestSupport.expectEqual(detector.finish(), [])
    }

    private static func testSingleSpeakerSegmentTiming() {
        var detector = makeDetector()
        feed(&detector, me: pattern(40, active: 5..<30), others: [Float](repeating: 0, count: 40))
        let segments = detector.finish()
        TestSupport.expectEqual(segments.count, 1)
        TestSupport.expectEqual(segments.first?.speaker, .me)
        TestSupport.expectApproximatelyEqual(segments.first?.start ?? -1, 0.5)
        TestSupport.expectApproximatelyEqual(segments.first?.end ?? -1, 3.0)
    }

    private static func testShortBlipsAreDropped() {
        var detector = makeDetector()
        feed(&detector, me: [Float](repeating: 0, count: 30), others: pattern(30, active: 10..<12))
        TestSupport.expect(detector.finish().isEmpty, "Two 100 ms windows are below the 300 ms minimum")

        var kept = makeDetector()
        feed(&kept, me: [Float](repeating: 0, count: 30), others: pattern(30, active: 10..<13))
        TestSupport.expect(kept.finish().count == 1, "Three windows meet the minimum segment length")
    }

    private static func testPausesMergeWithinGap() {
        var detector = makeDetector()
        var me = pattern(60, active: 2..<10)
        for index in 15..<25 { me[index] = 0.1 }   // 500 ms pause: merged
        for index in 40..<50 { me[index] = 0.1 }   // 1.5 s pause: separate segment
        feed(&detector, me: me, others: [Float](repeating: 0, count: 60))
        let segments = detector.finish()
        TestSupport.expectEqual(segments.count, 2)
        TestSupport.expectApproximatelyEqual(segments[0].start, 0.2)
        TestSupport.expectApproximatelyEqual(segments[0].end, 2.5)
        TestSupport.expectApproximatelyEqual(segments[1].start, 4.0)
        TestSupport.expectApproximatelyEqual(segments[1].end, 5.0)
    }

    private static func testSpeechFromTheFirstWindowStartsAtFirstPause() {
        var detector = makeDetector()
        // Recording starts mid-sentence: a flat level has no quieter window to
        // estimate the floor from until the speaker pauses.
        var me = pattern(30, active: 0..<8)
        for index in 9..<20 { me[index] = 0.1 }
        feed(&detector, me: me, others: [Float](repeating: 0, count: 30))
        let segments = detector.finish()
        TestSupport.expectEqual(segments.count, 1)
        TestSupport.expectApproximatelyEqual(segments[0].start, 0.9)
        TestSupport.expectApproximatelyEqual(segments[0].end, 2.0)
    }

    private static func testOverlappingSpeakersAreBothReported() {
        var detector = makeDetector()
        feed(&detector, me: pattern(40, active: 5..<20), others: pattern(40, active: 15..<35, level: 0.2))
        let segments = detector.finish()
        TestSupport.expectEqual(segments.map(\.speaker), [.me, .others])
        TestSupport.expectApproximatelyEqual(segments[0].start, 0.5)
        TestSupport.expectApproximatelyEqual(segments[0].end, 2.0)
        TestSupport.expectApproximatelyEqual(segments[1].start, 1.5)
        TestSupport.expectApproximatelyEqual(segments[1].end, 3.5)
    }

    private static func testSteadyBackgroundNoiseIsNotSpeech() {
        var detector = makeDetector()
        // Room noise well above the absolute gate, with speech on top of it.
        feed(&detector, me: pattern(80, active: 50..<70, level: 0.2, floor: 0.01), others: [Float](repeating: 0, count: 80))
        let segments = detector.finish()
        TestSupport.expectEqual(segments.count, 1)
        TestSupport.expectApproximatelyEqual(segments[0].start, 5.0)
        TestSupport.expectApproximatelyEqual(segments[0].end, 7.0)
    }

    private static func testNoiseFloorAdaptsAfterLevelRises() {
        var configuration = SpeakerActivityDetector.Configuration()
        configuration.noiseWindowFrames = 20
        var detector = SpeakerActivityDetector(configuration: configuration)
        var me = [Float](repeating: 0.001, count: 100)
        for index in 30..<100 { me[index] = 0.02 }   // a fan turns on and stays on
        feed(&detector, me: me, others: [Float](repeating: 0, count: 100))
        let segments = detector.finish()
        TestSupport.expect(segments.count == 1, "The new noise level counts as speech only until the history window has flushed")
        TestSupport.expectApproximatelyEqual(segments[0].start, 3.0)
        // Window 49 is the first whose 20-window history holds only the new level.
        TestSupport.expectApproximatelyEqual(segments[0].end, 4.9)
    }

    private static func testInterleavedSamplesMatchWindowRMS() {
        var configuration = SpeakerActivityDetector.Configuration()
        configuration.sampleRate = 100
        configuration.frameDuration = 0.1   // 10 frames per window
        var detector = SpeakerActivityDetector(configuration: configuration)

        var interleaved: [Int16] = []
        for window in 0..<30 {
            let meSpeaking = (5..<15).contains(window)
            let othersSpeaking = (20..<28).contains(window)
            for _ in 0..<10 {
                interleaved.append(meSpeaking ? 8_000 : 0)
                interleaved.append(othersSpeaking ? -6_000 : 20)
            }
        }
        // Deliver whole stereo frames in uneven chunks so partial windows carry across calls.
        var offset = 0
        for chunk in [6, 16, 102, 300, 44] {
            let end = min(interleaved.count, offset + chunk)
            detector.process(interleaved: Array(interleaved[offset..<end]))
            offset = end
        }
        detector.process(interleaved: Array(interleaved[offset...]))

        let segments = detector.finish()
        TestSupport.expectEqual(segments.map(\.speaker), [.me, .others])
        TestSupport.expectApproximatelyEqual(segments[0].start, 0.5)
        TestSupport.expectApproximatelyEqual(segments[0].end, 1.5)
        TestSupport.expectApproximatelyEqual(segments[1].start, 2.0)
        TestSupport.expectApproximatelyEqual(segments[1].end, 2.8)
    }

    // MARK: - Metadata

    private static func testMetadataRoundTrip() {
        let metadata = MeetingSessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 12.5,
            sampleRate: 16_000,
            channels: [
                .init(index: 0, speaker: .me, source: .microphone, applications: nil),
                .init(
                    index: 1,
                    speaker: .others,
                    source: .applications,
                    applications: [.init(bundleIdentifier: "com.example.meet", name: "Example Meet")]
                ),
            ],
            segments: [
                SpeakerActivitySegment(speaker: .me, start: 0.5, end: 3.2),
                SpeakerActivitySegment(speaker: .others, start: 3.4, end: 11.9),
            ]
        )

        let data: Data
        do {
            data = try metadata.jsonData()
        } catch {
            fatalError("Encoding failed: \(error)")
        }
        let json = String(decoding: data, as: UTF8.self)
        TestSupport.expect(json.contains("\"speaker\" : \"me\""), "Speaker labels must be stable strings")
        TestSupport.expect(json.contains("\"source\" : \"microphone\""), "Channel sources must be stable strings")
        TestSupport.expect(json.contains("2023-11-14T22:13:20Z"), "Dates must be ISO 8601")
        TestSupport.expect(json.contains("\"audioFileName\" : \"recording.wav\""), "Metadata must name its audio file")

        do {
            let decoded = try MeetingSessionMetadata.decode(from: data)
            TestSupport.expectEqual(decoded, metadata)
            TestSupport.expectEqual(decoded.version, MeetingSessionMetadata.currentVersion)
        } catch {
            fatalError("Decoding failed: \(error)")
        }
    }

    // MARK: - Selection

    private static func testSelectionDefaultsAndPersistence() {
        let suite = "MultiWhisprTests.MeetingSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let loaded = MeetingCaptureSelection.load(from: defaults)
        TestSupport.expectEqual(loaded.source, .allApplications)
        TestSupport.expectEqual(loaded.bundleIdentifiers, MeetingAppCatalog.defaultSelection)
        TestSupport.expect(loaded.isSelected(MeetingAppCatalog.zoom.bundleIdentifier), "Zoom must be selected by default")
        TestSupport.expect(!loaded.isSelected(MeetingAppCatalog.chrome.bundleIdentifier), "Browsers must be opt-in")
        TestSupport.expect(defaults.object(forKey: MeetingCaptureSelection.sourceStorageKey) == nil, "Loading defaults must not persist them")

        var selection = loaded
        selection.source = .allApplications
        selection.setSelected(true, bundleIdentifier: "com.example.meet")
        selection.setSelected(false, bundleIdentifier: MeetingAppCatalog.slack.bundleIdentifier)
        selection.save(to: defaults)

        let reloaded = MeetingCaptureSelection.load(from: UserDefaults(suiteName: suite)!)
        TestSupport.expectEqual(reloaded, selection)
        TestSupport.expect(reloaded.isSelected("com.example.meet"), "Custom apps must round-trip")
        TestSupport.expect(!reloaded.isSelected(MeetingAppCatalog.slack.bundleIdentifier), "Deselected apps must stay deselected")

        defaults.set("not-a-source", forKey: MeetingCaptureSelection.sourceStorageKey)
        TestSupport.expect(MeetingCaptureSelection.load(from: defaults).source == .allApplications, "Unknown sources fall back to the default")
    }

    private static func testProcessMatcherOwnership() {
        let selected: Set<String> = ["us.zoom.xos", "com.google.Chrome", "com.apple.Safari", "com.example.app.helper"]
        func owner(_ process: String) -> String? {
            MeetingProcessMatcher.owner(ofProcessBundleIdentifier: process, selectedBundleIdentifiers: selected)
        }

        TestSupport.expectEqual(owner("us.zoom.xos"), "us.zoom.xos")
        TestSupport.expectEqual(owner("com.google.Chrome.helper"), "com.google.Chrome")
        TestSupport.expectEqual(owner("com.google.Chrome.helper.renderer"), "com.google.Chrome")
        TestSupport.expect(owner("com.google.Chromecast") == nil, "A longer identifier sharing a prefix is a different app")
        TestSupport.expectEqual(owner("com.apple.WebKit.GPU"), "com.apple.Safari")
        TestSupport.expectEqual(owner("com.apple.WebKit.WebContent"), "com.apple.Safari")
        TestSupport.expectEqual(owner("com.apple.Music"), nil)
        TestSupport.expectEqual(owner(""), nil)
        TestSupport.expect(owner("com.example.app.helper.renderer") == "com.example.app.helper", "The longest matching owner wins")

        let withoutSafari = selected.subtracting(["com.apple.Safari"])
        TestSupport.expect(
            !MeetingProcessMatcher.matches(processBundleIdentifier: "com.apple.WebKit.GPU", selectedBundleIdentifiers: withoutSafari),
            "WebKit processes only count when Safari is selected"
        )
    }

    private static func testSelectionNormalization() {
        let selection = MeetingCaptureSelection(bundleIdentifiers: [" us.zoom.xos ", "", "   ", "com.example.meet"])
        TestSupport.expectEqual(selection.bundleIdentifiers, ["us.zoom.xos", "com.example.meet"])

        var mutable = selection
        mutable.setSelected(true, bundleIdentifier: "   ")
        TestSupport.expect(mutable == selection, "Blank identifiers must be ignored")
        mutable.setSelected(true, bundleIdentifier: " com.example.other ")
        TestSupport.expect(mutable.isSelected("com.example.other"), "Identifiers are trimmed before storage")
    }
}
