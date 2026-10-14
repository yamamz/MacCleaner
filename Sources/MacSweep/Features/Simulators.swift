import SwiftUI

struct SimDevice: Identifiable, Hashable, Sendable {
    let id: String // UDID
    let name: String
    let isBooted: Bool
    let size: Int64
    let lastBooted: Date?
    var isSelected = false
}

/// A simulator runtime (e.g. iOS 18.1) with the devices created for it.
struct SimRuntime: Identifiable, Sendable {
    let id: String          // runtime identifier, e.g. com.apple.CoreSimulator.SimRuntime.iOS-18-1
    let name: String        // "iOS 18.1"
    let platform: String    // "iOS"
    let build: String?
    /// Disk image to pass to `simctl runtime delete`; nil when the runtime is no longer installed.
    let imageID: String?
    let imageSize: Int64
    let deletable: Bool
    let lastUsed: Date?
    var devices: [SimDevice]
    /// Delete the runtime image and every device that uses it.
    var isSelected = false

    var isInstalled: Bool { imageID != nil }
    var hasBootedDevice: Bool { devices.contains(where: \.isBooted) }
    var canDeleteRuntime: Bool { !hasBootedDevice && (!isInstalled || deletable) }
    var devicesSize: Int64 { devices.reduce(0) { $0 + $1.size } }
    var total: Int64 { imageSize + devicesSize }
    var selectedSize: Int64 {
        isSelected ? total : devices.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }
    var selectedCount: Int { isSelected ? 1 + devices.count : devices.filter(\.isSelected).count }
}

enum Simctl {
    private struct DeviceList: Decodable { let devices: [String: [Device]] }
    private struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let dataPathSize: Int64?
        let lastBootedAt: String?
    }
    private struct RuntimeImage: Decodable {
        let identifier: String
        let runtimeIdentifier: String?
        let version: String?
        let build: String?
        let sizeBytes: Int64?
        let deletable: Bool?
        let lastUsedAt: String?
    }

    /// Builds runtimes from `simctl list devices --json` and `simctl runtime list --json`, newest first.
    static func parse(devices devicesJSON: Data, runtimes runtimesJSON: Data) throws -> [SimRuntime] {
        let devices = try JSONDecoder().decode(DeviceList.self, from: devicesJSON).devices
        let images = try JSONDecoder().decode([String: RuntimeImage].self, from: runtimesJSON).values
        let dates = ISO8601DateFormatter()

        var byID: [String: SimRuntime] = [:]
        for image in images {
            guard let runtimeID = image.runtimeIdentifier, byID[runtimeID] == nil else { continue }
            let (platform, version) = describe(runtimeID)
            byID[runtimeID] = SimRuntime(
                id: runtimeID, name: "\(platform) \(image.version ?? version)", platform: platform,
                build: image.build, imageID: image.identifier, imageSize: image.sizeBytes ?? 0,
                deletable: image.deletable ?? true, lastUsed: image.lastUsedAt.flatMap(dates.date(from:)),
                devices: [])
        }
        for (runtimeID, list) in devices where !list.isEmpty {
            if byID[runtimeID] == nil {
                // Devices left behind by a runtime that is no longer installed.
                let (platform, version) = describe(runtimeID)
                byID[runtimeID] = SimRuntime(id: runtimeID, name: "\(platform) \(version)", platform: platform,
                                             build: nil, imageID: nil, imageSize: 0, deletable: true,
                                             lastUsed: nil, devices: [])
            }
            byID[runtimeID]!.devices = list.map {
                SimDevice(id: $0.udid, name: $0.name, isBooted: $0.state == "Booted", size: $0.dataPathSize ?? 0,
                          lastBooted: $0.lastBootedAt.flatMap(dates.date(from:)))
            }
            .sorted { $0.size > $1.size }
        }
        return byID.values.sorted {
            $0.platform != $1.platform
                ? $0.platform < $1.platform
                : $0.name.compare($1.name, options: .numeric) == .orderedDescending
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-1" → ("iOS", "18.1").
    static func describe(_ runtimeID: String) -> (platform: String, version: String) {
        let parts = (runtimeID.split(separator: ".").last ?? "").split(separator: "-").map(String.init)
        guard let first = parts.first else { return (runtimeID, "") }
        let platform = first == "xrOS" ? "visionOS" : first
        return (platform, parts.dropFirst().joined(separator: "."))
    }

    /// `simctl` argument lists for the current selection: devices first, then runtime images.
    static func commands(for runtimes: [SimRuntime]) -> [[String]] {
        var deviceIDs: [String] = []
        var images: [String] = []
        for runtime in runtimes {
            if runtime.isSelected {
                deviceIDs += runtime.devices.map(\.id)
                if let image = runtime.imageID { images.append(image) }
            } else {
                deviceIDs += runtime.devices.filter { $0.isSelected && !$0.isBooted }.map(\.id)
            }
        }
        var commands: [[String]] = []
        if !deviceIDs.isEmpty { commands.append(["delete"] + deviceIDs) }
        commands += images.map { ["runtime", "delete", $0] }
        return commands
    }

    static func load() throws -> [SimRuntime] {
        let devices = try run(["list", "devices", "--json"])
        let runtimes = try run(["runtime", "list", "--json"])
        return try parse(devices: devices, runtimes: runtimes)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `xcrun simctl …` and returns its standard output.
    @discardableResult
    static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Drain stderr on another thread while reading stdout, so neither pipe can fill up and block simctl.
        final class Box: @unchecked Sendable { var data = Data() }
        let stderr = Box()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { stderr.data = errors.fileHandleForReading.readDataToEndOfFile() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: message.isEmpty ? "simctl exited with status \(process.terminationStatus)" : message)
        }
        return data
    }
}

