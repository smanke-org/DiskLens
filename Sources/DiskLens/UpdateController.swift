import AppKit

/// Downloads and installs the latest release from GitHub, then restarts.
///
/// This installs code fetched from the network, so nothing is trusted on the strength of
/// where it came from. Before anything is copied over the running app, the downloaded
/// bundle must:
///
/// 1. pass `codesign --verify --deep --strict`,
/// 2. carry the **same Team ID as the app that is running**, so a valid signature from
///    somebody else is refused, and
/// 3. pass Gatekeeper assessment, which means Apple notarized it.
///
/// A failure at any step aborts the update and leaves the installed app untouched.
enum UpdateController {
    private static let repository = "smanke-org/DiskLens"

    enum UpdateOutcome {
        case upToDate(current: String)
        case failed(String)
    }

    // MARK: - Entry point

    /// - Parameter silent: when true, say nothing unless there is an update to offer.
    ///   Used for the check at launch, where reporting "up to date" or a network hiccup
    ///   every time would just be noise.
    static func checkForUpdates(silent: Bool = false) {
        Task { @MainActor in
            let current = AppInfo.version
            do {
                // No release published yet (or the repository doesn't exist yet) means there
                // is nothing newer: that is "up to date", not a failure.
                guard let release = try await fetchLatestRelease() else {
                    if !silent { present(.upToDate(current: current)) }
                    return
                }
                guard isNewer(release.version, than: current) else {
                    if !silent { present(.upToDate(current: current)) }
                    return
                }
                // A version the user skipped is not raised again on its own.
                if silent, UserDefaults.standard.string(forKey: "skippedUpdateVersion") == release.version {
                    return
                }

                // The launch check never installs. It only records that something is
                // available, and the window surfaces it. Prompting from a background path
                // in a menu bar app is not safe: with no active app to own it, the modal
                // is not reliably shown and runModal() hands back its default button —
                // which silently installed an update nobody agreed to.
                if silent {
                    UpdateAvailability.shared.pending = release.version
                    return
                }

                let choice = confirmInstall(
                    newVersion: release.version,
                    current: current,
                    allowSkip: UpdateAvailability.shared.pending == release.version
                )
                switch choice {
                case .cancel:
                    return
                case .skip:
                    UserDefaults.standard.set(release.version, forKey: "skippedUpdateVersion")
                    UpdateAvailability.shared.pending = nil
                    return
                case .install:
                    break
                }

                let stagedApp = try await downloadAndStage(release)
                try verifySignature(of: stagedApp)
                try installAndRelaunch(from: stagedApp)
                // Control does not return: the app is replaced and restarted.
            } catch {
                if silent {
                    // Offline at launch is not worth interrupting anyone over.
                    NSLog("DiskLens: update check failed: \(error.localizedDescription)")
                } else {
                    present(.failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Release lookup

    private struct Release {
        let version: String
        let downloadURL: URL
    }

    private static func fetchLatestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API requests without one.
        request.setValue("DiskLens/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw fail("Could not reach GitHub to check for updates.")
        }
        // A repository with no published releases answers 404, which is not the same
        // thing as being offline and should not be reported as a network problem.
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200 else {
            throw fail("GitHub returned an error (\(http.statusCode)) while checking for updates.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw fail("The release information from GitHub could not be read.")
        }

        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        guard let urlString = dmg?["browser_download_url"] as? String,
              let url = URL(string: urlString), url.scheme == "https" else {
            throw fail("The latest release has no disk image to download.")
        }

        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, downloadURL: url)
    }

    /// Numeric component comparison, so 1.1.10 is correctly newer than 1.1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Download

    private static func downloadAndStage(_ release: Release) async throws -> URL {
        let (downloadedURL, response) = try await URLSession.shared.download(from: release.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw fail("The download failed.")
        }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiskLensUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let dmg = staging.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: downloadedURL, to: dmg)

        // Mount read-only and without opening a Finder window.
        let mountPoint = staging.appendingPathComponent("mount")
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path])
        guard attach.status == 0 else { throw fail("The downloaded disk image could not be opened.") }
        defer { run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)) ?? []
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw fail("The downloaded disk image does not contain an app.")
        }

