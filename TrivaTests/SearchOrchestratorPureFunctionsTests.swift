//
//  SearchOrchestratorPureFunctionsTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Routage, prompt des widgets, suggestions, planner (I1b) — fonctions pures

extension SearchOrchestratorTests {
    /// `nonisolated` : appelée depuis les arguments d'un test paramétré,
    /// évalués hors du main actor.
    nonisolated static func classification(
        skip: Bool = false,
        personal: Bool = false,
        academic: Bool = false,
        discussion: Bool = false,
        weather: Bool = false,
        stock: Bool = false,
        calculation: Bool = false
    ) -> QueryClassification {
        QueryClassification(
            skipSearch: skip,
            personalSearch: personal,
            academicSearch: academic,
            discussionSearch: discussion,
            showWeatherWidget: weather,
            showStockWidget: stock,
            showCalculationWidget: calculation,
            standaloneFollowUp: "question"
        )
    }

    /// Les lignes « calcul + skip » et « météo + skip » sont celles du bug
    /// 15 : `primaryAction` les résumait en widget, l'ancien `action(for:)` en
    /// recherche web.
    @Test("SearchRoute.resolve : la classification COMPLÈTE décide, pas primaryAction", arguments: [
        (classification(), false, SearchRoute.web(.general)),
        (classification(skip: true), false, SearchRoute.none),
        (classification(skip: true, calculation: true), false, SearchRoute.none),
        (classification(calculation: true), false, SearchRoute.web(.general)),
        (classification(skip: true, weather: true), false, SearchRoute.webUnlessWeatherAnswered),
        (classification(skip: true, weather: true, calculation: true), false, SearchRoute.webUnlessWeatherAnswered),
        (classification(weather: true), false, SearchRoute.web(.general)),
        (classification(skip: true, stock: true), false, SearchRoute.web(.general)),
        (classification(academic: true), false, SearchRoute.web(.academic)),
        (classification(discussion: true), false, SearchRoute.web(.discussion)),
        (classification(skip: true, academic: true), false, SearchRoute.none),
        (classification(personal: true), false, SearchRoute.web(.general)),
        (classification(personal: true), true, SearchRoute.attachments),
        (classification(skip: true, personal: true), true, SearchRoute.attachments),
        (classification(academic: true), true, SearchRoute.web(.academic)),
    ])
    func routeFollowsTheFullClassification(classification: QueryClassification, hasAttachments: Bool, expected: SearchRoute) {
        #expect(SearchRoute.resolve(for: classification, hasAttachments: hasAttachments) == expected)
    }

    @Test("Widgets dans le prompt : juste avant le bloc de la question, après la date, dans les QUATRE gabarits", arguments: [
        (true, WriterPromptComplexity.full),
        (true, WriterPromptComplexity.concise),
        (false, WriterPromptComplexity.full),
        (false, WriterPromptComplexity.concise),
    ])
    func widgetContextSitsRightBeforeTheQuestion(searchPerformed: Bool, complexity: WriterPromptComplexity) throws {
        let query = "Ligne 1 de la question\n\nLigne 2 de la question"
        let prompt = SearchOrchestrator.buildPrompt(
            query: query,
            standaloneQuery: "Question reformulée autonome",
            sources: [Self.makeResult(title: "Titre", url: "https://a.example", content: "Extrait")],
            mode: .deep,
            complexity: complexity,
            searchPerformed: searchPerformed,
            widgetContext: "Résultat du calcul « 2 + 2 » : 4."
        )

        let block = try #require(prompt.range(of: "<donnees_widgets>"))
        let dateLine = try #require(prompt.range(of: "(UTC", options: .backwards))
        let reformulation = try #require(prompt.range(of: "Question reformulée d'après la conversation", options: .backwards))
        #expect(dateLine.upperBound < block.lowerBound)
        #expect(block.upperBound < reformulation.lowerBound)
        #expect(prompt.components(separatedBy: "<donnees_widgets>").count == 2)
        #expect(prompt.contains(SearchOrchestrator.widgetContextInstruction))
        #expect(prompt.contains("Résultat du calcul « 2 + 2 » : 4.\n</donnees_widgets>\n\nQuestion reformulée"))
        #expect(prompt.hasSuffix(query))
    }

    @Test("Widgets dans le prompt : contexte vide -> prompt inchangé ; gabarit sans la question en fin -> bloc ajouté à la fin, jamais perdu")
    func widgetContextEdgeCases() {
        let prompt = "Consignes.\n\nQuestion : combien ?"

        #expect(SearchOrchestrator.insertingWidgetContext("  \n ", into: prompt, query: "combien ?") == prompt)
        let fallback = SearchOrchestrator.insertingWidgetContext("Donnée.", into: prompt, query: "autre question")
        #expect(fallback.hasPrefix(prompt + "\n\n<donnees_widgets>"))
        #expect(fallback.hasSuffix("Donnée.\n</donnees_widgets>"))
    }

