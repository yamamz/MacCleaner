import SwiftUI

struct MaintenanceTask: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let icon: String
    let command: String
    let needsAdmin: Bool
}

enum MaintenanceRunner {
    static let tasks: [MaintenanceTask] = [
        .init(id: "dns", name: "Flush DNS Cache",
              detail: "Fixes websites that won't load or resolve to old addresses.",
              icon: "network", command: "dscacheutil -flushcache; killall -HUP mDNSResponder", needsAdmin: true),
        .init(id: "ram", name: "Free Up RAM",
              detail: "Purges inactive memory and disk caches. Apps may feel slower for a moment.",
              icon: "memorychip", command: "purge", needsAdmin: true),
        .init(id: "spotlight", name: "Reindex Spotlight",
              detail: "Rebuilds the search index when Spotlight results are missing or wrong. Takes a while.",
              icon: "magnifyingglass", command: "mdutil -E /", needsAdmin: true),
        .init(id: "launchservices", name: "Rebuild Launch Services",
              detail: "Removes duplicate entries in the “Open With” menu and fixes wrong default apps.",
              icon: "list.bullet.rectangle",
              command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user",
              needsAdmin: false),
        .init(id: "quicklook", name: "Reset Quick Look",
              detail: "Clears thumbnail caches when previews show stale or blank images.",
              icon: "eye", command: "qlmanage -r cache; qlmanage -r", needsAdmin: false),
        .init(id: "fonts", name: "Clear Font Caches",
              detail: "Fixes garbled or missing fonts. Log out afterwards for full effect.",
              icon: "textformat", command: "atsutil databases -removeUser", needsAdmin: false),
        .init(id: "ui", name: "Relaunch Finder & Dock",
              detail: "Restarts the Finder and Dock if they become unresponsive.",
              icon: "dock.rectangle", command: "killall Finder; killall Dock", needsAdmin: false),
    ]

    /// Escapes a shell command for use inside an AppleScript string literal.
    static func appleScriptLiteral(_ command: String) -> String {
        command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Executable and arguments used to run a task.
    static func invocation(for task: MaintenanceTask) -> (executable: String, arguments: [String]) {
        if task.needsAdmin {
            let script = "do shell script \"\(appleScriptLiteral(task.command))\" with administrator privileges"
            return ("/usr/bin/osascript", ["-e", script])
        }
        return ("/bin/zsh", ["-c", task.command])
    }

    static func run(_ task: MaintenanceTask) -> (success: Bool, output: String) {
        let (executable, arguments) = invocation(for: task)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

@MainActor
final class MaintenanceModel: ObservableObject {
    enum Status: Equatable { case idle, running, succeeded(String), failed(String) }

    @Published var selected: Set<String> = []
    @Published var statuses: [String: Status] = [:]
    @Published var isRunning = false

    func runSelected() async {
        isRunning = true
        for task in MaintenanceRunner.tasks where selected.contains(task.id) {
            statuses[task.id] = .running
            let (ok, output) = await Task.detached(priority: .userInitiated) { MaintenanceRunner.run(task) }.value
            statuses[task.id] = ok ? .succeeded(output) : .failed(output.isEmpty ? "Failed" : output)
        }
        isRunning = false
    }
}

struct MaintenanceView: View {
    @EnvironmentObject var model: MaintenanceModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Maintenance", subtitle: "Routine fixes that keep macOS running smoothly.",
                       icon: "wrench.and.screwdriver.fill", tint: .brown) {
                if model.isRunning { ProgressView().controlSize(.small) }
                Button("Run \(model.selected.count) Task\(model.selected.count == 1 ? "" : "s")") {
                    Task { await model.runSelected() }
                }
                .buttonStyle(.borderedProminent).tint(.brown)
                .disabled(model.selected.isEmpty || model.isRunning)
            }
            List(MaintenanceRunner.tasks) { task in
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { model.selected.contains(task.id) },
                        set: { on in
                            if on { model.selected.insert(task.id) } else { model.selected.remove(task.id) }
                        }))
                        .labelsHidden()
                    Image(systemName: task.icon).font(.title3).foregroundStyle(.brown).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(task.name).font(.headline)
                            if task.needsAdmin {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                    .help("Asks for your administrator password")
                            }
                        }
                        Text(task.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusView(model.statuses[task.id] ?? .idle)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder private func statusView(_ status: MaintenanceModel.Status) -> some View {
        switch status {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .succeeded(let output):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(output.isEmpty ? "Done" : output)
        case .failed(let output):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(output)
        }
    }
}
