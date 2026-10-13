import SwiftUI

struct SmartScanView: View {
    @EnvironmentObject var junk: JunkModel
    @EnvironmentObject var trash: TrashModel
    @EnvironmentObject var large: LargeFilesModel
    @EnvironmentObject var monitor: MonitorModel
    @Binding var pane: Pane?
    @State private var isRunning = false
    @State private var finished = false
    @State private var spin = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [.purple.opacity(0.55), .pink.opacity(0.35), .blue.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    if !finished {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                    }
                    Text(finished ? "Scan complete" : "Welcome to MacSweep")
                        .font(.system(size: 34, weight: .bold))
                    Text(finished
                         ? "Here's what we found. Review the details or clean everything selected."
                         : "Run a Smart Scan to find junk, big files and space you can reclaim.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                if finished {
                    HStack(spacing: 16) {
                        tile("System Junk", FileUtils.format(junk.selectedTotal), "trash.circle.fill", .pink, .junk)
                        tile(trash.accessDenied ? "Trash · needs Full Disk Access" : "Trash",
                             trash.accessDenied ? "Locked" : FileUtils.format(trash.size), "trash.fill", .green, .trash)
                        tile("Large Files", "\(large.visibleIndices.count) files", "doc.on.doc.fill", .orange, .largeFiles)
                        tile("Free Storage", FileUtils.format(monitor.diskTotal - monitor.diskUsed),
                             "internaldrive.fill", .cyan, .monitor)
                    }
                    .frame(maxWidth: 760)
                }

                if let result = junk.lastResult, finished {
                    Text(result.summary).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 520)
                }

                Button {
                    Task { finished && junk.selectedCount > 0 ? await junk.clean() : await runScan() }
                } label: {
                    ZStack {
                        Circle().fill(.white.opacity(0.25)).frame(width: 150, height: 150)
                        if isRunning || junk.isCleaning {
                            Circle()
                                .trim(from: 0, to: 0.28)
                                .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .frame(width: 150, height: 150)
                                .rotationEffect(.degrees(spin ? 360 : 0))
                                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                                .onAppear { spin = true }
                                .onDisappear { spin = false }
                        }
                        Circle().fill(.white.opacity(0.9)).frame(width: 120, height: 120)
                            .shadow(color: .purple.opacity(0.35), radius: 12, y: 4)
                        if isRunning || junk.isCleaning {
                            ProgressView().controlSize(.large)
                        } else {
                            Text(finished && junk.selectedCount > 0 ? "Clean" : "Scan")
                                .font(.title.bold()).foregroundStyle(.purple)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRunning || junk.isCleaning)

                Text(isRunning ? (junk.status.isEmpty ? "Looking for large files…" : junk.status) : " ")
                    .font(.callout).foregroundStyle(.secondary)

                if finished && !isRunning {
                    Button("Scan Again") { Task { await runScan() } }.buttonStyle(.link)
                }
            }
            .padding(30)
        }
    }

    private func runScan() async {
        isRunning = true
        monitor.refresh()
        async let a: Void = junk.scan()
        async let b: Void = trash.refresh()
        async let c: Void = large.scan()
        _ = await (a, b, c)
        isRunning = false
        finished = true
    }

    private func tile(_ title: String, _ value: String, _ icon: String, _ tint: Color, _ target: Pane) -> some View {
        Button { pane = target } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(tint.gradient, in: Circle())
                    .shadow(color: tint.opacity(0.4), radius: 5, y: 2)
                Text(value).font(.title3.bold()).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
