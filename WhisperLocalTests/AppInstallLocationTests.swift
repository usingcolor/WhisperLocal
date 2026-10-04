import XCTest

/// A copy running from a temporary location cannot keep a login item or hold on to
/// permissions, and the user has no way to work that out. These cover the telling
/// apart and the wording, since the wording is the whole point of noticing.
final class AppInstallLocationTests: XCTestCase {
    private let translocated = "/private/var/folders/1p/abc/T/AppTranslocation/9673-8252/d/WhisperLocal.app"

    func testAnInstalledCopyHasNoProblem() {
        XCTAssertNil(AppInstallLocation.problem(
            forBundleAt: "/Applications/WhisperLocal.app",
            onReadOnlyVolume: false,
            hasApplicationsCopy: true
        ))
        XCTAssertNil(AppInstallLocation.problem(
            forBundleAt: "/Users/x/Downloads/WhisperLocal.app",
            onReadOnlyVolume: false,
            hasApplicationsCopy: false
        ))
    }

    /// The case an in-app update or a scripted copy leaves behind, and the one the
    /// app can do most about: it is installed, just still flagged.
    func testTranslocatedWithAnInstalledCopyIsToldApart() {
        XCTAssertEqual(
            AppInstallLocation.problem(
                forBundleAt: translocated,
                onReadOnlyVolume: false,
                hasApplicationsCopy: true
            ),
            .temporaryCopyOfInstalledApp
        )
        XCTAssertEqual(
            AppInstallLocation.problem(
                forBundleAt: translocated,
                onReadOnlyVolume: false,
                hasApplicationsCopy: false
            ),
            .temporaryCopy
        )
    }

    /// Translocation is checked first: an app opened straight off a mounted image
    /// is *both*, and the flag is the thing the user can clear.
    func testTranslocationWinsOverTheVolumeTest() {
        XCTAssertEqual(
            AppInstallLocation.problem(
                forBundleAt: translocated,
                onReadOnlyVolume: true,
                hasApplicationsCopy: true
            ),
            .temporaryCopyOfInstalledApp
        )
    }

    /// Apps kept on an external drive live under /Volumes too, and that path is as
    /// durable as /Applications. Only a read-only volume is refused.
    func testAnExternalDriveIsNotADiskImage() {
        XCTAssertNil(AppInstallLocation.problem(
            forBundleAt: "/Volumes/External/Applications/WhisperLocal.app",
            onReadOnlyVolume: false,
            hasApplicationsCopy: false
        ))
        XCTAssertEqual(
            AppInstallLocation.problem(
                forBundleAt: "/Volumes/WhisperLocal 0.2.2/WhisperLocal.app",
                onReadOnlyVolume: true,
                hasApplicationsCopy: false
            ),
            .readOnlyVolume
        )
    }

    /// Someone looking at the app in Applications must not be told to put it there.
    func testTheInstalledCaseIsNotToldToMoveTheApp() {
        let remedy = AppInstallLocation.remedy(.temporaryCopyOfInstalledApp, productName: "WhisperLocal")
        XCTAssertTrue(remedy.contains("out of Applications and back in"))
        XCTAssertFalse(remedy.contains("Drag WhisperLocal into your Applications folder"))
    }

    func testTheUninstalledCasesAreToldToMoveTheApp() {
        for problem: AppInstallLocation.Problem in [.temporaryCopy, .readOnlyVolume] {
            let remedy = AppInstallLocation.remedy(problem, productName: "WhisperLocal")
            XCTAssertTrue(remedy.contains("Applications folder"), "\(problem)")
        }
    }

    /// One line, no instructions — it has to fit a menu bar header.
    func testTheHeadlineNamesTheConsequence() {
        let line = AppInstallLocation.headline(.temporaryCopyOfInstalledApp, productName: "WhisperLocal")
        XCTAssertTrue(line.contains("temporary copy"))
        XCTAssertFalse(line.contains("Finder"))
    }
}
