import AppKit
import IOKit.pwr_mgt
import UserNotifications

/// Looks for updates every half hour and, depending on `UpdatePolicy`, notifies or installs.
///
/// An automatic install quits and relaunches DiskLens, so a downloaded update waits until:
/// - no app is holding the display awake (Keynote, PowerPoint, screen sharing and video
///   players do this while they present or play), and
/// - there has been no keyboard or mouse input for 2 minutes.
@MainActor
final class AutoUpdater: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AutoUpdater()

    @Published var policy = UpdatePolicy.current {
        didSet {
            guard policy != oldValue else { return }
            UpdatePolicy.current = policy
            if policy != .off { requestNotificationPermission(); check() }
            if policy != .automatic { staged = nil }
        }
    }

    /// A verified update waiting for a quiet moment.
    @Published private(set) var staged: (version: String, app: URL)?
    @Published private(set) var lastError: String?
    /// Without notifications, "Ask me first" can only use the menu, and the note after an
    /// automatic update never appears.
    @Published private(set) var notificationsAllowed = true

    private var checkTimer: Timer?
    private var idleTimer: Timer?
    private var checking = false

    // Overridable for testing, so a run doesn't take half an hour.
    private let checkInterval = TimeInterval(ProcessInfo.processInfo.environment["DISKLENS_UPDATE_CHECK_SECONDS"].flatMap(Double.init) ?? 30 * 60)
    private let userIdle = TimeInterval(ProcessInfo.processInfo.environment["DISKLENS_UPDATE_USER_IDLE_SECONDS"].flatMap(Double.init) ?? 2 * 60)

    private static let installedFromKey = "update.autoInstalledFrom"
    private static let notifiedVersionKey = "update.notifiedVersion"
    nonisolated private static let category = "update"
    private static let installAction = "install"

    func start() {
        UNUserNotificationCenter.current().delegate = self
        let install = UNNotificationAction(identifier: Self.installAction, title: "Install", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [install], intentIdentifiers: []),
        ])
        if policy != .off { requestNotificationPermission() }
        announceIfJustUpdated()

        // A few seconds after launch, so startup isn't waiting on the network.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { AutoUpdater.shared.check() }
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { _ in
            Task { @MainActor in AutoUpdater.shared.check() }
        }
    }

    /// Follows a policy that arrived from another Mac.
    func reloadPolicy() {
        let stored = UpdatePolicy.current
        if policy != stored { policy = stored }
    }

    /// Install a waiting (or available) update now, because the user asked to.
    func installNow() {
        if let staged {
            install(staged.app, version: staged.version)
        } else {
            UpdateController.checkForUpdates()
        }
    }

    // MARK: - Checking

    func check() {
        guard policy != .off, !checking, staged == nil else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                guard let release = try await UpdateController.latestRelease(),
                      UpdateController.isNewer(release.version, than: AppInfo.version) else {
                    UpdateAvailability.shared.pending = nil
                    return
                }
                UpdateAvailability.shared.pending = release.version
                switch policy {
                case .off:
                    return
                case .ask:
                    guard UserDefaults.standard.string(forKey: "skippedUpdateVersion") != release.version else { return }
                    notifyAvailable(release.version)
                case .automatic:
                    let app = try await UpdateController.downloadAndStage(release)
                    try UpdateController.verifyCandidate(app, version: release.version)
                    staged = (release.version, app)
                    lastError = nil
                    NSLog("DiskLens: update \(release.version) verified; waiting for a quiet moment to install")
                    waitForQuietMoment()
                }
            } catch {
                lastError = error.localizedDescription
                NSLog("DiskLens: update check failed: \(error.localizedDescription)")
                // An automatic install that failed falls back to asking, once per version.
                if policy == .automatic, let version = UpdateAvailability.shared.pending {
                    notify(id: "update-failed-\(version)", title: "DiskLens couldn't update itself",
                           body: "\(error.localizedDescription) You can install \(version) from the DiskLens menu.", installable: true)
                }
            }
        }
    }

    // MARK: - Waiting for a quiet moment

    private func waitForQuietMoment() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in AutoUpdater.shared.installIfQuiet() }
        }
        installIfQuiet()
    }

    private func installIfQuiet() {
        guard policy == .automatic, let staged else {
            idleTimer?.invalidate()
            return
        }
        guard let reason = busyReason() else {
            idleTimer?.invalidate()
            install(staged.app, version: staged.version)
            return
        }
        NSLog("DiskLens: holding update \(staged.version): \(reason)")
    }

    /// The app's own reason not to restart right now (a scan, a network switch), if any.
    var appBusyReason: (@MainActor () -> String?)?

    /// Why now would be a bad time to restart, or nil if it's fine.
    func busyReason() -> String? {
        if let reason = appBusyReason?() { return reason }
        if let app = Self.appKeepingDisplayAwake() { return "\(app) is keeping the display awake" }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < userIdle { return "the Mac is in use" }
        return nil
    }

    /// The name of a process asking macOS not to dim or sleep the display, as presentation
    /// apps, screen sharing and video players do while they run.
    nonisolated static func appKeepingDisplayAwake() -> String? {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        for (pid, assertions) in dict {
            for assertion in assertions where assertion["AssertType"] as? String == "PreventUserIdleDisplaySleep" {
                return assertion["Process Name"] as? String
                    ?? NSRunningApplication(processIdentifier: pid.int32Value)?.localizedName ?? "An app"
            }
        }
        return nil
    }

    private func install(_ app: URL, version: String) {
        do {
            // Checked again now: the staged copy may have waited hours in a folder that other
            // processes of this user can write to.
            try UpdateController.verifyCandidate(app, version: version)
            UserDefaults.standard.set(AppInfo.version, forKey: Self.installedFromKey)
            NSLog("DiskLens: installing update \(version)")
            try UpdateController.installAndRelaunch(from: app)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.installedFromKey)
            NSLog("DiskLens: update \(version) not installed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            staged = nil
        }
    }

    // MARK: - Notifications

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in AutoUpdater.shared.notificationsAllowed = allowed }
        }
    }

    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.smanke.DiskLens")") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("DiskLens: notification permission granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            Task { @MainActor in AutoUpdater.shared.refreshNotificationStatus() }
        }
    }

    /// After an automatic install, the relaunched app says what changed.
    private func announceIfJustUpdated() {
        guard let from = UserDefaults.standard.string(forKey: Self.installedFromKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.installedFromKey)
        guard from != AppInfo.version else { return }
        notify(id: "updated-\(AppInfo.version)", title: "DiskLens updated to \(AppInfo.version)",
               body: "It installed itself while your Mac wasn't in use.", installable: false)
    }

    private func notifyAvailable(_ version: String) {
        guard UserDefaults.standard.string(forKey: Self.notifiedVersionKey) != version else { return }
        UserDefaults.standard.set(version, forKey: Self.notifiedVersionKey)
        notify(id: "available-\(version)", title: "DiskLens \(version) is available",
               body: "Click to review and install it. You're on \(AppInfo.version).", installable: true)
    }

    private func notify(id: String, title: String, body: String, installable: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if installable { content.categoryIdentifier = Self.category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            NSLog("DiskLens: notification \(id) posted, error=\(error?.localizedDescription ?? "none")")
        }
    }

    // The completion-handler forms: the async ones compiled but were never called in
    // NetworkToggle, so clicking a banner silently did nothing.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let installable = response.notification.request.content.categoryIdentifier == Self.category
        DispatchQueue.main.async {
            // Clicking the banner or its Install button opens the usual confirmation,
            // so the user still sees what they're agreeing to.
            if installable { UpdateController.checkForUpdates() }
        }
        completionHandler()
    }
}
