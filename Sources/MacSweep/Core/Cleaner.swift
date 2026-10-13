import Foundation

struct CleanItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
    var isSelected: Bool
    var name: String { url.lastPathComponent }
}

struct CleanResult: Sendable {
    var removed = 0
    var freed: Int64 = 0
    var failures: [String] = []
    var movedToTrash = true

    var summary: String {
        var text = "Removed \(removed) item\(removed == 1 ? "" : "s") (\(FileUtils.format(freed)))"
        if movedToTrash && removed > 0 { text += " — moved to Trash. Empty the Trash to reclaim the space." }
        if !failures.isEmpty { text += "\n\(failures.count) item(s) could not be removed." }
        return text
    }
}

enum Cleaner {
    static let deletePermanentlyKey = "deletePermanently"

    static var deletePermanently: Bool {
        UserDefaults.standard.bool(forKey: deletePermanentlyKey)
    }

    /// Folders that must never be removed themselves (only their contents).
    private static let protectedRelativePaths: Set<String> = [
        "", "Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
        "Applications", "Public", ".Trash",
        "Library/Caches", "Library/Logs", "Library/Application Support", "Library/Preferences",
        "Library/Containers", "Library/Group Containers", "Library/LaunchAgents",
        "Library/Saved Application State", "Library/Developer", "Library/Developer/Xcode",
        "Library/Mobile Documents", "Library/CloudStorage", "Library/Keychains", "Library/Mail",
    ]

    /// Only allow removal inside the user's home (minus protected folders) or of app bundles.
    static func isSafeToRemove(_ url: URL, home homeURL: URL = FileUtils.home) -> Bool {
        // Resolve the parent only: removing a symlink deletes the link, never its target.
        let standardized = url.standardizedFileURL
        let path = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent).path
        let home = homeURL.standardizedFileURL.resolvingSymlinksInPath().path

        if path.hasPrefix(home + "/") || path == home {
            let relative = String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if protectedRelativePaths.contains(relative) { return false }
            if relative.hasPrefix("Library/Keychains") { return false }
            return true
        }
        if path.hasPrefix("/Applications/") && path.hasSuffix(".app") { return true }
        return false
    }

    static func remove(_ items: [CleanItem], permanently: Bool = deletePermanently,
                       home: URL = FileUtils.home) -> CleanResult {
        let fm = FileManager.default
        var result = CleanResult(movedToTrash: !permanently)

        for item in items {
            guard isSafeToRemove(item.url, home: home) else {
                result.failures.append("Skipped protected path: \(item.url.path)")
                continue
            }
            do {
                if permanently {
                    try fm.removeItem(at: item.url)
                } else {
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                }
                result.removed += 1
                result.freed += item.size
            } catch {
                result.failures.append("\(FileUtils.displayPath(item.url)): \(error.localizedDescription)")
            }
        }
        return result
    }
}
