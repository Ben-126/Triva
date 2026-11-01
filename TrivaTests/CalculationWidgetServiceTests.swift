//
//  CalculationWidgetServiceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 19/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Provider IA factice, même forme que `MockAIGenerating` de
/// `QueryClassifierTests` : une classe simple qui hérite de l'isolation par
/// défaut du projet, suffisante parce que `AIGenerating` fournit
/// `streamGenerate` par défaut — seul `generate` est à écrire.
private final class MockAIGenerating: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private let response: String
    private let error: Error?

    init(response: String = "", error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        if let error { throw error }
        return response
    }
}

private struct MockProviderError: Error {}

/// Le séparateur de milliers du français est un espace fine insécable
/// (U+202F) dans l'ICU actuelle. Le figer dans un littéral rendrait la suite
/// cassable par une mise à jour d'ICU, pour une raison sans rapport avec
/// Triva : on compare donc la projection en chiffres, et on vérifie
/// séparément qu'un séparateur EST présent.
private func digitsOnly(_ text: String) -> String {
    String(text.filter { $0.isASCII && $0.isNumber })
}

// MARK: - Évaluateur : expressions valides

@MainActor
@Suite("CalculationExpressionEvaluator — expressions valides")
struct CalculationEvaluatorValidExpressionTests {
    @Test(
        "Les quatre opérations, les parenthèses et les décimaux",
        arguments: [
            ("1+1", 2.0),
            ("2 + 3 * 4", 14.0),
            ("(2 + 3) * 4", 20.0),
            ("2 * (3 + 4)", 14.0),
            ("10 - 4 - 3", 3.0),
            ("8 / 4 / 2", 1.0),
            ("1.5 * 2", 3.0),
            ("  7  ", 7.0),
            ("0^2", 0.0),
            ("2^10", 1024.0),
            ("sqrt(16)", 4.0),
            ("2 * sqrt(9)", 6.0),
            ("sqrt(16.0)", 4.0),
        ]
    )
    func evaluatesCommonExpressions(expression: String, expected: Double) throws {
        #expect(try CalculationExpressionEvaluator.evaluate(expression) == expected)
    }

    /// Les parenthèses de `sqrt` sont obligatoires précisément pour que ce cas
    /// soit `sqrt(16) + 9 = 13` et non `sqrt(16 + 9) = 5`. C'est le test qui
    /// justifie l'exigence documentée dans `scanFunction`.
    @Test("sqrt ne capture que son argument parenthésé")
    func squareRootBindsOnlyItsArgument() throws {
        #expect(try CalculationExpressionEvaluator.evaluate("sqrt(16) + 9") == 13.0)
    }

    @Test("Notation scientifique dans les littéraux")
    func supportsScientificLiterals() throws {
        #expect(try CalculationExpressionEvaluator.evaluate("1e3") == 1000.0)
        #expect(try CalculationExpressionEvaluator.evaluate("2.5e-4") == 0.00025)
        #expect(try CalculationExpressionEvaluator.evaluate("1e2 + 1") == 101.0)
    }

    /// `sqrt(2)` est irrationnel : on compare à epsilon près, pas à l'égalité.
    @Test("Racine non exacte")
    func irrationalSquareRoot() throws {
        let value = try CalculationExpressionEvaluator.evaluate("sqrt(2)")
        #expect(abs(value - 1.4142135623730951) < 1e-15)
    }
}

// MARK: - Évaluateur : précédence et associativité

@MainActor
@Suite("CalculationExpressionEvaluator — précédence et associativité")
struct CalculationEvaluatorPrecedenceTests {
    /// Ces cas cassent au moindre réglage de travers de la table de
    /// précédence : la puissance à 4 et associative à droite, le moins unaire
    /// à 3 dans le trou laissé exprès entre `* /` et `^`.
    @Test(
        "Puissance, moins unaire et associativité",
        arguments: [
            ("2^3^2", 512.0),      // associatif à DROITE : 2^(3^2), pas (2^3)^2 = 64
            ("-2^2", -4.0),        // la puissance se lie plus fort que le moins unaire
            ("(-2)^2", 4.0),       // ... sauf si on parenthèse
            ("2^-3", 0.125),       // exposant négatif
            ("-2 * 3", -6.0),      // le moins unaire se lie plus fort que la multiplication
            ("-(3 + 4)", -7.0),
            ("--5", 5.0),          // double moins unaire
            ("+5", 5.0),           // plus unaire : neutre
            ("2 * +3", 6.0),
            ("2 - -3", 5.0),
        ]
    )
    func respectsPrecedence(expression: String, expected: Double) throws {
        #expect(try CalculationExpressionEvaluator.evaluate(expression) == expected)
    }

