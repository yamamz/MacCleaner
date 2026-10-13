import Foundation
import XCTest

/// A throwaway directory tree that is deleted when the test finishes.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ relative: String, bytes: Int = 16, fill: UInt8 = 0x41, modified: Date? = nil) throws -> URL {
        try file(relative, data: Data(repeating: fill, count: bytes), modified: modified)
    }

    @discardableResult
    func file(_ relative: String, data: Data, modified: Date? = nil) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// Creates a minimal .app bundle with an Info.plist.
    @discardableResult
    func app(_ relative: String, bundleID: String, name: String? = nil, version: String = "1.0") throws -> URL {
        let bundle = try dir(relative)
        var info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
                                   "CFBundlePackageType": "APPL"]
        if let name { info["CFBundleName"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try file("\(relative)/Contents/Info.plist", data: data)
        try file("\(relative)/Contents/MacOS/binary", bytes: 4096)
        return bundle
    }
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
