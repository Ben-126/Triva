//
//  ExternalQuerySanitizerTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M1) : le texte venu d'un Service du Mac est une entrée externe.
//

import Foundation
import Testing
@testable import Triva

struct ExternalQuerySanitizerTests {
    @Test("Texte ordinaire : inchangé")
    func plainTextUnchanged() {
        #expect(ExternalQuerySanitizer.sanitize("Capitale du Japon ?") == "Capitale du Japon ?")
    }

    @Test("Vide, espaces seuls ou retours à la ligne seuls : nil")
    func emptyOrBlankIsNil() {
        #expect(ExternalQuerySanitizer.sanitize("") == nil)
        #expect(ExternalQuerySanitizer.sanitize("   \t  ") == nil)
        #expect(ExternalQuerySanitizer.sanitize("\n\r\n \n") == nil)
        #expect(ExternalQuerySanitizer.sanitize(nil) == nil)
    }

    @Test("Espaces et retours rognés aux deux bouts, intérieur conservé")
    func trimsEnds() {
        #expect(ExternalQuerySanitizer.sanitize("  \n Bonjour le monde \n ") == "Bonjour le monde")
    }

    @Test("Caractères de contrôle retirés (NUL, BEL, ESC, DEL…)")
    func removesControlCharacters() {
        let dirty = "a\u{0}b\u{7}c\u{1B}d\u{7F}e"
        #expect(ExternalQuerySanitizer.sanitize(dirty) == "abcde")
        #expect(ExternalQuerySanitizer.sanitize("\u{0}\u{7}\u{1B}") == nil)
    }

    @Test("Sauts de ligne conservés (CRLF, CR, NEL, séparateurs Unicode ramenés à \\n), tabulation devient espace")
    func normalisesLineBreaksAndTabs() {
        #expect(ExternalQuerySanitizer.sanitize("a\r\nb\rc\u{85}d\u{2028}e\u{2029}f") == "a\nb\nc\nd\ne\nf")
        #expect(ExternalQuerySanitizer.sanitize("a\tb") == "a b")
    }

    @Test("Contrôles de sens d'écriture (U+202E…) retirés : pas de texte affiché à l'envers")
    func removesBidiOverrides() {
        #expect(ExternalQuerySanitizer.sanitize("abc\u{202E}def\u{2066}g\u{2069}") == "abcdefg")
    }

    @Test("Caractères invisibles (Tag, espace de largeur nulle, marques de sens, BOM) retirés : aucune instruction cachée")
    func removesInvisibleFormatCharacters() {
        // « ignore » écrit en caractères Tag (U+E0000 + code ASCII) : invisible à l'écran, lu par un modèle.
        let tagged = String(String.UnicodeScalarView("ignore".unicodeScalars.compactMap { Unicode.Scalar(0xE0000 + $0.value) }))
        #expect(!tagged.isEmpty)
        #expect(ExternalQuerySanitizer.sanitize("Capitale\(tagged) du Japon ?") == "Capitale du Japon ?")
        #expect(ExternalQuerySanitizer.sanitize(tagged) == nil)
        #expect(ExternalQuerySanitizer.sanitize("a\u{200B}b\u{200E}c\u{200F}d\u{061C}e\u{FEFF}f\u{2060}g\u{00AD}h") == "abcdefgh")
    }

    @Test("Joint et non-joint de largeur nulle gardés : les emoji composés et le persan restent lisibles")
    func keepsZeroWidthJoiners() {
        let text = "👩‍💻 می‌خواهم"
        #expect(text.unicodeScalars.contains("\u{200D}"))
        #expect(text.unicodeScalars.contains("\u{200C}"))
        #expect(ExternalQuerySanitizer.sanitize(text) == text)
    }

    @Test("Accents, emoji et séquences ZWJ intacts")
    func keepsAccentsAndEmoji() {
        let text = "Élève à Orléans 🇫🇷 👨‍👩‍👧 ça va ?"
        #expect(ExternalQuerySanitizer.sanitize(text) == text)
    }

    @Test("Limite de 2 000 caractères : exactement 2 000 passe, 2 001 est tronqué à 2 000")
    func lengthLimit() {
        let exact = String(repeating: "a", count: ExternalQuerySanitizer.maxLength)
        #expect(ExternalQuerySanitizer.maxLength == 2_000)
        #expect(ExternalQuerySanitizer.sanitize(exact)?.count == 2_000)
        #expect(ExternalQuerySanitizer.sanitize(exact + "b")?.count == 2_000)
    }

    @Test("Troncature : jamais au milieu d'un emoji, et sans espace final laissé par la coupe")
    func truncationKeepsGraphemesAndTrims() {
        let family = "👨‍👩‍👧"
        let text = String(repeating: "a", count: 1_999) + family + "suite"
        let result = ExternalQuerySanitizer.sanitize(text)
        #expect(result?.count == 2_000)
        #expect(result?.hasSuffix(family) == true)

        let spaced = String(repeating: "a", count: 1_998) + "  " + "bbb"
        let trimmed = ExternalQuerySanitizer.sanitize(spaced)
        #expect(trimmed == String(repeating: "a", count: 1_998))
    }

    @Test("Texte énorme : résultat borné")
    func hugeInputIsBounded() {
        let huge = String(repeating: "x", count: 500_000)
        #expect(ExternalQuerySanitizer.sanitize(huge)?.count == 2_000)
    }
}
