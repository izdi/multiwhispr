import Foundation

enum MeetingSpeaker: String, Codable, Equatable {
    case me
    case others
}

struct SpeakerActivitySegment: Codable, Equatable {
    let speaker: MeetingSpeaker
    /// Seconds from the start of the recording.
    let start: Double
    let end: Double
}

/// Energy-based voice activity detection over an aligned two-channel stream.
///
/// Channel 0 is the local microphone (`me`) and channel 1 the other
/// participants (`others`). Each channel is analysed independently in fixed
/// windows: a window is speech when its RMS exceeds both an absolute gate and
/// a multiple of the channel's recent noise floor. The noise floor is the
/// minimum window RMS over a sliding history, which keeps tracking room noise
/// through long monologues because speech always contains brief pauses.
struct SpeakerActivityDetector {
    struct Configuration: Equatable {
        var sampleRate = 16_000
        /// Analysis window length in seconds.
        var frameDuration = 0.1
        /// Windows at or below this RMS are never speech (about -48 dBFS).
        var minimumRMS: Float = 0.004
        /// Speech must exceed the noise floor by this factor (about +9.5 dB).
        var noiseFloorRatio: Float = 3
        /// Windows of history used for the noise floor estimate.
        var noiseWindowFrames = 100
        /// Same-speaker pauses shorter than this stay inside one segment.
        var mergeGap = 1.0
        /// Segments shorter than this are discarded as clicks or breaths.
        var minimumSegmentDuration = 0.3

        var framesPerWindow: Int {
            max(1, Int((Double(sampleRate) * frameDuration).rounded()))
        }

        var mergeGapWindows: Int {
            max(0, Int((mergeGap / frameDuration).rounded()))
        }

        var minimumSegmentWindows: Int {
            max(1, Int((minimumSegmentDuration / frameDuration).rounded()))
        }
    }

    private struct WindowRange {
        var start: Int
        var end: Int
    }

    private struct ChannelTracker {
        let speaker: MeetingSpeaker
        var recentRMS: [Float] = []
        var openRange: WindowRange?
        var ranges: [WindowRange] = []
        var sumOfSquares: Double = 0
        var accumulatedSamples = 0

        init(speaker: MeetingSpeaker) {
            self.speaker = speaker
        }

        mutating func observe(rms: Float, windowIndex: Int, configuration: Configuration) {
            recentRMS.append(rms)
            if recentRMS.count > configuration.noiseWindowFrames {
                recentRMS.removeFirst(recentRMS.count - configuration.noiseWindowFrames)
            }
            let noiseFloor = recentRMS.min() ?? 0
            let threshold = max(configuration.minimumRMS, noiseFloor * configuration.noiseFloorRatio)

            if rms > threshold {
                if openRange == nil {
                    openRange = WindowRange(start: windowIndex, end: windowIndex + 1)
                } else {
                    openRange?.end = windowIndex + 1
                }
            } else if let range = openRange {
                ranges.append(range)
                openRange = nil
            }
        }

        mutating func finish(configuration: Configuration) -> [SpeakerActivitySegment] {
            if let range = openRange {
                ranges.append(range)
                openRange = nil
            }

            var merged: [WindowRange] = []
            for range in ranges {
                if let last = merged.last, range.start - last.end < configuration.mergeGapWindows {
                    merged[merged.count - 1].end = range.end
                } else {
                    merged.append(range)
                }
            }

            return merged
                .filter { $0.end - $0.start >= configuration.minimumSegmentWindows }
                .map { range in
                    SpeakerActivitySegment(
                        speaker: speaker,
                        start: Self.seconds(forWindow: range.start, configuration: configuration),
                        end: Self.seconds(forWindow: range.end, configuration: configuration)
                    )
                }
        }

        private static func seconds(forWindow index: Int, configuration: Configuration) -> Double {
            (Double(index) * configuration.frameDuration * 1_000).rounded() / 1_000
        }
    }

    let configuration: Configuration
    private var me = ChannelTracker(speaker: .me)
    private var others = ChannelTracker(speaker: .others)
    private var windowIndex = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Consumes interleaved 16-bit frames (`[me, others, me, others, ...]`).
    mutating func process(interleaved samples: [Int16]) {
        let framesPerWindow = configuration.framesPerWindow
        var index = 0
        while index + 1 < samples.count {
            let meSample = Double(samples[index]) / 32_768
            let othersSample = Double(samples[index + 1]) / 32_768
            me.sumOfSquares += meSample * meSample
            others.sumOfSquares += othersSample * othersSample
            me.accumulatedSamples += 1
            others.accumulatedSamples += 1
            index += 2

            if me.accumulatedSamples >= framesPerWindow {
                flushWindow()
            }
        }
    }

    /// Feeds one analysis window per channel directly. Tests and callers with
    /// their own level metering use this instead of raw samples.
    mutating func processWindow(meRMS: Float, othersRMS: Float) {
        me.observe(rms: meRMS, windowIndex: windowIndex, configuration: configuration)
        others.observe(rms: othersRMS, windowIndex: windowIndex, configuration: configuration)
        windowIndex += 1
    }

    /// Flushes any partial window and returns all segments sorted by start.
    mutating func finish() -> [SpeakerActivitySegment] {
        if me.accumulatedSamples > 0 {
            flushWindow()
        }
        let segments = me.finish(configuration: configuration) + others.finish(configuration: configuration)
        return segments.sorted { lhs, rhs in
            if lhs.start != rhs.start {
                return lhs.start < rhs.start
            }
            return lhs.speaker.rawValue < rhs.speaker.rawValue
        }
    }

    private mutating func flushWindow() {
        let meRMS = Float(sqrt(me.sumOfSquares / Double(max(1, me.accumulatedSamples))))
        let othersRMS = Float(sqrt(others.sumOfSquares / Double(max(1, others.accumulatedSamples))))
        me.sumOfSquares = 0
        others.sumOfSquares = 0
        me.accumulatedSamples = 0
        others.accumulatedSamples = 0
        processWindow(meRMS: meRMS, othersRMS: othersRMS)
    }
}
