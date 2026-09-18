import Foundation
import XCTest
@testable import OboeSharedCapture

/// `embedded.mobileprovision` is a CMS/DER envelope around an XML plist —
/// the parser must find the plist inside arbitrary binary padding and read
/// the profile's allowed App Groups (three states: groups, empty, absent).
final class SigningDiagnosticsTests: XCTestCase {

    private func profileData(appGroups: [String]?, omitEntitlements: Bool = false) -> Data {
        var inner = "<key>Name</key><string>TestProfile</string>"
        if !omitEntitlements {
            inner += "<key>Entitlements</key><dict>"
            if let appGroups {
                inner += "<key>com.apple.security.application-groups</key><array>"
                inner += appGroups.map { "<string>\($0)</string>" }.joined()
                inner += "</array>"
            }
            inner += "</dict>"
        }
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>\(inner)</dict></plist>
            """
        // DER-ish padding before and after, like a real CMS envelope.
        return Data([0x30, 0x82, 0x10, 0x00, 0xFF])
            + xml.data(using: .utf8)!
            + Data([0x00, 0x31, 0x82])
    }

    func testGroupsAreExtracted() {
        let data = profileData(appGroups: ["group.a.b", "group.c.d"])
        XCTAssertEqual(
            SigningDiagnostics.parseAppGroups(fromProfileData: data),
            ["group.a.b", "group.c.d"]
        )
    }

    func testParsedProfileWithoutGroupsReturnsEmpty() {
        let data = profileData(appGroups: nil)
        XCTAssertEqual(SigningDiagnostics.parseAppGroups(fromProfileData: data), [])
    }

    func testProfileWithoutEntitlementsReturnsNil() {
        let data = profileData(appGroups: nil, omitEntitlements: true)
        XCTAssertNil(SigningDiagnostics.parseAppGroups(fromProfileData: data))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(SigningDiagnostics.parseAppGroups(
            fromProfileData: Data([0x01, 0x02, 0x03])
        ))
    }

    func testSummaryWithoutProfileNamesRequestedGroup() {
        // The test bundle carries no embedded.mobileprovision — the summary
        // takes the "no profile" branch deterministically.
        let summary = SigningDiagnostics.appGroupSummary(requestedGroup: "group.x.y")
        XCTAssertTrue(summary.contains("group.x.y"))
        XCTAssertTrue(summary.contains("embedded.mobileprovision"))
    }

    // MARK: - groupCandidates (personal-team `<requested>.<TeamID>` fallback)

    func testCandidatesWithoutProfileIsRequestedOnly() {
        XCTAssertEqual(
            AppGroupCaptureStore.groupCandidates("group.a.b", allowed: nil),
            ["group.a.b"]
        )
    }

    func testCandidatesIncludeTeamSuffixedVariant() {
        XCTAssertEqual(
            AppGroupCaptureStore.groupCandidates(
                "group.a.b",
                allowed: ["group.a.b.ABCDE12345", "group.other"]
            ),
            ["group.a.b", "group.a.b.ABCDE12345"]
        )
    }

    func testCandidatesSkipExactAndUnrelatedGroups() {
        XCTAssertEqual(
            AppGroupCaptureStore.groupCandidates(
                "group.a.b",
                allowed: ["group.a.b", "group.a.bc", "group.a.b.c"]
            ),
            ["group.a.b", "group.a.b.c"]
        )
    }
}
