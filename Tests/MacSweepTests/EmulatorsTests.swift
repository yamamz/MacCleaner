import XCTest
@testable import MacSweep

final class EmulatorsTests: XCTestCase {
    /// ~/.android/avd with two emulators (one is running) and one orphan folder, plus an SDK with two images.
    private func fixture() throws -> (temp: TempDir, avdHome: URL, sdk: URL) {
        let temp = try TempDir()
        let avdHome = temp.url.appendingPathComponent("avd")
        let sdk = temp.url.appendingPathComponent("sdk")
        let phoneImage = "system-images/android-35/google_apis_playstore/arm64-v8a"

        try temp.file("avd/Pixel_7.ini", data: Data("path=\(avdHome.path)/Pixel_7.avd\ntarget=android-35\n".utf8))
        try temp.file("avd/Pixel_7.avd/config.ini", data: Data("""
            avd.ini.displayname=Pixel 7 API 35
            hw.device.name=pixel_7
            image.sysdir.1=\(phoneImage)/
            """.utf8))
        try temp.file("avd/Pixel_7.avd/userdata-qemu.img.qcow2", bytes: 40_000)
        try temp.file("avd/Pixel_7.avd/cache.img", bytes: 8_000)
        try temp.file("avd/Pixel_7.avd/snapshots/default_boot/ram.bin", bytes: 30_000)
        try temp.file("avd/Pixel_7.avd/sdcard.img", bytes: 4_000)

        try temp.file("avd/Running.ini", data: Data("path=\(avdHome.path)/Running.avd\n".utf8))
        try temp.file("avd/Running.avd/config.ini", data: Data("image.sysdir.1=\(phoneImage)/\n".utf8))
        try temp.file("avd/Running.avd/userdata-qemu.img", bytes: 10_000)

        try temp.file("avd/Orphan.avd/userdata-qemu.img", bytes: 5_000) // no .ini pointer

        try temp.file("sdk/\(phoneImage)/system.img", bytes: 50_000)
        try temp.file("sdk/system-images/android-34/google_apis/arm64-v8a/system.img", bytes: 20_000)
        return (temp, avdHome, sdk)
    }

    func testScanFindsEmulatorsPartsAndImageUsage() throws {
        let (temp, avdHome, sdk) = try fixture()
        _ = temp
        let (avds, images) = AndroidEmulators.scan(avdHome: avdHome, sdk: sdk, running: ["Running"])

        XCTAssertEqual(Set(avds.map(\.id)), ["Pixel_7", "Running", "Orphan"])
        let pixel = try XCTUnwrap(avds.first { $0.id == "Pixel_7" })
        XCTAssertEqual(pixel.displayName, "Pixel 7 API 35")
        XCTAssertEqual(pixel.systemImage, "system-images/android-35/google_apis_playstore/arm64-v8a")
        XCTAssertNotNil(pixel.ini)
        XCTAssertEqual(pixel.parts.map(\.kind), [.snapshots, .userData])
        let userData = try XCTUnwrap(pixel.parts.first { $0.kind == .userData })
        XCTAssertEqual(Set(userData.urls.map(\.lastPathComponent)), ["userdata-qemu.img.qcow2", "cache.img"],
                       "the SD card is not part of a data wipe")
        XCTAssertTrue(avds.first { $0.id == "Running" }!.isRunning)
        XCTAssertNil(avds.first { $0.id == "Orphan" }!.ini)
        XCTAssertEqual(avds.first { $0.id == "Orphan" }!.displayName, "Orphan")

        XCTAssertEqual(images.count, 2)
        let phone = try XCTUnwrap(images.first { $0.id.contains("android-35") })
        XCTAssertEqual(Set(phone.usedBy), ["Pixel_7", "Running"])
        XCTAssertEqual(phone.name, "Android 15 (API 35) · Google Play · arm64")
        XCTAssertEqual(images.first { $0.id.contains("android-34") }?.usedBy, [])
    }

    func testRemovalItemsCoverWholeEmulatorsPartsAndImagesButNeverRunningOnes() throws {
        let (temp, avdHome, sdk) = try fixture()
        _ = temp
        var (avds, images) = AndroidEmulators.scan(avdHome: avdHome, sdk: sdk, running: ["Running"])
        avds[avds.firstIndex { $0.id == "Orphan" }!].isSelected = true
        avds[avds.firstIndex { $0.id == "Running" }!].isSelected = true // must be ignored
        let pixel = avds.firstIndex { $0.id == "Pixel_7" }!
        avds[pixel].parts[avds[pixel].parts.firstIndex { $0.kind == .snapshots }!].isSelected = true
        images[images.firstIndex { $0.id.contains("android-34") }!].isSelected = true

        let names = Set(AndroidEmulators.removalItems(avds: avds, images: images).map(\.url.lastPathComponent))
        XCTAssertEqual(names, ["Orphan.avd", "snapshots", "arm64-v8a"])
    }

    func testDeletingAWholeEmulatorAlsoRemovesItsIniPointer() throws {
        let (temp, avdHome, sdk) = try fixture()
        _ = temp
        var (avds, images) = AndroidEmulators.scan(avdHome: avdHome, sdk: sdk, running: [])
        avds[avds.firstIndex { $0.id == "Pixel_7" }!].isSelected = true
        let names = AndroidEmulators.removalItems(avds: avds, images: images).map(\.url.lastPathComponent)
        XCTAssertEqual(Set(names), ["Pixel_7.avd", "Pixel_7.ini"])
    }

    @MainActor
    func testImagesInUseByKeptEmulatorsCannotBeSelected() throws {
        let (temp, avdHome, sdk) = try fixture()
        _ = temp
        let model = EmulatorsModel()
        (model.avds, model.images) = AndroidEmulators.scan(avdHome: avdHome, sdk: sdk, running: [])
        model.selectUnusedImages()
        XCTAssertEqual(model.images.filter(\.isSelected).map(\.id), ["system-images/android-34/google_apis/arm64-v8a"])

        // Once every emulator using the API 35 image is being deleted, that image is free too.
        for i in model.avds.indices where model.avds[i].systemImage?.contains("android-35") == true {
            model.avds[i].isSelected = true
        }
        model.selectUnusedImages()
        XCTAssertEqual(model.images.filter(\.isSelected).count, 2)

        // Keeping one of them again deselects the image.
        model.avds[model.avds.firstIndex { $0.id == "Pixel_7" }!].isSelected = false
        model.reconcileImages()
        XCTAssertEqual(model.images.filter(\.isSelected).count, 1)
    }

    func testRunningEmulatorsAreReadFromProcessArguments() {
        let ps = """
        /Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Claude_Test_API_35 -no-audio
        /Users/me/Library/Android/sdk/emulator/emulator @Pixel_7_API_35
        /usr/bin/some-other-tool -avd NotAnEmulator
        """
        XCTAssertEqual(AndroidEmulators.runningAVDs(psOutput: ps), ["Claude_Test_API_35", "Pixel_7_API_35"])
    }

    func testEnvironmentOverridesLocations() {
        XCTAssertEqual(AndroidEmulators.avdHome(environment: ["ANDROID_AVD_HOME": "/x/avd"]).path, "/x/avd")
        XCTAssertEqual(AndroidEmulators.avdHome(environment: ["ANDROID_USER_HOME": "/x"]).path, "/x/avd")
        XCTAssertEqual(AndroidEmulators.sdkHome(environment: ["ANDROID_SDK_ROOT": "/sdk"]).path, "/sdk")
        XCTAssertTrue(AndroidEmulators.avdHome(environment: [:]).path.hasSuffix("/.android/avd"))
    }
}