    @Test("suggestionsHistory : tours précédents, question, puis la réponse telle que lue — sans <think> ni <tldr>")
    func suggestionsHistoryStripsReasoningBlocks() {
        let orchestrator = makePipelineOrchestrator(failoverManager: FailoverManager(client: PipelineMockSearXNGClient(), instances: [Self.instance]), aiProvider: PipelineMockAIGenerating())
        let previous = [
            ClassifierChatMessage(role: .user, content: "Q1"),
            ClassifierChatMessage(role: .assistant, content: "R1"),
        ]

        let history = orchestrator.suggestionsHistory(
            previousTurns: previous,
            query: "Q2",
            answer: "<think>Je pèse les sources.</think>\n<tldr>Résumé en une phrase.</tldr>\n\nCorps de la réponse[1]."
        )

        #expect(history.map(\.content) == ["Q1", "R1", "Q2", "Corps de la réponse[1]."])
        #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test("suggestionsHistory : bornée comme l'historique du classifieur (préréglage Apple Intelligence : 4 messages de 600 caractères)")
    func suggestionsHistoryIsBounded() {
        let orchestrator = SearchOrchestrator(
            failoverManager: FailoverManager(client: PipelineMockSearXNGClient(), instances: [Self.instance]),
            aiProvider: PipelineMockAIGenerating(),
            configuration: .appleIntelligence,
            widgets: []
        )
        let previous = (1...3).flatMap { turn in
            [ClassifierChatMessage(role: .user, content: "Q\(turn)"), ClassifierChatMessage(role: .assistant, content: "R\(turn)")]
        }
        let longAnswer = String(repeating: "La photosynthèse produit du glucose. ", count: 40)

        let history = orchestrator.suggestionsHistory(previousTurns: previous, query: "Q4", answer: longAnswer)

        #expect(history.count == 4)
        #expect(history.map(\.content).prefix(3) == ["Q3", "R3", "Q4"])
        let answer = history.last?.content ?? ""
        #expect(answer.hasSuffix("[…]"))
        #expect(answer.count <= 600 + " […]".count)
    }

    @Test("plannerActionNames : seulement les actions qui ont encore un objet, done toujours ; sans fichier joint, exactement l'ancienne liste")
    func plannerActionNamesFollowWhatIsLeft() {
        #expect(SearchOrchestrator.plannerActionNames(canScrape: true, canSearchUploads: false) == ["scrapeURL", "done"])
        #expect(SearchOrchestrator.plannerActionNames(canScrape: true, canSearchUploads: true) == ["scrapeURL", "uploadsSearch", "done"])
        #expect(SearchOrchestrator.plannerActionNames(canScrape: false, canSearchUploads: true) == ["uploadsSearch", "done"])
        #expect(SearchOrchestrator.plannerActionNames(canScrape: false, canSearchUploads: false) == ["done"])
    }

    @Test("plannerPrompt : uploadsSearch et son champ queries n'apparaissent qu'avec des fichiers joints ; sinon le texte d'avant 1.11")
    func plannerPromptOffersUploadsSearchOnlyWhenAvailable() {
        let sources = [Self.makeResult(title: "T", url: "https://a.example", content: nil)]

        let withoutUploads = SearchOrchestrator.plannerPrompt(
            query: "q", displayedSources: sources, availableActionNames: ["scrapeURL", "done"], iteration: 2, maxIterations: 3
        )
        let withUploads = SearchOrchestrator.plannerPrompt(
            query: "q", displayedSources: sources, availableActionNames: ["scrapeURL", "uploadsSearch", "done"], iteration: 2, maxIterations: 3
        )
        // Toutes les sources déjà tentées : il ne reste que les fichiers joints.
        let uploadsOnly = SearchOrchestrator.plannerPrompt(
            query: "q", displayedSources: sources, availableActionNames: ["uploadsSearch", "done"], iteration: 3, maxIterations: 3
        )

        #expect(!withoutUploads.contains("uploadsSearch"))
        #expect(!withoutUploads.contains("\"queries\""))
        #expect(withoutUploads.contains("\"action\": \"scrapeURL\" ou \"done\",\n  \"urls\": [\"url1\", \"url2\"]\n}"))
        #expect(withUploads.contains("- \"uploadsSearch\" : cherche dans les fichiers joints"))
        #expect(withUploads.contains("\"action\": \"scrapeURL\", \"uploadsSearch\" ou \"done\",\n  \"urls\": [\"url1\", \"url2\"],\n  \"queries\": [\"requête 1\"]\n}"))
        #expect(uploadsOnly.contains("\"action\": \"uploadsSearch\" ou \"done\",\n  \"queries\": [\"requête 1\"]\n}"))
        #expect(!uploadsOnly.contains("\"urls\""))
        #expect(!uploadsOnly.contains("- \"scrapeURL\""))
    }

    @Test("decideNextAction : lit les requêtes de uploadsSearch ; absentes, liste vide")
    func decideNextActionReadsQueries() {
        let uploads = SearchOrchestrator.decideNextAction(rawOutput: #"{"action":"uploadsSearch","queries":["clause de résiliation","préavis"]}"#)
        let scrape = SearchOrchestrator.decideNextAction(rawOutput: #"{"action":"scrapeURL","urls":["https://a.example"]}"#)

        #expect(uploads == PlannerDecision(actionName: "uploadsSearch", urls: [], queries: ["clause de résiliation", "préavis"]))
        #expect(scrape == PlannerDecision(actionName: "scrapeURL", urls: ["https://a.example"]))
    }
}
