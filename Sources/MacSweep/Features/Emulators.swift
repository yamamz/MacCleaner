import SwiftUI

/// A removable piece of an emulator that keeps the emulator itself (snapshots, user data).
struct AVDPart: Identifiable, Sendable {
    enum Kind: Sendable { case snapshots, userData }
    let kind: Kind
    let urls: [URL]
    let size: Int64
    var isSelected = false
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .snapshots: "Quick-boot snapshots"
        case .userData: "User data"
        }
    }

    var detail: String {
        switch kind {
        case .snapshots: "The emulator cold-boots once next time."
        case .userData: "Wipes installed apps and data, like Wipe Data in Android Studio."
        }
    }
}

/// An Android Virtual Device.
struct AndroidAVD: Identifiable, Sendable {
    let id: String              // AVD name, e.g. Pixel_7_API_35
    let displayName: String
    let device: String?         // hw.device.name, e.g. pixel_7
    let systemImage: String?    // image.sysdir.1, relative to the SDK
    let folder: URL
    let ini: URL?
    let size: Int64
    let lastUsed: Date?
    let isRunning: Bool
    var parts: [AVDPart]
    /// Delete the whole emulator.
    var isSelected = false

    var selectedSize: Int64 { isSelected ? size : parts.filter(\.isSelected).reduce(0) { $0 + $1.size } }
}

/// An installed system image under `<sdk>/system-images/<api>/<tag>/<abi>`.
struct AndroidSystemImage: Identifiable, Sendable {
    let id: String              // "system-images/android-35/google_apis_playstore/arm64-v8a"
    let url: URL
    let name: String
    let size: Int64
    let usedBy: [String]        // AVD ids
    var isSelected = false
}

enum AndroidEmulators {
    /// Where Android Studio keeps emulators, honouring the same environment variables it does.
    static func avdHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["ANDROID_AVD_HOME"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if let path = environment["ANDROID_USER_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("avd")
        }
        return FileUtils.home.appendingPathComponent(".android/avd")
    }

