import CryptoKit
import SwiftUI

struct DuplicateFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let modified: Date
    var isSelected = false
}

struct DuplicateGroup: Identifiable, Sendable {
    let id = UUID()
    let size: Int64
    var files: [DuplicateFile]
    var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
    var selectedSize: Int64 { size * Int64(files.filter(\.isSelected).count) }
}

enum DuplicateScanner {
    static let defaultMinimumSize: Int64 = 1024 * 1024
    private static let skippedFolderNames: Set<String> = ["node_modules", "Library", ".Trash"]

    private struct Candidate {
        let url: URL
        let size: Int64
        let modified: Date
    }

    static func scan(root: URL, minimumSize: Int64 = defaultMinimumSize, ignored: [String] = IgnoreList.paths,
                     progress: @escaping @Sendable (String) -> Void = { _ in }) -> [DuplicateGroup] {
        // 1. Group every file by exact byte size (cheap, no reads).
        progress("Listing files…")
        var bySize: [Int64: [Candidate]] = [:]
        var seenInodes = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if skippedFolderNames.contains(url.lastPathComponent) || IgnoreList.contains(url, in: ignored) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard v.isRegularFile == true, let size = v.fileSize, Int64(size) >= minimumSize,
                  !IgnoreList.contains(url, in: ignored) else { continue }
            // Hard links share an inode: they are the same data, not duplicates.
            if let inode = inodeKey(url), !seenInodes.insert(inode).inserted { continue }
            bySize[Int64(size), default: []].append(
                Candidate(url: url, size: Int64(size), modified: v.contentModificationDate ?? .distantPast))
        }

        // 2. Narrow with a hash of the first 64 KB, then confirm with a full SHA-256.
        var groups: [DuplicateGroup] = []
        let sizeBuckets = bySize.values.filter { $0.count > 1 }
        for (index, bucket) in sizeBuckets.enumerated() {
            progress("Comparing files (\(index + 1)/\(sizeBuckets.count))…")
            for partial in regroup(bucket, by: { hash($0.url, limit: 64 * 1024) }) {
                for full in regroup(partial, by: { hash($0.url, limit: nil) }) {
                    let files = full.sorted { $0.modified < $1.modified }
                        .map { DuplicateFile(url: $0.url, modified: $0.modified) }
                    groups.append(DuplicateGroup(size: full[0].size, files: files))
                }
            }
        }
        return autoSelect(groups.sorted { $0.wasted > $1.wasted })
    }

    /// Selects every copy except the oldest one in each group.
    static func autoSelect(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.map { group in
            var g = group
            for i in g.files.indices { g.files[i].isSelected = i != 0 }
            return g
        }
    }

    /// Selected files to remove, guaranteeing at least one copy of each group survives.
    static func filesToRemove(_ groups: [DuplicateGroup]) -> [DuplicateFile] {
        groups.flatMap { group -> [DuplicateFile] in
            let selected = group.files.filter(\.isSelected)
            return selected.count == group.files.count ? Array(selected.dropFirst()) : selected
        }
    }

    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = (try? handle.read(upToCount: min(1 << 20, remaining))) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func regroup(_ items: [Candidate], by key: (Candidate) -> String?) -> [[Candidate]] {
        var buckets: [String: [Candidate]] = [:]
        for item in items {
            if let k = key(item) { buckets[k, default: []].append(item) }
        }
        return buckets.values.filter { $0.count > 1 }
    }

    private static func inodeKey(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
}

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning = false
    @Published var hasScanned = false
    @Published var status = ""
    @Published var lastResult: CleanResult?
    @Published var root = FileUtils.home

    var toRemove: [DuplicateFile] { DuplicateScanner.filesToRemove(groups) }
    var selectedTotal: Int64 {
        groups.reduce(0) { total, g in
            total + g.size * Int64(DuplicateScanner.filesToRemove([g]).count)
        }
    }
    var wastedTotal: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastResult = nil
        let root = root
        groups = await Task.detached(priority: .userInitiated) {
            DuplicateScanner.scan(root: root) { text in
                Task { @MainActor [weak self] in self?.status = text }
            }
        }.value
        status = ""
        hasScanned = true
        isScanning = false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }

    func removeSelected() async {
        let groupSizes = Dictionary(uniqueKeysWithValues: groups.flatMap { g in g.files.map { ($0.id, g.size) } })
        let items = toRemove.map { CleanItem(url: $0.url, size: groupSizes[$0.id] ?? 0, isSelected: true) }
        guard !items.isEmpty else { return }
        lastResult = await Task.detached { Cleaner.remove(items) }.value
        for i in groups.indices { groups[i].files.removeAll { !FileUtils.exists($0.url) } }
        groups.removeAll { $0.files.count < 2 }
    }
}

struct DuplicatesView: View {
    @EnvironmentObject var model: DuplicatesModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Duplicates",
                       subtitle: model.hasScanned
                           ? "\(model.groups.count) sets · \(FileUtils.format(model.wastedTotal)) wasted"
                           : "Find identical files, verified byte-for-byte with SHA-256.",
                       icon: "square.on.square.fill", tint: Pane.duplicates.tint) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
                Button("Scan") { Task { await model.scan() } }.disabled(model.isScanning)
                Button("Remove \(FileUtils.format(model.selectedTotal))") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(model.toRemove.isEmpty || model.isScanning)
            }
            HStack {
                Text("Folder:").foregroundStyle(.secondary)
                Text(FileUtils.displayPath(model.root)).lineLimit(1).truncationMode(.middle)
                Button("Change…") { model.chooseFolder() }.disabled(model.isScanning)
                Spacer()
                Text("The oldest copy is kept by default.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if let result = model.lastResult {
                ResultBanner(result: result) { model.lastResult = nil }.padding(.bottom, 8)
            }

            if model.groups.isEmpty {
                if model.isScanning {
                    ProgressView(model.status).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(icon: "square.on.square",
                                   title: model.hasScanned ? "No duplicates" : "Ready to scan",
                                   message: model.hasScanned
                                       ? "No identical files over 1 MB were found."
                                       : "Scans the chosen folder for identical files over 1 MB.")
                }
            } else {
                List {
                    ForEach($model.groups) { $group in
                        DisclosureGroup {
                            ForEach($group.files) { $file in
                                FileRow(isSelected: $file.isSelected, url: file.url, size: group.size,
                                        caption: "\(FileUtils.displayPath(file.url.deletingLastPathComponent())) · modified \(file.modified.formatted(date: .abbreviated, time: .shortened))")
                            }
                        } label: {
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: group.files[0].url.path))
                                    .resizable().frame(width: 22, height: 22)
                                Text(group.files[0].url.lastPathComponent).lineLimit(1)
                                Spacer()
                                Text("\(group.files.count) copies · \(FileUtils.format(group.size)) each")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog("Remove \(model.toRemove.count) duplicate files?", isPresented: $confirm) {
            Button(Cleaner.deletePermanently ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                Task { await model.removeSelected() }
            }
        } message: {
            Text("At least one copy of every file is always kept.")
        }
    }
}
