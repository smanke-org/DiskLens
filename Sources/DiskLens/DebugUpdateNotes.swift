#if DEBUG
import AppKit

/// Debug builds only. `DISKLENS_DEBUG_UPDATE_NOTES=<folder>`: fetches the notes of DiskLens's
/// own releases, draws the update prompt, the What's New sheet Settings shows after an
/// automatic update, and Settings itself to PNGs, writes report.txt, and quits. It starts
/// nothing else: no sync, updates or ToolHUD menu. Run it from a copy with its own bundle
/// identifier, so it has its own settings; it refuses to run as com.smanke.DiskLens.
@MainActor
enum DebugUpdateNotes {
    static func run(folder: String) {
        guard Bundle.main.bundleIdentifier != "com.smanke.DiskLens" else {
            NSLog("DiskLens: run this test from a copy with its own bundle identifier")
            exit(2)
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").appending("\n").write(to: out.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        }
        func contentSize() -> CGSize {
            SettingsWindow.shared.debugWindow.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
        }

        Task {
            note("running \(AppInfo.version)")
            // The update prompt, as someone on 1.1.2 would see it offered 1.1.5.
            let notes = await ReleaseNotes.fetch(newAfter: "1.1.2", through: "1.1.5")
            note("notes fetched: \(notes.map { $0.version + ($0.isNew ? " new" : "") })")
            let alert = UpdateController.makeConfirmAlert(newVersion: "1.1.5", current: "1.1.2", notes: notes)
            alert.layout()
            alert.window.orderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            render(alert.window, to: out.appending(path: "update-prompt.png"))
            note("buttons: \(alert.buttons.map { "\($0.title) key='\($0.keyEquivalent)'" })")
            note("reminder box: '\(alert.suppressionButton?.title ?? "none")' on by default: \(alert.suppressionButton?.state == .on)")
            alert.window.orderOut(nil)

            // A brand-new install shows nothing.
            WhatsNew.shared.noteLaunch(newInstall: true, autoInstalledFrom: nil)
            note("new install pending: \(String(describing: WhatsNew.shared.pending))")
            // What's New in Settings after an automatic update from the release before this one.
            let previous = notes.first { UpdateController.isNewer(AppInfo.version, than: $0.version) }?.version ?? "1.1.4"
            WhatsNew.shared.noteLaunch(newInstall: false, autoInstalledFrom: previous)
            note("auto-update from \(previous) pending: \(String(describing: WhatsNew.shared.pending))")
            SettingsWindow.shared.show()
            // Before a window manager such as WindowKeeper moves it: the form's own height, or
            // the size dragged to last time.
            note("settings opened at \(contentSize()) (chosen \(String(describing: SettingsWindow.chosenSize)))")
            try? await Task.sleep(for: .seconds(4))
            render(SettingsWindow.shared.debugWindow?.attachedSheet, to: out.appending(path: "whats-new.png"))
            note("sheet shown: \(SettingsWindow.shared.debugWindow?.attachedSheet != nil)")
            if let window = SettingsWindow.shared.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }
            // OK with "Don't show this again" ticked puts it away for good.
            WhatsNew.shared.dismiss(forGood: true)
            note("after dismiss pending: \(String(describing: WhatsNew.shared.pending))")
            try? await Task.sleep(for: .seconds(1))
            let window = SettingsWindow.shared.debugWindow
            note("settings resizable: \(window?.styleMask.contains(.resizable) == true) min \(window?.contentMinSize ?? .zero) natural content \(contentSize())")
            // Scrolled to the bottom, where the Updates section and What's New… are.
            if let scroll = window?.contentView.flatMap(firstScrollView), let doc = scroll.documentView {
                doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? doc.bounds.maxY : 0))
                try? await Task.sleep(for: .seconds(1))
            }
            render(window, to: out.appending(path: "settings.png"))

            // Asked for from the What's New… button: this version's notes, no "Don't show" box.
            SettingsWindow.shared.showWhatsNew()
            try? await Task.sleep(for: .seconds(3))
            render(SettingsWindow.shared.debugWindow?.attachedSheet, to: out.appending(path: "whats-new-asked.png"))
            note("asked sheet shown: \(SettingsWindow.shared.debugWindow?.attachedSheet != nil)")
            if let window = SettingsWindow.shared.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }

            // Dragged bigger: the form fills the window, and the size is kept.
            if let window {
                window.setContentSize(NSSize(width: 640, height: 420))
                SettingsWindow.shared.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
                // Drawn straight away: a window manager (WindowKeeper) may put the window back.
                window.displayIfNeeded()
                render(window, to: out.appending(path: "settings-dragged.png"))
                note("dragged content \(contentSize()) chosen \(String(describing: SettingsWindow.chosenSize))")
                // The smallest it can be dragged to: the form's width, 280 points high.
                note("smallest content \(window.contentMinSize)")
            }
            note("done")
            exit(0)
        }
    }

    private static func firstScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = firstScrollView(sub) { return found } }
        return nil
    }

    private static func render(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
