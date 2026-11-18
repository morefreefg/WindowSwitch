import Foundation

/// Karabiner consumes this shortcut before it is posted by its virtual keyboard.
/// Ordinary modifiers remain held (their passthrough key must be last in "to").
public nonisolated enum KarabinerRule {
    public static let name = "WindowSwitch: direct window shortcut"
    public static let owner = "io.github.morefreefg.WindowSwitch.direct-input"
    public static let lease = "windowswitch_direct_until"
    public static let selection = "windowswitch_direct_modifier"
    public static let modifiers = ["command", "option", "control"]

    public static func make(modifier: String, endpoint: String) -> [String: Any] {
        let index = (modifiers.firstIndex(of: modifier) ?? 0) + 1
        let gate = "\(lease) > system.now.milliseconds and \(selection) == \(index)"
        func send(_ edge: String) -> [String: Any] {
            ["send_user_command": ["endpoint": endpoint, "payload": edge]]
        }
        func key(_ code: String, optional: [String], when condition: String,
                 down: [[String: Any]], up: [[String: Any]]) -> [String: Any] {
            ["type": "basic", "from": ["key_code": code, "modifiers": ["optional": optional]],
             "conditions": [["type": "expression_if", "expression": condition]],
             "to": down, "to_after_key_up": up]
        }
        func held(_ group: String) -> String {
            "(windowswitch_direct_left_\(group) or windowswitch_direct_right_\(group))"
        }
        var keys: [[String: Any]] = []
        for reverse in [true, false] {
            let condition = gate + " and " + held(modifier) + (reverse ? " and " + held("shift") : "")
            let allowed = [modifier, "caps_lock"] + (reverse ? ["shift"] : [])
            keys.append(key("tab", optional: allowed, when: condition,
                            down: [send(reverse ? "reverseTab" : "tab")], up: [send("tabUp")]))
        }
        for group in [modifier, "shift"] {
            for side in ["left", "right"] {
                let code = "\(side)_\(group)"
                func mark(_ value: Int) -> [String: Any] {
                    ["set_variable": ["name": "windowswitch_direct_" + code, "value": value]]
                }
                var down = [mark(1)], up = [mark(0)]
                if group == modifier { down.append(send(side + "Down")); up.append(send(side + "Up")) }
                down.append(["key_code": code])
                keys.append(key(code, optional: ["any"], when: gate, down: down, up: up))
            }
        }
        return ["description": name, "notes": [owner], "manipulators": keys]
    }
}
