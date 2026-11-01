//
//  SuggestionsServiceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 19/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Provider IA factice, même principe que `MockAIGenerating` dans
/// `QueryClassifierTests.swift` et `SearchOrchestratorTests.swift` : classe
/// simple (pas un acteur personnalisé) pour hériter de l'isolation par
/// défaut du projet et satisfaire `AIGenerating` sans conflit d'isolation.
/// Peut aussi être configurée pour `throw`, afin de tester le repli "liste
/// vide, jamais propagée" de `SuggestionsService.generateSuggestions`.
private final class MockAIGenerating: AIGenerating {
    enum Failure: Error, Sendable {
        case boom
    }

    private(set) var receivedPrompts: [String] = []
    private let response: String
    private let shouldThrow: Bool

    init(response: String = "", shouldThrow: Bool = false) {
        self.response = response
        self.shouldThrow = shouldThrow
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        if shouldThrow {
            throw Failure.boom
        }
        return response
    }
}

@MainActor
@Suite("SuggestionsService")
struct SuggestionsServiceTests {
    // MARK: - parse : formes de sortie acceptées

    @Test("JSON pur, objet enveloppe {\"suggestions\": [...]}")
    func parseEnvelopeObject() {
        let raw = """
        {"suggestions": ["Comment ça marche ?", "Quels sont les risques ?", "Où en savoir plus ?"]}
        """

        let result = SuggestionsService.parse(raw)

        #expect(result == ["Comment ça marche ?", "Quels sont les risques ?", "Où en savoir plus ?"])
    }

    @Test("JSON pur, tableau nu")
    func parseBareArray() {
        let raw = """
        ["Première question", "Deuxième question"]
        """

        let result = SuggestionsService.parse(raw)

        #expect(result == ["Première question", "Deuxième question"])
    }

    @Test("Bloc de code markdown ```json autour de l'objet enveloppe")
    func parseFencedMarkdownBlock() {
        let raw = """
        Voici les suggestions :
        ```json
        {"suggestions": ["Question A", "Question B"]}
        ```
        """

        let result = SuggestionsService.parse(raw)

        #expect(result == ["Question A", "Question B"])
    }

    @Test("Bloc de code markdown sans langage déclaré")
    func parseFencedBlockWithoutLanguageTag() {
        let raw = """
        ```
        ["Question A", "Question B"]
        ```
        """

        let result = SuggestionsService.parse(raw)

        #expect(result == ["Question A", "Question B"])
    }

