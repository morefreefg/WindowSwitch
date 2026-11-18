import Foundation

/// Edit only the managed rule. Karabiner configs may contain comments, custom
/// keys, trailing commas and hand formatting that a JSON round trip would discard.
public nonisolated enum KarabinerProfile {
    public enum EditError: Error { case invalidConfiguration }

    public static func updating(_ data: Data, rule: [String: Any]?) throws -> Data {
        let doc = Document(bytes: Array(data))
        let root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
        guard let profiles = root?["profiles"] as? [[String: Any]], !profiles.isEmpty,
              let profileArray = try doc.field("profiles", in: 0..<data.count) else { throw EditError.invalidConfiguration }
        let nodes = try doc.entries(profileArray)
        guard nodes.count == profiles.count else { throw EditError.invalidConfiguration }
        let selected = profiles.firstIndex { $0["selected"] as? Bool == true } ?? 0
        var edits: [(Range<Int>, [UInt8])] = []
        func encoded(_ object: Any) throws -> [UInt8] {
            Array(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        }
        for (i, profile) in profiles.enumerated() {
            let desired = i == selected ? rule : nil
            guard let complex = try doc.field("complex_modifications", in: nodes[i]) else {
                if let desired { edits.append(try doc.inserting(key: "complex_modifications", value: ["rules": [desired]], into: nodes[i])) }
                continue
            }
            guard let rules = try doc.field("rules", in: complex) else {
                if let desired { edits.append(try doc.inserting(key: "rules", value: [desired], into: complex)) }
                continue
            }
            guard let values = (profile["complex_modifications"] as? [String: Any])?["rules"] as? [[String: Any]] else {
                throw EditError.invalidConfiguration
            }
            let ranges = try doc.entries(rules)
            guard ranges.count == values.count else { throw EditError.invalidConfiguration }
            let owned = values.indices.filter { (values[$0]["notes"] as? [String])?.contains(KarabinerRule.owner) == true }
            guard owned.count <= 1 else { throw EditError.invalidConfiguration }
            if let index = owned.first {
                if let desired {
                    if !NSDictionary(dictionary: values[index]).isEqual(to: desired) {
                        edits.append((ranges[index], try encoded(desired)))
                    }
                } else {
                    edits.append((ranges[index], []))
                    let next = try doc.skip(ranges[index].upperBound)
                    if doc.bytes[next] == 44 { edits.append((next..<next+1, [])) }
                    else if index > 0 {
                        let comma = try doc.skip(ranges[index-1].upperBound)
                        edits.append((comma..<comma+1, []))
                    }
                }
            } else if let desired {
                // Append after existing personal rules so their mappings keep priority.
                let at = ranges.last?.upperBound ?? (rules.lowerBound + 1)
                edits.append((at..<at, (ranges.isEmpty ? [] : [44]) + (try encoded(desired))))
            }
        }
        var bytes = doc.bytes
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            bytes.replaceSubrange(range, with: replacement)
        }
        return Data(bytes)
    }

    private struct Document {
        let bytes: [UInt8]
        func skip(_ start: Int) throws -> Int {
            var i = start
            while i < bytes.count {
                if [9,10,13,32].contains(bytes[i]) { i += 1; continue }
                if bytes[i] != 47 || i + 1 >= bytes.count { break }
                if bytes[i+1] == 47 {
                    i += 2
                    while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 }
                } else if bytes[i+1] == 42 {
                    i += 2
                    while i + 1 < bytes.count && !(bytes[i] == 42 && bytes[i+1] == 47) { i += 1 }
                    guard i + 1 < bytes.count else { throw EditError.invalidConfiguration }
                    i += 2
                } else { break }
            }
            return i
        }
        func end(_ start: Int) throws -> Int {
            let b = bytes[start]
            var i = start + 1
            if b == 34 {
                while i < bytes.count {
                    if bytes[i] == 34 { return i + 1 }
                    i += bytes[i] == 92 ? 2 : 1
                }
            } else if b == 123 || b == 91 {
                let closer: UInt8 = b == 123 ? 125 : 93
                i = try skip(i)
                while i < bytes.count && bytes[i] != closer {
                    if bytes[i] == 44 || bytes[i] == 58 { i += 1 } else { i = try end(i) }
                    i = try skip(i)
                }
                if i < bytes.count { return i + 1 }
            } else {
                guard b != 39 else { throw EditError.invalidConfiguration }
                while i < bytes.count && ![44,93,125,47,9,10,13,32,58].contains(bytes[i]) { i += 1 }
                return i
            }
            throw EditError.invalidConfiguration
        }
        func entries(_ range: Range<Int>) throws -> [Range<Int>] {
            let start = try skip(range.lowerBound)
            guard start < range.upperBound, bytes[start] == 91 else { throw EditError.invalidConfiguration }
            var i = try skip(start + 1), result: [Range<Int>] = []
            while i < range.upperBound && bytes[i] != 93 {
                let next = try end(i)
                result.append(i..<next)
                i = try skip(next)
                if bytes[i] == 44 { i = try skip(i + 1) }
            }
            return result
        }
        func field(_ key: String, in range: Range<Int>) throws -> Range<Int>? {
            let start = try skip(range.lowerBound)
            guard start < range.upperBound, bytes[start] == 123 else { throw EditError.invalidConfiguration }
            var i = try skip(start + 1)
            while i < range.upperBound && bytes[i] != 125 {
                guard bytes[i] == 34 else { throw EditError.invalidConfiguration }
                let keyEnd = try end(i)
                let match = try JSONDecoder().decode(String.self, from: Data(bytes[i..<keyEnd])) == key
                let colon = try skip(keyEnd)
                guard bytes[colon] == 58 else { throw EditError.invalidConfiguration }
                let value = try skip(colon + 1), next = try end(value)
                if match { return value..<next }
                i = try skip(next)
                if bytes[i] == 44 { i = try skip(i + 1) }
            }
            return nil
        }
        func inserting(key: String, value: Any, into range: Range<Int>) throws -> (Range<Int>, [UInt8]) {
            let at = try skip(range.lowerBound) + 1
            guard bytes[at-1] == 123 else { throw EditError.invalidConfiguration }
            let more = bytes[try skip(at)] != 125
            let body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            return (at..<at, Array(("\"" + key + "\":").utf8) + Array(body) + (more ? [44] : []))
        }
    }
}