    @Test("Soustraction et division sont associatives à gauche")
    func leftAssociativity() throws {
        // Si elles étaient associatives à droite, on lirait 10-(4-3)=9 et 8/(4/2)=4.
        #expect(try CalculationExpressionEvaluator.evaluate("10 - 4 - 3") == 3.0)
        #expect(try CalculationExpressionEvaluator.evaluate("8 / 4 / 2") == 1.0)
    }
}

// MARK: - Évaluateur : pourcentage

@MainActor
@Suite("CalculationExpressionEvaluator — pourcentage")
struct CalculationEvaluatorPercentTests {
    /// Le cas explicitement cité par le plan 1.5 : « 15% de 240 », dans les
    /// deux écritures que le prompt propose au modèle.
    @Test("« 15% de 240 » vaut 36 dans les deux écritures acceptées")
    func planExample() throws {
        #expect(try CalculationExpressionEvaluator.evaluate("15% * 240") == 36.0)
        #expect(try CalculationExpressionEvaluator.evaluate("240 * 15 / 100") == 36.0)
        #expect(try CalculationExpressionEvaluator.evaluate("240 * 0.15") == 36.0)
    }

    /// Verrouille la convention documentée : `%` vaut « diviser par 100 »,
    /// toujours, et n'ajoute JAMAIS implicitement un pourcentage de
    /// l'opérande de gauche comme le feraient certaines calculatrices de
    /// poche. Si quelqu'un « corrige » ça un jour, ce test doit hurler.
    @Test("« 240 + 10% » vaut 240,1 et non 264")
    func percentIsNeverContextual() throws {
        #expect(try CalculationExpressionEvaluator.evaluate("240 + 10%") == 240.1)
    }

    @Test(
        "Le pourcentage se lie à l'opérande qui le précède",
        arguments: [
            ("50%", 0.5),
            ("(2 + 3)%", 0.05),
            ("2 * 50%", 1.0),
            ("100% + 100%", 2.0),
            ("5%%", 0.0005),    // postfixe applicable deux fois : conséquence assumée
        ]
    )
    func percentBinding(expression: String, expected: Double) throws {
        #expect(try CalculationExpressionEvaluator.evaluate(expression) == expected)
    }

    /// `%` n'est PAS le modulo : `10 % 3` doit échouer proprement plutôt que
    /// de rendre « 1 » (modulo) ou « 0,1 puis 3 » (silencieusement faux).
    @Test("« 10 % 3 » est une erreur de syntaxe, jamais un modulo")
    func percentIsNeverModulo() {
        #expect(throws: CalculationExpressionError.unexpectedToken) {
            try CalculationExpressionEvaluator.evaluate("10 % 3")
        }
    }
}

// MARK: - Évaluateur : normalisation

@MainActor
@Suite("CalculationExpressionEvaluator — normalisation")
struct CalculationEvaluatorNormalizationTests {
    @Test(
        "Les graphies alternatives donnent le même résultat",
        arguments: [
            ("3 \u{00D7} 4", 12.0),        // ×
            ("3 \u{22C5} 4", 12.0),        // ⋅
            ("10 \u{00F7} 4", 2.5),        // ÷
            ("\u{2212}5 + 3", -2.0),       // − moins typographique
            ("2**10", 1024.0),             // notation Python/JavaScript
            ("SQRT(25)", 5.0),             // insensible à la casse
            ("\u{221A}(16)", 4.0),         // √
            ("1E3", 1000.0),
            ("2\u{00A0}+\u{00A0}3", 5.0),  // espaces insécables autour d'un opérateur
        ]
    )
    func normalizesAlternativeSpellings(expression: String, expected: Double) throws {
        #expect(try CalculationExpressionEvaluator.evaluate(expression) == expected)
    }

    /// `**` doit être remplacé AVANT toute substitution touchant `*`, sinon
    /// `2**10` resterait deux multiplications de suite.
    @Test("L'ordre des substitutions préserve **")
    func doubleStarBecomesPower() {
        #expect(CalculationExpressionEvaluator.normalize("2**10") == "2^10")
    }

    @Test("normalize détoure et met en minuscules")
    func normalizeTrimsAndLowercases() {
        #expect(CalculationExpressionEvaluator.normalize("  SQRT(4)  ") == "sqrt(4)")
        #expect(CalculationExpressionEvaluator.normalize("\n2\t+\t2\n") == "2 + 2")
    }

