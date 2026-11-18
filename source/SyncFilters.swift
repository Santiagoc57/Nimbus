import Foundation

struct SyncFilters: Codable, Equatable {
    static let defaults = [".DS_Store", "._*"]
    var patterns: [String] = defaults
    /// The catalog presents a split package as a file; Drive presents the
    /// same object as a directory. Match the user's file glob before sending
    /// an exact directory exclusion to the physical transfer backend.
    static func excludesLogicalFile(_ path: String, patterns: [String]) -> Bool {
        for pattern in patterns where !pattern.hasSuffix("/") {
            var regex = "(?:^|/)"
            var cursor = pattern.startIndex
            while cursor < pattern.endIndex {
                let char = pattern[cursor]
                cursor = pattern.index(after: cursor)
                if char == "*" {
                    if cursor < pattern.endIndex && pattern[cursor] == "*" {
                        cursor = pattern.index(after: cursor)
                        regex += ".*"
                    } else {
                        regex += "[^/]*"
                    }
                } else if char == "?" {
                    regex += "[^/]"
                } else {
                    regex += NSRegularExpression.escapedPattern(for: String(char))
                }
            }
            if path.range(of: regex + "\\z", options: .regularExpression) != nil { return true }
        }
        return false
    }

    static func exactDirectoryRules(_ paths: [String]) -> [String] {
        var rules = Set<String>()
        for path in paths {
            for spelling in [path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping, path] {
                let components = spelling.components(separatedBy: "/").map { component in
                    let literal = component.unicodeScalars.map { scalar in
                        scalar.isASCII ? String(format: "\\x%02x", scalar.value) : String(scalar)
                    }.joined()
                    return "{{" + literal + "}}"
                }
                rules.insert("- /" + components.joined(separator: "/") + "/")
            }
        }
        return rules.sorted().flatMap { ["--filter", $0] }
    }
    /// Same literal matching as `exactDirectoryRules`, for the Mac side where a
    /// split document is a plain file at the package path.
    static func exactFileRules(_ paths: [String]) -> [String] {
        var rules = Set<String>()
        for path in paths {
            for spelling in [path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping, path] {
                let components = spelling.components(separatedBy: "/").map { component in
                    "{{" + component.unicodeScalars.map { $0.isASCII ? String(format: "\\x%02x", $0.value) : String($0) }.joined() + "}}"
                }
                rules.insert("- /" + components.joined(separator: "/"))
            }
        }
        return rules.sorted().flatMap { ["--filter", $0] }
    }
    static func validate(_ values: [String]) throws -> [String] {
        var result: [String] = []
        for raw in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
            guard raw.utf8.count <= 120, !raw.hasPrefix("/"), !raw.contains("\\"), !raw.split(separator: "/").contains(".."), raw != ".", raw != ".." else { throw SyncFailure.message("Una regla de exclusión no es segura. Usá nombres o patrones relativos, sin rutas absolutas ni '..'.") }
            guard raw.range(of: "^[A-Za-z0-9._*?+@=,: -]+(/[A-Za-z0-9._*?+@=,: -]+)*$", options: .regularExpression) != nil else { throw SyncFailure.message("Una regla de exclusión contiene caracteres no admitidos.") }
            if !result.contains(raw) { result.append(raw) }
        }
        return result.isEmpty ? defaults : result
    }
}
