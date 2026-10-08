import AppKit
import DiskLensKit
import Observation

/// A folder the user can scan.
struct ScanTarget: Identifiable, Hashable {
    var path: String
    var id: String { path }
    var isHome: Bool { path == NSHomeDirectory() }
    var title: String { isHome ? "Home" : FileManager.default.displayName(atPath: path) }
    var symbol: String { isHome ? "house" : path.hasPrefix("/Volumes/") ? "externaldrive" : "folder" }
}

enum Lens: String, CaseIterable, Identifiable {
    case browse, largest, leastUsed, suggestions, duplicates
    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: "Browse"
        case .largest: "Largest Files"
        case .leastUsed: "Least Used"
        case .suggestions: "Cleanup Suggestions"
        case .duplicates: "Duplicates"
        }
    }

    var symbol: String {
        switch self {
        case .browse: "square.grid.3x3.square"
        case .largest: "arrow.up.right.square"
        case .leastUsed: "clock.badge.questionmark"
        case .suggestions: "sparkles"
        case .duplicates: "doc.on.doc"
        }
    }
}

enum VisualizationStyle: String, CaseIterable, Identifiable {
    case treemap, sunburst
    var id: String { rawValue }
    var title: String { self == .treemap ? "Treemap" : "Sunburst" }
    var symbol: String { self == .treemap ? "square.grid.2x2" : "circle.circle" }
}

enum ColorScheme: String, CaseIterable, Identifiable {
    case type, safety
    var id: String { rawValue }
    var title: String { self == .type ? "Color by Type" : "Color by Safety" }
}

@Observable
@MainActor
final class AppModel {
    enum Phase {
        case idle
        case loading
        case scanning(DiskScanner)
        case ready
    }

    var targets: [ScanTarget]
    var selectedTarget: ScanTarget.ID
    var phase: Phase = .idle
    var progress = ScanProgress(files: 0, folders: 0, bytes: 0)
    private(set) var tree: FileTree?
    /// Bumped whenever `tree` changes, so views can key caches on it.
    private(set) var treeVersion = 0

    var lens: Lens = .browse
    var focus: NodeID = FileTree.root
    var selection: NodeID?
    var hovered: NodeID?
    var filter = FileFilter()

