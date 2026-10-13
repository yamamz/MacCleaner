import XCTest
@testable import MacSweep

final class CleanerTests: XCTestCase {
    var temp: TempDir!
    var home: URL { temp.url }

    override func setUpWithError() throws { temp = try TempDir() }
    override func tearDown() { temp = nil }

    // MARK: isSafeToRemove

    func testAllowsItemsInsideHome() {
        XCTAssertTrue(Cleaner.isSafeToRemove(home.appendingPathComponent("Library/Caches/com.example.app"), home: home))
        XCTAssertTrue(Cleaner.isSafeToRemove(home.appendingPathComponent("Downloads/installer.dmg"), home: home))
    }

    func testRejectsHomeAndProtectedFolders() {
        let protected = ["", "Library", "Documents", "Desktop", "Downloads", "Library/Caches", "Library/Logs",
                         "Library/Application Support", "Library/Preferences", "Library/Containers", ".Trash"]
        for relative in protected {
            let url = relative.isEmpty ? home : home.appendingPathComponent(relative)
            XCTAssertFalse(Cleaner.isSafeToRemove(url, home: home), "\(relative) should be protected")
        }
    }

    func testRejectsKeychains() {
        XCTAssertFalse(Cleaner.isSafeToRemove(home.appendingPathComponent("Library/Keychains/login.keychain-db"), home: home))
    }

    func testRejectsPathsOutsideHome() {
        XCTAssertFalse(Cleaner.isSafeToRemove(URL(fileURLWithPath: "/System/Library/Caches"), home: home))
        XCTAssertFalse(Cleaner.isSafeToRemove(URL(fileURLWithPath: "/usr/bin/zsh"), home: home))
        XCTAssertFalse(Cleaner.isSafeToRemove(URL(fileURLWithPath: "/Applications"), home: home))
    }

    func testRejectsParentTraversal() {
        let sneaky = URL(fileURLWithPath: home.path + "/Library/../../etc")
        XCTAssertFalse(Cleaner.isSafeToRemove(sneaky, home: home))
    }

    func testAllowsAppBundlesInApplications() {
        XCTAssertTrue(Cleaner.isSafeToRemove(URL(fileURLWithPath: "/Applications/Some App.app"), home: home))
        XCTAssertFalse(Cleaner.isSafeToRemove(URL(fileURLWithPath: "/Applications/Utilities"), home: home))
    }

    func testRejectsFolderReachedThroughSymlinkedParentOutsideHome() throws {
        let outside = try TempDir()
        try outside.file("victim/data.txt")
        let link = home.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
        XCTAssertFalse(Cleaner.isSafeToRemove(link.appendingPathComponent("victim"), home: home))
    }

    func testSymlinkItselfIsRemovableWithoutTouchingTarget() throws {
        let outside = try TempDir()
        let target = try outside.file("important.txt")
        let link = home.appendingPathComponent("Library/Caches/link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertTrue(Cleaner.isSafeToRemove(link, home: home))
        let result = Cleaner.remove([CleanItem(url: link, size: 0, isSelected: true)], permanently: true, home: home)
        XCTAssertEqual(result.removed, 1)
        XCTAssertTrue(exists(target), "symlink target must survive")
    }

    // MARK: remove

    func testRemoveDeletesAndReportsFreedBytes() throws {
        let a = try temp.file("Library/Caches/a/blob", bytes: 1000)
        let b = try temp.file("Library/Caches/b", bytes: 500)
        let items = [CleanItem(url: a.deletingLastPathComponent(), size: 1000, isSelected: true),
                     CleanItem(url: b, size: 500, isSelected: true)]

        let result = Cleaner.remove(items, permanently: true, home: home)

        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(result.freed, 1500)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.movedToTrash)
        XCTAssertFalse(exists(a))
        XCTAssertFalse(exists(b))
    }

    func testRemoveSkipsProtectedPathsAndKeepsThem() throws {
        let caches = try temp.dir("Library/Caches")
        let result = Cleaner.remove([CleanItem(url: caches, size: 1, isSelected: true)], permanently: true, home: home)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(exists(caches))
    }

    func testRemoveReportsMissingFiles() {
        let missing = home.appendingPathComponent("Library/Caches/nope")
        let result = Cleaner.remove([CleanItem(url: missing, size: 10, isSelected: true)], permanently: true, home: home)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.freed, 0)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testSummaryText() {
        var result = CleanResult(removed: 1, freed: 2048, failures: [], movedToTrash: true)
        XCTAssertTrue(result.summary.contains("1 item "))
        XCTAssertTrue(result.summary.contains("Trash"))
        result.removed = 3
        result.movedToTrash = false
        result.failures = ["x"]
        XCTAssertTrue(result.summary.contains("3 items"))
        XCTAssertFalse(result.summary.contains("Empty the Trash"))
        XCTAssertTrue(result.summary.contains("1 item(s) could not be removed"))
    }
}
