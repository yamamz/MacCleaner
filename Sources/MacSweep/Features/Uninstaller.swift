import AppKit
import SwiftUI

struct AppInfo: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    var size: Int64?
}

enum AppScanner {
    static let defaultRoots = [URL(fileURLWithPath: "/Applications"), FileUtils.home.appendingPathComponent("Applications")]

    static func installedApps(roots: [URL] = defaultRoots) -> [AppInfo] {
        var bundles: [URL] = []
        for root in roots {
            for child in (try? FileUtils.children(of: root)) ?? [] {
                if child.pathExtension == "app" {
                    bundles.append(child)
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level deeper, e.g. /Applications/Adobe Photoshop/Photoshop.app
                    bundles += ((try? FileUtils.children(of: child)) ?? []).filter { $0.pathExtension == "app" }
                }
            }
        }

        return bundles.compactMap { url -> AppInfo? in
            let bundle = Bundle(url: url)
            let bundleID = bundle?.bundleIdentifier
            if bundleID?.hasPrefix("com.apple.") == true { return nil } // keep system apps safe
            let info = bundle?.infoDictionary
            let name = (info?["CFBundleDisplayName"] as? String)
                ?? (info?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return AppInfo(url: url, name: name, bundleID: bundleID,
                           version: info?["CFBundleShortVersionString"] as? String)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static let leftoverFolders = [
        "Application Support", "Caches", "Preferences", "Containers", "Group Containers",
        "Saved Application State", "Logs", "HTTPStorages", "WebKit", "LaunchAgents",
        "Cookies", "Application Scripts", "Preferences/ByHost",
    ]

    /// Whether a ~/Library entry named `entryName` inside `folder` belongs to `app`.
    static func isLeftover(_ entryName: String, in folder: String, for app: AppInfo) -> Bool {
        let name = entryName.lowercased()
        let stem = (entryName as NSString).deletingPathExtension.lowercased()
        if let id = app.bundleID?.lowercased(), !id.isEmpty {
            if name == id || stem == id || name.hasPrefix(id + ".") { return true }
            if folder == "Group Containers" && name.hasSuffix("." + id) { return true }
        }
        // Folders named exactly after the app (e.g. "Application Support/Slack").
        let appNames = [app.name, app.url.deletingPathExtension().lastPathComponent]
            .map { $0.lowercased() }
            .filter { $0.count >= 3 }
        return appNames.contains(name)
    }

    static func leftovers(for app: AppInfo, library: URL = FileUtils.library) -> [CleanItem] {
        var found: [CleanItem] = []
        for folder in leftoverFolders {
            let dir = library.appendingPathComponent(folder)
            for child in (try? FileUtils.children(of: dir, includeHidden: true)) ?? []
            where isLeftover(child.lastPathComponent, in: folder, for: app) {
                found.append(CleanItem(url: child, size: FileUtils.size(of: child), isSelected: true))
            }
        }
        return found.sorted { $0.size > $1.size }
    }
}

@MainActor
final class UninstallerModel: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var selectedID: URL?
    @Published var leftovers: [CleanItem] = []
    @Published var isLoading = false
    @Published var isFindingLeftovers = false
    @Published var search = ""
    @Published var lastResult: CleanResult?

    var filteredApps: [AppInfo] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    var selectedApp: AppInfo? { apps.first { $0.id == selectedID } }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        apps = await Task.detached { AppScanner.installedApps() }.value
        isLoading = false

        // Compute bundle sizes in the background, filling them in as they arrive.
        for app in apps where app.size == nil {
            let size = await Task.detached(priority: .utility) { FileUtils.size(of: app.url) }.value
            if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].size = size }
        }
    }

    func select(_ id: URL?) async {
        selectedID = id
        leftovers = []
        guard let app = selectedApp else { return }
        isFindingLeftovers = true
        let found = await Task.detached { AppScanner.leftovers(for: app) }.value
        if selectedID == app.id { leftovers = found }
        isFindingLeftovers = false
    }

    func isRunning(_ app: AppInfo) -> Bool {
        guard let id = app.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    func quit(_ app: AppInfo) {
        guard let id = app.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
    }

    func uninstall(_ app: AppInfo) async {
        let files = leftovers.filter(\.isSelected)
        var result = await Task.detached { Cleaner.remove(files) }.value

        // The bundle goes through NSWorkspace so macOS can ask for an admin password if needed.
        let appSize = app.size ?? 0
        do {
            if Cleaner.deletePermanently {
                try FileManager.default.removeItem(at: app.url)
            } else {
                _ = try await NSWorkspace.shared.recycle([app.url])
            }
            result.removed += 1
            result.freed += appSize
        } catch {
            result.failures.append("\(app.name).app: \(error.localizedDescription)")
        }

        lastResult = result
        if !FileUtils.exists(app.url) {
            apps.removeAll { $0.id == app.id }
            selectedID = nil
            leftovers = []
        }
    }

    func removeLeftoversOnly() async {
        let files = leftovers.filter(\.isSelected)
        lastResult = await Task.detached { Cleaner.remove(files) }.value
        leftovers.removeAll { !FileUtils.exists($0.url) }
    }
}

