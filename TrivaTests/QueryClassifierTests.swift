//
//  QueryClassifierTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 14/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Provider IA factice qui capture le prompt exact reçu, même principe que
/// `MockAIGenerating` dans `SearchOrchestratorTests.swift` : classe simple
/// (pas un acteur personnalisé) pour hériter de l'isolation par défaut du
/// projet et satisfaire `AIGenerating` sans conflit d'isolation.
private final class MockAIGenerating: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private let response: String

    init(response: String) {
        self.response = response
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        return response
    }
}

@Suite("QueryClassifier")
struct QueryClassifierTests {
    // MARK: - parse

    @Test("JSON bien formé : tous les champs présents sont repris exactement, plusieurs combinaisons de booléens")
    func parseWellFormedJSON() {
        let raw = """
        {
          "classification": {
            "skipSearch": false,
            "personalSearch": true,
            "academicSearch": false,
            "discussionSearch": true,
            "showWeatherWidget": false,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "Quels sont les avis sur ce produit ?"
        }
        """

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result == QueryClassification(
            skipSearch: false,
            personalSearch: true,
            academicSearch: false,
            discussionSearch: true,
            showWeatherWidget: false,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: "Quels sont les avis sur ce produit ?"
        ))
    }

    @Test("JSON bien formé, autre combinaison de booléens (tous à true)")
    func parseWellFormedJSONAllTrue() {
        let raw = """
        {
          "classification": {
            "skipSearch": true,
            "personalSearch": true,
            "academicSearch": true,
            "discussionSearch": true,
            "showWeatherWidget": true,
            "showStockWidget": true,
            "showCalculationWidget": true
          },
          "standaloneFollowUp": "reformulation"
        }
        """

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result == QueryClassification(
            skipSearch: true,
            personalSearch: true,
            academicSearch: true,
            discussionSearch: true,
            showWeatherWidget: true,
            showStockWidget: true,
            showCalculationWidget: true,
            standaloneFollowUp: "reformulation"
        ))
    }

    @Test("JSON entouré d'un bloc markdown ```json ... ``` avec du texte explicatif avant et après : extraction correcte")
    func parseFencedJSONBlockWithSurroundingText() {
        let raw = """
        Voici ma classification pour cette requête :
        ```json
        {
          "classification": {
            "skipSearch": true,
            "personalSearch": false,
            "academicSearch": false,
            "discussionSearch": false,
            "showWeatherWidget": true,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "Quel temps fait-il à Paris ?"
        }
        ```
        J'espère que cela répond à ta demande !
        """

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result == QueryClassification(
            skipSearch: true,
            personalSearch: false,
            academicSearch: false,
            discussionSearch: false,
            showWeatherWidget: true,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: "Quel temps fait-il à Paris ?"
        ))
    }

    @Test("Champs booléens manquants dans le JSON : ils retombent à false, le reste est correct")
    func parseWithMissingBooleanFields() {
        let raw = """
        {
          "classification": {
            "personalSearch": true,
            "showWeatherWidget": true
          },
          "standaloneFollowUp": "reformulation partielle"
        }
        """

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result == QueryClassification(
            skipSearch: false,
            personalSearch: true,
            academicSearch: false,
            discussionSearch: false,
            showWeatherWidget: true,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: "reformulation partielle"
        ))
    }

    @Test("Sortie totalement invalide (texte libre, pas de JSON) : repli sûr, tous les booléens à false, standaloneFollowUp = requête originale, primaryAction = webSearch")
    func parseInvalidOutputFallsBackSafely() {
        let raw = "Désolé, je ne peux pas classifier cette requête pour le moment."

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result == QueryClassification(
            skipSearch: false,
            personalSearch: false,
            academicSearch: false,
            discussionSearch: false,
            showWeatherWidget: false,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: "requête originale"
        ))
        #expect(result.primaryAction == .webSearch)
    }

    @Test("Texte libre contenant des accolades qui ne forment PAS un JSON valide : le décodeur échoue réellement, repli sûr (pas un test qui passe trivialement faute d'accolades)")
    func parseProseWithBracesButNoValidJSONFallsBackSafely() {
        let raw = "Impossible de classifier {voir la doc}."

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result == QueryClassification(
            skipSearch: false,
            personalSearch: false,
            academicSearch: false,
            discussionSearch: false,
            showWeatherWidget: false,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: "requête originale"
        ))
    }

    @Test("JSON tronqué (accolade fermante manquante) : repli sûr")
    func parseTruncatedJSONFallsBackSafely() {
        let raw = """
        {
          "classification": {
            "skipSearch": true,
        """

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result.standaloneFollowUp == "requête originale")
        #expect(result.primaryAction == .webSearch)
    }

    @Test("Chaîne vide : repli sûr")
    func parseEmptyStringFallsBackSafely() {
        let result = QueryClassifier.parse("", fallbackQuery: "requête originale")

        #expect(result.standaloneFollowUp == "requête originale")
        #expect(result.primaryAction == .webSearch)
    }

    @Test("JSON top-level qui n'est pas un objet (un tableau) : repli sûr")
    func parseTopLevelArrayFallsBackSafely() {
        let result = QueryClassifier.parse("[1, 2, 3]", fallbackQuery: "requête originale")

        #expect(result.standaloneFollowUp == "requête originale")
        #expect(result.primaryAction == .webSearch)
    }

    @Test("Clé classification totalement absente : repli sûr identique à une sortie invalide")
    func parseMissingClassificationKeyFallsBackSafely() {
        let raw = """
        {
          "standaloneFollowUp": "reformulation orpheline"
        }
        """

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result == QueryClassification(
            skipSearch: false,
            personalSearch: false,
            academicSearch: false,
            discussionSearch: false,
            showWeatherWidget: false,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: "requête originale"
        ))
    }

    @Test("classification de mauvais type (chaîne au lieu d'objet) : repli sûr complet")
    func parseClassificationWrongTypeFallsBackSafely() {
        let raw = """
        {
          "classification": "oui",
          "standaloneFollowUp": "reformulation"
        }
        """

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result.standaloneFollowUp == "requête originale")
        #expect(result.primaryAction == .webSearch)
    }

    @Test("Un champ booléen présent mais de mauvais type (chaîne au lieu de booléen) invalide TOUTE la classification — jamais de skipSearch=true conservé à côté d'un champ mal interprété")
    func parseFieldWrongTypeInvalidatesWholeClassification() {
        let raw = """
        {
          "classification": {
            "skipSearch": "oui",
            "personalSearch": true,
            "academicSearch": false,
            "discussionSearch": false,
            "showWeatherWidget": false,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "reformulation"
        }
        """

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result == QueryClassification(
            skipSearch: false,
            personalSearch: false,
            academicSearch: false,
            discussionSearch: false,
            showWeatherWidget: false,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: "requête originale"
        ))
        #expect(result.primaryAction == .webSearch)
    }

    @Test("Plusieurs blocs de code dans la sortie, le premier n'étant pas du JSON valide : le JSON valide du second bloc n'est pas perdu")
    func parseFallsThroughToSecondFencedBlockWhenFirstIsNotValidJSON() {
        let raw = """
        Voici mon raisonnement :
        ```text
        Requête météo simple.
        ```
        Classification :
        ```json
        {
          "classification": {
            "skipSearch": true,
            "personalSearch": false,
            "academicSearch": false,
            "discussionSearch": false,
            "showWeatherWidget": true,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "Quel temps fait-il à Lyon ?"
        }
        ```
        """

        let result = QueryClassifier.parse(raw, fallbackQuery: "requête originale")

        #expect(result.showWeatherWidget)
        #expect(result.standaloneFollowUp == "Quel temps fait-il à Lyon ?")
    }

    // MARK: - primaryAction

    @Test("showWeatherWidget et showStockWidget tous les deux true : le widget météo gagne (priorité la plus haute)")
    func primaryActionWeatherBeatsStock() {
        let classification = QueryClassification(
            skipSearch: false, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: true, showStockWidget: true, showCalculationWidget: false,
            standaloneFollowUp: ""
        )
        #expect(classification.primaryAction == .weatherWidget)
    }

    @Test("showStockWidget et showCalculationWidget tous les deux true : le widget bourse gagne")
    func primaryActionStockBeatsCalculation() {
        let classification = QueryClassification(
            skipSearch: true, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: false, showStockWidget: true, showCalculationWidget: true,
            standaloneFollowUp: ""
        )
        #expect(classification.primaryAction == .stockWidget)
    }

    @Test("showCalculationWidget seul et skipSearch true : le widget calcul gagne sur skip")
    func primaryActionCalculationBeatsSkip() {
        let classification = QueryClassification(
            skipSearch: true, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: false, showStockWidget: false, showCalculationWidget: true,
            standaloneFollowUp: ""
        )
        #expect(classification.primaryAction == .calculationWidget)
    }

    @Test("skipSearch seul à true, aucun widget : action .skip")
    func primaryActionSkipAlone() {
        let classification = QueryClassification(
            skipSearch: true, personalSearch: true, academicSearch: false, discussionSearch: false,
            showWeatherWidget: false, showStockWidget: false, showCalculationWidget: false,
            standaloneFollowUp: ""
        )
        #expect(classification.primaryAction == .skip)
    }

    @Test("personalSearch seul à true (rien d'autre) : action .personalSearch")
    func primaryActionPersonalSearchAlone() {
        let classification = QueryClassification(
            skipSearch: false, personalSearch: true, academicSearch: true, discussionSearch: true,
            showWeatherWidget: false, showStockWidget: false, showCalculationWidget: false,
            standaloneFollowUp: ""
        )
        #expect(classification.primaryAction == .personalSearch)
    }

    @Test("academicSearch à true (personalSearch false) : action .academicSearch")
    func primaryActionAcademicSearch() {
        let classification = QueryClassification(
            skipSearch: false, personalSearch: false, academicSearch: true, discussionSearch: true,
            showWeatherWidget: false, showStockWidget: false, showCalculationWidget: false,
            standaloneFollowUp: ""
        )
        #expect(classification.primaryAction == .academicSearch)
    }

    @Test("discussionSearch à true (rien d'autre avant) : action .discussionSearch")
    func primaryActionDiscussionSearch() {
        let classification = QueryClassification(
            skipSearch: false, personalSearch: false, academicSearch: false, discussionSearch: true,
            showWeatherWidget: false, showStockWidget: false, showCalculationWidget: false,
            standaloneFollowUp: ""
        )
        #expect(classification.primaryAction == .discussionSearch)
    }

    @Test("Aucun booléen à true : recherche web par défaut")
    func primaryActionDefaultsToWebSearch() {
        let classification = QueryClassification(
            skipSearch: false, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: false, showStockWidget: false, showCalculationWidget: false,
            standaloneFollowUp: ""
        )
        #expect(classification.primaryAction == .webSearch)
    }

    // MARK: - buildPrompt

    @Test("Le prompt contient la requête et l'historique formaté avec les bons préfixes AI:/User:")
    func buildPromptContainsQueryAndFormattedHistory() {
        let history = [
            ClassifierChatMessage(role: .user, content: "Salut"),
            ClassifierChatMessage(role: .assistant, content: "Bonjour, comment puis-je t'aider ?"),
        ]

        let prompt = QueryClassifier.buildPrompt(query: "Quelle est la capitale de la France ?", chatHistory: history, maxHistoryMessages: 8)

        #expect(prompt.contains("Quelle est la capitale de la France ?"))
        #expect(prompt.contains("User: Salut"))
        #expect(prompt.contains("AI: Bonjour, comment puis-je t'aider ?"))
    }

    @Test("Avec maxHistoryMessages: 2 et un historique de 5 messages, seuls les 2 derniers sont conservés")
    func buildPromptTruncatesHistoryToMaxHistoryMessages() {
        let history = [
            ClassifierChatMessage(role: .user, content: "Message 1"),
            ClassifierChatMessage(role: .assistant, content: "Message 2"),
            ClassifierChatMessage(role: .user, content: "Message 3"),
            ClassifierChatMessage(role: .assistant, content: "Message 4"),
            ClassifierChatMessage(role: .user, content: "Message 5"),
        ]

        let prompt = QueryClassifier.buildPrompt(query: "requête", chatHistory: history, maxHistoryMessages: 2)

        #expect(!prompt.contains("Message 1"))
        #expect(!prompt.contains("Message 2"))
        #expect(!prompt.contains("Message 3"))
        #expect(prompt.contains("AI: Message 4"))
        #expect(prompt.contains("User: Message 5"))
    }

    @Test("Historique vide : le prompt reste valide, avec des balises <conversation_history> vides")
    func buildPromptWithEmptyHistory() {
        let prompt = QueryClassifier.buildPrompt(query: "requête", chatHistory: [], maxHistoryMessages: 8)

        #expect(prompt.contains("requête"))
        #expect(prompt.contains("<conversation_history>"))
        #expect(prompt.contains("</conversation_history>"))
    }

    @Test("maxHistoryMessages: 0 avec un historique non vide : aucun message d'historique conservé")
    func buildPromptWithZeroMaxHistoryMessages() {
        let history = [
            ClassifierChatMessage(role: .user, content: "Message 1"),
            ClassifierChatMessage(role: .assistant, content: "Message 2"),
        ]

        let prompt = QueryClassifier.buildPrompt(query: "requête", chatHistory: history, maxHistoryMessages: 0)

        #expect(!prompt.contains("Message 1"))
        #expect(!prompt.contains("Message 2"))
    }

    @Test("maxHistoryMessages négatif : ne plante pas (suffix protégé par max(0, ...)), traité comme 0")
    func buildPromptWithNegativeMaxHistoryMessagesDoesNotCrash() {
        let history = [ClassifierChatMessage(role: .user, content: "Message 1")]

        let prompt = QueryClassifier.buildPrompt(query: "requête", chatHistory: history, maxHistoryMessages: -1)

        #expect(!prompt.contains("Message 1"))
    }

    @Test("promptComplexity: .concise utilise le prompt court, pas le prompt détaillé")
    func buildPromptUsesConcisePromptWhenRequested() {
        let fullPrompt = QueryClassifier.buildPrompt(query: "requête", chatHistory: [], maxHistoryMessages: 8, promptComplexity: .full)
        let concisePrompt = QueryClassifier.buildPrompt(query: "requête", chatHistory: [], maxHistoryMessages: 8, promptComplexity: .concise)

        #expect(fullPrompt.contains("<labels>"))
        #expect(!concisePrompt.contains("<labels>"))
        #expect(concisePrompt.contains("\"skipSearch\""))
    }

    // MARK: - classify (bout-en-bout)

    @Test("classify envoie un prompt contenant la requête au provider, et retourne la classification correspondant à sa réponse")
    func classifyEndToEnd() async throws {
        let mockResponse = """
        {
          "classification": {
            "skipSearch": false,
            "personalSearch": false,
            "academicSearch": true,
            "discussionSearch": false,
            "showWeatherWidget": false,
            "showStockWidget": false,
            "showCalculationWidget": false
          },
          "standaloneFollowUp": "Quelles sont les dernières recherches sur la fusion nucléaire ?"
        }
        """
        let aiProvider = MockAIGenerating(response: mockResponse)
        let classifier = QueryClassifier(aiProvider: aiProvider)

        let result = try await classifier.classify(query: "Quelles sont les dernières recherches sur la fusion nucléaire ?")

        #expect(result == QueryClassification(
            skipSearch: false,
            personalSearch: false,
            academicSearch: true,
            discussionSearch: false,
            showWeatherWidget: false,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: "Quelles sont les dernières recherches sur la fusion nucléaire ?"
        ))

        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.count == 1)
        let prompt = try #require(prompts.first)
        #expect(prompt.contains("Quelles sont les dernières recherches sur la fusion nucléaire ?"))
    }
}