    /// Convertir l'espace insécable ne rend PAS `1 000 000` valide : un espace
    /// entre deux nombres reste ambigu, au même titre que la virgule.
    @Test("Un nombre à séparateurs de milliers reste refusé")
    func groupedThousandsAreRejected() {
        #expect(throws: CalculationExpressionError.unexpectedToken) {
            try CalculationExpressionEvaluator.evaluate("1 000 000 + 1")
        }
        #expect(throws: CalculationExpressionError.unexpectedToken) {
            try CalculationExpressionEvaluator.evaluate("1\u{202F}000 + 1")
        }
    }
}

// MARK: - Évaluateur : entrées refusées

@MainActor
@Suite("CalculationExpressionEvaluator — entrées refusées")
struct CalculationEvaluatorRejectionTests {
    @Test(
        "Chaque entrée invalide tombe sur SON motif d'erreur",
        arguments: [
            ("", CalculationExpressionError.emptyExpression),
            ("   ", CalculationExpressionError.emptyExpression),
            ("+", CalculationExpressionError.emptyExpression),    // plus unaire seul : aucun jeton émis
            ("2 +", CalculationExpressionError.unexpectedToken),
            ("2 + * 3", CalculationExpressionError.unexpectedToken),
            ("2 3", CalculationExpressionError.unexpectedToken),
            ("2(3+4)", CalculationExpressionError.unexpectedToken),  // multiplication implicite refusée
            (")(", CalculationExpressionError.unexpectedToken),
            ("()", CalculationExpressionError.unexpectedToken),
            ("sqrt()", CalculationExpressionError.unexpectedToken),
            ("2^", CalculationExpressionError.unexpectedToken),
            ("%", CalculationExpressionError.unexpectedToken),
            ("(1+2", CalculationExpressionError.unbalancedParentheses),
            ("1+2)", CalculationExpressionError.unbalancedParentheses),
            ("1.2.3", CalculationExpressionError.malformedNumber("1.2.")),
            (".", CalculationExpressionError.malformedNumber(".")),
            ("foo(2)", CalculationExpressionError.unknownFunction("foo")),
            ("a", CalculationExpressionError.unknownFunction("a")),
            ("sqrt 16", CalculationExpressionError.unexpectedToken),
            ("\u{221A}16", CalculationExpressionError.unexpectedToken),  // √ sans parenthèses
        ]
    )
    func rejectsWithExactReason(expression: String, expected: CalculationExpressionError) {
        #expect(throws: expected) { try CalculationExpressionEvaluator.evaluate(expression) }
    }

    /// Entrées hostiles ou simplement étrangères à la grammaire : toutes sont
    /// arrêtées par la LISTE BLANCHE, avant même la tokenisation. C'est la
    /// contrepartie testable du rejet de `NSExpression` (qui, lui, aurait
    /// interprété `FUNCTION(...)` et les key-paths).
    @Test(
        "La liste blanche arrête les caractères étrangers à l'arithmétique",
        arguments: [
            ("1,5", Character(",")),
            ("$5", Character("$")),
            ("2;3", Character(";")),
            ("1 + FUNCTION(1,2)", Character(",")),
            ("2 & 3", Character("&")),
            ("2 | 3", Character("|")),
            ("#", Character("#")),
            ("1 + [2]", Character("[")),
            ("{}", Character("{")),
            ("\"2\"", Character("\"")),
            ("2 \u{00B2}", Character("\u{00B2}")),  // exposant typographique ²
        ]
    )
    func whitelistRejectsHostileCharacters(expression: String, offending: Character) {
        #expect(throws: CalculationExpressionError.invalidCharacter(offending)) {
            try CalculationExpressionEvaluator.evaluate(expression)
        }
    }

    /// Un key-path — la forme que `NSExpression` aurait, elle, interprétée —
    /// ne contient que des caractères de la liste blanche : c'est le
    /// tokeniseur qui l'arrête, sur le premier identifiant inconnu. On pin le
    /// motif réel plutôt qu'une intuition.
    @Test("Un key-path style NSExpression est refusé par le tokeniseur")
    func keyPathIsRejected() {
        #expect(throws: CalculationExpressionError.unknownFunction("a")) {
            try CalculationExpressionEvaluator.evaluate("a.b.c")
        }
    }
}

// MARK: - Évaluateur : arithmétique impossible