struct UninstallerView: View {
    @EnvironmentObject var model: UninstallerModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Uninstaller",
                       subtitle: "Remove apps completely, including their hidden support files.",
                       icon: "xmark.app.fill", tint: Pane.uninstaller.tint) {
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload app list")
            }
            if let result = model.lastResult {
                ResultBanner(result: result) { model.lastResult = nil }.padding(.bottom, 8)
            }

            HSplitView {
                appList.frame(minWidth: 280, idealWidth: 320)
                detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if model.apps.isEmpty { await model.load() } }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $model.search)
                .textFieldStyle(.roundedBorder).padding(10)
            List(selection: Binding(get: { model.selectedID },
                                    set: { id in Task { await model.select(id) } })) {
                ForEach(model.filteredApps) { app in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading) {
                            Text(app.name).lineLimit(1)
                            if let v = app.version {
                                Text(v).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(app.size.map(FileUtils.format) ?? "…")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(app.id)
                }
            }
            .overlay { if model.isLoading { ProgressView() } }
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selectedApp {
            let leftoverTotal = model.leftovers.filter(\.isSelected).reduce(0) { $0 + $1.size }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title2.bold())
                        Text(app.bundleID ?? "Unknown bundle ID").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text("App \(app.size.map(FileUtils.format) ?? "…") · Leftovers \(FileUtils.format(leftoverTotal))")
                            .font(.callout)
                    }
                    Spacer()
                }

                if model.isRunning(app) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("\(app.name) is running. Quit it before uninstalling.")
                        Spacer()
                        Button("Quit App") { model.quit(app) }
                    }
                    .padding(10)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                Text("Related files").font(.headline)
                if model.isFindingLeftovers {
                    ProgressView().frame(maxWidth: .infinity)
                } else if model.leftovers.isEmpty {
                    Text("No support files found.").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach($model.leftovers) { $item in
                            FileRow(isSelected: $item.isSelected, url: item.url, size: item.size)
                        }
                    }
                    .listStyle(.inset)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Remove Leftovers Only") { Task { await model.removeLeftoversOnly() } }
                        .disabled(model.leftovers.filter(\.isSelected).isEmpty)
                    Spacer()
                    Button("Uninstall \(app.name)") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(model.isRunning(app) || model.isFindingLeftovers)
                }
            }
            .padding(20)
            .confirmationDialog("Uninstall \(app.name)?", isPresented: $confirm) {
                Button("Uninstall", role: .destructive) { Task { await model.uninstall(app) } }
            } message: {
                Text("The app and \(model.leftovers.filter(\.isSelected).count) related files will be "
                     + (Cleaner.deletePermanently ? "deleted permanently." : "moved to the Trash."))
            }
        } else {
            EmptyStateView(icon: "app.dashed", title: "Select an app",
                           message: "Pick an app to see its size and the support files it left around your Mac.")
        }
    }
}
