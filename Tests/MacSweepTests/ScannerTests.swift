import XCTest
@testable import MacSweep

final class JunkScannerTests: XCTestCase {
    var temp: TempDir!
    override func setUpWithError() throws { temp = try TempDir() }

    private func category(_ id: String) -> JunkCategory {
        JunkScanner.categories.first { $0.id == id }!
    }

    func testCategoryIDsAreUnique() {
        let ids = JunkScanner.categories.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testEveryCategoryRootIsSafeToClean() {
        // Every child the scanner can return must pass the safety guard.
        for category in JunkScanner.categories {
            for root in category.roots {
                let child = temp.url.appendingPathComponent(root).appendingPathComponent("item")
                XCTAssertTrue(Cleaner.isSafeToRemove(child, home: temp.url), "\(category.id): \(root)")
            }
        }
    }

    func testChildrenModeListsEachNonEmptyChildSortedBySize() throws {
        try temp.file("Library/Caches/com.small/data", bytes: 4096)
        try temp.file("Library/Caches/com.big/data", bytes: 64 * 1024)
        try temp.dir("Library/Caches/com.empty")

        let (group, denied) = JunkScanner.scan(category("caches"), home: temp.url, ignored: [])

        XCTAssertFalse(denied)
        XCTAssertEqual(group.items.map(\.name), ["com.big", "com.small"])
        XCTAssertTrue(group.items.allSatisfy(\.isSelected))
        XCTAssertEqual(group.total, group.items.reduce(0) { $0 + $1.size })
        XCTAssertEqual(group.selectedTotal, group.total)
    }

    func testExcludesOwnBundleAndIgnoredPaths() throws {
        try temp.file("Library/Caches/com.macsweep.app/data", bytes: 4096)
        let ignored = try temp.file("Library/Caches/com.keep.me/data", bytes: 4096)
        try temp.file("Library/Caches/com.other/data", bytes: 4096)

        let (group, _) = JunkScanner.scan(category("caches"), home: temp.url,
                                          ignored: [ignored.deletingLastPathComponent().path],
                                          excludedNames: ["com.macsweep.app"])
        XCTAssertEqual(group.items.map(\.name), ["com.other"])
    }

    func testIgnoredRootSkipsWholeCategory() throws {
        try temp.file("Library/Logs/app.log", bytes: 4096)
        let (group, _) = JunkScanner.scan(category("logs"), home: temp.url,
                                          ignored: [temp.url.appendingPathComponent("Library/Logs").path])
        XCTAssertTrue(group.items.isEmpty)
    }

    func testExtensionModeOnlyMatchesInstallers() throws {
        try temp.file("Downloads/Setup.dmg", bytes: 4096)
        try temp.file("Downloads/Tool.PKG", bytes: 4096)
        try temp.file("Downloads/notes.txt", bytes: 4096)
        try temp.file("Downloads/photo.jpg", bytes: 4096)

        let (group, _) = JunkScanner.scan(category("installers"), home: temp.url, ignored: [])
        XCTAssertEqual(Set(group.items.map(\.name)), ["Setup.dmg", "Tool.PKG"])
        XCTAssertTrue(group.items.allSatisfy { !$0.isSelected }, "installers are opt-in")
    }

    func testWholeFolderModeReturnsRootAsSingleItem() throws {
        try temp.file(".npm/_cacache/content/a", bytes: 4096)
        try temp.file(".npm/_cacache/content/b", bytes: 4096)
        let (group, _) = JunkScanner.scan(category("dev"), home: temp.url, ignored: [])
        XCTAssertEqual(group.items.count, 1)
        XCTAssertEqual(group.items.first?.name, "_cacache")
    }

    func testMissingRootsProduceEmptyGroup() {
        let (group, denied) = JunkScanner.scan(category("xcode"), home: temp.url, ignored: [])
        XCTAssertTrue(group.items.isEmpty)
        XCTAssertFalse(denied)
    }

    func testUnreadableRootReportsPermissionDenied() throws {
        let logs = try temp.dir("Library/Logs")
        try temp.file("Library/Logs/x.log")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path) }

        let (_, denied) = JunkScanner.scan(category("logs"), home: temp.url, ignored: [])
        XCTAssertTrue(denied)
    }
}

