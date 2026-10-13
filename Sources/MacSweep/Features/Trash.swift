import SwiftUI

@MainActor
final class TrashModel: ObservableObject {
    @Published var size: Int64 = 0
    @Published var itemCount = 0
    @Published var accessDenied = false
    @Published var isWorking = false
    @Published var message: String?

    private let trashURL = FileUtils.home.appendingPathComponent(".Trash")

    func refresh() async {
        isWorking = true
        let url = trashURL
        let (count, size, denied) = await Task.detached { () -> (Int, Int64, Bool) in
            guard let items = try? FileUtils.children(of: url, includeHidden: true) else { return (0, 0, true) }
            let visible = items.filter { $0.lastPathComponent != ".DS_Store" }
            return (visible.count, visible.reduce(0) { $0 + FileUtils.size(of: $1) }, false)
        }.value
        itemCount = count
        self.size = size
        accessDenied = denied
        isWorking = false
    }

    /// Asks Finder to empty the Trash (macOS will request Automation permission the first time).
    func empty() async {
        isWorking = true
        let status = await Task.detached { () -> Int32 in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"Finder\" to empty trash"]
            do { try task.run(); task.waitUntilExit() } catch { return -1 }
            return task.terminationStatus
        }.value
        message = status == 0 ? "Trash emptied." : "Could not empty the Trash. Allow MacSweep to control Finder in System Settings › Privacy & Security › Automation."
        await refresh()
    }
}

struct TrashView: View {
    @EnvironmentObject var model: TrashModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Trash Bins", subtitle: "Reclaim the space used by files you already deleted.",
                       icon: "trash.fill", tint: .green) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            }
            if model.accessDenied { FullDiskAccessHint() }

            VStack(spacing: 16) {
                Image(systemName: model.itemCount == 0 && !model.accessDenied ? "trash" : "trash.fill")
                    .font(.system(size: 80)).foregroundStyle(.green.gradient)
                if model.accessDenied {
                    Text("Size unknown").font(.largeTitle.bold())
                } else {
                    Text(FileUtils.format(model.size)).font(.system(size: 44, weight: .bold)).monospacedDigit()
                    Text("\(model.itemCount) items in Trash").foregroundStyle(.secondary)
                }
                Button("Empty Trash") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                    .disabled(model.isWorking || (model.itemCount == 0 && !model.accessDenied))
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.refresh() }
        .confirmationDialog("Empty the Trash?", isPresented: $confirm) {
            Button("Empty Trash", role: .destructive) { Task { await model.empty() } }
        } message: {
            Text("Items in the Trash will be permanently erased.")
        }
    }
}
