//
//  CalculationWidgetPresentationTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 02/10/2026.
//

import Testing
import Foundation
@testable import Triva

// Suites NON isolées, volontairement : `CalculationWidgetPresentation` est
// `nonisolated` et ne prend que des `String` (voir sa documentation dans
// `CalculationWidgetView.swift`) — les appeler de façon synchrone depuis un
// contexte non isolé prouve à la compilation qu'elle reste utilisable hors du
// main actor. Seule la suite qui passe par `CalculationWidgetService` (isolé
// au main actor par défaut) porte `@MainActor`.

// MARK: - Expression typographiée

@Suite("CalculationWidgetPresentation — expression typographiée")
struct CalculationWidgetPresentationExpressionTests {
    @Test(
        "Chaque symbole ASCII devient son glyphe typographique, rien d'autre",
        arguments: [
            ("15% * 240", "15\u{00A0}% \u{00D7} 240"),
            ("2**10", "2^10"),
            ("10 / 4", "10 \u{00F7} 4"),
            ("1.5 - 2", "1,5 \u{2212} 2"),
            ("SQRT (16)", "\u{221A}(16)"),
            ("sqrt(16)+2**10", "\u{221A}(16)+2^10"),
            ("1e-3 * 2", "1e\u{2212}3 \u{00D7} 2"),
        ]
    )
    func typographicSubstitutions(expression: String, expected: String) {
        #expect(CalculationWidgetPresentation.displayExpression(expression) == expected)
    }

    /// Une même expression doit s'afficher pareil quel que soit le moteur
    /// (Apple Intelligence, MLX, BYOK) qui l'a écrite.
    @Test(
        "Les synonymes Unicode acceptés par l'évaluateur s'affichent pareil",
        arguments: [
            ("2\u{00B7}3\u{22C5}4", "2\u{00D7}3\u{00D7}4"),
            ("8\u{2215}2", "8\u{00F7}2"),
            ("5\u{2013}3\u{2014}1", "5\u{2212}3\u{2212}1"),
        ]
    )
    func unicodeSynonyms(expression: String, expected: String) {
        #expect(CalculationWidgetPresentation.displayExpression(expression) == expected)
    }

    @Test("Exactement une espace insécable avant %", arguments: ["15%", "15 %", "15\u{00A0}\u{00A0}%"])
    func percentSpacing(expression: String) {
        #expect(CalculationWidgetPresentation.displayExpression(expression) == "15\u{00A0}%")
    }

    @Test("Blancs multiples et retours à la ligne ramenés à une espace")
    func whitespaceIsCollapsed() {
        #expect(CalculationWidgetPresentation.displayExpression("  2  +\n 3 ") == "2 + 3")
    }

    @Test("Expression vide : chaîne vide, la vue masque alors la ligne")
    func emptyExpression() {
        #expect(CalculationWidgetPresentation.displayExpression("").isEmpty)
    }
}

// MARK: - Résultat

@Suite("CalculationWidgetPresentation — résultat affiché")
struct CalculationWidgetPresentationResultTests {
    @Test("Le séparateur de milliers devient sécable, rien d'autre ne change")
    func groupingSeparatorBecomesBreakable() {
        #expect(CalculationWidgetPresentation.displayResult("1\u{202F}500\u{202F}000,25") == "1\u{2009}500\u{2009}000,25")
        #expect(CalculationWidgetPresentation.displayResult("-1,5") == "-1,5")
        #expect(CalculationWidgetPresentation.displayResult("1,152921505e18") == "1,152921505e18")
    }
}

// MARK: - VoiceOver

@Suite("CalculationWidgetPresentation — VoiceOver")
struct CalculationWidgetPresentationAccessibilityTests {
    @Test(
        "Chaque symbole est lu en toutes lettres",
        arguments: [
            ("15% * 240", "15 pour cent fois 240"),
            ("10 / 4 - 1", "10 divisé par 4 moins 1"),
            ("2 * (3 + 4)", "2 fois parenthèse ouvrante 3 plus 4 parenthèse fermante"),
            ("2**10", "2 puissance 10"),
        ]
    )
    func symbolsAreSpoken(expression: String, expected: String) {
        #expect(CalculationWidgetPresentation.spokenExpression(expression) == expected)
    }

    @Test(
        "Racine d'un nombre simple : lue sans les parenthèses",
        arguments: [
            ("sqrt(16) + 2", "racine carrée de 16 plus 2"),
            ("sqrt(2.25)", "racine carrée de 2,25"),
        ]
    )
    func simpleRootWithoutParentheses(expression: String, expected: String) {
        #expect(CalculationWidgetPresentation.spokenExpression(expression) == expected)
    }