    var style: VisualizationStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "visualizationStyle") }
    }
    var colors: ColorScheme {
        didSet { UserDefaults.standard.set(colors.rawValue, forKey: "colorScheme") }
    }

    /// Items waiting to be moved to the Trash, in the order added.
    var basket: [NodeID] = []
    var trashedThisSession: Int64 = 0

    /// Spotlight last-used dates, keyed by path; filled in as lists ask for them.
    var lastUsedDates: [String: Date] = [:]

    let suggestions = SuggestionsModel()
    let duplicates = DuplicatesModel()

    private var progressTimer: Timer?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "scanTargets") ?? []
        targets = [ScanTarget(path: NSHomeDirectory())]
            + saved.filter { $0 != NSHomeDirectory() }.map { ScanTarget(path: $0) }
        selectedTarget = NSHomeDirectory()
        style = VisualizationStyle(rawValue: UserDefaults.standard.string(forKey: "visualizationStyle") ?? "") ?? .treemap
        colors = ColorScheme(rawValue: UserDefaults.standard.string(forKey: "colorScheme") ?? "") ?? .type
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var currentTarget: ScanTarget {
        targets.first { $0.id == selectedTarget } ?? targets[0]
    }

    // MARK: Targets

    func addTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or drive to scan."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = ScanTarget(path: url.path)
        if !targets.contains(target) {
            targets.append(target)
            saveTargets()
        }
        select(target.id)
    }

    func removeTarget(_ target: ScanTarget) {
        guard !target.isHome else { return }
        targets.removeAll { $0 == target }
        saveTargets()
        if selectedTarget == target.id { select(NSHomeDirectory()) }
    }

    private func saveTargets() {
        UserDefaults.standard.set(targets.filter { !$0.isHome }.map(\.path), forKey: "scanTargets")
    }

    func select(_ id: ScanTarget.ID) {
        guard id != selectedTarget || tree == nil else { return }
        cancelScan()
        selectedTarget = id
        tree = nil
        treeVersion += 1
        phase = .loading
        Task {
            let cached = await Task.detached { ScanCache.shared.load(rootPath: id) }.value
            guard selectedTarget == id else { return }
            if let cached {
                install(cached, keepingFocus: false)
                rescanChanges()
            } else {
                scan()
            }
        }
    }

    // MARK: Scanning

    /// A full scan of the current target.
    func scan() {
        if case .scanning(let running) = phase { running.cancel() }
        let scanner = DiskScanner(root: currentTarget.path)
        runScan(scanner) { try await scanner.run() }
    }

    /// Rescans only folders that changed since the last scan; a full scan if FSEvents can't say.
    func rescanChanges() {
        guard let tree else { return scan() }
        guard !isScanning else { return }
        let target = selectedTarget
        Task {
            let changes = await Task.detached { ScanCache.shared.changes(since: tree) }.value
            guard selectedTarget == target, self.tree === tree, !isScanning else { return }
            guard let changes else { return scan() }
            guard !changes.isEmpty else { return }
            let scanner = DiskScanner(root: currentTarget.path)
            runScan(scanner) { try await scanner.rescan(tree, changes: changes) }
        }
    }

    private func runScan(_ scanner: DiskScanner, _ work: @escaping @Sendable () async throws -> FileTree) {
        let target = selectedTarget
        phase = .scanning(scanner)
        progress = ScanProgress(files: 0, folders: 0, bytes: 0)
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .scanning(let current) = self.phase else { return }
                self.progress = current.progress
            }
        }
        Task {
            let result = try? await work()
            progressTimer?.invalidate()
            guard case .scanning(let current) = phase, current === scanner, selectedTarget == target else { return }
            if let result {
                install(result, keepingFocus: tree?.rootPath == result.rootPath)
                ScanCache.shared.save(result)
            } else {
                phase = tree == nil ? .idle : .ready
            }
        }
    }

    func cancelScan() {
        if case .scanning(let scanner) = phase { scanner.cancel() }
    }

    private func install(_ newTree: FileTree, keepingFocus: Bool) {
        let previous = tree
        let focusPath = previous.map { $0.path(focus) }
        let selectionPath = selection.flatMap { id in previous.map { $0.path(id) } }
        let basketPaths = basket.compactMap { id in previous.map { $0.path(id) } }
        tree = newTree
        treeVersion += 1
        phase = .ready
        if keepingFocus {
            focus = focusPath.flatMap { newTree.node(atPath: $0) } ?? FileTree.root
            selection = selectionPath.flatMap { newTree.node(atPath: $0) }
            basket = basketPaths.compactMap { newTree.node(atPath: $0) }.filter { !newTree.isRemoved($0) }
        } else {
            focus = FileTree.root
            selection = nil
            basket = []
        }
        hovered = nil
        suggestions.refresh(newTree)
        duplicates.reset()
    }

    // MARK: Navigation

    func zoom(into id: NodeID) {
        guard let tree else { return }
        if tree.kind(id).isContainer {
            focus = id
        } else if let parent = tree.parent(id) {
            focus = parent
        }
        selection = id
    }

    func zoomOut() {
        guard let tree, let parent = tree.parent(focus) else { return }
        selection = focus
        focus = parent
    }

    /// Shows an item from a list: focuses its folder and selects it.
    func reveal(_ id: NodeID) {
        guard let tree else { return }
        if let parent = tree.parent(id) { focus = parent }
        selection = id
    }

    func revealInFinder(_ id: NodeID) {
        guard let tree else { return }
        NSWorkspace.shared.activateFileViewerSelecting([tree.url(id)])
    }

    func open(_ id: NodeID) {
        guard let tree else { return }
        NSWorkspace.shared.open(tree.url(id))
    }

    // MARK: Last used

    func lastUsed(_ id: NodeID) -> Date? {
        guard let tree else { return nil }
        return lastUsedDates[tree.path(id)]
    }

    /// The best available last-used date: Spotlight's if known, else the scan's estimate.
    func bestLastUsed(_ id: NodeID) -> Date {
        guard let tree else { return .distantPast }
        let estimate = tree.lastUsedEstimate(id)
        guard let spotlight = lastUsedDates[tree.path(id)] else { return estimate }
        return max(spotlight, tree.modified(id))
    }

    func loadLastUsed(for ids: [NodeID]) async {
        guard let tree else { return }
        let paths = ids.map { tree.path($0) }.filter { lastUsedDates[$0] == nil }
        guard !paths.isEmpty else { return }
        let found = await UsageInfo.lastUsed(paths: paths)
        lastUsedDates.merge(found) { $1 }
    }

    // MARK: Basket

    func canDelete(_ id: NodeID) -> Bool {
        guard let tree else { return false }
        return id != FileTree.root && tree.safety(id) != .locked && !tree.isRemoved(id)
    }

    func addToBasket(_ ids: [NodeID]) {
        for id in ids where canDelete(id) && !basket.contains(id) {
            basket.append(id)
        }
    }

    func removeFromBasket(_ id: NodeID) {
        basket.removeAll { $0 == id }
    }

    /// Bytes the basket would free: items inside another basket item count once.
    var basketBytes: Int64 {
        guard let tree else { return 0 }
        let set = Set(basket)
        return basket.filter { id in !tree.lineage(id).dropLast().contains(where: set.contains) }
            .reduce(0) { $0 + tree.size($1) }
    }

    /// Asks for confirmation, then moves the basket's items to the Trash.
    func confirmAndTrashBasket(in window: NSWindow?) {
        guard let tree, !basket.isEmpty else { return }
        TrashConfirmation.run(items: basket, tree: tree, window: window) { [weak self] in
            self?.trashBasket()
        }
    }

    private func trashBasket() {
        guard let tree else { return }
        let ids = basket
        let urls = ids.map { tree.url($0) }
        NSWorkspace.shared.recycle(urls) { [weak self] trashed, error in
            MainActor.assumeIsolated {
                guard let self, let current = self.tree, current === tree else { return }
                let trashedPaths = Set(trashed.keys.map(\.path))
                let done = ids.filter { trashedPaths.contains(tree.url($0).path) }
                let before = current.size(FileTree.root)
                let updated = current.removing(done)
                self.trashedThisSession += before - updated.size(FileTree.root)
                self.tree = updated
                self.treeVersion += 1
                self.basket.removeAll { done.contains($0) }
                if let selection = self.selection, updated.isRemoved(selection) { self.selection = nil }
                self.suggestions.refresh(updated)
                self.duplicates.removeTrashed(updated)
                ScanCache.shared.save(updated)
                if let error, done.count < ids.count {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Some items couldn't be moved to the Trash."
                    alert.runModal()
                }
            }
        }
    }
}
