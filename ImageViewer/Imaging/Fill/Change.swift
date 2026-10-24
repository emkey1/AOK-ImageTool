import Foundation

/// What Change Objects is asked to do to what's marked: give it another color (recolored in place, keeping
/// its shading) or make it something else (painted by the generative fill model from `description`).
nonisolated struct ChangeRequest: Equatable, Sendable {
    struct Color: Equatable, Sendable {
        var red: UInt8, green: UInt8, blue: UInt8
    }

    /// The new color (sRGB), when the change is only a color.
    var color: Color?
    /// What it should look like afterwards, for the generative fill model.
    var description: String

    /// The color it should be: the new color, or the first one the description names (“a red plaid shirt”), so
    /// the generative model can start from it.
    var tint: Color? {
        if let color { return color }
        let said = Self.words(description)
        for (i, _) in said.enumerated() {
            // (The longest name starting here: “navy blue” over “navy”.)
            for length in stride(from: min(3, said.count - i), through: 1, by: -1) {
                if let named = Self.colors[said[i..<(i + length)].joined(separator: " ")] { return named }
            }
        }
        return nil
    }

    /// What `text` asks for, by its words: ending on a color (“change his shirt to blue”, “make her dress dark
    /// green”, “navy”) with nothing about a pattern or material just before it, a color; anything else (“a red
    /// plaid shirt”, “a blue jacket”), a description.
    static func parse(_ text: String) -> ChangeRequest {
        let description = Self.description(of: text)
        let request = ChangeRequest(color: nil, description: description)
        // What it should be: after “to” or “into” where it says so, else the end of the instruction.
        var said = words(description)
        while let last = said.last, trailing.contains(last) { said.removeLast() }
        // The longest color name it ends with (“navy blue” over “blue”).
        guard let name = colors.keys.map({ words($0) }).filter({ said.count >= $0.count && Array(said.suffix($0.count)) == $0 })
                .max(by: { $0.count < $1.count }),
              var color = colors[name.joined(separator: " ")] else { return request }
        let before = said.dropLast(name.count)
        // Where it didn't say “to”, what comes before is what to change (“make her dress red”): just the word next
        // to the color counts.
        let saidTo = [" to ", " into "].contains { text.range(of: $0, options: .caseInsensitive) != nil }
        guard !(saidTo ? Array(before) : Array(before.suffix(1))).contains(where: notJustColor.contains) else { return request }
        let shade = before.suffix(2)
        if shade.contains(where: ["light", "pale", "pastel"].contains) { color = mix(color, with: 255, 0.4) }
        if shade.contains(where: ["dark", "deep"].contains) { color = mix(color, with: 0, 0.4) }
        return ChangeRequest(color: color, description: description)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "colour", with: "color").split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Words that can follow the color (“blue please”, “red instead”).
    private static let trailing: Set<String> = ["color", "colored", "one", "instead", "please", "now", "again", "too", "shade", "tone"]

    /// The instruction without its wording around the new look: “Change his shirt to be a red plaid shirt” →
    /// “a red plaid shirt”.
    static func description(of text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        for marker in [" to be ", " into ", " to "] {
            if let range = s.range(of: marker, options: [.caseInsensitive, .backwards]) {
                s = String(s[range.upperBound...])
                break
            }
        }
        if let range = s.range(of: #"^(please\s+)?(make|turn|change|paint|color)\s+(it|him|her|them|this|that)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(range)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func mix(_ c: Color, with v: UInt8, _ amount: Double) -> Color {
        func m(_ x: UInt8) -> UInt8 { UInt8((Double(x) * (1 - amount) + Double(v) * amount).rounded()) }
        return Color(red: m(c.red), green: m(c.green), blue: m(c.blue))
    }

    /// Words before a color that make a change more than the color (“plaid red”, “shiny black”).
    static let notJustColor: Set<String> = [
        "plaid", "tartan", "striped", "stripes", "stripe", "polka", "dots", "dotted", "checked", "checkered", "floral",
        "flowers", "flower", "pattern", "patterned", "print", "printed", "camo", "camouflage", "leopard", "zebra", "paisley",
        "sequins", "sequined", "glitter", "sparkly", "shiny", "metallic", "leather", "denim", "wool", "woolen", "knit",
        "knitted", "silk", "velvet", "lace", "fur", "furry", "logo", "text", "words", "writing", "letters", "with",
        "wearing", "and",
    ]

    /// Common color names (sRGB).
    static let colors: [String: Color] = {
        let hex: [String: UInt32] = [
            "red": 0xC8202A, "dark red": 0x8B0000, "crimson": 0xDC143C, "scarlet": 0xE0261B, "burgundy": 0x800020,
            "maroon": 0x800000, "wine": 0x722F37, "ruby": 0x9B111E, "cherry": 0xC2185B, "coral": 0xFF7F50,
            "salmon": 0xFA8072, "pink": 0xF4A6C0, "hot pink": 0xFF4FA3, "rose": 0xE8829A, "magenta": 0xD0208F,
            "fuchsia": 0xD82B9E, "orange": 0xF07F1A, "burnt orange": 0xCC5500, "peach": 0xFFC8A8, "rust": 0xB7410E,
            "yellow": 0xF5D020, "mustard": 0xD9A520, "gold": 0xD4AF37, "golden": 0xD4AF37, "lemon": 0xFFF44F,
            "cream": 0xF3EBD6, "beige": 0xE3D5B8, "tan": 0xC8A878, "khaki": 0xC3B091, "brown": 0x7A4A2A,
            "chocolate": 0x5C3317, "camel": 0xC19A6B, "olive": 0x6B7A2A, "lime": 0x8CD02A, "green": 0x2E8B3A,
            "forest green": 0x22582A, "emerald": 0x1F9D6B, "mint": 0x98E2C0, "sage": 0x9CAF88, "teal": 0x1F8A8A,
            "turquoise": 0x30C8C0, "aqua": 0x40D8E0, "cyan": 0x20C0E0, "sky blue": 0x87C3EB, "baby blue": 0xA9D2F0,
            "light blue": 0x9CC8F0, "blue": 0x1E50C8, "royal blue": 0x2A4FC8, "cobalt": 0x1F45A8, "navy": 0x1B2A4E,
            "navy blue": 0x1B2A4E, "denim blue": 0x3F5F8A, "indigo": 0x3F2A8A, "purple": 0x6A2C9A, "violet": 0x7F3FBF,
            "lavender": 0xB8A6E0, "lilac": 0xC8A2D8, "plum": 0x7D3F6E, "white": 0xF5F5F2, "ivory": 0xF8F4E6,
            "black": 0x161616, "gray": 0x808080, "grey": 0x808080, "light gray": 0xC0C0C0, "light grey": 0xC0C0C0,
            "dark gray": 0x444444, "dark grey": 0x444444, "charcoal": 0x36393D, "silver": 0xBFC1C2,
        ]
        return hex.mapValues { Color(red: UInt8($0 >> 16 & 0xFF), green: UInt8($0 >> 8 & 0xFF), blue: UInt8($0 & 0xFF)) }
    }()
}
