import Foundation

/// Which other-participant audio a meeting recording captures.
enum MeetingAudioSource: String, Codable, CaseIterable, Equatable {
    /// Only the applications the user picked, when they are running.
    case selectedApplications
    /// Every application except MultiWhispr itself.
    case allApplications

    var title: String {
        switch self {
        case .selectedApplications: return "Selected apps"
        case .allApplications: return "All apps"
        }
    }
}

struct MeetingAppCatalogEntry: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String

    var id: String { bundleIdentifier }
}

/// Meeting and browser apps offered up front so they can be selected before
/// they are running.
enum MeetingAppCatalog {
    static let zoom = MeetingAppCatalogEntry(bundleIdentifier: "us.zoom.xos", name: "Zoom")
    static let teams = MeetingAppCatalogEntry(bundleIdentifier: "com.microsoft.teams2", name: "Microsoft Teams")
    static let teamsClassic = MeetingAppCatalogEntry(bundleIdentifier: "com.microsoft.teams", name: "Microsoft Teams (classic)")
    static let slack = MeetingAppCatalogEntry(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
    static let webex = MeetingAppCatalogEntry(bundleIdentifier: "Cisco-Systems.Spark", name: "Webex")
    static let faceTime = MeetingAppCatalogEntry(bundleIdentifier: "com.apple.FaceTime", name: "FaceTime")
    static let chrome = MeetingAppCatalogEntry(bundleIdentifier: "com.google.Chrome", name: "Google Chrome")
    static let safari = MeetingAppCatalogEntry(bundleIdentifier: "com.apple.Safari", name: "Safari")
    static let arc = MeetingAppCatalogEntry(bundleIdentifier: "company.thebrowser.Browser", name: "Arc")
    static let firefox = MeetingAppCatalogEntry(bundleIdentifier: "org.mozilla.firefox", name: "Firefox")
    static let edge = MeetingAppCatalogEntry(bundleIdentifier: "com.microsoft.edgemac", name: "Microsoft Edge")
    static let brave = MeetingAppCatalogEntry(bundleIdentifier: "com.brave.Browser", name: "Brave")

    static let meetingApps: [MeetingAppCatalogEntry] = [zoom, teams, teamsClassic, slack, webex, faceTime]
    static let browsers: [MeetingAppCatalogEntry] = [chrome, safari, arc, firefox, edge, brave]
    static var allEntries: [MeetingAppCatalogEntry] { meetingApps + browsers }

    static let defaultSelection: Set<String> = [
        zoom.bundleIdentifier,
        teams.bundleIdentifier,
        teamsClassic.bundleIdentifier,
        slack.bundleIdentifier,
    ]

    static func entry(for bundleIdentifier: String) -> MeetingAppCatalogEntry? {
        allEntries.first { $0.bundleIdentifier == bundleIdentifier }
    }
}

/// Persisted choice of which applications count as "other participants".
struct MeetingCaptureSelection: Equatable {
    static let sourceStorageKey = "meeting_audio_source"
    static let bundleIdentifiersStorageKey = "meeting_selected_bundle_identifiers"

    var source: MeetingAudioSource
    var bundleIdentifiers: Set<String>

    init(source: MeetingAudioSource = .allApplications, bundleIdentifiers: Set<String> = MeetingAppCatalog.defaultSelection) {
        self.source = source
        self.bundleIdentifiers = Self.normalized(bundleIdentifiers)
    }

    static let `default` = MeetingCaptureSelection()

    /// A missing or malformed preference falls back to the default selection
    /// without writing anything.
    static func load(from defaults: UserDefaults) -> MeetingCaptureSelection {
        let source = (defaults.string(forKey: sourceStorageKey)).flatMap(MeetingAudioSource.init(rawValue:))
            ?? MeetingCaptureSelection.default.source
        let bundleIdentifiers: Set<String>
        if let stored = defaults.array(forKey: bundleIdentifiersStorageKey) as? [String] {
            bundleIdentifiers = normalized(Set(stored))
        } else {
            bundleIdentifiers = MeetingCaptureSelection.default.bundleIdentifiers
        }
        return MeetingCaptureSelection(source: source, bundleIdentifiers: bundleIdentifiers)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(source.rawValue, forKey: Self.sourceStorageKey)
        defaults.set(bundleIdentifiers.sorted(), forKey: Self.bundleIdentifiersStorageKey)
    }

    static func normalized(_ bundleIdentifiers: Set<String>) -> Set<String> {
        Set(
            bundleIdentifiers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    mutating func setSelected(_ selected: Bool, bundleIdentifier: String) {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if selected {
            bundleIdentifiers.insert(trimmed)
        } else {
            bundleIdentifiers.remove(trimmed)
        }
    }

    func isSelected(_ bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }
}