@MainActor
@Suite("CalculationExpressionEvaluator — arithmétique impossible")
struct CalculationEvaluatorArithmeticLimitTests {
    @Test(
        "Division par zéro, sous toutes ses formes",
        arguments: ["1/0", "0/0", "(5 - 5) / (5 - 5)", "1 / (2 - 2)", "1 / 0.0"]
    )
    func divisionByZero(expression: String) {
        #expect(throws: CalculationExpressionError.divisionByZero) {
            try CalculationExpressionEvaluator.evaluate(expression)
        }
    }

    /// Chacun de ces cas produirait `inf` ou `nan` si on ne vérifiait pas la
    /// finitude : ils s'afficheraient alors « NaN » ou « ∞ » dans le widget.
    @Test(
        "Dépassement et domaine interdit",
        arguments: [
            "9^9^9",        // dépassement par la puissance
            "1e999",        // littéral que strtod ramène à +infini, pas à nil
            "1e400 * 2",
            "1e308 * 10",
            "sqrt(-1)",     // domaine réel
            "0^-1",         // pow renvoie +infini
            "-1e999",
        ]
    )
    func notRepresentable(expression: String) {
        #expect(throws: CalculationExpressionError.resultNotRepresentable) {
            try CalculationExpressionEvaluator.evaluate(expression)
        }
    }

    @Test("Les grands entiers exactement représentables passent")
    func largeExactIntegersAreFine() throws {
        #expect(try CalculationExpressionEvaluator.evaluate("123456789012345 + 0") == 123_456_789_012_345)
        #expect(try CalculationExpressionEvaluator.evaluate("1e14 * 10") == 1e15)
    }
}

// MARK: - Évaluateur : bornes et robustesse

@MainActor
@Suite("CalculationExpressionEvaluator — bornes")
struct CalculationEvaluatorBoundsTests {
    @Test("Une expression trop longue est refusée avec sa longueur")
    func rejectsTooLongExpression() {
        // 200 « 1+ » suivis d'un « 1 » : 401 caractères après normalisation.
        let expression = String(repeating: "1+", count: 200) + "1"
        #expect(throws: CalculationExpressionError.expressionTooLong(length: 401)) {
            try CalculationExpressionEvaluator.evaluate(expression)
        }
    }

    @Test("Une expression pile à la limite passe")
    func acceptsExpressionAtTheLimit() throws {
        // 127 « 1+ » + « 1 » = 255 caractères, soit un de moins que la borne.
        let expression = String(repeating: "1+", count: 127) + "1"
        #expect(expression.count == CalculationExpressionEvaluator.maximumExpressionLength - 1)
        #expect(try CalculationExpressionEvaluator.evaluate(expression) == 128.0)
    }

    /// Les trois étapes sont itératives : 100 niveaux de parenthèses ne
    /// doivent pas faire déborder la pile d'appels. Un parseur récursif
    /// descendant crasherait ici.
    @Test("Parenthèses profondément imbriquées : pas de débordement de pile")
    func deeplyNestedParenthesesDoNotOverflow() throws {
        let depth = 100
        let expression = String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
        #expect(try CalculationExpressionEvaluator.evaluate(expression) == 1.0)
    }

    @Test("Une entrée énorme est refusée sur la longueur, pas sur le contenu")
    func hugeInputIsRejectedEarly() {
        let expression = String(repeating: "9", count: 10_000)
        #expect(throws: CalculationExpressionError.expressionTooLong(length: 10_000)) {
            try CalculationExpressionEvaluator.evaluate(expression)
        }
    }
}

// MARK: - Évaluateur : étapes internes

