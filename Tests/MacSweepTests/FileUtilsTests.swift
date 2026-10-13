import XCTest
@testable import MacSweep

final class FileUtilsTests: XCTestCase {
    func testSizeOfFileIsAtLeastItsLength() throws {
        let temp = try TempDir()
        let file = try temp.file("a.bin", bytes: 10_000)
        XCTAssertGreaterThanOrEqual(FileUtils.size(of: file), 10_000)
    }

    func testSizeOfDirectoryIsSumOfFiles() throws {
        let temp = try TempDir()
        let a = try temp.file("dir/a.bin", bytes: 8192)
        let b = try temp.file("dir/nested/b.bin", bytes: 8192)
        let expected = FileUtils.size(of: a) + FileUtils.size(of: b)
        XCTAssertEqual(FileUtils.size(of: temp.url.appendingPathComponent("dir")), expected)
    }

    func testSizeDoesNotFollowSymlinks() throws {
        let temp = try TempDir()
        let big = try temp.file("big/data.bin", bytes: 100_000)
        let link = temp.url.appendingPathComponent("scan/link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big.deletingLastPathComponent())
        XCTAssertEqual(FileUtils.size(of: link), 0)
        XCTAssertEqual(FileUtils.size(of: temp.url.appendingPathComponent("scan")), 0)
    }

    func testSizeOfMissingPathIsZero() {
        XCTAssertEqual(FileUtils.size(of: URL(fileURLWithPath: "/definitely/not/here")), 0)
    }

    func testChildrenSkipsHiddenByDefault() throws {
        let temp = try TempDir()
        try temp.file("visible")
        try temp.file(".hidden")
        XCTAssertEqual(try FileUtils.children(of: temp.url).map(\.lastPathComponent), ["visible"])
        XCTAssertEqual(Set(try FileUtils.children(of: temp.url, includeHidden: true).map(\.lastPathComponent)),
                       ["visible", ".hidden"])
    }

    func testDisplayPathAbbreviatesHome() {
        let url = FileUtils.home.appendingPathComponent("Documents/report.pdf")
        XCTAssertEqual(FileUtils.displayPath(url), "~/Documents/report.pdf")
        XCTAssertEqual(FileUtils.displayPath(URL(fileURLWithPath: "/tmp/x")), "/tmp/x")
    }

    func testFormat() {
        XCTAssertEqual(FileUtils.format(0), "Zero KB")
        XCTAssertTrue(FileUtils.format(1_500_000).contains("MB"))
        XCTAssertTrue(FileUtils.format(3_000_000_000).contains("GB"))
    }
}

final class IgnoreListTests: XCTestCase {
    func testMatchesExactPathAndDescendants() {
        let list = ["/Users/me/Projects"]
        XCTAssertTrue(IgnoreList.contains(URL(fileURLWithPath: "/Users/me/Projects"), in: list))
        XCTAssertTrue(IgnoreList.contains(URL(fileURLWithPath: "/Users/me/Projects/app/build"), in: list))
    }

    func testDoesNotMatchSiblingsWithSamePrefix() {
        let list = ["/Users/me/Projects"]
        XCTAssertFalse(IgnoreList.contains(URL(fileURLWithPath: "/Users/me/ProjectsOld"), in: list))
        XCTAssertFalse(IgnoreList.contains(URL(fileURLWithPath: "/Users/me"), in: list))
    }

    func testEmptyListMatchesNothing() {
        XCTAssertFalse(IgnoreList.contains(URL(fileURLWithPath: "/"), in: []))
    }
}
