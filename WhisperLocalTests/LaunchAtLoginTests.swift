import ServiceManagement
import XCTest

// Where the app is running from, and the wording for it, moved to
// AppInstallLocation — the login item is only the first thing a temporary copy
// breaks. Those cases live in AppInstallLocationTests.

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
