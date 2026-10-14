import AppKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case smartScan = "Smart Scan"
    case junk = "System Junk"
    case simulators = "Simulators"
    case emulators = "Android Emulators"
    case largeFiles = "Large & Old Files"
    case duplicates = "Duplicates"
    case spaceLens = "Space Lens"
    case security = "Malware & Bloatware"
    case trash = "Trash Bins"
    case uninstaller = "Uninstaller"
    case optimization = "Optimization"
    case maintenance = "Maintenance"
    case monitor = "Monitor"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smartScan: "sparkles"
        case .junk: "bubbles.and.sparkles.fill"
        case .simulators: "iphone.gen3"
        case .emulators: "smartphone"
        case .largeFiles: "doc.on.doc.fill"
        case .duplicates: "square.fill.on.square.fill"
        case .spaceLens: "circle.hexagongrid.fill"
        case .security: "checkmark.shield.fill"
        case .trash: "trash.fill"
        case .uninstaller: "xmark.app.fill"
        case .optimization: "slider.horizontal.3"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .monitor: "gauge.with.dots.needle.67percent"
        }
    }

    /// Matches the accent each screen uses in its header.
    var tint: Color {
        switch self {
        case .smartScan: .purple
        case .junk: .pink
        case .simulators: .mint
        case .emulators: Color(red: 0.20, green: 0.66, blue: 0.33) // Android green
        case .largeFiles: .orange
        case .duplicates: .teal
        case .spaceLens: .indigo
        case .security: .red
        case .trash: .green
        case .uninstaller: .blue
        case .optimization: .purple
        case .maintenance: .brown
        case .monitor: .cyan
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
    @StateObject private var simulators = SimulatorsModel()
    @StateObject private var emulators = EmulatorsModel()
    @StateObject private var security = SecurityModel()
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
                .environmentObject(simulators)
                .environmentObject(emulators)
                .environmentObject(security)
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
    @EnvironmentObject var monitor: MonitorModel
    @State private var pane: Pane? = .smartScan

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                row(.smartScan)
                Section("Cleanup") { ForEach([Pane.junk, .simulators, .emulators, .largeFiles, .duplicates, .trash]) { row($0) } }
                Section("Protection") { row(.security) }
                Section("Storage") { row(.spaceLens) }
                Section("Applications") { ForEach([Pane.uninstaller, .optimization]) { row($0) } }
                Section("Performance") { ForEach([Pane.maintenance, .monitor]) { row($0) } }
            }
            .safeAreaInset(edge: .top, spacing: 0) { brand }
            .safeAreaInset(edge: .bottom, spacing: 0) { storageMeter }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch pane ?? .smartScan {
            case .smartScan: SmartScanView(pane: $pane)
            case .junk: JunkView()
            case .simulators: SimulatorsView()
            case .emulators: EmulatorsView()
            case .largeFiles: LargeFilesView()
            case .duplicates: DuplicatesView()
            case .spaceLens: SpaceLensView()
            case .security: SecurityView()
            case .trash: TrashView()
            case .uninstaller: UninstallerView()
            case .optimization: OptimizationView()
            case .maintenance: MaintenanceView()
            case .monitor: MonitorView()
            }
        }
    }

    /// Colored rounded-square icon tiles, like System Settings.
    private func row(_ p: Pane) -> some View {
        Label {
            Text(p.rawValue)
        } icon: {
            Image(systemName: p.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(p.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: p.tint.opacity(0.35), radius: 2, y: 1)
        }
        .padding(.vertical, 2)
        .tag(p)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("MacSweep").font(.headline)
                Text("Keep your Mac fresh").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var storageMeter: some View {
        let used = Double(monitor.diskUsed) / Double(max(monitor.diskTotal, 1))
        let tint: Color = used > 0.9 ? .red : used > 0.75 ? .orange : .green
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                Text("Macintosh HD").font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int(used * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(used, 0), 1)).tint(tint)
            Text("\(FileUtils.format(monitor.diskTotal - monitor.diskUsed)) available")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(12)
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
