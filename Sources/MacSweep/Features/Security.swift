import AppKit
import CoreServices
import Security
import SwiftUI

// MARK: - Findings

struct SecurityFinding: Identifiable, Sendable {
    enum Category: Int, Comparable, Sendable {
        case threat, suspicious, bloatware
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .threat: "Known adware & unwanted software"
            case .suspicious: "Suspicious items"
            case .bloatware: "Bloatware"
            }
        }
    }

    /// What MacSweep can do about the finding.
    enum Action: Sendable {
        case uninstall(AppInfo)         // app + its leftovers
        case trash(URL, unload: Bool)   // a user-level file (unload: also stop the launch agent)
        case revealOnly(String)         // needs admin rights or the browser; the string says how
    }

    let id: String
    let category: Category
    let title: String
    let kind: String            // "App", "Launch agent", "Chrome extension"…
    let url: URL
    let reasons: [String]
    let size: Int64?
    let action: Action
    var isSelected = false

    var isRemovable: Bool {
        if case .revealOnly = action { return false }
        return true
    }
}

// MARK: - Known adware and potentially unwanted programs

/// Publicly documented macOS adware families and PUP "optimizers".
/// Matched case-insensitively as substrings of app names, bundle IDs, launch labels and paths.
struct AdwareSignature: Sendable {
    let family: String
    let isAdware: Bool          // false: potentially unwanted program (aggressive "cleaner"/"optimizer")
    let patterns: [String]

    static let all: [AdwareSignature] = [
        .init(family: "Genieo", isAdware: true, patterns: ["genieo"]),
        .init(family: "VSearch", isAdware: true, patterns: ["vsearch"]),
        .init(family: "Conduit", isAdware: true, patterns: ["com.conduit."]),
        .init(family: "Spigot", isAdware: true, patterns: ["com.spigot."]),
        .init(family: "Crossrider", isAdware: true, patterns: ["crossrider"]),
        .init(family: "InstallCore", isAdware: true, patterns: ["installcore", "com.installmac."]),
        .init(family: "Bundlore", isAdware: true, patterns: ["bundlore"]),
        .init(family: "Pirrit", isAdware: true, patterns: ["pirrit"]),
        .init(family: "Shlayer", isAdware: true, patterns: ["shlayer"]),
        .init(family: "Mughthesec", isAdware: true, patterns: ["mughthesec"]),
        .init(family: "SearchMine", isAdware: true, patterns: ["searchmine"]),
        .init(family: "SearchBaron", isAdware: true, patterns: ["searchbaron"]),
        .init(family: "SafeFinder", isAdware: true, patterns: ["safefinder"]),
        .init(family: "ChumSearch", isAdware: true, patterns: ["chumsearch"]),
        .init(family: "MacKeeper", isAdware: false, patterns: ["mackeeper", "com.zeobit."]),
        .init(family: "PCVARK (Advanced Mac Cleaner, Mac Tonic)", isAdware: false,
              patterns: ["com.pcv.", "advancedmaccleaner", "advanced mac cleaner", "mactonic", "mac tonic"]),
        .init(family: "Mac Auto Fixer", isAdware: false, patterns: ["macautofixer", "mac auto fixer"]),
        .init(family: "Smart Mac Care", isAdware: false, patterns: ["smartmaccare", "smart mac care"]),
        .init(family: "Mac Cleanup Pro", isAdware: false, patterns: ["maccleanuppro", "mac cleanup pro"]),
        .init(family: "MacBooster", isAdware: false, patterns: ["macbooster"]),
    ]

    static func match(_ haystacks: [String?]) -> AdwareSignature? {
        let text = haystacks.compactMap { $0?.lowercased() }
        return all.first { signature in signature.patterns.contains { p in text.contains { $0.contains(p) } } }
    }
}

// MARK: - Code signatures

enum CodeSignature: Equatable, Sendable {
    case apple
    case developer(team: String)
    case adHoc
    case unsigned
    case invalid

