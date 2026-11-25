//
//  ExternalQuerySanitizerInvisibleTests.swift
//  TrivaTests
//
//  Mission X1 (C7) : un texte venu de l'extérieur ne peut pas cacher des dizaines de milliers de scalaires
//  invisibles derrière un seul « caractère » : sélecteurs de variante, joints, marques combinantes. Les emoji
//  composés et le persan restent intacts.
//

import Foundation
import Testing
@testable import Triva

@Suite("Assainissement : scalaires invisibles")
struct ExternalQuerySanitizerInvisibleTests {
    private func scalarCount(_ text: String?) -> Int { text?.unicodeScalars.count ?? 0 }

    @Test("Un emoji suivi de 90 000 sélecteurs de variante : un seul sélecteur reste")
    func variationSelectorsFlood() {
        let flood = "\u{2764}" + String(repeating: "\u{FE0F}", count: 90_000)
        let result = ExternalQuerySanitizer.sanitize(flood)
        #expect(result == "\u{2764}\u{FE0F}")
    }

    @Test("Sélecteurs de variante idéographiques U+E0100–E01EF : retirés")
    func supplementarySelectors() {
        let scalars = (0xE0100...0xE01EF).compactMap(Unicode.Scalar.init)
        let hidden = String(String.UnicodeScalarView(scalars))
        #expect(ExternalQuerySanitizer.sanitize("a" + hidden + "b") == "ab")
    }

    @Test("Joints répétés : 4 001 U+200D deviennent un seul, jamais deux de suite")
    func repeatedJoiners() {
        let result = ExternalQuerySanitizer.sanitize("a" + String(repeating: "\u{200D}", count: 4_001) + "b")
        #expect(result == "a\u{200D}b")
        let mixed = ExternalQuerySanitizer.sanitize("a" + String(repeating: "\u{200D}\u{200C}", count: 500) + "b")
        #expect(mixed == "a\u{200D}b")
    }

    @Test("Emoji familial (joints séparés par des emoji) : conservé")
    func familyEmojiKept() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(ExternalQuerySanitizer.sanitize(family) == family)
    }

    @Test("Emoji avec sélecteur (cœur, drapeau, pouce teinté) : conservés")
    func emojiSelectorKept() {
        for text in ["\u{2764}\u{FE0F}", "\u{1F1EB}\u{1F1F7}", "\u{1F44D}\u{1F3FD}", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"] {
            #expect(ExternalQuerySanitizer.sanitize(text) == text)
        }
    }

    @Test("Persan : le non-joint de largeur nulle isolé est conservé")
    func persianKept() {
        let persian = "می\u{200C}خواهم"
        #expect(ExternalQuerySanitizer.sanitize(persian) == persian)
    }

    @Test("Marques combinantes en masse : plafond de scalaires, annoncé comme coupé")
    func combiningFloodIsCapped() throws {
        let flood = "e" + String(repeating: "\u{0301}", count: 50_000)
        #expect(flood.count == 1)
        let result = try #require(ExternalQuerySanitizer.sanitizeReportingTruncation(flood))
        #expect(scalarCount(result.text) <= ExternalQuerySanitizer.maxScalarCount)
        #expect(result.wasTruncated)
    }

    @Test("Texte ordinaire long de 2 000 caractères : pas de fausse coupure par le plafond de scalaires")
    func ordinaryTextNotFlagged() throws {
        let text = String(repeating: "a", count: ExternalQuerySanitizer.maxLength)
        let result = try #require(ExternalQuerySanitizer.sanitizeReportingTruncation(text))
        #expect(result.text == text)
        #expect(!result.wasTruncated)
    }

    @Test("Titre du widget : borné en scalaires avant tout comptage de caractères")
    func widgetTitleBounded() {
        let flood = "e" + String(repeating: "\u{0301}", count: 90_000)
        let title = WidgetSnapshot.displayTitle(flood)
        #expect(title.unicodeScalars.count <= WidgetSnapshot.maxTitleLength * 8 + 1)
    }

    @Test("Question de l'activité en direct : bornée en scalaires")
    func liveActivityQuestionBounded() {
        let flood = "e" + String(repeating: "\u{0301}", count: 90_000)
        let attributes = SearchActivityAttributes(question: flood, conversationID: nil)
        #expect(attributes.question.unicodeScalars.count <= SearchActivityAttributes.maxQuestionLength * 4 + 1)
    }
}
