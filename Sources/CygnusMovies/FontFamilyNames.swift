import AppKit
import CoreText

enum FontFamilyNames {
    private static let japanese = names(japanese: true)
    private static let english = names(japanese: false)

    static func title(_ family: String, language: AppLanguage) -> String {
        (language.resolved == .japanese ? japanese : english)[family] ?? family
    }

    private static func names(japanese: Bool) -> [String: String] {
        var result: [String: String] = [:]
        for family in NSFontManager.shared.availableFontFamilies {
            guard let face = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 14),
                  let data = CTFontCopyTable(face as CTFont, CTFontTableTag(kCTFontTableName), []) as Data? else { continue }
            result[family] = familyName(in: data, japanese: japanese)
        }
        return result
    }

    // The name table can contain several translations. AppKit's localizedName
    // follows the system language even when the app's language menu overrides it.
    private static func familyName(in data: Data, japanese: Bool) -> String? {
        guard data.count >= 6 else { return nil }
        func word(_ offset: Int) -> Int { Int(data[offset]) << 8 | Int(data[offset + 1]) }
        let count = word(2), strings = word(4)
        guard 6 + 12 * count <= data.count else { return nil }
        var best: (rank: Int, name: String)?
        for index in 0..<count {
            let offset = 6 + index * 12
            let platform = word(offset), language = word(offset + 4), name = word(offset + 6)
            guard name == 16 || name == 1 else { continue }
            let encoding: String.Encoding
            if platform == 3, language & 0x3ff == (japanese ? 0x11 : 0x09) {
                encoding = .utf16BigEndian
            } else if platform == 1, language == (japanese ? 11 : 0) {
                encoding = japanese ? .shiftJIS : .macOSRoman
            } else { continue }
            let rank = (name == 16 ? 2 : 0) + (platform == 3 ? 1 : 0)
            let start = strings + word(offset + 10), end = start + word(offset + 8)
            guard end <= data.count, rank > (best?.rank ?? -1),
                  let title = String(data: data[start..<end], encoding: encoding), !title.isEmpty else { continue }
            best = (rank, title)
        }
        return best?.name
    }
}
