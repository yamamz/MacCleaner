import SwiftUI

struct LargeFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
    let lastOpened: Date?
    var isSelected = false
}

enum AgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age"
    case month = "Not opened in 1 month"
    case halfYear = "Not opened in 6 months"
    case year = "Not opened in 1 year"

    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .any: nil
        case .month: 30
        case .halfYear: 182
        case .year: 365
        }
    }
}

enum LargeFileScanner {
    static let minimumBytes: Int64 = 50 * 1024 * 1024
    private static let skippedFolderNames: Set<String> = ["node_modules", "Library", ".Trash"]

    /// Whether a file passes the size / "not opened since" filters.
    static func matches(_ file: LargeFile, minBytes: Int64, olderThanDays days: Int?, now: Date = Date()) -> Bool {
        guard file.size >= minBytes else { return false }
        if let days, let opened = file.lastOpened, opened > now.addingTimeInterval(-Double(days) * 86_400) {
            return false
        }
        return true
    }

    static func scan(root: URL, minimumBytes: Int64 = minimumBytes, ignored: [String] = IgnoreList.paths,
                     progress: @escaping @Sendable (Int) -> Void = { _ in }) -> [LargeFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var results: [LargeFile] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited % 2000 == 0 { progress(visited) }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if skippedFolderNames.contains(url.lastPathComponent) || IgnoreList.contains(url, in: ignored) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if IgnoreList.contains(url, in: ignored) { continue }
            guard v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if size >= minimumBytes {
                results.append(LargeFile(url: url, size: size,
                                         lastOpened: v.contentAccessDate ?? v.contentModificationDate))
            }
        }
        progress(visited)
        return results.sorted { $0.size > $1.size }
    }
}

@MainActor
final class LargeFilesModel: ObservableObject {
    @Published var files: [LargeFile] = []
    @Published var isScanning = false
    @Published var hasScanned = false
    @Published var scannedCount = 0
    @Published var minSizeMB = 100
    @Published var ageFilter: AgeFilter = .any
    @Published var lastResult: CleanResult?

    var visibleIndices: [Int] {
        let minBytes = Int64(minSizeMB) * 1024 * 1024
        let now = Date()
        return files.indices.filter {
            LargeFileScanner.matches(files[$0], minBytes: minBytes, olderThanDays: ageFilter.days, now: now)
        }
    }

    var selected: [LargeFile] { visibleIndices.map { files[$0] }.filter(\.isSelected) }
    var visibleTotal: Int64 { visibleIndices.reduce(0) { $0 + files[$1].size } }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        scannedCount = 0
        lastResult = nil
        let root = FileUtils.home
        files = await Task.detached(priority: .userInitiated) {
            LargeFileScanner.scan(root: root) { count in
                Task { @MainActor [weak self] in self?.scannedCount = count }
            }
        }.value
        hasScanned = true
        isScanning = false
    }

    func removeSelected() async {
        let items = selected.map { CleanItem(url: $0.url, size: $0.size, isSelected: true) }
        guard !items.isEmpty else { return }
        lastResult = await Task.detached { Cleaner.remove(items) }.value
        files.removeAll { !FileUtils.exists($0.url) }
    }
}

struct LargeFilesView: View {
    @EnvironmentObject var model: LargeFilesModel
    @State private var confirm = false

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Large & Old Files",
                       subtitle: model.hasScanned
                           ? "\(model.visibleIndices.count) files · \(FileUtils.format(model.visibleTotal))"
                           : "Find big files hiding in your home folder.",
                       icon: "doc.on.doc.fill", tint: Pane.largeFiles.tint) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("\(model.scannedCount.formatted()) files checked")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Scan") { Task { await model.scan() } }.disabled(model.isScanning)
                Button("Remove \(model.selected.count)") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(model.selected.isEmpty)
            }

            HStack {
                Picker("Size", selection: $model.minSizeMB) {
                    ForEach([50, 100, 250, 500, 1000], id: \.self) { mb in
                        Text(mb >= 1000 ? "> 1 GB" : "> \(mb) MB").tag(mb)
                    }
                }
                .frame(width: 160)
                Picker("Age", selection: $model.ageFilter) {
                    ForEach(AgeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 260)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if let result = model.lastResult {
                ResultBanner(result: result) { model.lastResult = nil }.padding(.bottom, 8)
            }

            if model.visibleIndices.isEmpty {
                if model.isScanning {
                    ProgressView("Scanning your home folder…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(icon: "doc.text.magnifyingglass",
                                   title: model.hasScanned ? "Nothing matched" : "Ready to scan",
                                   message: model.hasScanned
                                       ? "No files match the current filters."
                                       : "Scans your home folder (excluding Library) for files over 50 MB.")
                }
            } else {
                List {
                    ForEach(model.visibleIndices, id: \.self) { i in
                        let file = model.files[i]
                        FileRow(isSelected: $model.files[i].isSelected, url: file.url, size: file.size,
                                caption: caption(for: file))
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog("Remove \(model.selected.count) files?", isPresented: $confirm) {
            Button(Cleaner.deletePermanently ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                Task { await model.removeSelected() }
            }
        }
    }

    private func caption(for file: LargeFile) -> String {
        let folder = FileUtils.displayPath(file.url.deletingLastPathComponent())
        guard let date = file.lastOpened else { return folder }
        return "\(folder) · opened \(Self.dateFormatter.localizedString(for: date, relativeTo: Date()))"
    }
}
