import Foundation

/// Decides which Core Audio process objects belong to a selected app.
///
/// Browsers and Electron apps play audio from helper processes whose bundle
/// identifiers extend the app's own (`com.google.Chrome.helper`), and Safari
/// plays media from WebKit's shared GPU process, so an exact match on the
/// selected identifier would miss the audio entirely.
enum MeetingProcessMatcher {
    static let safariBundleIdentifier = "com.apple.Safari"
    static let webKitProcessPrefix = "com.apple.WebKit."

    /// The selected app that owns a process, or nil when none does.
    static func owner(
        ofProcessBundleIdentifier processBundleIdentifier: String,
        selectedBundleIdentifiers: Set<String>
    ) -> String? {
        let process = processBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !process.isEmpty else { return nil }

        if selectedBundleIdentifiers.contains(process) {
            return process
        }

        let prefixOwners = selectedBundleIdentifiers
            .filter { process.hasPrefix($0 + ".") }
            .sorted { $0.count > $1.count }
        if let owner = prefixOwners.first {
            return owner
        }

        if selectedBundleIdentifiers.contains(safariBundleIdentifier), process.hasPrefix(webKitProcessPrefix) {
            return safariBundleIdentifier
        }

        return nil
    }

    static func matches(
        processBundleIdentifier: String,
        selectedBundleIdentifiers: Set<String>
    ) -> Bool {
        owner(ofProcessBundleIdentifier: processBundleIdentifier, selectedBundleIdentifiers: selectedBundleIdentifiers) != nil
    }
}