@MainActor
@Suite("CalculationExpressionEvaluator — étapes internes")
struct CalculationEvaluatorStageTests {
    @Test("tokenize distingue le moins unaire du moins binaire")
    func tokenizeDisambiguatesMinus() throws {
        #expect(try CalculationExpressionEvaluator.tokenize("-2") == [.unaryMinus, .number(2)])
        #expect(try CalculationExpressionEvaluator.tokenize("3-2") == [
            .number(3), .binaryOperator(.subtract), .number(2),
        ])
        #expect(try CalculationExpressionEvaluator.tokenize("3*-2") == [
            .number(3), .binaryOperator(.multiply), .unaryMinus, .number(2),
        ])
    }

    @Test("tokenize émet le pourcentage comme jeton postfixe")
    func tokenizeEmitsPercent() throws {
        #expect(try CalculationExpressionEvaluator.tokenize("5%") == [.number(5), .percent])
    }

    @Test("shuntingYard place le pourcentage juste après son opérande")
    func shuntingYardKeepsPercentAttached() throws {
        let rpn = try CalculationExpressionEvaluator.shuntingYard(
            CalculationExpressionEvaluator.tokenize("240 + 10%")
        )
        #expect(rpn == [.number(240), .number(10), .percent, .binaryOperator(.add)])
    }

    @Test("shuntingYard sort la fonction après son argument")
    func shuntingYardEmitsFunctionAfterArgument() throws {
        let rpn = try CalculationExpressionEvaluator.shuntingYard(
            CalculationExpressionEvaluator.tokenize("sqrt(9) + 1")
        )
        #expect(rpn == [.number(9), .function(.squareRoot), .number(1), .binaryOperator(.add)])
    }

    /// Une file RPN incohérente ne peut pas venir du shunting-yard, mais
    /// `evaluateRPN` est exposé : il doit refuser plutôt que planter sur une
    /// pile vide.
    @Test(
        "evaluateRPN refuse une file incohérente au lieu de planter",
        arguments: [
            [CalculationRPNItem.binaryOperator(.add)],                    // pas d'opérande
            [CalculationRPNItem.number(1), .binaryOperator(.add)],        // un seul opérande
            [CalculationRPNItem.number(1), .number(2)],                   // deux résultats
            [CalculationRPNItem.percent],
            [CalculationRPNItem.unaryMinus],
            [],                                                           // file vide
        ]
    )
    func evaluateRPNRejectsMalformedQueues(items: [CalculationRPNItem]) {
        #expect(throws: CalculationExpressionError.unexpectedToken) {
            try CalculationExpressionEvaluator.evaluateRPN(items)
        }
    }

    @Test("La table de précédence est celle qui est documentée")
    func precedenceTable() {
        #expect(CalculationBinaryOperator.add.precedence == 1)
        #expect(CalculationBinaryOperator.subtract.precedence == 1)
        #expect(CalculationBinaryOperator.multiply.precedence == 2)
        #expect(CalculationBinaryOperator.divide.precedence == 2)
        #expect(CalculationBinaryOperator.power.precedence == 4)
        // Le trou à 3 est réservé au moins unaire : c'est lui qui fait -2^2 = -4.
        #expect(CalculationExpressionEvaluator.unaryMinusPrecedence == 3)
        #expect(CalculationBinaryOperator.power.isRightAssociative)
        #expect(!CalculationBinaryOperator.multiply.isRightAssociative)
    }

    @Test("sqrt est la seule fonction ouverte")
    func onlySquareRootIsExposed() {
        #expect(CalculationFunction.allCases == [.squareRoot])
        #expect(CalculationFunction(rawValue: "sqrt") == .squareRoot)
        #expect(CalculationFunction(rawValue: "log") == nil)
    }

    @Test("La virgule n'est pas dans la liste blanche")
    func commaIsNotAllowed() {
        #expect(!CalculationExpressionEvaluator.isAllowed(","))
        #expect(CalculationExpressionEvaluator.isAllowed("."))
        #expect(CalculationExpressionEvaluator.isAllowed("%"))
        #expect(!CalculationExpressionEvaluator.isAllowed("\u{00D7}"))  // × : normalisé AVANT le filtre
    }
}

// MARK: - Formatage

@MainActor
@Suite("CalculationResultFormatter")
struct CalculationResultFormatterTests {
    /// LE test de la mission : le bruit binaire ne doit jamais atteindre
    /// l'écran. `4.35 * 100` vaut `434.99999999999994` en `Double`.
    @Test("Le bruit binaire disparaît")
    func removesBinaryNoise() throws {
        #expect(CalculationResultFormatter.format(434.99999999999994) == "435")
        #expect(CalculationResultFormatter.format(36.000000000000004) == "36")
        #expect(CalculationResultFormatter.format(0.30000000000000004) == "0,3")
        #expect(CalculationResultFormatter.format(3.3000000000000003) == "3,3")
        #expect(CalculationResultFormatter.format(0.09999999999999998) == "0,1")
    }

    /// Le trajet complet demandé par le plan : expression -> valeur -> texte.
    @Test(
        "De l'expression au texte affiché",
        arguments: [
            ("15% * 240", "36"),
            ("240 * 0.15", "36"),
            ("4.35 * 100", "435"),
            ("0.1 + 0.2", "0,3"),
            ("1 / 4", "0,25"),
            ("10 / 4", "2,5"),
            ("-1234.5", "-1 234,5"),
        ]
    )
    func formatsEvaluatedExpressions(expression: String, expected: String) throws {
        let value = try CalculationExpressionEvaluator.evaluate(expression)
        let formatted = try #require(CalculationResultFormatter.format(value))
        // On compare la projection en chiffres et le séparateur décimal, pas
        // l'espace de milliers (voir `digitsOnly`).
        #expect(digitsOnly(formatted) == digitsOnly(expected))
        #expect(formatted.contains(",") == expected.contains(","))
        #expect(formatted.hasPrefix("-") == expected.hasPrefix("-"))
    }

