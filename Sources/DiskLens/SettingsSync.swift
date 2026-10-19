import AppKit
import Foundation

/// Keeps DiskLens's settings the same on every Mac on one iCloud account, through
/// `iCloud Drive/DiskLens/Settings.plist`. Whole-document, last writer wins.
///
/// Only the settings listed in `keys` travel; everything else in the defaults domain
/// describes this Mac (which folders and drives to scan, the last one selected, and saved scans) and must never be replaced by another Mac's.
@MainActor
final class SettingsSync: ObservableObject {
    static let shared = SettingsSync()

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                // Turning sync on adopts what other Macs share; this Mac's settings are
                // uploaded only if nothing is there yet.
                localModified = nil
                start()
            } else {
                stop()
            }
        }
    }
    @Published private(set) var lastSynced: Date?
    @Published private(set) var lastSource: String?
    @Published private(set) var lastError: String?

    /// Reloads the app's own in-memory settings after another Mac's were adopted.
    var onApply: (() -> Void)?

    /// The settings that follow the user between Macs.
    static let keys = [
        "showInDock",
        "showInMenuBar",
        AppAppearance.key,
        "colorScheme",
        "visualizationStyle",
        "visualizationFraction",
        "leastUsedMinimumMB", UpdatePolicy.key, UpdateInterval.valueKey, UpdateInterval.unitKey,
    ]

    /// What each setting is when this Mac has never changed it, for settings without a
    /// registered default. Uploading these too means a Mac adopting the file never mistakes
    /// "at its default" for "missing".
    private static let fallbacks: [String: Any] = [
        "showInDock": true, "showInMenuBar": false, AppAppearance.key: AppAppearance.system.rawValue, "colorScheme": "type", "visualizationStyle": "treemap", "visualizationFraction": 0.55, "leastUsedMinimumMB": 10
    ]

    private var localModified: Date? {
        get { defaults.object(forKey: Keys.localModified) as? Date }
        set { defaults.set(newValue, forKey: Keys.localModified) }
    }

    private let defaults = UserDefaults.standard
    private var applying = false
    private var started = false
    private var writeTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastSeenFileDate: Date?
    /// The settings as last written or adopted, to tell a real change from the many writes
    /// the app makes to the same defaults domain for its own data.
    private var lastSnapshot: NSDictionary = [:]
    private var defaultsObserver: NSObjectProtocol?

    private enum Keys {
        static let enabled = "settingsSync.enabled"
        static let localModified = "settingsSync.localModified"
    }

    nonisolated static var file: URL {
        let folder: URL
        if let override = ProcessInfo.processInfo.environment["DISKLENS_SETTINGS_SYNC_FOLDER"], !override.isEmpty {
            folder = URL(fileURLWithPath: override)
        } else {
            folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/DiskLens")
        }
        return folder.appendingPathComponent("Settings.plist")
    }

    var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.file.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    /// True on a brand-new install: nothing has been stored for this app yet. Call it first
    /// thing at launch, before anything saves a setting.
    nonisolated static func domainIsEmpty() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return UserDefaults.standard.persistentDomain(forName: id)?.isEmpty ?? true
    }

    // MARK: - Lifecycle

    /// On a brand-new install, a settings file already in iCloud Drive means this user has DiskLens
    /// on another Mac: turn sync on and start from those settings, rather than the defaults.
    func adoptOnNewInstall() {
        guard !isEnabled, FileManager.default.fileExists(atPath: Self.file.path) else { return }
        NSLog("DiskLens: new install found settings in iCloud Drive; turning settings sync on")
        isEnabled = true
    }

    func start() {
        guard isEnabled, !started else { return }
        guard iCloudDriveAvailable else {
            lastError = "iCloud Drive isn't turned on for this Mac. Turn it on in System Settings › Apple Account › iCloud."
            return
        }
        started = true
        lastError = nil
        lastSnapshot = snapshot()
        pull()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in SettingsSync.shared.checkForRemoteChange() }
        }
        // Settings are saved from many places (Settings, the menu, view models), so watch
        // the defaults domain and compare the listed settings, rather than hooking each setter.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SettingsSync.shared.defaultsChanged() }
        }
    }

    private func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        writeTask?.cancel()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        lastError = nil
    }

    func syncNow() {
        guard isEnabled else { return }
        if !started { start() } else { pull() }
    }

    private func defaultsChanged() {
        guard started, !applying else { return }
        let current = snapshot()
        guard current != lastSnapshot else { return }
        lastSnapshot = current
        localModified = Self.now
        writeTask?.cancel()
        // Debounced, so a burst of changes writes once.
        writeTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            write()
        }
    }

    // MARK: - Reading and writing

    /// Every listed setting's current value, defaults included.
    private func snapshot() -> NSDictionary {
        var settings: [String: Any] = [:]
        for key in Self.keys {
            if let value = defaults.object(forKey: key) ?? Self.fallbacks[key] { settings[key] = value }
        }
        settings[UpdatePolicy.key] = UpdatePolicy.current.rawValue
        settings[UpdateInterval.valueKey] = UpdateInterval.current.value
        settings[UpdateInterval.unitKey] = UpdateInterval.current.unit.rawValue
        return settings as NSDictionary
    }

    private func checkForRemoteChange() {
        guard started else { return }
        let date = (try? Self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if date != lastSeenFileDate { pull() }
    }

    private struct Document {
        var updatedAt: Date
        var updatedBy: String
        var settings: [String: Any]
    }

    private func pull() {
        guard let remote = readRemote() else {
            // Nothing in iCloud yet: this Mac's settings become the shared copy.
            if lastError == nil { write() }
            return
        }
        if let local = localModified, local > remote.updatedAt {
            write()
        } else if localModified == nil || remote.updatedAt > localModified! {
            apply(remote)
        } else {
            noteSynced(remote)
        }
    }

    private func readRemote() -> Document? {
        guard FileManager.default.fileExists(atPath: Self.file.path) else { return nil }
        var result: Document?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: Self.file, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let updatedAt = plist["updatedAt"] as? Date,
                  let settings = plist["settings"] as? [String: Any]
            else {
                lastError = "The settings file in iCloud Drive couldn't be read."
                return
            }
            result = Document(updatedAt: updatedAt, updatedBy: plist["updatedBy"] as? String ?? "another Mac", settings: settings)
            lastError = nil
        }
        if let coordinationError { lastError = coordinationError.localizedDescription }
        lastSeenFileDate = (try? Self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return result
    }

    private func write() {
        guard isEnabled, iCloudDriveAvailable else { return }
        let updatedAt = localModified ?? Self.now
        let settings = snapshot()
        let plist: [String: Any] = ["version": 1, "updatedAt": updatedAt, "updatedBy": (Host.current().localizedName ?? ProcessInfo.processInfo.hostName), "settings": settings]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: Self.file, options: .forReplacing, error: &coordinationError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
            if localModified == nil { localModified = updatedAt }
            lastSnapshot = settings
            lastSeenFileDate = (try? Self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            noteSynced(Document(updatedAt: updatedAt, updatedBy: (Host.current().localizedName ?? ProcessInfo.processInfo.hostName), settings: [:]))
        } catch {
            lastError = "Settings couldn't be saved to iCloud Drive: \(error.localizedDescription)"
        }
    }

    private func apply(_ remote: Document) {
        applying = true
        defer { applying = false }
        // Only what the file holds: a setting missing from it keeps this Mac's value.
        for key in Self.keys {
            if let value = remote.settings[key] { defaults.set(value, forKey: key) }
        }
        lastSnapshot = snapshot()
        localModified = remote.updatedAt

        // Tell everything that reads these settings to look again.
        NotificationCenter.default.post(name: AppPresence.menuBarDidChange, object: nil)
        AppPresence.applyDock()
        AutoUpdater.shared.reloadPolicy()
        onApply?()
        noteSynced(remote)
        NSLog("DiskLens: adopted settings from \(remote.updatedBy) (\(remote.updatedAt))")
    }

    private func noteSynced(_ document: Document) {
        lastSynced = Date()
        lastSource = document.updatedBy
        lastError = nil
    }

    /// Whole seconds, so a date read back from the file compares equal to the one written.
    private static var now: Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
    }
}