    @Test("Liste à puces en texte brut, format '-'")
    func parseBulletListDash() {
        let raw = """
        - Quelle est la capitale de la France ?
        - Quelle est sa population ?
        - Quand a-t-elle été fondée ?
        """

        let result = SuggestionsService.parse(raw)

        #expect(result == [
            "Quelle est la capitale de la France ?",
            "Quelle est sa population ?",
            "Quand a-t-elle été fondée ?",
        ])
    }

    @Test("Liste à puces en texte brut, format '•'")
    func parseBulletListDot() {
        let raw = "• Une question\n• Une autre question"

        let result = SuggestionsService.parse(raw)

        #expect(result == ["Une question", "Une autre question"])
    }

    @Test("Liste numérotée en texte brut, format 'N.'")
    func parseNumberedListDot() {
        let raw = """
        1. Comment fonctionne la photosynthèse ?
        2. Quelles plantes en dépendent le plus ?
        3. Peut-on la reproduire artificiellement ?
        """

        let result = SuggestionsService.parse(raw)

        #expect(result == [
            "Comment fonctionne la photosynthèse ?",
            "Quelles plantes en dépendent le plus ?",
            "Peut-on la reproduire artificiellement ?",
        ])
    }

    @Test("Liste numérotée en texte brut, format 'N)'")
    func parseNumberedListParenthesis() {
        let raw = "1) Première question\n2) Deuxième question"

        let result = SuggestionsService.parse(raw)

        #expect(result == ["Première question", "Deuxième question"])
    }

    // MARK: - parse : cas limites

    @Test("Sortie vide -> liste vide")
    func parseEmptyOutput() {
        #expect(SuggestionsService.parse("") == [])
        #expect(SuggestionsService.parse("   \n  \n") == [])
    }

    @Test("Sortie absurde (prose sans JSON ni puces) -> repli sûr, jamais de crash")
    func parseNonsenseOutput() {
        let raw = "Le chat mange une pomme pendant que la lune brille sur l'océan Pacifique tranquillement ce soir-là."

        // Aucune assertion sur le contenu exact : le seul contrat est que ça
        // ne throw jamais et respecte toujours la borne de longueur.
        let result = SuggestionsService.parse(raw)

        #expect(result.allSatisfy { $0.count <= 160 })
    }

    @Test("JSON structurellement invalide (accolade non fermée) -> repli sur le découpage en texte brut")
    func parseMalformedJSONFallsBackToPlainText() {
        let raw = """
        {"suggestions": ["Question incomplète
        - Vraie question de secours un
        - Vraie question de secours deux
        """

        let result = SuggestionsService.parse(raw)

        #expect(result.contains("Vraie question de secours un"))
        #expect(result.contains("Vraie question de secours deux"))
    }

    // MARK: - sanitize : nettoyage

    @Test("Retrait des puces et numéros résiduels à l'intérieur d'éléments déjà décodés")
    func sanitizeStripsResidualMarkers() {
        let result = SuggestionsService.sanitize(["1. Une question", "- Une autre question", "• Encore une"])

        #expect(result == ["Une question", "Une autre question", "Encore une"])
    }

    @Test("Retrait des guillemets englobants (droits, simples, chevrons)")
    func sanitizeStripsWrappingQuotes() {
        let result = SuggestionsService.sanitize([
            "\"Une question entre guillemets ?\"",
            "'Une autre, guillemets simples ?'",
            "«Une troisième, chevrons ?»",
        ])

        #expect(result == [
            "Une question entre guillemets ?",
            "Une autre, guillemets simples ?",
            "Une troisième, chevrons ?",
        ])
    }

    @Test("Ne retire pas des guillemets internes qui ne encadrent pas toute la chaîne")
    func sanitizePreservesInternalQuotes() {
        let result = SuggestionsService.sanitize(["Que veut dire \"photosynthèse\" exactement ?"])

        #expect(result == ["Que veut dire \"photosynthèse\" exactement ?"])
    }

    @Test("Déduplication insensible à la casse, garde la première occurrence")
    func sanitizeDeduplicatesCaseInsensitively() {
        let result = SuggestionsService.sanitize([
            "Comment ça marche ?",
            "COMMENT ÇA MARCHE ?",
            "Comment ça marche ?",
            "Une question différente ?",
        ])

        #expect(result == ["Comment ça marche ?", "Une question différente ?"])
    }

    @Test("Exclut les suggestions vides ou réduites à du blanc")
    func sanitizeExcludesEmptySuggestions() {
        let result = SuggestionsService.sanitize(["", "   ", "Une vraie question ?"])

        #expect(result == ["Une vraie question ?"])
    }

    @Test("Exclut les suggestions dépassant la longueur maximale")
    func sanitizeExcludesOverlyLongSuggestions() {
        let shortEnough = String(repeating: "a", count: 160)
        let tooLong = String(repeating: "b", count: 161)

        let result = SuggestionsService.sanitize([shortEnough, tooLong], maxLength: 160)

        #expect(result == [shortEnough])
    }

    @Test("Borne le nombre de suggestions renvoyées")
    func sanitizeCapsCount() {
        let candidates = (1...10).map { "Question numéro \($0) ?" }

        let result = SuggestionsService.sanitize(candidates, maxCount: 5)

        #expect(result.count == 5)
        #expect(result == candidates.prefix(5).map { $0 })
    }

    // MARK: - buildPrompt : troncature d'historique

    @Test("Tronque l'historique aux N derniers messages")
    func buildPromptTruncatesHistory() {
        let history = (1...12).map { index in
            ClassifierChatMessage(role: index.isMultiple(of: 2) ? .assistant : .user, content: "Message \(index)")
        }

        let prompt = SuggestionsService.buildPrompt(chatHistory: history, maxHistoryMessages: 4)

        #expect(prompt.contains("Message 9"))
        #expect(prompt.contains("Message 12"))
        #expect(!prompt.contains("Message 8"))
        #expect(!prompt.contains("Message 1\n"))
    }

    @Test("maxHistoryMessages négatif ne fait pas trapper suffix(_:)")
    func buildPromptToleratesNegativeMaxHistoryMessages() {
        let history = [ClassifierChatMessage(role: .user, content: "Bonjour")]

        let prompt = SuggestionsService.buildPrompt(chatHistory: history, maxHistoryMessages: -1)

        #expect(prompt.contains("<conversation_history>"))
    }

    // MARK: - generateSuggestions : intégration avec le provider

    @Test("Provider en succès : renvoie les suggestions parsées et envoie un prompt non vide")
    func generateSuggestionsSuccess() async {
        let mock = MockAIGenerating(response: "{\"suggestions\": [\"Question un ?\", \"Question deux ?\"]}")
        let service = SuggestionsService(aiProvider: mock)

        let result = await service.generateSuggestions(chatHistory: [
            ClassifierChatMessage(role: .user, content: "Parle-moi de la photosynthèse"),
            ClassifierChatMessage(role: .assistant, content: "La photosynthèse est..."),
        ])

        #expect(result == ["Question un ?", "Question deux ?"])
        #expect(mock.receivedPrompts.count == 1)
        #expect(mock.receivedPrompts[0].contains("photosynthèse"))
    }

    @Test("Provider qui throw : renvoie une liste vide, ne propage jamais l'erreur")
    func generateSuggestionsProviderThrows() async {
        let mock = MockAIGenerating(shouldThrow: true)
        let service = SuggestionsService(aiProvider: mock)

        let result = await service.generateSuggestions(chatHistory: [
            ClassifierChatMessage(role: .user, content: "Une question quelconque"),
        ])

        #expect(result == [])
    }

    @Test("Respecte les bornes personnalisées passées à l'init")
    func generateSuggestionsRespectsCustomBounds() async {
        let suggestions = (1...10).map { "Question \($0) ?" }
        let json = try! JSONEncoder().encode(["suggestions": suggestions])
        let mock = MockAIGenerating(response: String(data: json, encoding: .utf8)!)
        let service = SuggestionsService(aiProvider: mock, maxSuggestionCount: 3)

        let result = await service.generateSuggestions(chatHistory: [
            ClassifierChatMessage(role: .user, content: "Une question"),
        ])

        #expect(result.count == 3)
    }
}
