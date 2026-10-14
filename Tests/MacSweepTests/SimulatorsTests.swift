import XCTest
@testable import MacSweep

final class SimulatorsTests: XCTestCase {
    private let devicesJSON = Data("""
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-18-1": [
        {"udid": "A1", "name": "iPhone 16", "state": "Shutdown", "isAvailable": true,
         "dataPathSize": 1000, "lastBootedAt": "2025-12-09T12:21:05Z"},
        {"udid": "A2", "name": "iPad Air", "state": "Booted", "isAvailable": true, "dataPathSize": 5000}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
        {"udid": "B1", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true, "dataPathSize": 200}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
        {"udid": "C1", "name": "iPhone 14", "state": "Shutdown", "isAvailable": false}
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": []
    }}
    """.utf8)

    private let runtimesJSON = Data("""
    {
      "IMG-181": {"identifier": "IMG-181", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-1",
                  "version": "18.1", "build": "22B81", "sizeBytes": 8000000, "deletable": true,
                  "lastUsedAt": "2026-10-01T07:25:41Z"},
      "IMG-265": {"identifier": "IMG-265", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                  "version": "26.5", "build": "23F77", "sizeBytes": 10000000, "deletable": true},
      "IMG-185": {"identifier": "IMG-185", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
                  "version": "18.5", "build": "22F77", "sizeBytes": 9000000, "deletable": false}
    }
    """.utf8)

    private func parsed() throws -> [SimRuntime] {
        try Simctl.parse(devices: devicesJSON, runtimes: runtimesJSON)
    }

    func testParseGroupsDevicesUnderRuntimesNewestFirst() throws {
        let runtimes = try parsed()
        XCTAssertEqual(runtimes.map(\.name), ["iOS 26.5", "iOS 18.5", "iOS 18.1", "iOS 16.4"],
                       "empty device lists without an image are dropped")
        let ios181 = try XCTUnwrap(runtimes.first { $0.name == "iOS 18.1" })
        XCTAssertEqual(ios181.imageID, "IMG-181")
        XCTAssertEqual(ios181.devices.map(\.id), ["A2", "A1"], "largest device first")
        XCTAssertTrue(ios181.hasBootedDevice)
        XCTAssertFalse(ios181.canDeleteRuntime, "a running simulator blocks deleting its runtime")
        XCTAssertEqual(ios181.total, 8_006_000)
        XCTAssertNotNil(ios181.lastUsed)
    }

    func testDevicesWithoutAnInstalledRuntimeAreKept() throws {
        let orphan = try XCTUnwrap(try parsed().first { $0.name == "iOS 16.4" })
        XCTAssertFalse(orphan.isInstalled)
        XCTAssertTrue(orphan.canDeleteRuntime)
        XCTAssertEqual(orphan.devices.map(\.id), ["C1"])
        XCTAssertEqual(orphan.devices[0].size, 0, "missing dataPathSize counts as zero")
    }

    func testDescribeRuntimeIdentifier() {
        XCTAssertEqual(Simctl.describe("com.apple.CoreSimulator.SimRuntime.iOS-18-1").platform, "iOS")
        XCTAssertEqual(Simctl.describe("com.apple.CoreSimulator.SimRuntime.iOS-18-1").version, "18.1")
        XCTAssertEqual(Simctl.describe("com.apple.CoreSimulator.SimRuntime.xrOS-2-0").platform, "visionOS")
    }

    func testCommandsDeleteDevicesBeforeRuntimesAndSkipBootedDevices() throws {
        var runtimes = try parsed()
        let i265 = try XCTUnwrap(runtimes.firstIndex { $0.name == "iOS 26.5" })
        let i181 = try XCTUnwrap(runtimes.firstIndex { $0.name == "iOS 18.1" })
        let i164 = try XCTUnwrap(runtimes.firstIndex { $0.name == "iOS 16.4" })
        runtimes[i265].isSelected = true
        runtimes[i164].isSelected = true
        for d in runtimes[i181].devices.indices { runtimes[i181].devices[d].isSelected = true }

        XCTAssertEqual(Simctl.commands(for: runtimes), [
            ["delete", "B1", "A1", "C1"],          // booted A2 is skipped
            ["runtime", "delete", "IMG-265"],      // uninstalled 16.4 has no image to delete
        ])
        XCTAssertEqual(Simctl.commands(for: try parsed()), [], "nothing selected by default")
    }

    @MainActor
    func testKeepNewestOnlySelectsOlderDeletableRuntimes() throws {
        let model = SimulatorsModel()
        model.runtimes = try parsed()
        model.selectAllButNewest()
        let selected = Dictionary(uniqueKeysWithValues: model.runtimes.map { ($0.name, $0.isSelected) })
        XCTAssertEqual(selected, ["iOS 26.5": false,   // newest is kept
                                  "iOS 18.5": false,   // not deletable
                                  "iOS 18.1": false,   // has a running simulator
                                  "iOS 16.4": true])
    }
}
