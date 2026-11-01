import Foundation

/// Tidy capitals: a tag written entirely in CAPITALS or
/// entirely in lower case becomes Title Case; anything already in mixed case is
/// left alone. Applied to titles and albums only, never to artist names
/// (ruled 1 Nov 2026: some artists write their names in capitals on purpose).
enum TitleCase {
    /// Small words stay lower case unless first, last, or right after a bracket or dash.
    static let small: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or",
                                     "the", "to", "vs", "vs.", "feat.", "ft."]
    /// Short forms kept in capitals.
    static let keepUpper: Set<String> = ["DJ", "MC", "VIP", "UK", "USA", "US", "EP", "LP", "II", "III", "IV", "NYC", "ID"]

    static func tidy(_ s: String) -> String {
        guard s.rangeOfCharacter(from: .letters) != nil else { return s }
        guard s == s.uppercased() || s == s.lowercased() else { return s }

        let words = s.lowercased().components(separatedBy: " ")
        var out: [String] = []
        let wordIndices = words.indices.filter { words[$0].rangeOfCharacter(from: .alphanumerics) != nil }
        let lastWord = wordIndices.last ?? 0
        var startOfPhrase = true
        for (i, w) in words.enumerated() {
            guard w.rangeOfCharacter(from: .alphanumerics) != nil else {
                out.append(w)
                if w.contains("-") || w.contains("–") || w.contains(":") || w.contains("(") || w.contains("[") { startOfPhrase = true }
                continue
            }
            let lead = String(w.prefix { !$0.isLetter && !$0.isNumber })
            let rest = String(w.dropFirst(lead.count))
            let core = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "'" || $0 == "’" || $0 == "-" })
            let trail = String(rest.dropFirst(core.count))
            let first = startOfPhrase || lead.contains("(") || lead.contains("[")
            let last = i == lastWord || trail.contains(")") || trail.contains("]")
            let fixed: String
            if keepUpper.contains(core.uppercased().replacingOccurrences(of: ".", with: "")) {
                fixed = core.uppercased()
            } else if small.contains(core) && !first && !last {
                fixed = core
            } else {
                // capitalise each hyphenated part: "hip-hop" -> "Hip-Hop"
                fixed = core.components(separatedBy: "-").map { part in
                    guard let f = part.first else { return part }
                    return f.uppercased() + part.dropFirst()
                }.joined(separator: "-")
            }
            out.append(lead + fixed + trail)
            startOfPhrase = trail.contains(":")
        }
        return out.joined(separator: " ")
    }
}
