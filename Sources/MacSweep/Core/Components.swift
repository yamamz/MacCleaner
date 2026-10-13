import SwiftUI

struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(20)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, icon: String, tint: Color) {
        self.init(title: title, subtitle: subtitle, icon: icon, tint: tint) { EmptyView() }
    }
}

struct ResultBanner: View {
    let result: CleanResult
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.failures.isEmpty ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.summary).font(.callout)
                if !result.failures.isEmpty {
                    DisclosureGroup("Details") {
                        ScrollView {
                            Text(result.failures.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                    }
                    .font(.caption)
                }
            }
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
    }
}

struct FullDiskAccessHint: View {
    var body: some View {
        HStack {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Some locations need Full Disk Access to scan.")
                .font(.callout)
            Spacer()
            Button("Open Settings") { FileUtils.openFullDiskAccessSettings() }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileRow: View {
    @Binding var isSelected: Bool
    let url: URL
    let size: Int64
    var caption: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isSelected).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(caption ?? FileUtils.displayPath(url.deletingLastPathComponent()))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(FileUtils.format(size)).monospacedDigit().foregroundStyle(.secondary)
            Button { FileUtils.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
        }
    }
}
