import AppKit
import Darwin
import SwiftUI

enum SystemStats {
    struct CPUTicks { var user, system, idle, nice: UInt32 }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    static func cpuUsage(from a: CPUTicks, to b: CPUTicks) -> Double {
        let user = Double(b.user &- a.user), sys = Double(b.system &- a.system)
        let idle = Double(b.idle &- a.idle), nice = Double(b.nice &- a.nice)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total : 0
    }

    /// Mirrors Activity Monitor's "Memory Used" (app memory + wired + compressed).
    static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    static func disk() -> (used: Int64, total: Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity else { return (0, 0) }
        let free = v.volumeAvailableCapacityForImportantUsage ?? 0
        return (Int64(total) - free, Int64(total))
    }

    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return kr == 0 ? info.ri_phys_footprint : nil
    }
}

struct RunningAppInfo: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let memory: UInt64
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var cpu: Double = 0
    @Published var cpuHistory: [Double] = []
    @Published var memUsed: UInt64 = 0
    @Published var memTotal: UInt64 = 1
    @Published var diskUsed: Int64 = 0
    @Published var diskTotal: Int64 = 1
    @Published var apps: [RunningAppInfo] = []

    private var lastTicks = SystemStats.cpuTicks()
    private var loop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refresh() {
        if let now = SystemStats.cpuTicks() {
            if let last = lastTicks { cpu = SystemStats.cpuUsage(from: last, to: now) }
            lastTicks = now
            cpuHistory.append(cpu)
            if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        }
        (memUsed, memTotal) = SystemStats.memory()
        (diskUsed, diskTotal) = SystemStats.disk()
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map { RunningAppInfo(id: $0.processIdentifier, name: $0.localizedName ?? "App", icon: $0.icon,
                                  memory: SystemStats.footprint(of: $0.processIdentifier) ?? 0) }
            .sorted { $0.memory > $1.memory }
    }

    func quit(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            refresh()
        }
    }
}

struct GaugeCard: View {
    let title: String
    let value: Double
    let detail: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Gauge(value: min(max(value, 0), 1)) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(value * 100))%").font(.title3.bold()).monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .scaleEffect(1.6)
            .frame(width: 100, height: 100)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                let step = geo.size.width / CGFloat(max(values.count - 1, 1))
                for (i, v) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(v)))
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }
}

struct MonitorView: View {
    @EnvironmentObject var model: MonitorModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "System Monitor", subtitle: "Live CPU, memory and storage usage.",
                       icon: "gauge.with.dots.needle.67percent", tint: .cyan)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        GaugeCard(title: "CPU", value: model.cpu, detail: "All cores", tint: .cyan)
                        GaugeCard(title: "Memory", value: Double(model.memUsed) / Double(model.memTotal),
                                  detail: "\(FileUtils.format(Int64(model.memUsed))) of \(FileUtils.format(Int64(model.memTotal)))",
                                  tint: .indigo)
                        GaugeCard(title: "Storage", value: Double(model.diskUsed) / Double(max(model.diskTotal, 1)),
                                  detail: "\(FileUtils.format(model.diskTotal - model.diskUsed)) available",
                                  tint: .mint)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CPU history (2 min)").font(.headline)
                        Sparkline(values: model.cpuHistory).frame(height: 60)
                            .padding(10)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("Running apps by memory").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(model.apps) { app in
                            HStack {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                                }
                                Text(app.name)
                                Spacer()
                                Text(FileUtils.format(Int64(app.memory))).monospacedDigit().foregroundStyle(.secondary)
                                Button("Quit") { model.quit(app.id) }.controlSize(.small)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            Divider()
                        }
                    }
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .onAppear { model.start() }
    }
}

struct MenuBarMonitorView: View {
    @EnvironmentObject var model: MonitorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacSweep").font(.headline)
            meter("CPU", model.cpu, "\(Int(model.cpu * 100))%", .cyan)
            meter("Memory", Double(model.memUsed) / Double(model.memTotal),
                  "\(FileUtils.format(Int64(model.memUsed))) / \(FileUtils.format(Int64(model.memTotal)))", .indigo)
            meter("Storage", Double(model.diskUsed) / Double(max(model.diskTotal, 1)),
                  "\(FileUtils.format(model.diskTotal - model.diskUsed)) free", .mint)
            Divider()
            if let top = model.apps.first {
                Text("Top app: \(top.name) (\(FileUtils.format(Int64(top.memory))))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open MacSweep") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { model.start() }
    }

    private func meter(_ title: String, _ value: Double, _ detail: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 1)).tint(tint)
        }
    }
}