    @Test("Le séparateur décimal est la virgule, jamais le point")
    func usesFrenchDecimalSeparator() {
        let formatted = CalculationResultFormatter.format(2.5)
        #expect(formatted == "2,5")
        #expect(formatted?.contains(".") == false)
    }

    /// Le séparateur de milliers est présent mais son CARACTÈRE exact dépend
    /// d'ICU : on vérifie les chiffres et le fait qu'il y ait bien des
    /// séparateurs, pas lesquels.
    @Test("Les milliers sont groupés")
    func groupsThousands() throws {
        let formatted = try #require(CalculationResultFormatter.format(1_234_567))
        #expect(digitsOnly(formatted) == "1234567")
        #expect(formatted.count == 9)  // 7 chiffres + 2 séparateurs
        #expect(!formatted.contains(","))
    }

    @Test("Zéro et zéro négatif s'affichent tous les deux « 0 »")
    func zeroIsNeverSigned() {
        #expect(CalculationResultFormatter.format(0) == "0")
        #expect(CalculationResultFormatter.format(-0.0) == "0")
    }

    /// Au-delà de 1e15, les chiffres d'un `Double` deviennent du bruit et une
    /// ligne de 300 chiffres serait illisible : on bascule en scientifique.
    @Test(
        "Bascule en notation scientifique aux deux extrémités",
        arguments: [
            (1e20, "1e20"),
            (1e15, "1e15"),
            (-1e18, "-1e18"),
            (1e-12, "1e-12"),
            (1e-30, "1e-30"),
        ]
    )
    func switchesToScientificNotation(value: Double, expected: String) {
        #expect(CalculationResultFormatter.format(value) == expected)
    }

    @Test("Juste sous le seuil, on reste en décimal")
    func staysDecimalJustBelowTheThreshold() throws {
        let formatted = try #require(CalculationResultFormatter.format(999_999_999_999_999))
        #expect(digitsOnly(formatted) == "999999999999999")
        #expect(!formatted.contains("e"))
    }

    @Test("Une valeur non finie ne se formate pas")
    func rejectsNonFiniteValues() {
        #expect(CalculationResultFormatter.format(.nan) == nil)
        #expect(CalculationResultFormatter.format(.infinity) == nil)
        #expect(CalculationResultFormatter.format(-.infinity) == nil)
    }

    @Test("Au plus 10 décimales")
    func capsFractionDigits() throws {
        let value = try CalculationExpressionEvaluator.evaluate("1 / 3")
        #expect(CalculationResultFormatter.format(value) == "0,3333333333")
    }
}

// MARK: - Service : prompt d'extraction

@MainActor
@Suite("CalculationWidgetService — prompt d'extraction")
struct CalculationWidgetPromptTests {
    @Test("Le prompt contient la requête, le format de sortie et la grammaire")
    func promptContainsEssentials() {
        let prompt = CalculationWidgetService.buildExtractionPrompt(
            query: "combien font 15% de 240 ?",
            chatHistory: []
        )
        #expect(prompt.contains("combien font 15% de 240 ?"))
        #expect(prompt.contains("<output_format>"))
        #expect(prompt.contains("\"notPresent\""))
        #expect(prompt.contains("\"expression\""))
        // La grammaire est la contrepartie du choix d'un évaluateur maison :
        // sans elle, le modèle produirait du mathjs générique, rejeté ici.
        #expect(prompt.contains("<grammar>"))
        #expect(prompt.contains("sqrt(x)"))
        #expect(prompt.contains("15% * 240"))
    }

    @Test("L'historique est repris avec les rôles, dans l'ordre")
    func promptIncludesHistory() throws {
        let prompt = CalculationWidgetService.buildExtractionPrompt(
            query: "et fois 3 ?",
            chatHistory: [
                ClassifierChatMessage(role: .user, content: "combien font 12 * 4 ?"),
                ClassifierChatMessage(role: .assistant, content: "48"),
            ]
        )
        #expect(prompt.contains("User: combien font 12 * 4 ?"))
        #expect(prompt.contains("AI: 48"))
        let userRange = try #require(prompt.range(of: "User: combien"))
        let assistantRange = try #require(prompt.range(of: "AI: 48"))
        #expect(userRange.lowerBound < assistantRange.lowerBound)
    }