final class LargeFileScannerTests: XCTestCase {
    func testFindsFilesOverThresholdSortedBySize() throws {
        let temp = try TempDir()
        try temp.file("Movies/big.mov", bytes: 300_000)
        try temp.file("Documents/medium.zip", bytes: 200_000)
        try temp.file("Documents/small.txt", bytes: 1_000)

        let files = LargeFileScanner.scan(root: temp.url, minimumBytes: 100_000, ignored: [])
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["big.mov", "medium.zip"])
    }

    func testSkipsLibraryHiddenNodeModulesAndIgnored() throws {
        let temp = try TempDir()
        try temp.file("Library/huge.bin", bytes: 200_000)
        try temp.file(".hidden/huge.bin", bytes: 200_000)
        try temp.file("code/node_modules/dep/huge.bin", bytes: 200_000)
        let ignored = try temp.file("Keep/huge.bin", bytes: 200_000)
        try temp.file("Videos/found.bin", bytes: 200_000)

        let files = LargeFileScanner.scan(root: temp.url, minimumBytes: 100_000,
                                          ignored: [ignored.deletingLastPathComponent().path])
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["found.bin"])
    }

    func testSkipsPackageContents() throws {
        let temp = try TempDir()
        try temp.app("Tools/Fake.app", bundleID: "com.example.fake")
        try temp.file("Tools/Fake.app/Contents/Resources/asset.bin", bytes: 200_000)
        XCTAssertTrue(LargeFileScanner.scan(root: temp.url, minimumBytes: 100_000, ignored: []).isEmpty)
    }

    func testReportsProgress() throws {
        let temp = try TempDir()
        for i in 0..<5 { try temp.file("f\(i)") }
        let expectation = expectation(description: "progress")
        expectation.assertForOverFulfill = false
        _ = LargeFileScanner.scan(root: temp.url, minimumBytes: 1, ignored: []) { count in
            if count >= 5 { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 1)
    }

    func testMatchesFilter() {
        let now = Date()
        let old = LargeFile(url: URL(fileURLWithPath: "/a"), size: 500, lastOpened: now.addingTimeInterval(-400 * 86_400))
        let recent = LargeFile(url: URL(fileURLWithPath: "/b"), size: 500, lastOpened: now.addingTimeInterval(-5 * 86_400))
        let unknown = LargeFile(url: URL(fileURLWithPath: "/c"), size: 500, lastOpened: nil)

        XCTAssertTrue(LargeFileScanner.matches(old, minBytes: 100, olderThanDays: nil, now: now))
        XCTAssertFalse(LargeFileScanner.matches(old, minBytes: 1000, olderThanDays: nil, now: now))
        XCTAssertTrue(LargeFileScanner.matches(old, minBytes: 100, olderThanDays: 365, now: now))
        XCTAssertFalse(LargeFileScanner.matches(recent, minBytes: 100, olderThanDays: 30, now: now))
        XCTAssertTrue(LargeFileScanner.matches(unknown, minBytes: 100, olderThanDays: 30, now: now))
    }

    func testAgeFilterDays() {
        XCTAssertNil(AgeFilter.any.days)
        XCTAssertEqual(AgeFilter.month.days, 30)
        XCTAssertEqual(AgeFilter.halfYear.days, 182)
        XCTAssertEqual(AgeFilter.year.days, 365)
    }
}

final class SpaceLensScannerTests: XCTestCase {
    func testEntriesAreSortedAndClassified() throws {
        let temp = try TempDir()
        try temp.file("Big/a.bin", bytes: 100_000)
        try temp.file("Big/b.bin", bytes: 100_000)
        try temp.file("single.bin", bytes: 50_000)
        try temp.app("Tool.app", bundleID: "com.example.tool")
        try temp.dir("Empty")

        let entries = SpaceLensScanner.entries(in: temp.url)
        let names = entries.map { $0.url.lastPathComponent }

        XCTAssertEqual(names.first, "Big")
        XCTAssertFalse(names.contains("Empty"), "zero-byte folders are hidden")
        XCTAssertEqual(entries, entries.sorted { $0.size > $1.size }, "largest first")
        XCTAssertEqual(entries.first { $0.url.lastPathComponent == "Big" }?.isFolder, true)
        XCTAssertEqual(entries.first { $0.url.lastPathComponent == "single.bin" }?.isFolder, false)
        XCTAssertEqual(entries.first { $0.url.lastPathComponent == "Tool.app" }?.isFolder, false, "packages aren't drillable")
    }

    func testSymlinksAreExcluded() throws {
        let temp = try TempDir()
        let target = try temp.file("real/data.bin", bytes: 10_000)
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("link"), withDestinationURL: target)
        XCTAssertEqual(SpaceLensScanner.entries(in: temp.url).map { $0.url.lastPathComponent }, ["real"])
    }

    func testMissingFolderIsEmpty() {
        XCTAssertTrue(SpaceLensScanner.entries(in: URL(fileURLWithPath: "/no/such/folder")).isEmpty)
    }
}

extension SpaceEntry: Equatable {
    public static func == (a: SpaceEntry, b: SpaceEntry) -> Bool { a.url == b.url && a.size == b.size }
}