        // Copy off the image before it is unmounted.
        let stagedApp = staging.appendingPathComponent(appName)
        try FileManager.default.copyItem(at: mountPoint.appendingPathComponent(appName), to: stagedApp)
        return stagedApp
    }

    // MARK: - Verification

    private static func verifySignature(of app: URL) throws {
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else {
            throw fail("The downloaded app's signature is not valid, so it was not installed.")
        }

        guard let downloadedTeam = teamIdentifier(of: app.path) else {
            throw fail("The downloaded app is not signed by an identifiable developer, so it was not installed.")
        }
        guard let runningTeam = teamIdentifier(of: Bundle.main.bundlePath) else {
            throw fail("This copy of the app is unsigned, so an update cannot be verified against it.")
        }
        guard downloadedTeam == runningTeam else {
            throw fail("The downloaded app is signed by a different developer (\(downloadedTeam)), so it was not installed.")
        }

        // Gatekeeper assessment: passes only if Apple notarized the build.
        let assess = run("/usr/sbin/spctl", ["-a", "-t", "exec", app.path])
        guard assess.status == 0 else {
            throw fail("The downloaded app is not notarized by Apple, so it was not installed.")
        }
    }

    private static func teamIdentifier(of path: String) -> String? {
        let result = run("/usr/bin/codesign", ["-dvvv", path])
        // codesign writes its description to stderr, which run() folds in.
        for line in result.output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    // MARK: - Install

    /// Hands the swap to a detached shell script, because the app cannot replace and
    /// relaunch itself while it is the one running.
    @MainActor
    private static func installAndRelaunch(from stagedApp: URL) throws {
        let destination = Bundle.main.bundlePath
        let staging = stagedApp.deletingLastPathComponent()
        let script = staging.appendingPathComponent("install.sh")

        // The bundle is updated *in place* rather than deleted and recreated, so the Login
        // Items registration and any privacy approvals keep pointing at the same app. A
        // backup is kept alongside only long enough to roll back a failed sync.
        let body = """
        #!/bin/sh
        # Wait for the running app to quit before replacing its bundle.
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf "\(destination).backup"
        /bin/cp -R "\(destination)" "\(destination).backup"
        if /usr/bin/rsync -a --delete "\(stagedApp.path)/" "\(destination)/"; then
          /bin/rm -rf "\(destination).backup"
        else
          /usr/bin/rsync -a --delete "\(destination).backup/" "\(destination)/"
          /bin/rm -rf "\(destination).backup"
        fi
        # Verified above, so clear the download flag to avoid a redundant prompt.
        /usr/bin/xattr -dr com.apple.quarantine "\(destination)" 2>/dev/null
        /usr/bin/open "\(destination)"
        /bin/rm -rf "\(staging.path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [script.path]
        try task.run()

        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "DiskLens.Update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - UI

    private enum ConfirmChoice: CustomStringConvertible {
        var description: String {
            switch self {
            case .install: "install"
            case .cancel: "cancel"
            case .skip: "skip"
            }
        }

        case install
        case cancel
        case skip
    }

    @MainActor
    private static func confirmInstall(newVersion: String, current: String, allowSkip: Bool) -> ConfirmChoice {
        // An accessory app has no Dock presence, and a modal it puts up cannot reliably
        // take focus — runModal() then returns its default button without ever showing
        // anything. Becoming a regular app for the duration gives the alert something to
        // belong to; the policy is restored either way.
        //
        // Restoring the old policy synchronously does not take: AppKit ignores a
        // .regular -> .accessory transition while the app is still active from the
        // modal, which would leave a menu bar app sitting in the Dock. Doing it on
        // the next runloop turn, once the alert is gone, works.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer {
            DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) }
        }

        let alert = NSAlert()
        alert.messageText = "Update to version \(newVersion)?"
        alert.informativeText = """
        You have \(current). The update will be downloaded, checked, and installed automatically.

        DiskLens will quit and reopen to finish.
        """
        // Installing takes a deliberate press of "Update and Restart", never a stray key.
        //
        // This app takes keyboard focus when the dialog opens, so a Return the user meant
        // for another app lands here. When "Update and Restart" was the default button,
        // that one keystroke installed an update from a dialog nobody had read (reproduced
        // 2026-09-13). "Not Now" is now first, so it owns Return. "Update and Restart" has
        // no key equivalent, and InstallConsent keeps it disabled until the dialog has been
        // on screen and in front for a moment, and records the press itself.
        alert.addButton(withTitle: "Not Now")
        let install = alert.addButton(withTitle: "Update and Restart")
        install.keyEquivalent = ""
        if allowSkip { alert.addButton(withTitle: "Skip This Version") }
        let consent = InstallConsent(button: install, window: alert.window)
        defer { consent.finish() }
        bringForward(alert)

        let response = alert.runModal()
        NSLog("DiskLens: update prompt response=\(response.rawValue) installPressed=\(consent.pressed)")
        if consent.pressed { return .install }
        return response == .alertThirdButtonReturn && allowSkip ? .skip : .cancel
    }

    /// Makes the app active with the alert in front, before `runModal()`.
    ///
    /// The check finishes after a network wait, by which time another app is
    /// frontmost. Asking to activate with no window of ours on screen is then
    /// refused, and the alert opened by `runModal()` sits in the background.
    /// That kept "Update and Restart" disabled (InstallConsent waits for the app
    /// to be active) until the user clicked the Dock icon. Ordering the alert's
    /// window front with the request is honoured. Reproduced and verified with a
    /// harness on macOS 27: without this, never active; with it, active and key
    /// within 0.25 s.
    @MainActor
    private static func bringForward(_ alert: NSAlert) {
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
    }

    /// Makes "Update and Restart" respond only to a deliberate press.
    ///
    /// The button starts disabled. It is enabled only after the dialog has been key, visible
    /// and unobscured, with the app active, for `delay` without a break, and it is disabled
    /// again the moment any of that stops being true. The press is recorded here rather than
    /// inferred from runModal's return value, so an install requires this button to have
    /// actually been pressed while enabled.
    @MainActor
    private final class InstallConsent: NSObject {
        private let button: NSButton
        private let window: NSWindow
        private let delay: TimeInterval
        private var timer: Timer?
        private var readySince: Date?
        private(set) var pressed = false

        init(button: NSButton, window: NSWindow, delay: TimeInterval = 1.0) {
            self.button = button
            self.window = window
            self.delay = delay
            super.init()
            button.isEnabled = false
            button.target = self
            button.action = #selector(installPressed(_:))
            let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(tick),
                              userInfo: nil, repeats: true)
            // Common modes, so it keeps firing inside runModal's modal run loop.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        @objc private func tick() {
            let ready = NSApp.isActive && window.isVisible && window.isKeyWindow
                && window.occlusionState.contains(.visible)
            if ready {
                let since = readySince ?? Date()
                readySince = since
                button.isEnabled = Date().timeIntervalSince(since) >= delay
            } else {
                readySince = nil
                button.isEnabled = false
            }
        }

        @objc private func installPressed(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            pressed = true
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }

        /// Stops the timer, which otherwise keeps this object alive.
        func finish() {
            timer?.invalidate()
            timer = nil
        }
    }

    @MainActor
    private static func present(_ outcome: UpdateOutcome) {
        let alert = NSAlert()
        switch outcome {
        case .upToDate(let current):
            alert.messageText = "You're up to date"
            alert.informativeText = "Version \(current) is the latest release."
        case .failed(let message):
            alert.messageText = "Update failed"
            alert.informativeText = message
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        bringForward(alert)
        alert.runModal()
    }
}