    /// Checks the signature of an app bundle or executable. Resources aren't re-hashed, so this is fast
    /// even for very large apps; a modified executable or a broken signature still shows up as `.invalid`.
    static func check(_ url: URL) -> CodeSignature {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unsigned }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess else { return .invalid }

        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           let requirement, SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess {
            return .apple
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String { return .developer(team: team) }
        let codeFlags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return codeFlags & 0x2 != 0 ? .adHoc : .developer(team: "unknown") // 0x2 = kSecCodeSignatureAdhoc
    }
}

// MARK: - Scanner

enum SecurityScanner {
    static let staleAfterDays = 180

    /// Apple apps people often never open and can safely remove (they're re-downloadable from the App Store).
    static let optionalAppleApps: Set<String> = [
        "com.apple.garageband10", "com.apple.iMovieApp", "com.apple.iWork.Keynote",
        "com.apple.iWork.Pages", "com.apple.iWork.Numbers",
    ]

    // Launch items

    static func check(_ item: LaunchItem, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                      signature: (URL) -> CodeSignature = CodeSignature.check) -> SecurityFinding? {
        let label = item.label
        let program = item.program ?? ""
        let commandLine = ([program] + item.arguments.dropFirst()).joined(separator: " ")
        let kind = item.isUserItem ? "Launch agent" : (item.url.path.contains("LaunchDaemons") ? "Launch daemon" : "Launch agent (all users)")
        let action: SecurityFinding.Action = item.isUserItem
            ? .trash(item.url, unload: true)
            : .revealOnly("Removing system-wide launch items needs an administrator. Delete the file in Finder, then restart.")

        func finding(_ category: SecurityFinding.Category, _ reasons: [String]) -> SecurityFinding {
            SecurityFinding(id: item.url.path, category: category, title: label, kind: kind, url: item.url,
                            reasons: reasons, size: nil, action: action)
        }

        if let signature = AdwareSignature.match([label, program, item.url.lastPathComponent]) {
            return finding(.threat, ["Matches \(signature.family), \(signature.isAdware ? "known adware" : "a potentially unwanted program")."])
        }

        var reasons: [String] = []
        let lowerLine = commandLine.lowercased()
        if label.hasPrefix("com.apple."), !program.isEmpty,
           !["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains(where: program.hasPrefix) {
            reasons.append("Uses an Apple name (\(label)) but runs a program outside macOS: \(program)")
        }
        if lowerLine.contains("curl ") || lowerLine.contains("wget ") {
            reasons.append("Downloads from the internet every time it runs.")
        }
        if lowerLine.contains("base64") || lowerLine.contains("eval ") {
            reasons.append("Runs hidden or encoded commands.")
        }
        let path = program.lowercased()
        if ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "/users/shared/"].contains(where: path.hasPrefix) {
            reasons.append("Runs a program from a temporary or shared folder: \(program)")
        } else if program.split(separator: "/").dropLast().contains(where: { $0.hasPrefix(".") }) {
            reasons.append("Runs a program from a hidden folder: \(program)")
        }
        if !program.isEmpty, program.hasPrefix("/"), fileExists(program),
           !["/bin/", "/usr/bin/", "/sbin/", "/usr/sbin/", "/System/"].contains(where: program.hasPrefix) {
            switch signature(URL(fileURLWithPath: program)) {
            case .invalid: reasons.append("Its program's code signature is broken; it may have been modified.")
            case .unsigned where !reasons.isEmpty: reasons.append("Its program isn't code-signed.")
            default: break
            }
        }
        if !reasons.isEmpty { return finding(.suspicious, reasons) }

