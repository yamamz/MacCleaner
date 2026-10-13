import XCTest
@testable import MacSweep

final class AppScannerTests: XCTestCase {
    var temp: TempDir!
    override func setUpWithError() throws { temp = try TempDir() }

    func testListsAppsSortedAndReadsInfoPlist() throws {
        try temp.app("Applications/Zeta.app", bundleID: "com.example.zeta", version: "2.1")
        try temp.app("Applications/alpha.app", bundleID: "com.example.alpha", name: "Alpha Pro")

        let apps = AppScanner.installedApps(roots: [temp.url.appendingPathComponent("Applications")])

        XCTAssertEqual(apps.map(\.name), ["Alpha Pro", "Zeta"])
        XCTAssertEqual(apps.last?.version, "2.1")
        XCTAssertEqual(apps.first?.bundleID, "com.example.alpha")
    }

    func testIncludesAppsOneFolderDeep() throws {
        try temp.app("Applications/Adobe Suite/Editor.app", bundleID: "com.adobe.editor")
        let apps = AppScanner.installedApps(roots: [temp.url.appendingPathComponent("Applications")])
        XCTAssertEqual(apps.map(\.name), ["Editor"])
    }

    func testExcludesAppleApps() throws {
        try temp.app("Applications/Safari.app", bundleID: "com.apple.Safari")
        try temp.app("Applications/Other.app", bundleID: "com.example.other")
        let apps = AppScanner.installedApps(roots: [temp.url.appendingPathComponent("Applications")])
        XCTAssertEqual(apps.map(\.name), ["Other"])
    }

    func testMissingRootsAreIgnored() {
        XCTAssertTrue(AppScanner.installedApps(roots: [URL(fileURLWithPath: "/no/such/dir")]).isEmpty)
    }

    // MARK: Leftover matching

    private let slack = AppInfo(url: URL(fileURLWithPath: "/Applications/Slack.app"), name: "Slack",
                                bundleID: "com.tinyspeck.slackmacgap", version: nil)

    func testMatchesBundleIDVariants() {
        XCTAssertTrue(AppScanner.isLeftover("com.tinyspeck.slackmacgap", in: "Containers", for: slack))
        XCTAssertTrue(AppScanner.isLeftover("com.tinyspeck.slackmacgap.plist", in: "Preferences", for: slack))
        XCTAssertTrue(AppScanner.isLeftover("com.tinyspeck.slackmacgap.savedState", in: "Saved Application State", for: slack))
        XCTAssertTrue(AppScanner.isLeftover("COM.TinySpeck.SlackMacGap", in: "Caches", for: slack), "case-insensitive")
        XCTAssertTrue(AppScanner.isLeftover("ABCDE12345.com.tinyspeck.slackmacgap", in: "Group Containers", for: slack))
    }

    func testMatchesFolderNamedAfterApp() {
        XCTAssertTrue(AppScanner.isLeftover("Slack", in: "Application Support", for: slack))
    }

    func testDoesNotMatchSimilarNames() {
        XCTAssertFalse(AppScanner.isLeftover("com.tinyspeck.other", in: "Caches", for: slack))
        XCTAssertFalse(AppScanner.isLeftover("SlackBackup", in: "Application Support", for: slack))
        XCTAssertFalse(AppScanner.isLeftover("com.tinyspeck.slackmacgapX", in: "Caches", for: slack))
        // Team-ID suffix matching only applies to Group Containers.
        XCTAssertFalse(AppScanner.isLeftover("XYZ.com.tinyspeck.slackmacgap", in: "Caches", for: slack))
    }

    func testShortAppNamesDoNotMatchGenerically() {
        let app = AppInfo(url: URL(fileURLWithPath: "/Applications/Go.app"), name: "Go", bundleID: nil, version: nil)
        XCTAssertFalse(AppScanner.isLeftover("go", in: "Application Support", for: app))
    }

    func testLeftoversScansLibraryFolders() throws {
        let lib = temp.url.appendingPathComponent("Library")
        try temp.file("Library/Application Support/Slack/storage", bytes: 8192)
        try temp.file("Library/Preferences/com.tinyspeck.slackmacgap.plist", bytes: 100)
        try temp.file("Library/Caches/com.tinyspeck.slackmacgap/cache.db", bytes: 4096)
        try temp.file("Library/Caches/com.other.app/cache.db", bytes: 4096)
        try temp.file("Library/Application Support/Zoom/data", bytes: 4096)

        let found = AppScanner.leftovers(for: slack, library: lib)

        XCTAssertEqual(Set(found.map(\.name)),
                       ["Slack", "com.tinyspeck.slackmacgap.plist", "com.tinyspeck.slackmacgap"])
        XCTAssertTrue(found.allSatisfy(\.isSelected))
        XCTAssertEqual(found.first?.name, "Slack", "sorted largest first")
        XCTAssertTrue(found.allSatisfy { Cleaner.isSafeToRemove($0.url, home: temp.url) })
    }
}

final class LaunchItemScannerTests: XCTestCase {
    private func writePlist(_ dict: [String: Any], to temp: TempDir, name: String) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        return try temp.file("LaunchAgents/\(name)", data: data)
    }

    func testParsesProgramAndRunAtLoad() throws {
        let temp = try TempDir()
        let url = try writePlist(["Label": "com.example.agent", "Program": "/usr/local/bin/agent", "RunAtLoad": true],
                                 to: temp, name: "com.example.agent.plist")
        let item = LaunchItemScanner.parse(url, isUserItem: true)
        XCTAssertEqual(item.label, "com.example.agent")
        XCTAssertEqual(item.program, "/usr/local/bin/agent")
        XCTAssertTrue(item.runAtLoad)
        XCTAssertTrue(item.isUserItem)
    }

    func testFallsBackToProgramArgumentsAndFileName() throws {
        let temp = try TempDir()
        let url = try writePlist(["ProgramArguments": ["/opt/tool", "--daemon"]], to: temp, name: "com.example.tool.plist")
        let item = LaunchItemScanner.parse(url, isUserItem: false)
        XCTAssertEqual(item.label, "com.example.tool")
        XCTAssertEqual(item.program, "/opt/tool")
        XCTAssertFalse(item.runAtLoad)
    }

    func testCorruptPlistStillProducesItem() throws {
        let temp = try TempDir()
        let url = try temp.file("LaunchAgents/broken.plist", data: Data("not a plist".utf8))
        let item = LaunchItemScanner.parse(url, isUserItem: true)
        XCTAssertEqual(item.label, "broken")
        XCTAssertNil(item.program)
    }

    func testScanOnlyReadsPlistsAndSorts() throws {
        let temp = try TempDir()
        _ = try writePlist(["Label": "zeta"], to: temp, name: "z.plist")
        _ = try writePlist(["Label": "Alpha"], to: temp, name: "a.plist")
        try temp.file("LaunchAgents/readme.txt")

        let items = LaunchItemScanner.scan(sources: [(temp.url.appendingPathComponent("LaunchAgents"), true)])
        XCTAssertEqual(items.map(\.label), ["Alpha", "zeta"])
    }
}
