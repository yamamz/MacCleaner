import SwiftUI

struct JunkCategory: Sendable {
    enum Mode: Sendable {
        /// Each child of the root is a separate removable item.
        case children
        /// The root folder itself is one item.
        case wholeFolder
        /// Children of the root matching these file extensions.
        case extensions([String])
    }

    let id: String
    let name: String
    let icon: String
    let detail: String
    let roots: [String] // relative to home
    let mode: Mode
    let selectedByDefault: Bool
}

struct JunkGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let icon: String
    let detail: String
    var items: [CleanItem]
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedTotal: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.size } }
}

enum JunkScanner {
    static let categories: [JunkCategory] = [
        .init(id: "caches", name: "User Cache Files", icon: "archivebox.fill",
              detail: "Temporary data apps keep to speed things up. Apps rebuild these when needed.",
              roots: ["Library/Caches"], mode: .children, selectedByDefault: true),
        .init(id: "logs", name: "User Log Files", icon: "doc.text.fill",
              detail: "Diagnostic logs and crash reports.",
              roots: ["Library/Logs"], mode: .children, selectedByDefault: true),
        .init(id: "xcode", name: "Xcode Junk", icon: "hammer.fill",
              detail: "Derived data, old device support files and simulator caches.",
              roots: ["Library/Developer/Xcode/DerivedData",
                      "Library/Developer/Xcode/iOS DeviceSupport",
                      "Library/Developer/Xcode/watchOS DeviceSupport",
                      "Library/Developer/Xcode/macOS DeviceSupport",
                      "Library/Developer/CoreSimulator/Caches"],
              mode: .children, selectedByDefault: true),
        .init(id: "dev", name: "Developer Package Caches", icon: "shippingbox.fill",
              detail: "npm, Yarn, pnpm, Gradle, pip and CocoaPods download caches. Re-downloaded on demand.",
              roots: [".npm/_cacache", ".yarn/cache", "Library/pnpm/store", ".gradle/caches",
                      ".cache/pip", ".cocoapods/repos", ".m2/repository"],
              mode: .wholeFolder, selectedByDefault: false),
        .init(id: "mail", name: "Mail Attachments", icon: "paperclip",
              detail: "Attachments downloaded by Mail. Originals stay on your mail server.",
              roots: ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads"],
              mode: .children, selectedByDefault: false),
        .init(id: "installers", name: "Installers in Downloads", icon: "externaldrive.fill",
              detail: "Disk images and installer packages you probably already installed.",
              roots: ["Downloads"], mode: .extensions(["dmg", "pkg", "mpkg", "iso", "xip"]),
              selectedByDefault: false),
        .init(id: "archives", name: "Xcode Archives", icon: "archivebox.circle.fill",
              detail: "Old app archives. Keep them if you need to symbolicate crash reports.",
              roots: ["Library/Developer/Xcode/Archives"], mode: .children, selectedByDefault: false),
    ]

    static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.macsweep.app"

    static func scan(_ category: JunkCategory, home: URL = FileUtils.home,
                     ignored: [String] = IgnoreList.paths,
                     excludedNames: Set<String> = [ownBundleID]) -> (group: JunkGroup, permissionDenied: Bool) {
        var items: [CleanItem] = []
        var denied = false

        for relative in category.roots {
            let root = home.appendingPathComponent(relative)
            guard FileUtils.exists(root), !IgnoreList.contains(root, in: ignored) else { continue }

            switch category.mode {
            case .wholeFolder:
                let size = FileUtils.size(of: root)
                if size > 0 { items.append(CleanItem(url: root, size: size, isSelected: category.selectedByDefault)) }

            case .children, .extensions:
                let children: [URL]
                do {
                    children = try FileUtils.children(of: root, includeHidden: false)
                } catch {
                    denied = true
                    continue
                }
                for child in children {
                    if excludedNames.contains(child.lastPathComponent) { continue }
                    if IgnoreList.contains(child, in: ignored) { continue }
                    if case let .extensions(exts) = category.mode,
                       !exts.contains(child.pathExtension.lowercased()) { continue }
                    let size = FileUtils.size(of: child)
                    if size > 0 {
                        items.append(CleanItem(url: child, size: size, isSelected: category.selectedByDefault))
                    }
                }
            }
        }

        items.sort { $0.size > $1.size }
        let group = JunkGroup(id: category.id, name: category.name, icon: category.icon,
                              detail: category.detail, items: items)
        return (group, denied)
    }
}