    static func sdkHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let path = environment[key], !path.isEmpty { return URL(fileURLWithPath: path) }
        }
        return FileUtils.library.appendingPathComponent("Android/sdk")
    }

    static func scan(avdHome: URL, sdk: URL, running: Set<String>) -> (avds: [AndroidAVD], images: [AndroidSystemImage]) {
        let fm = FileManager.default
        var folders: [(name: String, folder: URL, ini: URL?)] = []
        let entries = (try? FileUtils.children(of: avdHome)) ?? []

        // Each emulator is a NAME.ini pointer plus a NAME.avd folder (usually side by side).
        for ini in entries where ini.pathExtension == "ini" {
            let name = ini.deletingPathExtension().lastPathComponent
            let values = readINI(ini)
            var folder = avdHome.appendingPathComponent(name + ".avd")
            if let path = values["path"], fm.fileExists(atPath: path) { folder = URL(fileURLWithPath: path) }
            guard fm.fileExists(atPath: folder.path) else { continue }
            folders.append((name, folder, ini))
        }
        for folder in entries where folder.pathExtension == "avd"
            && !folders.contains(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) {
            folders.append((folder.deletingPathExtension().lastPathComponent, folder, nil))
        }

        var avds: [AndroidAVD] = folders.map { name, folder, ini in
            let config = readINI(folder.appendingPathComponent("config.ini"))
            let launched = folder.appendingPathComponent("hardware-qemu.ini")
            let lastUsed = (try? (FileUtils.exists(launched) ? launched : folder)
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return AndroidAVD(
                id: name,
                displayName: config["avd.ini.displayname"] ?? name.replacingOccurrences(of: "_", with: " "),
                device: config["hw.device.name"],
                systemImage: config["image.sysdir.1"].map(normalizeImagePath),
                folder: folder, ini: ini,
                size: FileUtils.size(of: folder) + (ini.map(FileUtils.size(of:)) ?? 0),
                lastUsed: lastUsed, isRunning: running.contains(name),
                parts: parts(of: folder))
        }
        avds.sort { $0.size > $1.size }

        var images: [AndroidSystemImage] = []
        let root = sdk.appendingPathComponent("system-images")
        for api in (try? FileUtils.children(of: root)) ?? [] {
            for tag in (try? FileUtils.children(of: api)) ?? [] {
                for abi in (try? FileUtils.children(of: tag)) ?? [] where FileUtils.isDirectory(abi) {
                    let id = "system-images/\(api.lastPathComponent)/\(tag.lastPathComponent)/\(abi.lastPathComponent)"
                    images.append(AndroidSystemImage(
                        id: id, url: abi,
                        name: describeImage(api: api.lastPathComponent, tag: tag.lastPathComponent, abi: abi.lastPathComponent),
                        size: FileUtils.size(of: abi),
                        usedBy: avds.filter { $0.systemImage == id }.map(\.id)))
                }
            }
        }
        images.sort { $0.size > $1.size }
        return (avds, images)
    }

    /// Snapshots and user data: the parts that can go while keeping the emulator.
    static func parts(of folder: URL) -> [AVDPart] {
        var parts: [AVDPart] = []
        let snapshots = folder.appendingPathComponent("snapshots")
        let snapshotSize = FileUtils.size(of: snapshots)
        if snapshotSize > 0 { parts.append(AVDPart(kind: .snapshots, urls: [snapshots], size: snapshotSize)) }

        let userData = ((try? FileUtils.children(of: folder)) ?? []).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("userdata-qemu.img") || name.hasPrefix("cache.img")
        }
        let userDataSize = userData.reduce(0) { $0 + FileUtils.size(of: $1) }
        if userDataSize > 0 { parts.append(AVDPart(kind: .userData, urls: userData, size: userDataSize)) }
        return parts
    }

    /// Files to move to the Trash for the current selection.
    static func removalItems(avds: [AndroidAVD], images: [AndroidSystemImage]) -> [CleanItem] {
        var items: [CleanItem] = []
        for avd in avds where !avd.isRunning {
            if avd.isSelected {
                items.append(CleanItem(url: avd.folder, size: avd.size, isSelected: true))
                if let ini = avd.ini { items.append(CleanItem(url: ini, size: 0, isSelected: true)) }
            } else {
                for part in avd.parts where part.isSelected {
                    items += part.urls.map { CleanItem(url: $0, size: FileUtils.size(of: $0), isSelected: true) }
                }
            }
        }
        items += images.filter(\.isSelected).map { CleanItem(url: $0.url, size: $0.size, isSelected: true) }
        return items
    }

    /// AVD names of emulators that are running now (from the emulator's `-avd NAME` argument).
    static func runningAVDs(psOutput: String) -> Set<String> {
        var names: Set<String> = []
        for line in psOutput.split(separator: "\n") where line.contains("qemu-system") || line.contains("emulator") {
            let words = line.split(separator: " ").map(String.init)
            if let i = words.firstIndex(of: "-avd"), i + 1 < words.count { names.insert(words[i + 1]) }
            for word in words where word.hasPrefix("@") && word.count > 1 { names.insert(String(word.dropFirst())) }
        }
        return names
    }

    static func runningAVDs() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return runningAVDs(psOutput: String(decoding: data, as: UTF8.self))
    }

    static func readINI(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            values[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// "system-images/android-35/google_apis_playstore/arm64-v8a/" → without the trailing slash.
    static func normalizeImagePath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// "android-35", "google_apis_playstore", "arm64-v8a" → "Android 15 (API 35) · Google Play · arm64".
    static func describeImage(api: String, tag: String, abi: String) -> String {
        let level = api.replacingOccurrences(of: "android-", with: "")
        let versions = ["36": "16", "35": "15", "34": "14", "33": "13", "32": "12L", "31": "12", "30": "11",
                        "29": "10", "28": "9", "27": "8.1", "26": "8.0", "25": "7.1", "24": "7.0", "23": "6.0"]
        let android = versions[level].map { "Android \($0) (API \(level))" } ?? "API \(level)"
        var variant: String
        switch tag.replacingOccurrences(of: "_tablet", with: "") {
        case "google_apis_playstore": variant = "Google Play"
        case "google_apis": variant = "Google APIs"
        case "default": variant = "AOSP"
        default: variant = tag.replacingOccurrences(of: "_", with: " ")
        }
        if tag.hasSuffix("_tablet") { variant += " Tablet" }
        let arch = abi.replacingOccurrences(of: "-v8a", with: "")
        return "\(android) · \(variant) · \(arch)"
    }
}

@MainActor
final class EmulatorsModel: ObservableObject {
    @Published var avds: [AndroidAVD] = []
    @Published var images: [AndroidSystemImage] = []
    @Published var isLoading = false
    @Published var isCleaning = false
    @Published var hasLoaded = false
    @Published var lastResult: CleanResult?

    var total: Int64 { avds.reduce(0) { $0 + $1.size } + images.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 {
        avds.reduce(0) { $0 + $1.selectedSize } + images.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }
    var hasSelection: Bool {
        avds.contains { $0.isSelected || $0.parts.contains(where: \.isSelected) } || images.contains(where: \.isSelected)
    }

    /// An image can go only when every emulator that uses it is being deleted too.
    func isInUse(_ image: AndroidSystemImage) -> Bool {
        image.usedBy.contains { id in !(avds.first { $0.id == id }?.isSelected ?? false) }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        let (avds, images) = await Task.detached(priority: .userInitiated) {
            AndroidEmulators.scan(avdHome: AndroidEmulators.avdHome(), sdk: AndroidEmulators.sdkHome(),
                                  running: AndroidEmulators.runningAVDs())
        }.value
        self.avds = avds
        self.images = images
        hasLoaded = true
        isLoading = false
    }

    /// Deselects images that became in use after an emulator was deselected.
    func reconcileImages() {
        for i in images.indices where images[i].isSelected && isInUse(images[i]) { images[i].isSelected = false }
    }

    func selectUnusedImages() {
        for i in images.indices { images[i].isSelected = !isInUse(images[i]) }
    }

    func clean() async {
        let items = AndroidEmulators.removalItems(avds: avds, images: images)
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        lastResult = await Task.detached(priority: .userInitiated) { Cleaner.remove(items) }.value
        isCleaning = false
        await load()
    }
}

struct EmulatorsView: View {
    @EnvironmentObject var model: EmulatorsModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Android Emulators",
                       subtitle: model.hasLoaded
                           ? "\(FileUtils.format(model.total)) in emulators and system images · \(FileUtils.format(model.selectedSize)) selected"
                           : "Remove Android emulators, their snapshots and unused system images.",
                       icon: Pane.emulators.icon, tint: Pane.emulators.tint) {
                if model.isLoading || model.isCleaning {
                    ProgressView().controlSize(.small)
                    Text(model.isCleaning ? "Cleaning…" : "Reading emulators…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isLoading || model.isCleaning)
                Button("Clean \(FileUtils.format(model.selectedSize))") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(Pane.emulators.tint)
                    .disabled(!model.hasSelection || model.isLoading || model.isCleaning)
            }

            if let result = model.lastResult {
                ResultBanner(result: result) { model.lastResult = nil }.padding(.bottom, 8)
            }

            if model.avds.isEmpty && model.images.isEmpty {
                if model.isLoading || !model.hasLoaded {
                    ProgressView("Reading emulators…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(icon: "smartphone", title: "No Android emulators",
                                   message: "No emulators were found in ~/.android/avd and no system images in the Android SDK.")
                }
            } else {
                List {
                    if !model.avds.isEmpty {
                        Section("Emulators") {
                            ForEach($model.avds) { $avd in
                                DisclosureGroup {
                                    ForEach($avd.parts) { $part in partRow($part, avd: avd) }
                                } label: {
                                    avdLabel($avd)
                                }
                            }
                        }
                    }
                    if !model.images.isEmpty {
                        Section {
                            ForEach($model.images) { $image in imageRow($image) }
                        } header: {
                            HStack {
                                Text("System Images")
                                Spacer()
                                Button("Select Unused") { model.selectUnusedImages() }
                                    .buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .task { if !model.hasLoaded { await model.load() } }
        .confirmationDialog("Clean \(FileUtils.format(model.selectedSize)) of Android emulator data?", isPresented: $confirm) {
            Button(Cleaner.deletePermanently ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                Task { await model.clean() }
            }
        } message: {
            Text(Cleaner.deletePermanently
                 ? "Files will be deleted permanently. This cannot be undone."
                 : "Files will be moved to the Trash so you can restore them if needed. "
                   + "Android Studio can download system images again from the SDK Manager.")
        }
    }

    private func avdLabel(_ avd: Binding<AndroidAVD>) -> some View {
        let a = avd.wrappedValue
        var details: [String] = []
        if let device = a.device { details.append(device.replacingOccurrences(of: "_", with: " ").capitalized) }
        if let image = a.systemImage, let name = model.images.first(where: { $0.id == image })?.name {
            details.append(name.components(separatedBy: " · ").first ?? name)
        } else if a.systemImage != nil {
            details.append("System image missing")
        }
        if a.isRunning {
            details.append("Running")
        } else if let used = a.lastUsed {
            details.append("Last used \(used.formatted(.relative(presentation: .named)))")
        }
        let selected = Binding(get: { avd.wrappedValue.isSelected },
                               set: { avd.wrappedValue.isSelected = $0; model.reconcileImages() })

        return HStack(spacing: 10) {
            Toggle("", isOn: selected).labelsHidden().disabled(a.isRunning)
                .help(a.isRunning ? "Close this emulator first" : "Delete this emulator")
            Image(systemName: a.device?.contains("tablet") == true ? "ipad.landscape" : "smartphone")
                .foregroundStyle(Pane.emulators.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.displayName).font(.headline)
                Text(details.joined(separator: " · ")).font(.caption)
                    .foregroundStyle(a.isRunning ? .green : .secondary).lineLimit(1)
            }
            Spacer()
            Text(FileUtils.format(a.size)).monospacedDigit().fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func partRow(_ part: Binding<AVDPart>, avd: AndroidAVD) -> some View {
        let p = part.wrappedValue
        let selected = Binding(get: { avd.isSelected || p.isSelected }, set: { part.wrappedValue.isSelected = $0 })
        return HStack(spacing: 10) {
            Toggle("", isOn: selected).labelsHidden().disabled(avd.isSelected || avd.isRunning)
            Image(systemName: p.kind == .snapshots ? "clock.arrow.circlepath" : "eraser.fill")
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.title)
                Text(p.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(FileUtils.format(p.size)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func imageRow(_ image: Binding<AndroidSystemImage>) -> some View {
        let i = image.wrappedValue
        let inUse = model.isInUse(i)
        let users = i.usedBy.compactMap { id in model.avds.first { $0.id == id }?.displayName }
        return HStack(spacing: 10) {
            Toggle("", isOn: image.isSelected).labelsHidden().disabled(inUse)
                .help(inUse ? "Used by an emulator you're keeping" : "Delete this system image")
            Image(systemName: "shippingbox.fill").foregroundStyle(Pane.emulators.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(i.name)
                Text(users.isEmpty ? "Not used by any emulator" : "Used by \(users.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(users.isEmpty ? .orange : .secondary).lineLimit(1)
            }
            Spacer()
            Text(FileUtils.format(i.size)).monospacedDigit().foregroundStyle(.secondary)
            Button { FileUtils.reveal(i.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
        }
    }
}
