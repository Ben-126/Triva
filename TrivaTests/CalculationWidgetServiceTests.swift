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
