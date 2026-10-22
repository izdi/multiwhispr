import Foundation

/// Places PCM chunks from one capture source on a shared timeline.
///
/// The microphone and application audio arrive from independent capture
/// pipelines with their own latency and buffer sizes. Each chunk carries a
/// presentation timestamp on the host clock; this type uses that timestamp to
/// insert silence where a source was quiet or late, so two tracks can later be
/// interleaved sample-for-sample. Audio is never dropped except when a source
/// runs ahead of the timeline by more than the tolerance.
struct AlignedTrack {
    let sampleRate: Int
    let toleranceFrames: Int
    private(set) var pending: [Int16] = []
    /// Frames placed on the timeline so far, including frames already drained.
    private(set) var placedFrames = 0
    private var hasReceivedAudio = false

    init(sampleRate: Int, tolerance: Double = 0.1) {
        self.sampleRate = sampleRate
        toleranceFrames = max(0, Int((Double(sampleRate) * tolerance).rounded()))
    }

    /// Appends samples that start at `timestamp` seconds on the shared timeline.
    /// A `nil` timestamp appends directly after the previous chunk.
    mutating func append(_ samples: [Int16], at timestamp: Double?) {
        guard !samples.isEmpty else { return }
        var remaining = samples[...]

        if let timestamp {
            let expected = frameIndex(at: timestamp)
            let offset = expected - placedFrames
            if offset > 0 && (!hasReceivedAudio || offset > toleranceFrames) {
                padSilence(frames: offset)
            } else if offset < -toleranceFrames {
                remaining = remaining.dropFirst(min(remaining.count, -offset))
            }
        }

        hasReceivedAudio = true
        pending.append(contentsOf: remaining)
        placedFrames += remaining.count
    }

    /// Extends the track with silence until it covers `timestamp` seconds.
    mutating func padSilence(upTo timestamp: Double) {
        let target = frameIndex(at: timestamp)
        if target > placedFrames {
            padSilence(frames: target - placedFrames)
        }
    }

    mutating func padSilence(frames: Int) {
        guard frames > 0 else { return }
        pending.append(contentsOf: repeatElement(0, count: frames))
        placedFrames += frames
    }

    mutating func drain(_ count: Int) -> [Int16] {
        let available = min(max(0, count), pending.count)
        guard available > 0 else { return [] }
        let drained = Array(pending.prefix(available))
        pending.removeFirst(available)
        return drained
    }

    private func frameIndex(at seconds: Double) -> Int {
        Int((max(0, seconds) * Double(sampleRate)).rounded())
    }
}

/// Keeps two aligned tracks and interleaves the span both have covered.
///
/// Channel 0 is the primary track (the local microphone) and channel 1 the
/// secondary track (other participants). A stalled source is padded with
/// silence by `catchUp` so it can never block the other track from being
/// written.
struct DualTrackAligner {
    let sampleRate: Int
    private(set) var primary: AlignedTrack
    private(set) var secondary: AlignedTrack

    init(sampleRate: Int = 16_000, tolerance: Double = 0.1) {
        self.sampleRate = sampleRate
        primary = AlignedTrack(sampleRate: sampleRate, tolerance: tolerance)
        secondary = AlignedTrack(sampleRate: sampleRate, tolerance: tolerance)
    }

    /// Frames covered by the longer track, including frames already drained.
    var placedFrames: Int {
        max(primary.placedFrames, secondary.placedFrames)
    }

    mutating func appendPrimary(_ samples: [Int16], at timestamp: Double?) {
        primary.append(samples, at: timestamp)
    }

    mutating func appendSecondary(_ samples: [Int16], at timestamp: Double?) {
        secondary.append(samples, at: timestamp)
    }

    /// Pads any track that lags more than `maxLag` seconds behind `now`.
    mutating func catchUp(to now: Double, maxLag: Double) {
        let target = now - maxLag
        guard target > 0 else { return }
        primary.padSilence(upTo: target)
        secondary.padSilence(upTo: target)
    }

    /// Returns interleaved frames `[p0, s0, p1, s1, ...]` for the span both
    /// tracks have covered.
    mutating func drainInterleaved() -> [Int16] {
        let frames = min(primary.pending.count, secondary.pending.count)
        guard frames > 0 else { return [] }
        let primarySamples = primary.drain(frames)
        let secondarySamples = secondary.drain(frames)
        var interleaved = [Int16](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            interleaved[index * 2] = primarySamples[index]
            interleaved[index * 2 + 1] = secondarySamples[index]
        }
        return interleaved
    }

    /// Pads the shorter track to the longer one and drains everything left.
    mutating func finish() -> [Int16] {
        let target = placedFrames
        primary.padSilence(frames: target - primary.placedFrames)
        secondary.padSilence(frames: target - secondary.placedFrames)
        return drainInterleaved()
    }
}
