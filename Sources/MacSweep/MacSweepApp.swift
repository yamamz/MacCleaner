import AppKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case smartScan = "Smart Scan"
    case junk = "System Junk"
    case largeFiles = "Large & Old Files"
    case duplicates = "Duplicates"
    case spaceLens = "Space Lens"
    case trash = "Trash Bins"
    case uninstaller = "Uninstaller"
    case optimization = "Optimization"
    case maintenance = "Maintenance"
    case monitor = "Monitor"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smartScan: "sparkles"
        case .junk: "trash.circle"
        case .largeFiles: "doc.on.doc"
        case .duplicates: "square.on.square"
        case .spaceLens: "circle.hexagongrid"
        case .trash: "trash"
        case .uninstaller: "xmark.app"
        case .optimization: "slider.horizontal.3"
        case .maintenance: "wrench.and.screwdriver"
        case .monitor: "gauge.with.dots.needle.67percent"
        }
    }
}

enum SettingsKeys {
    static let showMenuBar = "showMenuBarMonitor"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running in the menu bar when the monitor is enabled.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: SettingsKeys.showMenuBar)
    }
}

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(SettingsKeys.showMenuBar) private var showMenuBar = true
    @StateObject private var junk = JunkModel()
    @StateObject private var large = LargeFilesModel()
    @StateObject private var duplicates = DuplicatesModel()
    @StateObject private var spaceLens = SpaceLensModel()
    @StateObject private var trash = TrashModel()
    @StateObject private var uninstaller = UninstallerModel()
    @StateObject private var optimization = OptimizationModel()
    @StateObject private var maintenance = MaintenanceModel()
    @StateObject private var monitor = MonitorModel()

    var body: some Scene {
        Window("MacSweep", id: "main") {
            ContentView()
                .environmentObject(junk)
                .environmentObject(large)
                .environmentObject(duplicates)
                .environmentObject(spaceLens)
                .environmentObject(trash)
                .environmentObject(uninstaller)
                .environmentObject(optimization)
                .environmentObject(maintenance)
                .environmentObject(monitor)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { monitor.start() }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarMonitorView().environmentObject(monitor)
        } label: {
            Image(systemName: "sparkles")
            Text("\(Int(monitor.cpu * 100))%")
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView() }
    }
}

struct ContentView: View {
    @State private var pane: Pane? = .smartScan

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                row(.smartScan)
                Section("Cleanup") { ForEach([Pane.junk, .largeFiles, .duplicates, .trash]) { row($0) } }
                Section("Storage") { row(.spaceLens) }
                Section("Applications") { ForEach([Pane.uninstaller, .optimization]) { row($0) } }
                Section("Performance") { ForEach([Pane.maintenance, .monitor]) { row($0) } }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch pane ?? .smartScan {
            case .smartScan: SmartScanView(pane: $pane)
            case .junk: JunkView()
            case .largeFiles: LargeFilesView()
            case .duplicates: DuplicatesView()
            case .spaceLens: SpaceLensView()
            case .trash: TrashView()
            case .uninstaller: UninstallerView()
            case .optimization: OptimizationView()
            case .maintenance: MaintenanceView()
            case .monitor: MonitorView()
            }
        }
    }

    private func row(_ p: Pane) -> some View {
        Label(p.rawValue, systemImage: p.icon).tag(p)
    }
}

struct SettingsView: View {
    @AppStorage(Cleaner.deletePermanentlyKey) private var deletePermanently = false
    @AppStorage(SettingsKeys.showMenuBar) private var showMenuBar = true
    @State private var ignored = IgnoreList.paths
    @State private var selectedIgnored: String?

    var body: some View {
        TabView {
            Form {
                Toggle("Delete files permanently instead of moving them to the Trash", isOn: $deletePermanently)
                Text(deletePermanently
                     ? "⚠️ Cleaned files cannot be recovered."
                     : "Cleaned files go to the Trash so you can restore them. Empty the Trash to reclaim space.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show CPU monitor in the menu bar", isOn: $showMenuBar)
                Divider()
                Button("Grant Full Disk Access…") { FileUtils.openFullDiskAccessSettings() }
                Text("Full Disk Access lets MacSweep scan Mail, Trash and app containers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gearshape") }

            VStack(alignment: .leading, spacing: 8) {
                Text("MacSweep never scans or cleans these folders and files.")
                    .font(.callout).foregroundStyle(.secondary)
                List(ignored, id: \.self, selection: $selectedIgnored) { path in
                    Label(FileUtils.displayPath(URL(fileURLWithPath: path)), systemImage: "eye.slash")
                }
                .frame(minHeight: 160)
                HStack {
                    Button { addIgnored() } label: { Image(systemName: "plus") }
                    Button {
                        ignored.removeAll { $0 == selectedIgnored }
                        IgnoreList.paths = ignored
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedIgnored == nil)
                }
            }
            .padding(20)
            .tabItem { Label("Ignore List", systemImage: "eye.slash") }
        }
        .frame(width: 500, height: 320)
    }

    private func addIgnored() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileUtils.home
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !ignored.contains(url.path) { ignored.append(url.path) }
        IgnoreList.paths = ignored
    }
}