        // Leftover from an app that was removed: harmless but useless.
        if program.hasPrefix("/"), !fileExists(program) {
            return finding(.bloatware, ["Points to a program that no longer exists: \(program)"])
        }
        return nil
    }

    // Apps

    static func check(app: AppInfo, lastUsed: Date?, signature: CodeSignature, now: Date = Date()) -> SecurityFinding? {
        func finding(_ category: SecurityFinding.Category, _ reasons: [String]) -> SecurityFinding {
            SecurityFinding(id: app.url.path, category: category, title: app.name, kind: "App", url: app.url,
                            reasons: reasons, size: app.size, action: .uninstall(app))
        }

        if let match = AdwareSignature.match([app.name, app.bundleID, app.url.lastPathComponent]) {
            return finding(.threat, ["Matches \(match.family), \(match.isAdware ? "known adware" : "a potentially unwanted program")."])
        }
        if signature == .invalid {
            return finding(.suspicious, ["Its code signature is broken, so it may have been modified after it was signed."])
        }

        let isApple = app.bundleID?.hasPrefix("com.apple.") == true
        let days = lastUsed.map { Int(now.timeIntervalSince($0) / 86_400) }
        if days == nil || days! >= staleAfterDays {
            var reasons = [days.map { "Not used in \(describe(days: $0))." } ?? "No sign it has ever been opened."]
            if isApple { reasons.append("Comes with macOS and can be downloaded again from the App Store.") }
            if signature == .unsigned { reasons.append("Not code-signed.") }
            return finding(.bloatware, reasons)
        }
        return nil
    }

    static func describe(days: Int) -> String {
        days >= 730 ? "over \(days / 365) years"
            : days >= 365 ? "over a year"
            : days >= 60 ? "\(days / 30) months" : "\(days) days"
    }

    /// When the app was last used: Spotlight's last-opened date or, since Spotlight misses apps launched
    /// from links and helpers, the newest change to the preferences and data the app writes while running.
    static func lastUsedDate(_ app: AppInfo, library: URL = FileUtils.library) -> Date? {
        var dates: [Date] = []
        if let item = MDItemCreateWithURL(nil, app.url as CFURL),
           let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            dates.append(date)
        }
        var traces = ["Application Support/\(app.name)"]
        if let id = app.bundleID {
            traces += ["Preferences/\(id).plist", "Containers/\(id)", "Caches/\(id)", "Application Support/\(id)",
                       "HTTPStorages/\(id)", "Saved Application State/\(id).savedState"]
        }
        for trace in traces {
            let url = library.appendingPathComponent(trace)
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                dates.append(date)
            }
        }
        return dates.max()
    }

    static func apps() -> [AppInfo] {
        var apps = AppScanner.installedApps()
        // AppScanner hides Apple apps; add back the optional ones people often never use.
        for root in AppScanner.defaultRoots {
            for url in (try? FileUtils.children(of: root)) ?? [] where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      optionalAppleApps.contains(id) else { continue }
                apps.append(AppInfo(url: url, name: url.deletingPathExtension().lastPathComponent,
                                    bundleID: id, version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String))
            }
        }
        return apps.filter { $0.bundleID != Bundle.main.bundleIdentifier }
    }

    // Browser extensions (Chromium-based browsers)

    static let browsers: [(name: String, path: String)] = [
        ("Chrome", "Google/Chrome"), ("Brave", "BraveSoftware/Brave-Browser"), ("Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"), ("Arc", "Arc/User Data"),
    ]

    struct Extension: Sendable {
        let id: String
        let name: String
        let folder: URL
        let overridesSearchOrHome: Bool
    }

    /// The extension's latest version folder, its display name and whether it takes over search/home.
    static func readExtension(_ folder: URL) -> Extension? {
        let versions = ((try? FileUtils.children(of: folder)) ?? []).filter { FileUtils.isDirectory($0) }
        guard let latest = versions.max(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }),
              let data = try? Data(contentsOf: latest.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var name = manifest["name"] as? String ?? folder.lastPathComponent
        if name.hasPrefix("__MSG_"), name.hasSuffix("__") {
            // Localized name: look it up in _locales/<default_locale>/messages.json (keys are case-insensitive).
            let key = String(name.dropFirst(6).dropLast(2)).lowercased()
            let locale = manifest["default_locale"] as? String ?? "en"
            let messages = latest.appendingPathComponent("_locales/\(locale)/messages.json")
            if let data = try? Data(contentsOf: messages),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entry = dict.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
               let message = entry["message"] as? String {
                name = message
            }
        }
        let overrides = manifest["chrome_settings_overrides"] as? [String: Any] ?? [:]
        let hijacks = overrides["search_provider"] != nil || overrides["homepage"] != nil || overrides["startup_pages"] != nil
        return Extension(id: folder.lastPathComponent, name: name, folder: latest.deletingLastPathComponent(),
                         overridesSearchOrHome: hijacks)
    }

    static func extensionFindings(support: URL = FileUtils.library.appendingPathComponent("Application Support")) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        for browser in browsers {
            let root = support.appendingPathComponent(browser.path)
            let profiles = ((try? FileUtils.children(of: root)) ?? []).filter {
                $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ")
            }
            for profile in profiles {
                for folder in (try? FileUtils.children(of: profile.appendingPathComponent("Extensions"))) ?? [] {
                    guard let ext = readExtension(folder) else { continue }
                    var category: SecurityFinding.Category?
                    var reasons: [String] = []
                    if let match = AdwareSignature.match([ext.name, ext.id]) {
                        category = .threat
                        reasons.append("Matches \(match.family), \(match.isAdware ? "known adware" : "a potentially unwanted program").")
                    } else if ext.overridesSearchOrHome {
                        category = .suspicious
                        reasons.append("Changes your search engine, homepage or startup pages. Browser hijackers do this; "
                                       + "it's fine if you added it on purpose.")
                    }
                    guard let category else { continue }
                    findings.append(SecurityFinding(
                        id: ext.folder.path, category: category, title: ext.name,
                        kind: "\(browser.name) extension (\(profile.lastPathComponent))", url: ext.folder,
                        reasons: reasons, size: nil,
                        action: .revealOnly("Remove it in \(browser.name): open the Extensions page and click Remove.")))
                }
            }
        }
        return findings
    }

    /// Browser settings forced by a policy, a common adware trick (fine if your Mac is managed by work or school).
    static func policyFindings(locations: [URL] = [
        URL(fileURLWithPath: "/Library/Managed Preferences"),
        URL(fileURLWithPath: "/Library/Managed Preferences").appendingPathComponent(NSUserName()),
    ]) -> [SecurityFinding] {
        let domains = ["com.google.Chrome": "Chrome", "com.brave.Browser": "Brave", "com.microsoft.Edge": "Edge",
                       "com.apple.Safari": "Safari"]
        let keys = ["ExtensionInstallForcelist": "installs extensions you can't remove",
                    "HomepageLocation": "sets your homepage",
                    "DefaultSearchProviderSearchURL": "sets your search engine",
                    "RestoreOnStartupURLs": "opens pages at startup",
                    "HomePage": "sets your homepage"]
        var findings: [SecurityFinding] = []
        for location in locations {
            for (domain, browser) in domains {
                let plist = location.appendingPathComponent(domain + ".plist")
                guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { continue }
                let forced = keys.filter { dict[$0.key] != nil }.map(\.value).sorted()
                guard !forced.isEmpty else { continue }
                findings.append(SecurityFinding(
                    id: plist.path, category: .suspicious, title: "\(browser) settings are locked by a policy",
                    kind: "Browser policy", url: plist,
                    reasons: ["A configuration profile \(forced.joined(separator: ", ")).",
                              "If your Mac isn't managed by your work or school, this is a common sign of adware."],
                    size: nil,
                    action: .revealOnly("Remove the profile in System Settings › General › Device Management.")))
            }
        }
        return findings
    }

    /// Everything, most serious first. `progress` reports what is being checked.
    static func scan(progress: @escaping @Sendable (String) -> Void = { _ in }) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []

        progress("Checking launch agents and daemons…")
        findings += LaunchItemScanner.scan().compactMap { check($0) }

        progress("Checking apps…")
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleURL?.standardizedFileURL))
        let apps = apps().filter { !running.contains($0.url.standardizedFileURL) } // running means in use
        var appFindings = [SecurityFinding?](repeating: nil, count: apps.count)
        appFindings.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                var app = apps[i]
                let signature = CodeSignature.check(app.url)
                guard var finding = check(app: app, lastUsed: lastUsedDate(app), signature: signature) else { return }
                app.size = FileUtils.size(of: app.url)
                finding = SecurityFinding(id: finding.id, category: finding.category, title: finding.title,
                                          kind: finding.kind, url: finding.url, reasons: finding.reasons,
                                          size: app.size, action: .uninstall(app))
                results[i] = finding
            }
        }
        findings += appFindings.compactMap { $0 }

        progress("Checking browser extensions and policies…")
        findings += extensionFindings()
        findings += policyFindings()

        return findings.sorted {
            $0.category != $1.category ? $0.category < $1.category : ($0.size ?? 0) > ($1.size ?? 0)
        }
    }

    /// Apple's built-in malware protection version, e.g. "5366".
    static func xprotectVersion() -> String? {
        let plist = URL(fileURLWithPath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
    }
}

