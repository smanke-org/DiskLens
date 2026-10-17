import AppKit
import DiskLensKit
import Observation

@Observable
@MainActor
final class SuggestionsModel {
    private(set) var items: [Suggestion] = []
    private(set) var isLoading = false
    private var generation = 0

    func refresh(_ tree: FileTree) {
        generation += 1
        let current = generation
        isLoading = true
        Task {
            let found = await Task.detached { CleanupSuggestions.find(in: tree) }.value
            guard current == generation else { return }
            items = found
            isLoading = false
        }
    }

    var totalBytes: Int64 { items.filter(\.canTrash).reduce(0) { $0 + $1.bytes } }
}

@Observable
@MainActor
final class DuplicatesModel {
    enum State {
        case idle
        case running(DuplicateFinder)
        case done
    }

    private(set) var state: State = .idle
    private(set) var groups: [DuplicateGroup] = []
    private(set) var progress = DuplicateFinder.Progress(filesToCheck: 0, filesChecked: 0)
    /// The folder the last search covered.
    private(set) var scope: NodeID = FileTree.root
    private var timer: Timer?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }

    func start(_ tree: FileTree, under root: NodeID) {
        cancel()
        let finder = DuplicateFinder()
        state = .running(finder)
        scope = root
        groups = []
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .running(let current) = self.state else { return }
                self.progress = current.progress
            }
        }
        Task {
            let found = await finder.find(in: tree, under: root)
            timer?.invalidate()
            guard case .running(let current) = state, current === finder else { return }
            groups = found
            state = .done
        }
    }

    func cancel() {
        if case .running(let finder) = state { finder.cancel() }
        timer?.invalidate()
        state = groups.isEmpty ? .idle : .done
    }

    func reset() {
        cancel()
        groups = []
        state = .idle
    }

    /// Drops trashed copies, and groups with only one copy left.
    func removeTrashed(_ tree: FileTree) {
        groups = groups.compactMap { group in
            let remaining = group.items.filter { !tree.isRemoved($0) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(id: group.id, size: group.size, items: remaining, cloneIDs: group.cloneIDs)
        }
    }
}

/// The last step before anything is deleted. Moving to the Trash is the only action
/// offered, Cancel is the default button so a stray Return can't trash anything, and
/// items that need care must be acknowledged with a checkbox first.
@MainActor
enum TrashConfirmation {
    static func run(items: [NodeID], tree: FileTree, window: NSWindow?, onConfirm: @escaping () -> Void) {
        let total = items.reduce(Int64(0)) { $0 + tree.size($1) }
        let careful = items.filter { tree.safety($0) == .caution }

        let alert = NSAlert()
        alert.alertStyle = careful.isEmpty ? .informational : .warning
        alert.messageText = items.count == 1
            ? "Move “\(tree.name(items[0]))” to the Trash?"
            : "Move \(items.count) items to the Trash?"
        var info = "This frees about \(Format.bytes(total)) once you empty the Trash. Until then you can put items back from the Trash."
        if !careful.isEmpty {
            let names = careful.prefix(5).map { "• \(tree.name($0)): \(tree.safetyVerdict($0).reason ?? "")" }
            let more = careful.count > 5 ? "\n…and \(careful.count - 5) more." : ""
            info += "\n\n\(careful.count == 1 ? "This item contains" : "These items contain") app or system data:\n"
                + names.joined(separator: "\n") + more
        }
        alert.informativeText = info

        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.keyEquivalent = ""
        trash.hasDestructiveAction = true

        let acknowledgement = CheckboxTarget(button: trash)
        if !careful.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "I understand this can reset or break apps that use this data."
            alert.suppressionButton?.state = .off
            alert.suppressionButton?.target = acknowledgement
            alert.suppressionButton?.action = #selector(CheckboxTarget.toggled(_:))
            trash.isEnabled = false
        }

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            _ = acknowledgement
            if response == .alertSecondButtonReturn { onConfirm() }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    @MainActor private final class CheckboxTarget: NSObject {
        let button: NSButton
        init(button: NSButton) { self.button = button }
        @objc func toggled(_ sender: NSButton) { button.isEnabled = sender.state == .on }
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func relative(_ date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "—" }
        return date.formatted(.relative(presentation: .named))
    }

    static func date(_ date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
