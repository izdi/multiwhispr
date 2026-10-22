import Foundation

/// Sidecar description of a meeting recording, saved as `session.json` next
/// to the audio file so a later transcription step knows which channel is
/// which and when each side was speaking.
struct MeetingSessionMetadata: Codable, Equatable {
    static let currentVersion = 1
    static let audioFileName = "recording.wav"
    static let metadataFileName = "session.json"

    struct CapturedApplication: Codable, Equatable {
        let bundleIdentifier: String
        let name: String
    }

    enum ChannelSource: String, Codable, Equatable {
        case microphone
        case applications
        case systemAudio
    }

    struct Channel: Codable, Equatable {
        /// Zero-based channel index inside the audio file.
        let index: Int
        let speaker: MeetingSpeaker
        let source: ChannelSource
        /// Applications whose audio feeds this channel, when the source is a
        /// fixed set of applications.
        let applications: [CapturedApplication]?
    }

    let version: Int
    let startedAt: Date
    /// Recording length in seconds.
    let duration: Double
    let sampleRate: Int
    let audioFileName: String
    let channels: [Channel]
    /// Speaker activity sorted by start time. Segments of different speakers
    /// may overlap when people talk at the same time.
    let segments: [SpeakerActivitySegment]

    init(
        version: Int = MeetingSessionMetadata.currentVersion,
        startedAt: Date,
        duration: Double,
        sampleRate: Int,
        audioFileName: String = MeetingSessionMetadata.audioFileName,
        channels: [Channel],
        segments: [SpeakerActivitySegment]
    ) {
        self.version = version
        self.startedAt = startedAt
        self.duration = duration
        self.sampleRate = sampleRate
        self.audioFileName = audioFileName
        self.channels = channels
        self.segments = segments
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func jsonData() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    static func decode(from data: Data) throws -> MeetingSessionMetadata {
        try makeDecoder().decode(MeetingSessionMetadata.self, from: data)
    }
}
