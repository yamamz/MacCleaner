import XCTest
@testable import MacSweep

final class DuplicateScannerTests: XCTestCase {
    var temp: TempDir!
    override func setUpWithError() throws { temp = try TempDir() }

    private func scan(minimumSize: Int64 = 1) -> [DuplicateGroup] {
        DuplicateScanner.scan(root: temp.url, minimumSize: minimumSize, ignored: [])
    }

    func testFindsIdenticalFilesAcrossFolders() throws {
        try temp.file("a/photo.jpg", bytes: 5000, fill: 1)
        try temp.file("b/photo copy.jpg", bytes: 5000, fill: 1)
        try temp.file("c/unique.jpg", bytes: 5000, fill: 2)

        let groups = scan()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map { $0.url.lastPathComponent }), ["photo.jpg", "photo copy.jpg"])
        XCTAssertEqual(groups[0].size, 5000)
        XCTAssertEqual(groups[0].wasted, 5000)
    }

    func testSameSizeDifferentContentIsNotDuplicate() throws {
        try temp.file("x", bytes: 4096, fill: 1)
        try temp.file("y", bytes: 4096, fill: 2)
        XCTAssertTrue(scan().isEmpty)
    }

    func testFilesDifferingOnlyAfterFirst64KBAreNotDuplicates() throws {
        var a = Data(repeating: 7, count: 200_000)
        var b = a
        a[150_000] = 1
        b[150_000] = 2
        try temp.file("a.bin", data: a)
        try temp.file("b.bin", data: b)
        XCTAssertTrue(scan().isEmpty, "full hash must catch late differences")
    }

    func testHardLinksAreNotDuplicates() throws {
        let original = try temp.file("original.bin", bytes: 4096)
        try FileManager.default.linkItem(at: original, to: temp.url.appendingPathComponent("hardlink.bin"))
        XCTAssertTrue(scan().isEmpty)
    }

    func testRespectsMinimumSize() throws {
        try temp.file("a", bytes: 100)
        try temp.file("b", bytes: 100)
        XCTAssertEqual(scan(minimumSize: 1).count, 1)
        XCTAssertTrue(scan(minimumSize: 1000).isEmpty)
    }

    func testSkipsLibraryAndHiddenFolders() throws {
        try temp.file("Library/a", bytes: 100)
        try temp.file(".hidden/a", bytes: 100)
        try temp.file("Docs/a", bytes: 100)
        XCTAssertTrue(scan().isEmpty)
    }

    func testIgnoredPathsAreSkipped() throws {
        try temp.file("keep/a", bytes: 100)
        try temp.file("other/a", bytes: 100)
        let groups = DuplicateScanner.scan(root: temp.url, minimumSize: 1,
                                           ignored: [temp.url.appendingPathComponent("keep").path])
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupsSortedByWastedSpaceAndOldestKept() throws {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        try temp.file("small/new", bytes: 1000, fill: 1, modified: new)
        try temp.file("small/old", bytes: 1000, fill: 1, modified: old)
        try temp.file("big/1", bytes: 9000, fill: 2)
        try temp.file("big/2", bytes: 9000, fill: 2)
        try temp.file("big/3", bytes: 9000, fill: 2)

        let groups = scan()
        XCTAssertEqual(groups.map(\.size), [9000, 1000])
        XCTAssertEqual(groups[0].wasted, 18_000)

        let small = groups[1]
        XCTAssertEqual(small.files.first?.url.lastPathComponent, "old")
        XCTAssertFalse(small.files[0].isSelected, "oldest copy kept")
        XCTAssertTrue(small.files[1].isSelected)
    }

    func testFilesToRemoveAlwaysKeepsOneCopy() {
        func file(_ name: String, _ selected: Bool) -> DuplicateFile {
            DuplicateFile(url: URL(fileURLWithPath: "/\(name)"), modified: .distantPast, isSelected: selected)
        }
        let allSelected = DuplicateGroup(size: 10, files: [file("a", true), file("b", true), file("c", true)])
        let someSelected = DuplicateGroup(size: 10, files: [file("d", false), file("e", true)])
        let noneSelected = DuplicateGroup(size: 10, files: [file("f", false), file("g", false)])

        let names = DuplicateScanner.filesToRemove([allSelected, someSelected, noneSelected]).map(\.url.lastPathComponent)
        XCTAssertEqual(names, ["b", "c", "e"])
    }

    func testHashIsStableAndRespectsLimit() throws {
        let a = try temp.file("a", data: Data("hello world".utf8))
        XCTAssertEqual(DuplicateScanner.hash(a, limit: nil),
                       "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        XCTAssertEqual(DuplicateScanner.hash(a, limit: 5), DuplicateScanner.hash(try temp.file("b", data: Data("hello".utf8)), limit: nil))
        XCTAssertNil(DuplicateScanner.hash(URL(fileURLWithPath: "/no/such/file"), limit: nil))
    }
}
