#if DEBUG
import AppKit

/// `DISKLENS_DEBUG_QUIT_TEST=<return|cancel|quit|suppress|off>` (trace to `DISKLENS_DEBUG_TRACE`):
/// quits as ⌘Q does, then answers the question a second later: presses Return, clicks Cancel
/// or Quit (ticking "Don't ask again" first for `suppress`), or with `off` turns the setting
/// off first. What the question looked like is traced before any answer, and a run that is
/// still going afterwards traces the setting and the activation policy.
/// `DISKLENS_DEBUG_QUIT_DELAY` (seconds, default 1) waits longer before quitting, time enough
/// to open the app again so it is active, as it is when you quit it yourself.
@MainActor
enum DebugQuitTest {
    private static var lines: [String] = []

    static func run(_ how: String) {
        trace("started policy \(NSApp.activationPolicy().rawValue)")
        let delay = ProcessInfo.processInfo.environment["DISKLENS_DEBUG_QUIT_DELAY"].flatMap(Double.init) ?? 1
        if delay > 1 {
            // Opening the app again makes it a regular app. With the Dock icon off, leave the
            // Dock again as the Settings switch does, keeping the front window active, so the
            // quit starts from an app with no Dock icon that you're using.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 1) {
                MainActor.assumeIsolated {
                    if !AppPresence.showInDock { AppPresence.applyDock(keepInFront: NSApp.keyWindow) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                if how == "off" { UserDefaults.standard.set(false, forKey: QuitConfirmation.key) }
                trace("quitting confirmQuit \(QuitConfirmation.isOn) policy \(NSApp.activationPolicy().rawValue) active \(NSApp.isActive)")
                let answer = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { Self.answer(how) }
                }
                RunLoop.main.add(answer, forMode: .common)
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        trace("still running; confirmQuit \(QuitConfirmation.isOn); policy \(NSApp.activationPolicy().rawValue) active \(NSApp.isActive)")
                    }
                }
            }
        }
    }

    private static func trace(_ s: String) {
        lines.append(s)
        guard let path = ProcessInfo.processInfo.environment["DISKLENS_DEBUG_TRACE"] else { return }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func answer(_ how: String) {
        guard let window = NSApp.modalWindow else { trace("no question"); return }
        var texts: [String] = []
        var buttons: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        let titles = buttons.map { "\($0.title)[\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent == "\u{1b}" ? "Esc" : $0.keyEquivalent)]" }
        trace("asked \(texts) buttons \(titles) key \(window.isKeyWindow) visible \(window.isVisible) active \(NSApp.isActive) policy \(NSApp.activationPolicy().rawValue)")
        switch how {
        case "return":
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
            // Return should leave the question up; close it with Cancel afterwards.
            let check = Timer(timeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    trace("after Return: question still up \(NSApp.modalWindow != nil)")
                    buttons.first { $0.title == "Cancel" }?.performClick(nil)
                }
            }
            RunLoop.main.add(check, forMode: .common)
        case "cancel": buttons.first { $0.title == "Cancel" }?.performClick(nil)
        case "quit", "suppress":
            if how == "suppress" { buttons.first { $0.title == "Don't ask again" }?.performClick(nil) }
            buttons.first { $0.title == "Quit" }?.performClick(nil)
        default: break
        }
    }
}
#endif