// MARK: - Model

@MainActor
final class SecurityModel: ObservableObject {
    @Published var findings: [SecurityFinding] = []
    @Published var isScanning = false
    @Published var isRemoving = false
    @Published var hasScanned = false
    @Published var status = ""
    @Published var lastResult: CleanResult?
    @Published var xprotectVersion: String?

    func count(_ category: SecurityFinding.Category) -> Int { findings.filter { $0.category == category }.count }
    var bloatSize: Int64 { findings.filter { $0.category == .bloatware }.reduce(0) { $0 + ($1.size ?? 0) } }
    var selected: [SecurityFinding] { findings.filter { $0.isSelected && $0.isRemovable } }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastResult = nil
        xprotectVersion = SecurityScanner.xprotectVersion()
        findings = await Task.detached(priority: .userInitiated) {
            SecurityScanner.scan { message in Task { @MainActor [weak self] in self?.status = message } }
        }.value
        status = ""
        hasScanned = true
        isScanning = false
    }

    func removeSelected() async {
        let targets = selected
        guard !targets.isEmpty, !isRemoving else { return }
        isRemoving = true
        var result = CleanResult(movedToTrash: !Cleaner.deletePermanently)
        for finding in targets {
            let part: CleanResult
            switch finding.action {
            case let .uninstall(app):
                let leftovers = await Task.detached { AppScanner.leftovers(for: app) }.value
                part = await AppRemover.uninstall(app, leftovers: leftovers)
            case let .trash(url, unload):
                if unload { await Task.detached { Self.unloadLaunchAgent(url) }.value }
                let item = CleanItem(url: url, size: FileUtils.size(of: url), isSelected: true)
                part = await Task.detached { Cleaner.remove([item]) }.value
            case .revealOnly:
                continue
            }
            result.removed += part.removed
            result.freed += part.freed
            result.failures += part.failures
        }
        findings.removeAll { $0.isSelected && !FileUtils.exists($0.url) }
        lastResult = result
        isRemoving = false
    }

    /// Stops a user launch agent so it doesn't keep running until the next login.
    nonisolated static func unloadLaunchAgent(_ plist: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())", plist.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - View

