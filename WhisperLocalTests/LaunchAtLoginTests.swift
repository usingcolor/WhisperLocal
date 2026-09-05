import ServiceManagement
import XCTest

final class LaunchAtLoginLocationTests: XCTestCase {
    private func reason(_ path: String) -> String? {
        LaunchAtLogin.unavailableReason(forBundleAt: path, productName: "WhisperLocal")
    }

    func testAnInstalledCopyCanRegister() {
        XCTAssertNil(reason("/Applications/WhisperLocal.app"))
        XCTAssertNil(reason("/Users/x/Applications/WhisperLocal.app"))
        XCTAssertNil(reason("/Users/x/Downloads/WhisperLocal.app"))
    }

    /// A quarantined copy opened from the DMG or from Downloads runs from a
    /// randomised read-only image. Registering that path makes a login item that
    /// points at nothing after the next restart, with no error at any point.
    func testATranslocatedCopyIsRefused() {
        let path = "/private/var/folders/j2/abc/T/AppTranslocation/8F3B-4C/d/WhisperLocal.app"
        XCTAssertEqual(
            reason(path),
            "macOS is running this copy from a temporary location. Move WhisperLocal to your Applications folder, then reopen it."
        )
    }

    func testACopyRunningFromAMountedImageIsRefused() {
        XCTAssertEqual(
            reason("/Volumes/WhisperLocal 0.2.0/WhisperLocal.app"),
            "This copy is running from a disk image. Drag WhisperLocal to your Applications folder, then open it from there."
        )
    }

    /// The Dev channel installs to /Applications like the public app, and the
    /// message has to name the copy the user is actually looking at.
    func testTheMessageNamesTheRunningApp() {
        let path = "/Volumes/Install/WhisperLocal Dev.app"
        XCTAssertEqual(
            LaunchAtLogin.unavailableReason(forBundleAt: path, productName: "WhisperLocal Dev"),
            "This copy is running from a disk image. Drag WhisperLocal Dev to your Applications folder, then open it from there."
        )
    }

    /// A path that merely mentions a volume elsewhere is not a mounted copy.
    func testOnlyTheVolumesPrefixCounts() {
        XCTAssertNil(reason("/Applications/Volumes Tool/WhisperLocal.app"))
    }
}

final class LaunchAtLoginStateTests: XCTestCase {
    func testEveryServiceStatusMapsToAState() {
        XCTAssertEqual(LaunchAtLogin.State(.enabled), .on)
        XCTAssertEqual(LaunchAtLogin.State(.notRegistered), .off)
        XCTAssertEqual(LaunchAtLogin.State(.requiresApproval), .blockedByUser)
        XCTAssertEqual(LaunchAtLogin.State(.notFound), .stale)
    }

    /// The toggle is only frozen where `register()` genuinely cannot help. Getting
    /// this wrong either fights the user in System Settings or leaves a dead switch.
    func testOnlyTheUnfixableStatesFreezeTheToggle() {
        XCTAssertFalse(LaunchAtLogin.State.on.isBlocked)
        XCTAssertFalse(LaunchAtLogin.State.off.isBlocked)
        XCTAssertFalse(LaunchAtLogin.State.stale.isBlocked)
        XCTAssertTrue(LaunchAtLogin.State.blockedByUser.isBlocked)
        XCTAssertTrue(LaunchAtLogin.State.unavailable(reason: "on a disk image").isBlocked)
    }

    func testOnlyEnabledReadsAsOn() {
        XCTAssertTrue(LaunchAtLogin.State.on.isOn)
        for state: LaunchAtLogin.State in [.off, .stale, .blockedByUser, .unavailable(reason: "x")] {
            XCTAssertFalse(state.isOn)
        }
    }
}
