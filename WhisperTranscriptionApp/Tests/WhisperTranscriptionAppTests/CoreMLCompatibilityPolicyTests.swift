import XCTest
@testable import WhisperTranscriptionApp

final class CoreMLCompatibilityPolicyTests: XCTestCase {
    func testValidatedIOSVersionsAllowVerifiedCoreMLEncoder() {
        for version in [version(17, 0), version(25, 9), version(26, 3)] {
            XCTAssertEqual(
                CoreMLCompatibilityPolicy.accelerationMode(
                    operatingSystemVersion: version,
                    isSimulator: false,
                    hasVerifiedEncoder: true
                ),
                .coreML
            )
        }
    }

    func testIOS264AndLaterNeverEnterCoreML() {
        for version in [version(26, 4), version(26, 5), version(26, 6), version(27, 0)] {
            let mode = CoreMLCompatibilityPolicy.accelerationMode(
                operatingSystemVersion: version,
                isSimulator: false,
                hasVerifiedEncoder: true
            )
            XCTAssertFalse(mode.usesCoreML)
        }
    }

    func testSimulatorNeverEntersCoreML() {
        XCTAssertEqual(
            CoreMLCompatibilityPolicy.accelerationMode(
                operatingSystemVersion: version(26, 3),
                isSimulator: true,
                hasVerifiedEncoder: true
            ),
            .metal(reason: .simulator)
        )
    }

    func testMissingVerifiedEncoderUsesMetal() {
        XCTAssertEqual(
            CoreMLCompatibilityPolicy.accelerationMode(
                operatingSystemVersion: version(17, 0),
                isSimulator: false,
                hasVerifiedEncoder: false
            ),
            .metal(reason: .encoderMissing)
        )
    }

    private func version(_ major: Int, _ minor: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    }
}