    /// « racine carrée de 16 pour cent » s'entendrait √(16 %) alors que
    /// l'expression vaut √(16) % : les parenthèses doivent rester prononcées.
    @Test(
        "Racine suivie de % ou ^ : parenthèses gardées",
        arguments: [
            ("sqrt(16)%", "racine carrée de parenthèse ouvrante 16 parenthèse fermante pour cent"),
            ("sqrt(16)^2", "racine carrée de parenthèse ouvrante 16 parenthèse fermante puissance 2"),
        ]
    )
    func rootFollowedByPostfixKeepsParentheses(expression: String, expected: String) {
        #expect(CalculationWidgetPresentation.spokenExpression(expression) == expected)
    }

    @Test(
        "Exposant scientifique lu « fois 10 puissance »",
        arguments: [
            ("1.5e-3 * 2", "1,5 fois 10 puissance moins 3 fois 2"),
            ("1E+3", "1 fois 10 puissance 3"),
        ]
    )
    func scientificExponentIsSpoken(expression: String, expected: String) {
        #expect(CalculationWidgetPresentation.spokenExpression(expression) == expected)
    }

    /// L'espace fine insécable U+202F (séparateur de milliers) n'est PAS
    /// remplacée : une espace ordinaire ferait entendre trois nombres.
    @Test(
        "Résultat : signe lu, milliers préservés",
        arguments: [
            ("-1,5", "moins 1,5"),
            ("1,152921505e18", "1,152921505 fois 10 puissance 18"),
            ("1\u{202F}500\u{202F}000", "1\u{202F}500\u{202F}000"),
        ]
    )
    func resultIsSpoken(formattedResult: String, expected: String) {
        #expect(CalculationWidgetPresentation.spokenResult(formattedResult) == expected)
    }

    @Test("Libellé de carte, avec et sans expression")
    func cardLabel() {
        #expect(
            CalculationWidgetPresentation.accessibilityLabel(expression: "15% * 240", formattedResult: "36")
                == "Calcul. 15 pour cent fois 240 égale 36."
        )
        #expect(
            CalculationWidgetPresentation.accessibilityLabel(expression: "", formattedResult: "36")
                == "Calcul. Résultat 36."
        )
    }
}

// MARK: - Accord avec le vrai service

@MainActor
@Suite("CalculationWidgetPresentation — accord avec CalculationWidgetService")
struct CalculationWidgetPresentationServiceAgreementTests {
    /// Ce test fige un détail d'ICU, À REBOURS de `CalculationWidgetServiceTests`
    /// qui l'évite volontairement : ici le caractère n'est pas un détail,
    /// `displayResult` (coupure entre groupes de chiffres) et `spokenText`
    /// (milliers préservés pour VoiceOver) en dépendent. Si une mise à jour
    /// d'ICU change le séparateur, ce test DOIT échouer pour le signaler —
    /// sinon un résultat à 15 chiffres redeviendrait insécable sans bruit.
    @Test("Le formateur fr_FR sépare les milliers par le caractère que la vue remplace")
    func formatterUsesTheGroupingSeparatorTheViewReplaces() throws {
        let formatted = try #require(CalculationResultFormatter.format(1_500_000))
        #expect(formatted.contains(CalculationWidgetPresentation.groupingSeparator))
        #expect(!CalculationWidgetPresentation.displayResult(formatted).contains(CalculationWidgetPresentation.groupingSeparator))
    }

    @Test("Bout en bout : « 15% * 240 » s'affiche et se lit correctement")
    func percentEndToEnd() throws {
        let data = try #require(CalculationWidgetService.makeResult(forExpression: "15% * 240")?.data)
        #expect(CalculationWidgetPresentation.displayExpression(data.expression) == "15\u{00A0}% \u{00D7} 240")
        #expect(
            CalculationWidgetPresentation.accessibilityLabel(expression: data.expression, formattedResult: data.formattedResult)
                == "Calcul. 15 pour cent fois 240 égale 36."
        )
    }

    @Test("Résultat négatif du formateur : lu « moins »")
    func negativeResultIsSpoken() throws {
        let data = try #require(CalculationWidgetService.makeResult(forExpression: "(2.5 - 7) / 3")?.data)
        #expect(CalculationWidgetPresentation.spokenResult(data.formattedResult) == "moins 1,5")
    }

    @Test("Notation scientifique du formateur : lue « fois 10 puissance »")
    func scientificResultIsSpoken() throws {
        let data = try #require(CalculationWidgetService.makeResult(forExpression: "2^60")?.data)
        #expect(CalculationWidgetPresentation.spokenResult(data.formattedResult) == "1,152921505 fois 10 puissance 18")
    }
}
