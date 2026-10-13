import SwiftUI

struct LaunchItem: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let label: String
    let program: String?
    let runAtLoad: Bool
    let isUserItem: Bool
}

enum LaunchItemScanner {
    static let defaultSources: [(URL, Bool)] = [
        (FileUtils.library.appendingPathComponent("LaunchAgents"), true),
        (URL(fileURLWithPath: "/Library/LaunchAgents"), false),
        (URL(fileURLWithPath: "/Library/LaunchDaemons"), false),
    ]

    static func parse(_ url: URL, isUserItem: Bool) -> LaunchItem {
        let dict = NSDictionary(contentsOf: url) as? [String: Any] ?? [:]
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        return LaunchItem(url: url,
                          label: dict["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                          program: program,
                          runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
                          isUserItem: isUserItem)
    }

    static func scan(sources: [(URL, Bool)] = defaultSources) -> [LaunchItem] {
        var items: [LaunchItem] = []
        for (dir, isUser) in sources {
            for url in (try? FileUtils.children(of: dir)) ?? [] where url.pathExtension == "plist" {
                items.append(parse(url, isUserItem: isUser))
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}

@MainActor
final class OptimizationModel: ObservableObject {
    @Published var items: [LaunchItem] = []
    @Published var lastResult: CleanResult?

    func load() async {
        items = await Task.detached { LaunchItemScanner.scan() }.value
    }

    func remove(_ item: LaunchItem) async {
        let clean = [CleanItem(url: item.url, size: FileUtils.size(of: item.url), isSelected: true)]
        lastResult = await Task.detached { Cleaner.remove(clean) }.value
        await load()
    }
}

struct OptimizationView: View {
    @EnvironmentObject var model: OptimizationModel
    @State private var pending: LaunchItem?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Optimization",
                       subtitle: "Review background agents and login items that start with your Mac.",
                       icon: "slider.horizontal.3", tint: .purple) {
                Button("Login Items…") { FileUtils.openLoginItemsSettings() }
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
            }
            if let result = model.lastResult {
                ResultBanner(result: result) { model.lastResult = nil }.padding(.bottom, 8)
            }
            List {
                section("Your Launch Agents", items: model.items.filter(\.isUserItem), removable: true)
                section("System-wide Agents & Daemons (read only)", items: model.items.filter { !$0.isUserItem }, removable: false)
            }
            .listStyle(.inset)
        }
        .task { await model.load() }
        .confirmationDialog("Remove \(pending?.label ?? "")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let item = pending { Task { await model.remove(item) } }
            }
        } message: {
            Text("The agent stops launching after your next login. The app that installed it may add it back.")
        }
    }

    private func section(_ title: String, items: [LaunchItem], removable: Bool) -> some View {
        Section(title) {
            if items.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack {
                    Image(systemName: item.runAtLoad ? "bolt.circle.fill" : "clock.circle")
                        .foregroundStyle(item.runAtLoad ? .purple : .secondary)
                        .help(item.runAtLoad ? "Runs at login" : "Runs on demand / schedule")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label).lineLimit(1)
                        Text(item.program ?? item.url.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { FileUtils.reveal(item.url) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                    if removable {
                        Button("Remove") { pending = item }
                    }
                }
            }
        }
    }
}
