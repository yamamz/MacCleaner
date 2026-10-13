import XCTest
@testable import MacSweep

final class SystemStatsTests: XCTestCase {
    func testCPUUsageMath() {
        let a = SystemStats.CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = SystemStats.CPUTicks(user: 200, system: 100, idle: 900, nice: 100)
        // busy delta = 100 + 50 + 50 = 200, total = 300
        XCTAssertEqual(SystemStats.cpuUsage(from: a, to: b), 200.0 / 300.0, accuracy: 1e-9)
    }

    func testCPUUsageHandlesCounterWraparound() {
        let a = SystemStats.CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)
        let b = SystemStats.CPUTicks(user: 10, system: 0, idle: 20, nice: 0)
        XCTAssertEqual(SystemStats.cpuUsage(from: a, to: b), 20.0 / 40.0, accuracy: 1e-9)
    }

    func testCPUUsageWithNoElapsedTicksIsZero() {
        let a = SystemStats.CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        XCTAssertEqual(SystemStats.cpuUsage(from: a, to: a), 0)
    }

    func testLiveReadingsAreSane() {
        XCTAssertNotNil(SystemStats.cpuTicks())

        let memory = SystemStats.memory()
        XCTAssertEqual(memory.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)

        let disk = SystemStats.disk()
        XCTAssertGreaterThan(disk.total, 0)
        XCTAssertGreaterThan(disk.used, 0)
        XCTAssertLessThanOrEqual(disk.used, disk.total)
    }

    func testFootprintOfOwnProcess() {
        let footprint = SystemStats.footprint(of: getpid())
        XCTAssertNotNil(footprint)
        XCTAssertGreaterThan(footprint ?? 0, 1024 * 1024)
    }
}

final class MaintenanceTests: XCTestCase {
    func testTaskIDsUnique() {
        let ids = MaintenanceRunner.tasks.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(MaintenanceRunner.appleScriptLiteral(#"echo "hi" \ there"#), #"echo \"hi\" \\ there"#)
    }

    func testAdminTasksGoThroughOsascript() {
        let task = MaintenanceTask(id: "t", name: "", detail: "", icon: "", command: #"say "x""#, needsAdmin: true)
        let (exe, args) = MaintenanceRunner.invocation(for: task)
        XCTAssertEqual(exe, "/usr/bin/osascript")
        XCTAssertEqual(args, ["-e", #"do shell script "say \"x\"" with administrator privileges"#])
    }

    func testUserTasksRunInShell() {
        let task = MaintenanceTask(id: "t", name: "", detail: "", icon: "", command: "echo hi", needsAdmin: false)
        let (exe, args) = MaintenanceRunner.invocation(for: task)
        XCTAssertEqual(exe, "/bin/zsh")
        XCTAssertEqual(args, ["-c", "echo hi"])
    }

    func testRunCapturesOutputAndStatus() {
        let ok = MaintenanceRunner.run(MaintenanceTask(id: "ok", name: "", detail: "", icon: "",
                                                       command: "echo hello; echo oops >&2", needsAdmin: false))
        XCTAssertTrue(ok.success)
        XCTAssertTrue(ok.output.contains("hello"))
        XCTAssertTrue(ok.output.contains("oops"))

        let fail = MaintenanceRunner.run(MaintenanceTask(id: "bad", name: "", detail: "", icon: "",
                                                         command: "exit 3", needsAdmin: false))
        XCTAssertFalse(fail.success)
    }

    func testBuiltInToolsExist() {
        // The executables each task relies on must be present on this macOS version.
        let tools = ["/usr/bin/dscacheutil", "/usr/sbin/purge", "/usr/bin/mdutil", "/usr/bin/qlmanage", "/usr/bin/atsutil",
                     "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"]
        for tool in tools {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tool), tool)
        }
    }
}