@MainActor
final class SimulatorsModel: ObservableObject {
    @Published var runtimes: [SimRuntime] = []
    @Published var isLoading = false
    @Published var isDeleting = false
    @Published var hasLoaded = false
    @Published var error: String?
    @Published var lastResult: CleanResult?

    var total: Int64 { runtimes.reduce(0) { $0 + $1.total } }
    var selectedSize: Int64 { runtimes.reduce(0) { $0 + $1.selectedSize } }
    var selectedCount: Int { runtimes.reduce(0) { $0 + $1.selectedCount } }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        do {
            runtimes = try await Task.detached(priority: .userInitiated) { try Simctl.load() }.value
        } catch {
            runtimes = []
            self.error = "Couldn't read simulators. Is Xcode installed? (\(error.localizedDescription))"
        }
        hasLoaded = true
        isLoading = false
    }

    /// Selects every runtime except the newest one of each platform.
    func selectAllButNewest() {
        var seenPlatforms: Set<String> = []
        for i in runtimes.indices where runtimes[i].isInstalled || !runtimes[i].devices.isEmpty {
            let isNewest = runtimes[i].isInstalled && seenPlatforms.insert(runtimes[i].platform).inserted
            runtimes[i].isSelected = !isNewest && runtimes[i].canDeleteRuntime
        }
    }

    func delete() async {
        let commands = Simctl.commands(for: runtimes)
        guard !commands.isEmpty, !isDeleting else { return }
        isDeleting = true
        var result = CleanResult(movedToTrash: false)
        let freed = selectedSize, count = selectedCount
        let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
            var failures: [String] = []
            for command in commands {
                do { try Simctl.run(command) } catch {
                    failures.append("simctl \(command.prefix(2).joined(separator: " ")): \(error.localizedDescription)")
                }
            }
            return failures
        }.value
        result.failures = failures
        if failures.isEmpty {
            result.removed = count
            result.freed = freed
        }
        lastResult = result
        isDeleting = false
        await load()
    }
}

