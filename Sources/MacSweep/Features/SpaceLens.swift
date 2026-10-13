import SwiftUI

struct SpaceEntry: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let isFolder: Bool
}

/// Lets the UI stop a scan that is no longer needed (e.g. the user opened another folder).
final class ScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

enum SpaceLensScanner {
    struct Result: Sendable {
        var entries: [SpaceEntry] = []
        /// Directory totals found along the way (path → bytes), reused when drilling down.
        var sizes: [String: Int64] = [:]
    }

    /// Immediate children of `folder` with their total sizes, largest first.
    static func entries(in folder: URL) -> [SpaceEntry] {
        scan(folder).entries
    }

    /// Measures each child of `folder`, calling `onEntry` as soon as one is done.
    /// Sizes in `known` are reused instead of re-measuring.
    static func scan(_ folder: URL, known: [String: Int64] = [:], token: ScanToken = ScanToken(),
                     onEntry: @escaping @Sendable (SpaceEntry) -> Void = { _ in }) -> Result {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        var folders: [String: URL] = [:] // subfolders and packages, by name
        var drillable: Set<String> = []
        var result = Result()

        func add(_ entry: SpaceEntry) {
            guard entry.size > 0 else { return }
            result.entries.append(entry)
            onEntry(entry)
        }

        for url in (try? FileUtils.children(of: folder, includeHidden: true)) ?? [] {
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                folders[url.lastPathComponent] = url
                if values.isPackage != true { drillable.insert(url.lastPathComponent) }
            } else {
                add(SpaceEntry(url: url, size: FileUtils.size(of: url), isFolder: false))
            }
        }

        // Measure all subfolders as one tree so the work spreads across every core.
        let measured = FileUtils.measure(folder, recordDepth: 4, known: known,
                                         isCancelled: { token.isCancelled }) { path, size in
            // Match by name: `folder` may be reached through a symlink (e.g. /var → /private/var).
            let name = (path as NSString).lastPathComponent
            guard !token.isCancelled, let url = folders[name] else { return }
            add(SpaceEntry(url: url, size: size, isFolder: drillable.contains(name)))
        }
        result.sizes = measured.directories
        result.entries.sort { $0.size > $1.size }
        return result
    }
}

@MainActor
final class SpaceLensModel: ObservableObject {
    @Published var path: [URL] = [FileUtils.home]
    @Published var entries: [SpaceEntry] = []
    @Published var isLoading = false
    @Published var lastResult: CleanResult?
    private var listings: [URL: [SpaceEntry]] = [:]
    private var sizes: [String: Int64] = [:]
    private var token: ScanToken?

    var current: URL { path.last ?? FileUtils.home }
    var total: Int64 { entries.reduce(0) { $0 + $1.size } }

    func load(refresh: Bool = false) async {
        let folder = current
        token?.cancel()
        if refresh { forget(folder) }
        if let cached = listings[folder] { entries = cached; isLoading = false; return }

        let token = ScanToken()
        self.token = token
        isLoading = true
        entries = []
        let known = sizes
        let result = await Task.detached(priority: .userInitiated) {
            SpaceLensScanner.scan(folder, known: known, token: token) { entry in
                Task { @MainActor [weak self] in self?.receive(entry, token: token) }
            }
        }.value
        guard !token.isCancelled else { return }

        sizes.merge(result.sizes) { $1 }
        listings[folder] = result.entries
        entries = result.entries
        isLoading = false
    }

    private func receive(_ entry: SpaceEntry, token: ScanToken) {
        guard token === self.token, isLoading, !entries.contains(where: { $0.url == entry.url }) else { return }
        let index = entries.firstIndex { $0.size < entry.size } ?? entries.endIndex
        entries.insert(entry, at: index)
    }

    /// Drops cached sizes for `url`, everything inside it and every folder above it.
    private func forget(_ url: URL) {
        let prefix = url.path + "/"
        sizes = sizes.filter { !$0.key.hasPrefix(prefix) && $0.key != url.path && !prefix.hasPrefix($0.key + "/") }
        listings = listings.filter { !$0.key.path.hasPrefix(prefix) && !prefix.hasPrefix($0.key.path + "/") }
    }

    func open(_ entry: SpaceEntry) async {
        guard entry.isFolder else { return }
        path.append(entry.url)
        await load()
    }

    func goTo(index: Int) async {
        path = Array(path.prefix(index + 1))
        await load()
    }

    func remove(_ entry: SpaceEntry) async {
        let item = CleanItem(url: entry.url, size: entry.size, isSelected: true)
        lastResult = await Task.detached { Cleaner.remove([item]) }.value
        // Invalidate the removed item, this folder and every ancestor so totals stay correct.
        forget(entry.url)
        await load(refresh: true)
    }
}

struct SpaceLensView: View {
    @EnvironmentObject var model: SpaceLensModel
    @State private var pending: SpaceEntry?

    private let palette: [Color] = [.indigo, .blue, .teal, .green, .orange, .pink, .purple, .red]

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Space Lens", subtitle: "See what's taking up space, folder by folder.",
                       icon: "circle.hexagongrid.fill", tint: Pane.spaceLens.tint) {
                if model.isLoading && !model.entries.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.load(refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isLoading)
            }

            // Breadcrumbs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.path.enumerated()), id: \.offset) { index, url in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        Button(index == 0 ? "Home" : url.lastPathComponent) { Task { await model.goTo(index: index) } }
                            .buttonStyle(.link)
                    }
                    Spacer()
                    Text(FileUtils.format(model.total)).font(.headline).monospacedDigit()
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 8)

            if !model.entries.isEmpty { overviewBar.padding(.horizontal, 20).padding(.bottom, 10) }

            if let result = model.lastResult {
                ResultBanner(result: result) { model.lastResult = nil }.padding(.bottom, 8)
            }

            if model.isLoading && model.entries.isEmpty {
                ProgressView("Measuring \(model.current.lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, color: palette[index % palette.count])
                }
                .listStyle(.inset)
            }
        }
        .task { if model.entries.isEmpty { await model.load() } }
        .confirmationDialog("Remove \(pending?.url.lastPathComponent ?? "")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(Cleaner.deletePermanently ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                if let entry = pending { Task { await model.remove(entry) } }
            }
        } message: {
            Text("\(FileUtils.format(pending?.size ?? 0)) will be removed.")
        }
    }

    private var overviewBar: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(model.entries.prefix(8).enumerated()), id: \.element.id) { index, entry in
                    Rectangle().fill(palette[index % palette.count].gradient)
                        .frame(width: max(2, geo.size.width * CGFloat(entry.size) / CGFloat(max(model.total, 1))))
                        .help("\(entry.url.lastPathComponent) — \(FileUtils.format(entry.size))")
                }
                Rectangle().fill(.quaternary)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func row(_ entry: SpaceEntry, color: Color) -> some View {
        let fraction = Double(entry.size) / Double(max(model.total, 1))
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.url.lastPathComponent).lineLimit(1)
                GeometryReader { geo in
                    Capsule().fill(color.gradient).frame(width: max(3, geo.size.width * fraction))
                }
                .frame(height: 5)
            }
            Text(String(format: "%.1f%%", fraction * 100)).font(.caption).foregroundStyle(.secondary)
                .monospacedDigit().frame(width: 50, alignment: .trailing)
            Text(FileUtils.format(entry.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button { FileUtils.reveal(entry.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
            Button { pending = entry } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove")
                .disabled(!Cleaner.isSafeToRemove(entry.url))
            Image(systemName: "chevron.right").foregroundStyle(.secondary).opacity(entry.isFolder ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.open(entry) } }
    }
}
