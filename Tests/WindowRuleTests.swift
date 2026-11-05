import Foundation
import Testing
@testable import WindowSwitchCore

struct WindowRuleTests {
    @Test func wildcardExcludesOnlyItsApplication() {
        let rule = WindowRule(bundleID: "com.example.Editor")
        #expect(rule.matches(bundleID: "com.example.Editor", title: ""))
        #expect(rule.matches(bundleID: "com.example.Editor", title: "Draft"))
        #expect(!rule.matches(bundleID: "com.example.EditorBeta", title: "Draft"))
    }

    @Test func titlePatternMatchesWholeTitle() {
        let exact = WindowRule(bundleID: "app", titlePattern: "Draft")
        let wildcard = WindowRule(bundleID: "app", titlePattern: "*Draft*")
        #expect(exact.matches(bundleID: "app", title: "Draft"))
        #expect(!exact.matches(bundleID: "app", title: "Draft 2"))
        #expect(wildcard.matches(bundleID: "app", title: "My Draft 2"))
    }

    @Test func preservesRegexAndFullMatchAlternation() {
        let rule = WindowRule(bundleID: "app", titlePattern: "a|ab")
        #expect(rule.matches(bundleID: "app", title: "ab"))
        #expect(!rule.matches(bundleID: "app", title: "abc"))
        let classes = WindowRule(bundleID: "app", titlePattern: "Report [0-9]+\\.pdf")
        #expect(classes.matches(bundleID: "app", title: "Report 12.pdf"))
        #expect(!classes.matches(bundleID: "app", title: "Report twelve.pdf"))
    }

    @Test func isCaseSensitiveAndUnicodeAware() {
        let rule = WindowRule(bundleID: "app", titlePattern: "文档😀*")
        #expect(rule.matches(bundleID: "app", title: "文档😀 — 草稿"))
        #expect(!WindowRule(bundleID: "app", titlePattern: "Draft")
            .matches(bundleID: "app", title: "draft"))
    }

    @Test func invalidPatternDoesNotExcludeOrCrash() {
        let rule = WindowRule(bundleID: "app", titlePattern: "[")
        #expect(rule.validationError != nil)
        #expect(!rule.matches(bundleID: "app", title: "Draft"))
    }

    @Test func disabledRuleDoesNotExclude() {
        let rule = WindowRule(bundleID: "app", isEnabled: false)
        #expect(!rule.matches(bundleID: "app", title: "Draft"))
    }

    @Test func rulesRoundTripWithoutLosingIdentity() throws {
        let rule = WindowRule(bundleID: "app", titlePattern: "Secret*")
        let decoded = try JSONDecoder().decode(WindowRule.self, from: JSONEncoder().encode(rule))
        #expect(decoded == rule)
    }
}