struct SecurityView: View {
    @EnvironmentObject var model: SecurityModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Malware & Bloatware",
                       subtitle: "Find adware, suspicious background items, browser hijackers and apps you never use.",
                       icon: Pane.security.icon, tint: Pane.security.tint) {
                if model.isScanning || model.isRemoving {
                    ProgressView().controlSize(.small)
                    Text(model.isRemoving ? "Removing…" : model.status)
                        .font(.caption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                }
                Button(model.hasScanned ? "Scan Again" : "Scan") { Task { await model.scan() } }
                    .disabled(model.isScanning || model.isRemoving)
                Button("Remove \(model.selected.count)") { confirm = true }
                    .buttonStyle(.borderedProminent).tint(Pane.security.tint)
                    .disabled(model.selected.isEmpty || model.isScanning || model.isRemoving)
            }

            if let result = model.lastResult {
                ResultBanner(result: result) { model.lastResult = nil }.padding(.bottom, 8)
            }

            if model.hasScanned {
                summary.padding(.horizontal, 20).padding(.bottom, 10)
            }

            if !model.hasScanned {
                if model.isScanning {
                    ProgressView(model.status.isEmpty ? "Scanning…" : model.status)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(icon: "checkmark.shield.fill", title: "Ready to scan",
                                   message: "MacSweep checks apps, launch agents and browser extensions on this Mac. "
                                       + "Nothing is sent anywhere.")
                }
            } else if model.findings.isEmpty {
                EmptyStateView(icon: "checkmark.shield.fill", title: "Nothing found",
                               message: "No known adware, suspicious background items or unused apps were found.")
            } else {
                List {
                    ForEach([SecurityFinding.Category.threat, .suspicious, .bloatware], id: \.self) { category in
                        let indices = model.findings.indices.filter { model.findings[$0].category == category }
                        if !indices.isEmpty {
                            Section(category.title) {
                                ForEach(indices, id: \.self) { i in row($model.findings[i]) }
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }

            Text("These are local heuristic checks, not a full antivirus scan. macOS also protects you with XProtect"
                 + (model.xprotectVersion.map { " (version \($0))" } ?? "") + ".")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .confirmationDialog("Remove \(model.selected.count) item(s)?", isPresented: $confirm) {
            Button(Cleaner.deletePermanently ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                Task { await model.removeSelected() }
            }
        } message: {
            Text("Apps are removed together with their support files. Launch agents are stopped and removed. "
                 + (Cleaner.deletePermanently ? "This cannot be undone." : "Everything goes to the Trash."))
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            card("Adware & PUPs", "\(model.count(.threat))", "exclamationmark.octagon.fill",
                 model.count(.threat) > 0 ? .red : .green)
            card("Suspicious", "\(model.count(.suspicious))", "exclamationmark.triangle.fill",
                 model.count(.suspicious) > 0 ? .orange : .green)
            card("Bloatware", "\(model.count(.bloatware)) · \(FileUtils.format(model.bloatSize))", "shippingbox.fill", .blue)
            card("XProtect", model.xprotectVersion.map { "v\($0)" } ?? "Unknown", "checkmark.shield.fill", .green)
        }
    }

    private func card(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.headline).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ finding: Binding<SecurityFinding>) -> some View {
        let f = finding.wrappedValue
        let tint: Color = f.category == .threat ? .red : f.category == .suspicious ? .orange : .blue
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: finding.isSelected).labelsHidden().disabled(!f.isRemovable)
                .help(f.isRemovable ? "Select to remove" : "MacSweep can't remove this one for you")
            Group {
                if f.kind == "App" {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable()
                } else {
                    Image(systemName: f.kind.contains("extension") ? "puzzlepiece.extension.fill"
                          : f.kind.contains("policy") ? "lock.doc.fill" : "gearshape.2.fill")
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(f.title).fontWeight(.semibold).lineLimit(1)
                    Text(f.kind).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(tint.opacity(0.15), in: Capsule()).foregroundStyle(tint)
                }
                ForEach(f.reasons, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if case let .revealOnly(how) = f.action {
                    Text(how).font(.caption).foregroundStyle(tint)
                }
                Text(FileUtils.displayPath(f.url)).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let size = f.size { Text(FileUtils.format(size)).monospacedDigit().foregroundStyle(.secondary) }
            Button { FileUtils.reveal(f.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
        }
        .padding(.vertical, 3)
    }
}