@MainActor
final class JunkModel: ObservableObject {
    @Published var groups: [JunkGroup] = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var hasScanned = false
    @Published var permissionDenied = false
    @Published var status = ""
    @Published var lastResult: CleanResult?

    var total: Int64 { groups.reduce(0) { $0 + $1.total } }
    var selectedTotal: Int64 { groups.reduce(0) { $0 + $1.selectedTotal } }
    var selectedCount: Int { groups.reduce(0) { $0 + $1.items.filter(\.isSelected).count } }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastResult = nil
        permissionDenied = false
        var found: [JunkGroup] = []

        for category in JunkScanner.categories {
            status = "Scanning \(category.name)…"
            let (group, denied) = await Task.detached(priority: .userInitiated) {
                JunkScanner.scan(category)
            }.value
            if denied { permissionDenied = true }
            if !group.items.isEmpty { found.append(group) }
            groups = found
        }

        status = ""
        hasScanned = true
        isScanning = false
    }

    func clean() async {
        let selected = groups.flatMap { $0.items.filter(\.isSelected) }
        guard !selected.isEmpty, !isCleaning else { return }
        isCleaning = true
        let result = await Task.detached(priority: .userInitiated) { Cleaner.remove(selected) }.value

        for index in groups.indices {
            groups[index].items.removeAll { $0.isSelected && !FileUtils.exists($0.url) }
        }
        groups.removeAll { $0.items.isEmpty }
        lastResult = result
        isCleaning = false
    }

    func setAll(in groupID: String, _ value: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        for i in groups[index].items.indices { groups[index].items[i].isSelected = value }
    }
}

struct JunkView: View {
    @EnvironmentObject var model: JunkModel
    @State private var confirmClean = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "System Junk",
                       subtitle: model.hasScanned
                           ? "Found \(FileUtils.format(model.total)) · \(FileUtils.format(model.selectedTotal)) selected"
                           : "Remove caches, logs and developer leftovers.",
                       icon: "trash.circle.fill", tint: .pink) {
                if model.isScanning || model.isCleaning {
                    ProgressView().controlSize(.small)
                    Text(model.isCleaning ? "Cleaning…" : model.status)
                        .font(.caption).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
                }
                Button("Scan") { Task { await model.scan() } }
                    .disabled(model.isScanning || model.isCleaning)
                Button("Clean \(FileUtils.format(model.selectedTotal))") { confirmClean = true }
                    .buttonStyle(.borderedProminent).tint(.pink)
                    .disabled(model.selectedCount == 0 || model.isScanning || model.isCleaning)
            }

            if let result = model.lastResult {
                ResultBanner(result: result) { model.lastResult = nil }.padding(.bottom, 8)
            }
            if model.permissionDenied { FullDiskAccessHint().padding(.bottom, 8) }

            if model.groups.isEmpty {
                if model.isScanning {
                    ProgressView(model.status).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(icon: "sparkles",
                                   title: model.hasScanned ? "All clean" : "Ready to scan",
                                   message: model.hasScanned
                                       ? "No junk was found."
                                       : "Scan your Mac for caches, logs and other files that are safe to remove.")
                }
            } else {
                List {
                    ForEach($model.groups) { $group in
                        DisclosureGroup {
                            ForEach($group.items) { $item in
                                FileRow(isSelected: $item.isSelected, url: item.url, size: item.size)
                            }
                        } label: {
                            groupLabel(group)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .confirmationDialog("Clean \(model.selectedCount) items (\(FileUtils.format(model.selectedTotal)))?",
                            isPresented: $confirmClean) {
            Button(Cleaner.deletePermanently ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                Task { await model.clean() }
            }
        } message: {
            Text(Cleaner.deletePermanently
                 ? "Files will be deleted permanently. This cannot be undone."
                 : "Files will be moved to the Trash so you can restore them if needed.")
        }
    }

    private func groupLabel(_ group: JunkGroup) -> some View {
        let allSelected = !group.items.isEmpty && group.items.allSatisfy(\.isSelected)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { allSelected },
                                     set: { model.setAll(in: group.id, $0) }))
                .labelsHidden()
            Image(systemName: group.icon).foregroundStyle(.pink).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.headline)
                Text(group.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(group.items.count) items").font(.caption).foregroundStyle(.secondary)
            Text(FileUtils.format(group.total)).monospacedDigit().fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}