    @Test("Seuls les derniers messages sont injectés")
    func promptTruncatesHistory() {
        let history = (1...12).map { ClassifierChatMessage(role: .user, content: "message \($0)") }
        let prompt = CalculationWidgetService.buildExtractionPrompt(
            query: "et alors ?",
            chatHistory: history,
            maxHistoryMessages: 3
        )
        #expect(!prompt.contains("message 9"))
        #expect(prompt.contains("message 10"))
        #expect(prompt.contains("message 12"))
    }

    @Test("Un budget d'historique nul ou négatif n'explose pas")
    func promptToleratesNonPositiveBudget() {
        let history = [ClassifierChatMessage(role: .user, content: "message")]
        for budget in [0, -5] {
            let prompt = CalculationWidgetService.buildExtractionPrompt(
                query: "q",
                chatHistory: history,
                maxHistoryMessages: budget
            )
            #expect(!prompt.contains("User: message"))
        }
    }
}

// MARK: - Service : parsing de la sortie LLM

@MainActor
@Suite("CalculationWidgetService — parsing de la sortie LLM")
struct CalculationWidgetParsingTests {
    @Test("JSON strict")
    func parsesStrictJSON() {
        let raw = #"{"expression": "15% * 240", "notPresent": false}"#
        #expect(CalculationWidgetService.parseExtraction(raw) == "15% * 240")
    }

    @Test("JSON dans un bloc markdown, avec ou sans étiquette de langage")
    func parsesFencedJSON() {
        let labelled = """
        Voici le résultat :
        ```json
        {"expression": "2 + 2", "notPresent": false}
        ```
        """
        let unlabelled = """
        ```
        {"expression": "2 + 2", "notPresent": false}
        ```
        """
        #expect(CalculationWidgetService.parseExtraction(labelled) == "2 + 2")
        #expect(CalculationWidgetService.parseExtraction(unlabelled) == "2 + 2")
    }

    @Test("JSON noyé dans du bavardage")
    func parsesJSONSurroundedByProse() {
        let raw = "Bien sûr ! {\"expression\": \"7*6\", \"notPresent\": false} Voilà."
        #expect(CalculationWidgetService.parseExtraction(raw) == "7*6")
    }

    @Test("L'expression est détourée")
    func trimsExtractedExpression() {
        #expect(CalculationWidgetService.parseExtraction(#"{"expression": "  2+2  "}"#) == "2+2")
    }

    /// `notPresent: true`, expression vide, champ absent, JSON cassé, texte
    /// libre : tous « pas de widget ». Le parsing ne throw jamais, règle
    /// générale du projet pour toute sortie de LLM.
    @Test(
        "Tout ce qui n'est pas exploitable renvoie nil, sans jamais throw",
        arguments: [
            #"{"expression": "2+2", "notPresent": true}"#,
            #"{"expression": "", "notPresent": false}"#,
            #"{"expression": "   "}"#,
            #"{"notPresent": false}"#,
            #"{"expression": 42}"#,
            "{ ceci n'est pas du JSON }",
            "Je ne peux pas répondre.",
            "",
            "{",
            "}{",
        ]
    )
    func returnsNilForUnusableOutput(raw: String) {
        #expect(CalculationWidgetService.parseExtraction(raw) == nil)
    }

    /// Si le premier bloc est décodable mais vide, on tente le suivant plutôt
    /// que d'abandonner : un modèle bavard produit parfois un gabarit vide
    /// avant la vraie réponse.
    @Test("Un premier bloc vide n'empêche pas de lire le suivant")
    func fallsBackToNextCandidate() {
        let raw = """
        ```json
        {"expression": ""}
        ```
        ```json
        {"expression": "3*3", "notPresent": false}
        ```
        """
        #expect(CalculationWidgetService.parseExtraction(raw) == "3*3")
    }

    /// `notPresent: true` est prioritaire : le modèle a explicitement dit
    /// qu'il n'y avait rien à calculer, on ne cherche pas plus loin.
    @Test("notPresent arrête la recherche immédiatement")
    func notPresentStopsTheSearch() {
        let raw = """
        ```json
        {"expression": "", "notPresent": true}
        ```
        ```json
        {"expression": "9*9"}
        ```
        """
        #expect(CalculationWidgetService.parseExtraction(raw) == nil)
    }
}

// MARK: - Service : de l'expression au résultat

@MainActor
@Suite("CalculationWidgetService — de l'expression au résultat")
struct CalculationWidgetResultTests {
    @Test("Le cas du plan 1.5, de bout en bout")
    func planExampleEndToEnd() throws {
        let result = try #require(CalculationWidgetService.makeResult(forExpression: "15% * 240"))
        #expect(result.data.expression == "15% * 240")
        #expect(result.data.result == 36.0)
        #expect(result.data.formattedResult == "36")
        #expect(result.llmContext == "Résultat du calcul « 15% * 240 » : 36.")
    }

