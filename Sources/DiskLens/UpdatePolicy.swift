import Foundation

/// What DiskLens does when a newer release appears.
enum UpdatePolicy: String, CaseIterable {
    /// Download, verify and install on its own, while the Mac isn't being used.
    case automatic
    /// Say so (menu item and notification) and wait for the user to choose.
    case ask
    /// Don't look for updates; Check for Updates still works.
    case off

    var title: String {
        switch self {
        case .automatic: return "Install automatically"
        case .ask: return "Ask me first"
        case .off: return "Don't check"
        }
    }

    static let key = "updatePolicy"

    static var current: UpdatePolicy {
        get {
            if let raw = UserDefaults.standard.string(forKey: key), let policy = UpdatePolicy(rawValue: raw) { return policy }
            // Earlier versions had only an on/off switch for checking.
            if UserDefaults.standard.object(forKey: "checkForUpdatesAutomatically") as? Bool == false { return .off }
            return .ask
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
