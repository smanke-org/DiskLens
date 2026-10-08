import DiskLensKit
import Foundation

// Temporary command-line driver until the app UI exists: scans a folder and prints a summary.
let path = CommandLine.arguments.dropFirst().first ?? NSHomeDirectory()
let scanner = Scanner(root: path)
let start = Date()
guard let tree = scanner.scanSync() else { exit(1) }
let seconds = Date().timeIntervalSince(start)
print("\(tree.count) items, \(tree.size(FileTree.root) / 1024) KB in \(String(format: "%.1f", seconds)) s; \(tree.unreadableFolders.count) unreadable folders")
for child in tree.childrenBySize(FileTree.root).prefix(15) {
    print(String(format: "%12lld KB  %-8@ %@", tree.size(child) / 1024, "\(tree.safety(child))" as NSString, tree.name(child) as NSString))
}
