import AppKit
import Foundation

enum FileUtils {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    static let library = home.appendingPathComponent("Library")

    /// Disk space actually used by a file or directory tree (does not follow symlinks).
    static func size(of url: URL) -> Int64 {
        measure(url).size
    }

    /// Measures a file or directory tree. See `DiskUsage` for the options.
    static func measure(_ url: URL, recordDepth: Int = 0, known: [String: Int64] = [:],
                        isCancelled: @escaping @Sendable () -> Bool = { false },
                        onChild: ((String, Int64) -> Void)? = nil) -> (size: Int64, directories: [String: Int64]) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return (0, [:]) }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return (0, [:])
        case S_IFDIR:
            return DiskUsage(root: url.path, recordDepth: recordDepth, known: known,
                             isCancelled: isCancelled, onChild: onChild).run()
        default: return (Int64(info.st_blocks) * 512, [:])
        }
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

/// Parallel disk-usage measurement of a directory tree.
///
/// The top `splitDepth` levels are listed breadth-first, one level per parallel batch, then every
/// folder at the split depth is measured in one flat parallel batch. (Nested `concurrentPerform`
/// calls get very few threads, so the work is kept flat.) Totals roll up to their parents as
/// folders finish; `onChild` fires for each direct subfolder of the root once its total is known.
/// Directories up to `recordDepth` levels deep are returned so callers can cache them, and any
/// path in `known` is used as-is instead of being walked. A cancelled run returns zero and no folders.
private final class DiskUsage {
    private struct Node {
        let path: String
        let parent: Int
        let depth: Int
        var size: Int64 = 0
        var pending = 0
    }

    private let splitDepth = 3
    private let recordDepth: Int
    private let known: [String: Int64]
    private let isCancelled: @Sendable () -> Bool
    private let onChild: ((String, Int64) -> Void)?
    private var nodes: [Node]
    private var recorded: [String: Int64] = [:]
    private let lock = NSLock()

    init(root: String, recordDepth: Int, known: [String: Int64],
         isCancelled: @escaping @Sendable () -> Bool, onChild: ((String, Int64) -> Void)?) {
        self.recordDepth = recordDepth
        self.known = known
        self.isCancelled = isCancelled
        self.onChild = onChild
        nodes = [Node(path: root, parent: -1, depth: 0)]
    }

    func run() -> (size: Int64, directories: [String: Int64]) {
        var level = [0]
        while !level.isEmpty, nodes[level[0]].depth < splitDepth, !isCancelled() {
            // List this level in parallel, then link the results up serially.
            let paths = level.map { nodes[$0].path }
            var listings = [(Int64, [String])](repeating: (0, []), count: level.count)
            let workers = min(paths.count, ProcessInfo.processInfo.activeProcessorCount)
            listings.withUnsafeMutableBufferPointer { listings in
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let buffer = BulkWalker.Buffer() // one per worker, reused for its share of folders
                    for i in stride(from: worker, to: paths.count, by: workers) {
                        let fd = open(paths[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else { continue }
                        listings[i] = BulkWalker.readEntries(fd, buffer: buffer)
                        close(fd)
                    }
                }
            }
            var next: [Int] = []
            for (i, index) in level.enumerated() {
                let (files, subdirectories) = listings[i]
                nodes[index].size = files
                nodes[index].pending = subdirectories.count
                for name in subdirectories {
                    let path = nodes[index].path + "/" + name
                    nodes.append(Node(path: path, parent: index, depth: nodes[index].depth + 1))
                    if let size = known[path] {
                        nodes[nodes.count - 1].size = size
                        complete(nodes.count - 1)
                    } else {
                        next.append(nodes.count - 1)
                    }
                }
                if subdirectories.isEmpty { complete(index) }
            }
            level = next
        }

        // Measure everything below the split depth in one flat parallel batch.
        // Snapshot what the workers read: `nodes` is mutated under the lock as folders finish.
        let leaves = level.map { (index: $0, path: nodes[$0].path, depth: nodes[$0].depth) }
        DispatchQueue.concurrentPerform(iterations: leaves.count) { i in
            let (index, path, depth) = leaves[i]
            guard !isCancelled() else { return }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let walker = BulkWalker(recordDepth: recordDepth, isCancelled: isCancelled)
            let size = fd >= 0 ? walker.measureDirectory(fd: fd, path: path, depth: depth) : 0

            lock.lock(); defer { lock.unlock() }
            recorded.merge(walker.recorded) { $1 }
            nodes[index].size = size
            complete(index)
        }
        // A cancelled walk has partial totals; don't hand them out as real sizes.
        return isCancelled() ? (0, [:]) : (nodes[0].size, recorded)
    }

    /// Marks a node's total as final and rolls it up into its parent. Caller holds the lock or runs serially.
    private func complete(_ index: Int) {
        var index = index
        while true {
            let node = nodes[index]
            if node.depth >= 1, node.depth <= recordDepth { recorded[node.path] = node.size }
            if node.depth == 1, !isCancelled() { onChild?(node.path, node.size) }
            guard node.parent >= 0 else { return }
            nodes[node.parent].size += node.size
            nodes[node.parent].pending -= 1
            guard nodes[node.parent].pending == 0 else { return }
            index = node.parent
        }
    }
}

/// Serial recursive directory walker built on getattrlistbulk(2), which reads a whole
/// directory's metadata per call. One walker per thread.
private final class BulkWalker {
    final class Buffer {
        static let size = 128 * 1024
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Buffer.size, alignment: 8)
        deinit { pointer.deallocate() }
    }

    private let buffer = Buffer()
    private let recordDepth: Int
    private let isCancelled: @Sendable () -> Bool
    private var directories = 0
    private var cancelled = false
    private(set) var recorded: [String: Int64] = [:]

    init(recordDepth: Int, isCancelled: @escaping @Sendable () -> Bool) {
        self.recordDepth = recordDepth
        self.isCancelled = isCancelled
    }

    /// Total allocated size of the directory open at `fd`. Takes ownership of `fd`.
    func measureDirectory(fd: Int32, path: String, depth: Int) -> Int64 {
        directories += 1
        if directories % 256 == 0, isCancelled() { cancelled = true }
        if cancelled { close(fd); return 0 }

        var (total, subdirectories) = BulkWalker.readEntries(fd, buffer: buffer)
        // Close before descending: holding one descriptor per level on every thread can exceed
        // the 256 open-file limit GUI apps get in deep trees.
        close(fd)
        for name in subdirectories {
            if cancelled { break }
            let childPath = path + "/" + name
            let child = open(childPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            let size = measureDirectory(fd: child, path: childPath, depth: depth + 1)
            total += size
            if depth + 1 <= recordDepth { recorded[childPath] = size }
        }
        return total
    }

    /// Sums the files directly inside the directory and lists its subfolders (symlinks are skipped).
    static func readEntries(_ fd: Int32, buffer: Buffer) -> (Int64, [String]) {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE)
        attributes.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)

        var total: Int64 = 0
        var subdirectories: [String] = []
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer.pointer, Buffer.size, 0)
            if count <= 0 { break }
            var entry = buffer.pointer
            for _ in 0..<count {
                let length = entry.loadUnaligned(as: UInt32.self)
                defer { entry += Int(length) }
                var field = entry + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let name = String(cString: (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size

                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                    if error != 0 { continue }
                }
                let type = field.loadUnaligned(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size

                if type == VDIR.rawValue {
                    subdirectories.append(name)
                } else if type != VLNK.rawValue,
                          returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    total += field.loadUnaligned(as: off_t.self)
                }
            }
        }
        return (total, subdirectories)
    }
}
