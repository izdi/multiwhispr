import AppKit
import AVFoundation
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let uid: String
    let name: String

    var id: String { uid }

    static let systemDefaultUID = "default"

    static func available() -> [AudioInputDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        var seen = Set<String>()
        return AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .audio, position: .unspecified)
            .devices
            .compactMap { device in
                let uid = device.uniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = device.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !uid.isEmpty, !name.isEmpty, seen.insert(uid).inserted else { return nil }
                return AudioInputDevice(uid: uid, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum MicrophoneAccess {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Asks once when undecided; otherwise sends the user to System Settings.
    static func request(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            DispatchQueue.main.async { completion(false) }
        }
    }
}
