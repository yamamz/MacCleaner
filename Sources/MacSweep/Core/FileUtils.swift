import AppKit
import Foundation

enum FileUtils {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    static let library = home.appendingPathComponent("Library")

    /// Disk space actually used by a file or directory tree (does not follow symlinks).
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func children(of url: URL, includeHidden: Bool = false) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil,
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: home.path, with: "~")
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
