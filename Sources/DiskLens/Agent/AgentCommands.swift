import AppKit
import DiskLensKit

/// Everything an agent can do in DiskLens. Add a command here and the CLI, `help`, and the
/// MCP tools all get it. Each `run` is on the main actor and calls the same model code as the
/// window's buttons and lists, so the window updates live. Moving to the Trash goes through
/// the same safety labels as the Trash list: protected items are refused, "Use caution" items
/// need --caution-ok (the confirmation's checkbox), and nothing is ever deleted outright.
enum AgentCommands {
    /// The window's model, set by DiskLensApp as it starts.
    @MainActor static var model: AppModel?

    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the version, the folder chosen in the sidebar, whether a scan is running (`phase`: idle, loading, scanning or ready), the scan's totals, the Trash list, Full Disk Access and the startup disk's free space.",
                     example: "disklens status --json", readOnly: true) { _ in
            let model = try app()
            var result: JSONObject = ["app": AppInfo.name, "version": AppInfo.version,
                                      "target": model.currentTarget.path, "phase": phase(model),
                                      "trashList": ["items": model.basket.count, "bytes": model.basketBytes] as JSONObject,
                                      "trashedThisSessionBytes": model.trashedThisSession,
                                      "fullDiskAccess": FullDiskAccess.isGranted,
                                      "lens": model.lens.rawValue, "windowOpen": mainWindow() != nil]
            if model.isScanning { result["progress"] = progress(model) }
            if let tree = model.tree { result["scan"] = scanSummary(tree) }
            let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                                                .volumeAvailableCapacityForImportantUsageKey])
            result["startupDisk"] = ["freeBytes": disk?.volumeAvailableCapacityForImportantUsage ?? 0,
                                     "totalBytes": disk?.volumeTotalCapacity ?? 0] as JSONObject
            return result
        },

        AgentCommand(name: "targets list", summary: "List the folders and drives in the sidebar. Returns `targets` (path, title, selected) and `total`.",
                     example: "disklens targets list --json", readOnly: true) { _ in
            let model = try app()
            let targets = model.targets.map { target -> JSONObject in
                ["path": target.path, "title": target.title, "selected": target.id == model.selectedTarget]
            }
            return ["targets": targets, "total": targets.count]
        },

        // MARK: Scanning

        AgentCommand(name: "scan start", summary: "Scan a folder or drive, as choosing it in the sidebar does (it's added there if new). A folder scanned before loads its saved scan and rescans only what changed; --full rescans everything. Returns at once: follow it with `disklens scan status --wait 25`.",
                     params: [.init(name: "path", kind: .path, positional: true, help: "the folder to scan. Default: the folder chosen in the sidebar"),
                              .init(name: "full", kind: .boolean, help: "rescan every folder, not only the ones that changed")],
                     example: "disklens scan start ~/Downloads --json") { args in
            let model = try app()
            var path = model.currentTarget.path
            if let given = args.string("path") {
                path = try absolutePath(given)
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { throw AgentError.notFound("nothing at \(path)") }
                guard isFolder.boolValue else { throw AgentError.invalid("\(path) is a file. Scan the folder it's in") }
                // The same folder by another name (/tmp is /private/tmp) is the same sidebar item.
                let real = realPath(path)
                path = model.targets.first { realPath($0.path) == real }?.path ?? path
            }
            let full = try args.bool("full") == true
            if path != model.selectedTarget {
                model.addTarget(path: path)
            } else if model.isScanning, !full {
                return ["target": path, "phase": phase(model), "started": false, "next": "already scanning. Run `disklens scan status --wait 25`"]
            } else if full {
                model.scan()
            } else if model.tree == nil {
                // Its saved scan, caught up on what changed, as choosing it in the sidebar does.
                model.select(path)
            } else {
                model.rescanChanges()
            }
            return ["target": path, "phase": phase(model), "started": true, "full": full,
                    "next": "run `disklens scan status --wait 25` until phase is ready"]
        },

        AgentCommand(name: "scan status", summary: "Show the scan of the folder chosen in the sidebar: `phase` (idle, loading, scanning or ready), progress while scanning, and totals once ready. --wait waits up to that many seconds for a running scan to finish.",
                     params: [.init(name: "wait", kind: .integer, help: "seconds to wait for the scan to finish, 0–25 (default 0)")],
                     example: "disklens scan status --wait 25 --json", readOnly: true) { args in
            let model = try app()
            let wait = try args.int("wait", default: 0)
            guard (0...25).contains(wait) else { throw AgentError.usage("--wait must be 0 to 25 seconds") }
            let deadline = Date().addingTimeInterval(TimeInterval(wait))
            while busy(model), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            var result: JSONObject = ["target": model.currentTarget.path, "phase": phase(model)]
            if model.isScanning { result["progress"] = progress(model) }
            if let tree = model.tree { result["scan"] = scanSummary(tree) }
            return result
        },

        AgentCommand(name: "scan cancel", summary: "Stop the running scan, as the Stop button does. The last finished scan stays.",
                     example: "disklens scan cancel --json") { _ in
            let model = try app()
            let wasScanning = model.isScanning
            model.cancelScan()
            return ["stopped": wasScanning, "target": model.currentTarget.path]
        },

        // MARK: Items

        AgentCommand(name: "items list", summary: "List what's directly inside a scanned folder, largest first, as the treemap shows it. Returns `folder`, `items` (path, name, kind, bytes, safety, canTrash), `total` and `nextOffset` when there are more.",
                     params: [.init(name: "path", kind: .path, positional: true, help: "a folder in the scan. Default: the scanned folder itself"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "disklens items list ~/Library --limit 10 --json", readOnly: true) { args in
            if let empty = try unscanned("items") { return empty }
            let (model, tree) = try scanned()
            let folder = try args.string("path").map { try node($0, in: tree) } ?? FileTree.root
            guard tree.kind(folder).isContainer else { throw AgentError.invalid("\(tree.path(folder)) is a file. Use `disklens items show`") }
            var result = try page(tree.visibleChildren(folder), args) { item($0, tree, model) }
            result["folder"] = item(folder, tree, model)
            return result
        },

        AgentCommand(name: "items largest", summary: "List the largest files anywhere under a scanned folder, as Largest Files does (app and document packages count as one item). Returns `items`, and `nextOffset` when there are more.",
                     params: [.init(name: "under", kind: .path, help: "a folder in the scan. Default: the scanned folder itself"),
                              .init(name: "search", help: "only names containing this"),
                              .init(name: "min-mb", kind: .integer, help: "only items of at least this many megabytes"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "disklens items largest --under ~/Downloads --min-mb 100 --limit 20 --json", readOnly: true) { args in
            if let empty = try unscanned("items") { return empty }
            let (model, tree) = try scanned()
            let under = try args.string("under").map { try node($0, in: tree) } ?? FileTree.root
            var filter = FileFilter()
            filter.search = args.string("search") ?? ""
            let minimum = try args.int("min-mb", default: 0)
            guard minimum >= 0 else { throw AgentError.usage("--min-mb must be 0 or more") }
            filter.minimumSize = Int64(minimum) * 1_000_000
            let limit = try args.int("limit", default: 50), offset = try args.int("offset", default: 0)
            guard limit > 0, offset >= 0, limit + offset <= 2000 else {
                throw AgentError.usage("--limit must be 1 or more, --offset 0 or more, and together at most 2000")
            }
            // One more than the page, so a next page shows up as nextOffset.
            let found = tree.largestFiles(under: under, limit: offset + limit + 1, filter: filter)
            let slice = found.dropFirst(offset).prefix(limit)
            var result: JSONObject = ["items": slice.map { item($0, tree, model) }, "under": tree.path(under)]
            if found.count > offset + limit { result["nextOffset"] = offset + limit }
            return result
        },

        AgentCommand(name: "items show", summary: "Show one scanned item: size, kind, file count, dates, its safety label and why, and whether it can go on the Trash list.",
                     params: [.init(name: "path", kind: .path, required: true, positional: true, help: "a file or folder in the scan")],
                     example: "disklens items show ~/Library/Caches --json", readOnly: true) { args in
            let (model, tree) = try scanned()
            let id = try node(try args.required("path"), in: tree)
            var result = item(id, tree, model)
            result["logicalBytes"] = tree.logicalSize(id)
            result["category"] = tree.category(id).rawValue
            if tree.kind(id).isContainer { result["childCount"] = tree.visibleChildren(id).count }
            let flags = tree.flags(id)
            if flags.contains(.unreadable) { result["unreadable"] = true }
            if flags.contains(.dataless) { result["inCloudOnly"] = true }
            if flags.contains(.insidePackage) { result["insidePackage"] = true }
            return result
        },

        // MARK: Suggestions

        AgentCommand(name: "suggestions list", summary: "List the Cleanup Suggestions for the current scan (app caches, logs, Xcode data, installers, old downloads…): id, title, what it is, bytes, item count and items per safety label. Returns `suggestions`, `totalBytes` and `loading`.",
                     example: "disklens suggestions list --json", readOnly: true) { _ in
            if let empty = try unscanned("suggestions") { return empty }
            let (model, tree) = try scanned()
            let suggestions = model.suggestions.items.map { suggestion -> JSONObject in
                var levels: [String: Int] = [:]
                for id in suggestion.items { levels[safetyName(tree.safety(id)), default: 0] += 1 }
                return ["id": suggestion.id, "title": suggestion.title, "detail": suggestion.detail,
                        "bytes": suggestion.bytes, "items": suggestion.items.count, "safety": levels,
                        "canTrash": suggestion.canTrash]
            }
            return ["suggestions": suggestions, "total": suggestions.count, "totalBytes": model.suggestions.totalBytes,
                    "loading": model.suggestions.isLoading]
        },

        AgentCommand(name: "suggestions show", summary: "List the items in one Cleanup Suggestion, largest first, with each one's safety label. Returns `items`, `total` and `nextOffset`.",
                     params: [.init(name: "id", required: true, positional: true, help: "the suggestion's id, from `disklens suggestions list` (like caches or logs)"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "disklens suggestions show caches --limit 20 --json", readOnly: true) { args in
            let (model, tree) = try scanned()
            let suggestion = try findSuggestion(try args.required("id"), model)
            var result = try page(suggestion.items, args) { item($0, tree, model) }
            result["id"] = suggestion.id
            result["title"] = suggestion.title
            result["detail"] = suggestion.detail
            result["canTrash"] = suggestion.canTrash
            return result
        },

        // MARK: Trash list

        AgentCommand(name: "trash list", summary: "List the items on the Trash list (the panel on the right): what `disklens trash move --yes` would move. Returns `items`, `total` and `bytes` (counted once when items are inside each other).",
                     example: "disklens trash list --json", readOnly: true) { _ in
            if let empty = try unscanned("items") { return empty }
            let (model, tree) = try scanned()
            return ["items": model.basket.map { item($0, tree, model) }, "total": model.basket.count, "bytes": model.basketBytes]
        },

        AgentCommand(name: "trash add", summary: "Put an item, or every item in a Cleanup Suggestion, on the Trash list. Nothing moves yet. Protected items are skipped, as in the window.",
                     params: [.init(name: "path", kind: .path, positional: true, help: "a file or folder in the scan"),
                              .init(name: "suggestion", help: "instead of a path: add every item of this suggestion (its Add All button)")],
                     example: "disklens trash add ~/Downloads/Installer.dmg --json") { args in
            let (model, tree) = try scanned()
            let ids: [NodeID]
            if let path = args.string("path") {
                guard args.string("suggestion") == nil else { throw AgentError.usage("give a path or --suggestion, not both") }
                ids = [try node(path, in: tree)]
            } else if let id = args.string("suggestion") {
                let suggestion = try findSuggestion(id, model)
                guard suggestion.canTrash else { throw AgentError.invalid("\"\(suggestion.title)\" can't go to the Trash: \(suggestion.detail)") }
                ids = suggestion.items
            } else {
                throw AgentError.usage("give a path or --suggestion. Example: disklens trash add ~/Downloads/Installer.dmg")
            }
            let before = Set(model.basket)
            model.addToBasket(ids)
            let added = ids.filter { model.basket.contains($0) && !before.contains($0) }
            let skipped = ids.filter { !model.basket.contains($0) }.map { id -> JSONObject in
                ["path": tree.path(id), "why": refusal(id, tree)]
            }
            return ["added": added.map { tree.path($0) }, "alreadyListed": ids.filter { before.contains($0) }.count,
                    "skipped": skipped, "trashList": ["items": model.basket.count, "bytes": model.basketBytes] as JSONObject]
        },

        AgentCommand(name: "trash remove", summary: "Take an item off the Trash list, or clear the list with --all, as the × and Clear buttons do. Nothing is deleted.",
                     params: [.init(name: "path", kind: .path, positional: true, help: "an item on the Trash list"),
                              .init(name: "all", kind: .boolean, help: "clear the whole list")],
                     example: "disklens trash remove ~/Downloads/Installer.dmg --json") { args in
            let (model, tree) = try scanned()
            if try args.bool("all") == true {
                let count = model.basket.count
                model.basket.removeAll()
                return ["removed": count, "trashList": ["items": 0, "bytes": 0] as JSONObject]
            }
            guard let path = args.string("path") else { throw AgentError.usage("give a path, or --all to clear the list") }
            let id = try node(path, in: tree)
            guard model.basket.contains(id) else { throw AgentError.notFound("\(tree.path(id)) isn't on the Trash list. Run `disklens trash list`") }
            model.removeFromBasket(id)
            return ["removed": 1, "path": tree.path(id), "trashList": ["items": model.basket.count, "bytes": model.basketBytes] as JSONObject]
        },

        AgentCommand(name: "trash move", summary: "Move an item, or everything on the Trash list, to the Finder Trash (it can be put back from there; nothing is deleted outright). Protected items are refused; items labeled Use caution also need --caution-ok. Without --yes it only shows what it would move.",
                     params: [.init(name: "path", kind: .path, positional: true, help: "a file or folder in the scan. Default: everything on the Trash list"),
                              .init(name: "caution-ok", kind: .boolean, help: "the person understands that items labeled Use caution hold app or system data, and moving them can reset or break apps")],
                     example: "disklens trash move ~/Downloads/Installer.dmg --yes --json", destructive: true) { args in
            try await moveToTrash(args)
        },

        // MARK: Window

        AgentCommand(name: "window open", summary: "Bring up the DiskLens window, on a lens and with an item selected if you give them.",
                     params: [.init(name: "lens", help: "browse, largest, leastUsed, suggestions or duplicates"),
                              .init(name: "reveal", kind: .path, help: "a scanned item to show and select")],
                     example: "disklens window open --lens suggestions --json") { args in
            let model = try app()
            if let raw = args.string("lens") {
                guard let lens = Lens.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) else {
                    throw AgentError.usage("--lens must be one of \(Lens.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                model.lens = lens
            }
            var revealed: String?
            if let path = args.string("reveal") {
                let (_, tree) = try scanned()
                let id = try node(path, in: tree)
                model.reveal(id)
                revealed = tree.path(id)
            }
            if let window = mainWindow() {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            } else {
                #if DEBUG
                // A test copy runs as a bare binary: reopening "the app" would open its build folder.
                if AgentSocket.isTestRun { throw AgentError.invalid("a test copy has no window to bring up (it opens none on its own)") }
                #endif
                HubMenu.openMainWindow()
            }
            return ["open": true, "lens": model.lens.rawValue, "revealed": revealed.map { $0 as Any } ?? NSNull()]
        },
    ]

    // MARK: The model and the scan

    @MainActor
    static func app() throws -> AppModel {
        guard let model else { throw AgentError.unavailable("DiskLens is still starting. Try again in a moment") }
        return model
    }

    /// The model and its finished scan, or an error saying how to get one.
    @MainActor
    static func scanned() throws -> (AppModel, FileTree) {
        let model = try app()
        guard let tree = model.tree else {
            if busy(model) {
                throw AgentError.notScanned("\(model.currentTarget.path) is still being scanned. Run `disklens scan status --wait 25`, then try again")
            }
            throw AgentError.notScanned("\(model.currentTarget.path) hasn't been scanned. Run `disklens scan start \(model.currentTarget.path)` first")
        }
        return (model, tree)
    }

    /// A list asked for before there's a scan: empty, with what to do (a fresh copy has none).
    @MainActor
    static func unscanned(_ key: String) throws -> JSONObject? {
        let model = try app()
        guard model.tree == nil else { return nil }
        let hint = busy(model) ? "\(model.currentTarget.path) is still being scanned. Run `disklens scan status --wait 25`, then try again"
            : "\(model.currentTarget.path) hasn't been scanned. Run `disklens scan start \(model.currentTarget.path)` first"
        return [key: [JSONObject](), "total": 0, "phase": phase(model), "hint": hint]
    }

    @MainActor
    static func busy(_ model: AppModel) -> Bool {
        switch model.phase {
        case .loading, .scanning: true
        case .idle, .ready: false
        }
    }

    @MainActor
    static func phase(_ model: AppModel) -> String {
        switch model.phase {
        case .idle: "idle"
        case .loading: "loading"
        case .scanning: "scanning"
        case .ready: "ready"
        }
    }

    @MainActor
    static func progress(_ model: AppModel) -> JSONObject {
        ["files": model.progress.files, "folders": model.progress.folders, "bytes": model.progress.bytes]
    }

    static func scanSummary(_ tree: FileTree) -> JSONObject {
        ["path": tree.rootPath, "scannedAt": JSON.date(tree.scannedAt), "bytes": tree.size(FileTree.root),
         "files": tree.fileCount(FileTree.root), "unreadableFolders": tree.unreadableFolders.count]
    }

    /// The scanned item at `path`. The same place by another name (/tmp is /private/tmp) counts.
    @MainActor
    static func node(_ path: String, in tree: FileTree) throws -> NodeID {
        let path = try absolutePath(path)
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if let id = tree.node(atPath: trimmed) { return id }
        // The same place by another name: /tmp is /private/tmp.
        let realRoot = realPath(tree.rootPath), realItem = realPath(trimmed)
        if realItem == realRoot { return FileTree.root }
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard realItem.hasPrefix(prefix) || trimmed.hasPrefix(tree.rootPath + "/") else {
            throw AgentError.notFound("\(trimmed) isn't inside the scanned folder \(tree.rootPath). "
                                      + "Run `disklens scan start <folder>` on a folder that holds it")
        }
        if realItem.hasPrefix(prefix) {
            let base = tree.rootPath.hasSuffix("/") ? tree.rootPath : tree.rootPath + "/"
            if let id = tree.node(atPath: base + realItem.dropFirst(prefix.count)) { return id }
        }
        throw AgentError.notFound("\(trimmed) isn't in the scan of \(tree.rootPath) (if it's new, run `disklens scan start`). "
                                  + "See what's there with `disklens items list`")
    }

    /// Why the Trash list won't take an item (`AppModel.canDelete` said no).
    static func refusal(_ id: NodeID, _ tree: FileTree) -> String {
        if id == FileTree.root { return "it's the scanned folder itself" }
        if tree.isRemoved(id) { return "it was already moved to the Trash" }
        return "it's protected: \(tree.safetyVerdict(id).reason ?? "macOS needs it")"
    }

    static func realPath(_ path: String) -> String {
        guard let pointer = realpath(path, nil) else { return path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    @MainActor
    static func findSuggestion(_ id: String, _ model: AppModel) throws -> Suggestion {
        if let found = model.suggestions.items.first(where: { $0.id.lowercased() == id.lowercased() }) { return found }
        let hint = model.suggestions.isLoading ? "Suggestions are still being worked out; try again in a moment"
            : "Run `disklens suggestions list`"
        throw AgentError.notFound("no suggestion \"\(id)\" in this scan. \(hint)")
    }

    // MARK: Results

    static func safetyName(_ level: SafetyLevel) -> String {
        switch level {
        case .safe: "safe"
        case .user: "user"
        case .caution: "caution"
        case .locked: "protected"
        }
    }

    static func kindName(_ kind: NodeKind) -> String {
        switch kind {
        case .file: "file"
        case .directory: "folder"
        case .package: "package"
        case .symlink: "symlink"
        case .other: "other"
        }
    }

    @MainActor
    static func item(_ id: NodeID, _ tree: FileTree, _ model: AppModel) -> JSONObject {
        let verdict = tree.safetyVerdict(id)
        var json: JSONObject = ["path": tree.path(id), "name": id == FileTree.root ? model.displayName(id) : tree.name(id),
                                "kind": kindName(tree.kind(id)), "bytes": tree.size(id), "files": tree.fileCount(id),
                                "safety": safetyName(tree.safety(id)), "safetyTitle": tree.safety(id).title,
                                "modified": JSON.date(tree.modified(id)), "lastUsed": JSON.date(model.bestLastUsed(id)),
                                "canTrash": model.canDelete(id), "onTrashList": model.basket.contains(id)]
        if let reason = verdict.reason { json["safetyReason"] = reason }
        if tree.isRemoved(id) { json["movedToTrash"] = true }
        return json
    }

    @MainActor
    static func page(_ all: [NodeID], _ args: Args, _ json: (NodeID) -> JSONObject) throws -> JSONObject {
        let limit = try args.int("limit", default: 50)
        let offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be 1 or more, and --offset 0 or more") }
        let slice = all.dropFirst(offset).prefix(limit)
        var result: JSONObject = ["items": slice.map(json), "total": all.count]
        if offset + slice.count < all.count { result["nextOffset"] = offset + slice.count }
        return result
    }

    /// MCP clients send paths as they are, so they must already be absolute.
    static func absolutePath(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw AgentError.usage("\"\(path)\" isn't a full path. Give one that starts with / or ~") }
        return expanded
    }

    @MainActor
    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
    }

    // MARK: Moving to the Trash

    /// The Trash list's checks, then the same move as its "Move to Trash…" button. The
    /// confirmation's questions become options: --yes for the button, --caution-ok for its checkbox.
    @MainActor
    static func moveToTrash(_ args: Args) async throws -> JSONObject {
        let (model, tree) = try scanned()
        guard !model.isScanning else {
            throw AgentError.busy("a scan is running. Wait for it (`disklens scan status --wait 25`), then try again")
        }
        let fromList = args.string("path") == nil
        let ids = fromList ? model.basket : [try node(args.required("path"), in: tree)]
        guard !ids.isEmpty else {
            throw AgentError.invalid("the Trash list is empty. Give a path, or add items with `disklens trash add`")
        }
        let refused = ids.filter { !model.canDelete($0) }
        guard refused.isEmpty else {
            throw AgentError.invalid("DiskLens won't move \(tree.path(refused[0])) to the Trash: \(refusal(refused[0], tree))")
        }
        let missing = ids.filter { !FileManager.default.fileExists(atPath: tree.path($0)) }
        guard missing.isEmpty else {
            throw AgentError.notFound("\(tree.path(missing[0])) is no longer there. Run `disklens scan start` to update the scan")
        }
        // Items inside another one move with it, and count once.
        let set = Set(ids)
        let top = ids.filter { !tree.lineage($0).dropLast().contains(where: set.contains) }
        let bytes = top.reduce(Int64(0)) { $0 + tree.size($1) }
        let careful = top.filter { tree.safety($0) == .caution }
        let cautionOK = try args.bool("caution-ok") == true

        guard args.confirmed else {
            var result: JSONObject = ["wouldMove": top.map { item($0, tree, model) }, "bytes": bytes, "fromTrashList": fromList,
                                      "hint": "add --yes to move these to the Trash. They can be put back from the Trash until it's emptied"]
            if !careful.isEmpty {
                result["needsCautionOk"] = careful.map { tree.path($0) }
                result["hint"] = "\(careful.count) of these \(careful.count == 1 ? "holds" : "hold") app or system data, and moving "
                    + "\(careful.count == 1 ? "it" : "them") can reset or break apps that use it. Show the person, and only with their OK add "
                    + (cautionOK ? "--yes" : "--caution-ok --yes")
            }
            return result
        }
        guard careful.isEmpty || cautionOK else {
            throw AgentError.invalid("\(careful.count == 1 ? "1 item holds" : "\(careful.count) items hold") app or system data "
                                     + "(\(tree.path(careful[0]))\(careful.count > 1 ? "…" : "")), and moving it can reset or break apps. "
                                     + "Show the person, and only with their OK add --caution-ok")
        }
        let (moved, error) = await model.moveToTrash(top)
        let failed = top.filter { !moved.contains($0) }
        var result: JSONObject = ["moved": moved.map { tree.path($0) }, "bytes": moved.reduce(Int64(0)) { $0 + tree.size($1) },
                                  "note": "the space is freed when the Trash is emptied in the Finder"]
        if !failed.isEmpty {
            result["failed"] = failed.map { tree.path($0) }
            result["error"] = error?.localizedDescription ?? "the Finder didn't move them"
        }
        return result
    }
}
