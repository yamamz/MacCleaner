import SwiftUI

struct SpaceEntry: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let isFolder: Bool
}

enum SpaceLensScanner {
    /// Immediate children of `folder` with their total sizes, largest first.
    static func entries(in folder: URL) -> [SpaceEntry] {
        let children = (try? FileUtils.children(of: folder, includeHidden: true)) ?? []
        var results = [SpaceEntry?](repeating: nil, count: children.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: children.count) { i in
            let url = children[i]
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { return }
            let entry = SpaceEntry(url: url, size: FileUtils.size(of: url),
                                   isFolder: values?.isDirectory == true && values?.isPackage != true)
            lock.lock(); results[i] = entry; lock.unlock()
        }
        return results.compactMap { $0 }.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }
}

@MainActor
final class SpaceLensModel: ObservableObject {
    @Published var path: [URL] = [FileUtils.home]
    @Published var entries: [SpaceEntry] = []
    @Published var isLoading = false
    @Published var lastResult: CleanResult?
    private var cache: [URL: [SpaceEntry]] = [:]

    var current: URL { path.last ?? FileUtils.home }
    var total: Int64 { entries.reduce(0) { $0 + $1.size } }

    func load(refresh: Bool = false) async {
        let folder = current
        if !refresh, let cached = cache[folder] { entries = cached; return }
        isLoading = true
        entries = []
        let found = await Task.detached(priority: .userInitiated) { SpaceLensScanner.entries(in: folder) }.value
        cache[folder] = found
        if current == folder { entries = found }
        isLoading = false
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
        // Invalidate this folder and every ancestor so totals stay correct.
        for url in path { cache[url] = nil }
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
                       icon: "circle.hexagongrid.fill", tint: .indigo) {
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

            if model.isLoading {
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
