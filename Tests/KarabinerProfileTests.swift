import Foundation
import XCTest
@testable import WindowSwitchCore

final class KarabinerProfileTests: XCTestCase {
    private let rule = KarabinerRule.make(modifier: "command", endpoint: "/tmp/test-input.sock")

    func testManagedRulePreservesExistingJSONCAndRestoresOriginal() throws {
        let original = Data(#"""
        { /* another profile first */ "profiles": [
          { "name": "Other" },
          { "name":"Active", "selected":true, "complex_modifications":{"rules":[
            /* user rule */ {"description":"WindowSwitch: direct window shortcut", "extra":"[},] // \"quoted\""},
          ]} }
        ]}
        """#.utf8)
        let enabled = try KarabinerProfile.updating(original, rule: rule)
        XCTAssertEqual(try KarabinerProfile.updating(enabled, rule: rule), enabled)
        XCTAssertTrue(String(decoding: enabled, as: UTF8.self).contains("/* user rule */"))
        let changed = try KarabinerProfile.updating(enabled, rule: KarabinerRule.make(modifier: "control", endpoint: "/tmp/other.sock"))
        XCTAssertFalse(String(decoding: changed, as: UTF8.self).contains("test-input.sock"))
        let disabled = try KarabinerProfile.updating(changed, rule: nil)
        let settings: (Data) throws -> NSDictionary = { try XCTUnwrap(JSONSerialization.jsonObject(with: $0, options: .json5Allowed) as? NSDictionary) }
        XCTAssertEqual(try settings(disabled), try settings(original))
    }

    func testNewProfilesAndChangingSelection() throws {
        let original = Data(#"{"profiles":[{"name":"A","selected":true},{"name":"B","selected":false,"complex_modifications":{}}]}"#.utf8)
        let enabled = try KarabinerProfile.updating(original, rule: rule)
        let switched = String(decoding: enabled, as: UTF8.self)
            .replacingOccurrences(of: #""name":"A","selected":true"#, with: #""name":"A","selected":false"#)
            .replacingOccurrences(of: #""name":"B","selected":false"#, with: #""name":"B","selected":true"#)
        let data = try KarabinerProfile.updating(Data(switched.utf8), rule: rule)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profiles = try XCTUnwrap(root["profiles"] as? [[String: Any]])
        let counts = profiles.map { (($0["complex_modifications"] as? [String: Any])?["rules"] as? [[String: Any]])?.count }
        XCTAssertEqual(counts, [0,1])
        XCTAssertThrowsError(try KarabinerProfile.updating(Data("broken".utf8), rule: rule))
    }
}