    @Test("L'expression affichée est celle du modèle, pas sa forme normalisée")
    func keepsTheAuthoredExpression() throws {
        let result = try #require(CalculationWidgetService.makeResult(forExpression: "  SQRT(16)  "))
        #expect(result.data.expression == "SQRT(16)")  // détourée, mais pas mise en minuscules
        #expect(result.data.formattedResult == "4")
    }

    /// Chaque motif d'échec de l'évaluateur donne la même chose ici : pas de
    /// widget. C'est ce qui garantit qu'un calcul raté ne dégrade jamais la
    /// réponse principale.
    @Test(
        "Toute expression inexploitable ne produit aucun widget",
        arguments: ["", "   ", "1/0", "sqrt(-1)", "(1+2", "1,5", "9^9^9", "2(3+4)", "bonjour"]
    )
    func producesNoWidgetForUnusableExpressions(expression: String) {
        #expect(CalculationWidgetService.makeResult(forExpression: expression) == nil)
    }

    @Test("Le contexte LLM est une phrase française autoportante")
    func llmContextIsSelfContained() {
        let data = CalculationWidgetData(expression: "2 + 2", result: 4, formattedResult: "4")
        let context = CalculationWidgetService.llmContext(for: data)
        #expect(context == "Résultat du calcul « 2 + 2 » : 4.")
        #expect(!context.contains("{"))  // pas de JSON brut, contrairement au web
    }
}

// MARK: - Service : pipeline complet avec provider IA

@MainActor
@Suite("CalculationWidgetService — pipeline complet")
struct CalculationWidgetPipelineTests {
    @Test("Le provider est appelé une fois et son expression est évaluée")
    func computesFromProviderOutput() async throws {
        let provider = MockAIGenerating(response: #"{"expression": "15% * 240", "notPresent": false}"#)
        let service = CalculationWidgetService(aiProvider: provider)

        let result = try #require(await service.computeCalculation(forQuery: "15% de 240"))

        #expect(result.data.formattedResult == "36")
        #expect(provider.receivedPrompts.count == 1)
        #expect(provider.receivedPrompts.first?.contains("15% de 240") == true)
    }

    @Test("L'historique fourni arrive bien dans le prompt")
    func forwardsChatHistory() async throws {
        let provider = MockAIGenerating(response: #"{"expression": "12 * 4 * 3"}"#)
        let service = CalculationWidgetService(aiProvider: provider)

        let result = await service.computeCalculation(
            forQuery: "et fois 3 ?",
            chatHistory: [ClassifierChatMessage(role: .user, content: "combien font 12 * 4 ?")]
        )

        #expect(result?.data.result == 144)
        #expect(provider.receivedPrompts.first?.contains("User: combien font 12 * 4 ?") == true)
    }

    /// Un provider qui échoue (réseau coupé, clé BYOK invalide, modèle MLX
    /// absent) ne doit pas faire remonter d'erreur : le widget disparaît, la
    /// réponse principale continue.
    @Test("Un provider en erreur ne produit pas de widget et ne throw pas")
    func swallowsProviderFailure() async {
        let provider = MockAIGenerating(error: MockProviderError())
        let service = CalculationWidgetService(aiProvider: provider)

        let result = await service.computeCalculation(forQuery: "2+2")
        #expect(result == nil)
    }

    @Test(
        "Sortie de modèle inexploitable : pas de widget",
        arguments: [
            #"{"expression": "2+2", "notPresent": true}"#,
            #"{"expression": "1/0"}"#,
            #"{"expression": "raconte-moi une blague"}"#,
            "je ne sais pas",
            "",
        ]
    )
    func producesNoWidgetForUnusableModelOutput(response: String) async {
        let provider = MockAIGenerating(response: response)
        let service = CalculationWidgetService(aiProvider: provider)

        let result = await service.computeCalculation(forQuery: "une question")
        #expect(result == nil)
    }

    /// Le service se déclare via un protocole `nonisolated` : il doit pouvoir
    /// être manipulé derrière l'existentiel, comme le fera l'appelant.
    @Test("Utilisable derrière son protocole")
    func usableThroughItsProtocol() async throws {
        let service: any CalculationWidgetServing = CalculationWidgetService(
            aiProvider: MockAIGenerating(response: #"{"expression": "6*7"}"#)
        )
        let result = try #require(await service.computeCalculation(forQuery: "6 fois 7", chatHistory: []))
        #expect(result.data.formattedResult == "42")
    }
}