struct SimulatorsView: View {
    @EnvironmentObject var model: SimulatorsModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Simulators",
                       subtitle: model.hasLoaded && model.error == nil
                           ? "\(FileUtils.format(model.total)) in Xcode simulators · \(FileUtils.format(model.selectedSize)) selected"
                           : "Remove old Xcode simulator runtimes and devices.",
                       icon: Pane.simulators.icon, tint: Pane.simulators.tint) {
                if model.isLoading || model.isDeleting {
                    ProgressView().controlSize(.small)
                    Text(model.isDeleting ? "Deleting…" : "Reading simulators…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Keep Newest Only") { model.selectAllButNewest() }
                    .disabled(model.runtimes.count < 2 || model.isLoading || model.isDeleting)
                    .help("Select every runtime except the newest one for each platform")
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isLoading || model.isDeleting)
                Button("Delete \(FileUtils.format(model.selectedSize))") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(Pane.simulators.tint)
                    .disabled(model.selectedCount == 0 || model.isLoading || model.isDeleting)
            }

            if let result = model.lastResult {
                ResultBanner(result: result) { model.lastResult = nil }.padding(.bottom, 8)
            }
            if model.hasLoaded, !model.runtimes.isEmpty { permanenceNote.padding(.bottom, 8) }

            if let error = model.error {
                EmptyStateView(icon: "exclamationmark.triangle.fill", title: "Simulators unavailable", message: error)
            } else if model.runtimes.isEmpty {
                if model.isLoading || !model.hasLoaded {
                    ProgressView("Reading simulators…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(icon: "iphone.gen3", title: "No simulators",
                                   message: "There are no Xcode simulator runtimes or devices on this Mac.")
                }
            } else {
                List {
                    ForEach($model.runtimes) { $runtime in
                        DisclosureGroup {
                            ForEach($runtime.devices) { $device in deviceRow($device, runtime: runtime) }
                        } label: {
                            runtimeLabel($runtime)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .task { if !model.hasLoaded { await model.load() } }
        .confirmationDialog("Delete \(model.selectedCount) simulator item(s) (\(FileUtils.format(model.selectedSize)))?",
                            isPresented: $confirm) {
            Button("Delete Permanently", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("Simulators are deleted permanently, including any apps and data installed on them. "
                 + "Xcode can download runtimes again from Settings › Components.")
        }
    }

    private var permanenceNote: some View {
        HStack {
            Image(systemName: "info.circle.fill").foregroundStyle(Pane.simulators.tint)
            Text("Deleted simulators don't go to the Trash. Tick a runtime to remove it with all its devices, "
                 + "or expand it to pick individual devices.")
                .font(.callout)
            Spacer()
        }
        .padding(12)
        .background(Pane.simulators.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
    }

    private func runtimeLabel(_ runtime: Binding<SimRuntime>) -> some View {
        let r = runtime.wrappedValue
        var details: [String] = []
        if let build = r.build { details.append("Build \(build)") }
        if !r.isInstalled { details.append("Runtime not installed") }
        if let used = r.lastUsed { details.append("Last used \(used.formatted(.relative(presentation: .named)))") }
        if r.hasBootedDevice { details.append("Has a running simulator") }
        details.append("\(r.devices.count) device\(r.devices.count == 1 ? "" : "s")")

        return HStack(spacing: 10) {
            Toggle("", isOn: runtime.isSelected).labelsHidden().disabled(!r.canDeleteRuntime)
                .help(r.canDeleteRuntime ? "Delete this runtime and all its devices" : "Can't delete while a simulator is running")
            Image(systemName: icon(for: r.platform)).foregroundStyle(Pane.simulators.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.headline)
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if r.isInstalled {
                Text("Runtime \(FileUtils.format(r.imageSize))").font(.caption).foregroundStyle(.secondary)
            }
            Text(FileUtils.format(r.total)).monospacedDigit().fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func deviceRow(_ device: Binding<SimDevice>, runtime: SimRuntime) -> some View {
        let d = device.wrappedValue
        let selected = Binding(get: { runtime.isSelected || d.isSelected }, set: { device.wrappedValue.isSelected = $0 })
        return HStack(spacing: 10) {
            Toggle("", isOn: selected).labelsHidden().disabled(runtime.isSelected || d.isBooted)
            Image(systemName: d.name.contains("iPad") ? "ipad.and.iphone" : "iphone.gen3")
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name)
                Text(d.isBooted ? "Running" : d.lastBooted.map { "Last booted \($0.formatted(.relative(presentation: .named)))" } ?? "Never booted")
                    .font(.caption).foregroundStyle(d.isBooted ? .green : .secondary)
            }
            Spacer()
            Text(FileUtils.format(d.size)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func icon(for platform: String) -> String {
        switch platform {
        case "watchOS": "applewatch"
        case "tvOS": "appletv"
        case "visionOS": "visionpro"
        default: "iphone.gen3"
        }
    }
}
