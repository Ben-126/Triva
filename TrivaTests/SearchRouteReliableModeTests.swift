//
//  SearchRouteReliableModeTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Mission E2a, trou 3 (décision de Ben, 2026-11-12) : « En Fiable, TOUJOURS chercher, sauf
/// salutation et calcul. » `SearchRoute.resolve` ne laisse plus le classifieur dispenser un
/// tour de recherche en Fiable ; Rapide et Approfondie gardent leur comportement.
@Suite("SearchRoute — recherche forcée en mode Fiable (mission E2a)")
struct SearchRouteReliableModeTests {
    private static let realQuestion = "Quelle est la hauteur de la tour Eiffel ?"

    private static func route(
        _ classification: QueryClassification,
        mode: ResponseMode,
        query: String = realQuestion,
        hasAttachments: Bool = false
    ) -> SearchRoute {
        SearchRoute.resolve(for: classification, hasAttachments: hasAttachments, mode: mode, query: query)
    }

    @Test("Vraie question classée « sans recherche » : recherche forcée en Fiable SEULEMENT")
    func realQuestionMisclassifiedAsSkipSearchSearchesInReliableOnly() {
        let skipped = SearchOrchestratorTests.classification(skip: true)

        #expect(Self.route(skipped, mode: .reliable) == .web(.general))
        #expect(Self.route(skipped, mode: .quick) == .none)
        #expect(Self.route(skipped, mode: .deep) == .none)
    }

    @Test("Salutation et politesse : aucune recherche en Fiable, comme dans les autres modes", arguments: [
        "Bonjour !", "Salut Triva", "Merci beaucoup", "Au revoir", "Ça va ?",
    ])
    func greetingsStayWithoutSearchInReliable(greeting: String) {
        let skipped = SearchOrchestratorTests.classification(skip: true)

        #expect(Self.route(skipped, mode: .reliable, query: greeting) == .none)
        #expect(Self.route(skipped, mode: .quick, query: greeting) == .none)
    }

    @Test("Une salutation suivie d'une vraie question n'est pas une salutation : recherche en Fiable")
    func greetingFollowedByQuestionSearchesInReliable() {
        let skipped = SearchOrchestratorTests.classification(skip: true)
        let query = "Bonjour, quelle est la hauteur de la tour Eiffel ?"

        #expect(Self.route(skipped, mode: .reliable, query: query) == .web(.general))
    }

    @Test("Calcul : le widget répond, aucune recherche en Fiable (le calcul seul, sans skipSearch, cherche déjà)")
    func calculationStaysWithoutSearchInReliable() {
        let calculation = SearchOrchestratorTests.classification(skip: true, calculation: true)
        let query = "Combien font 15 % de 240 ?"

        #expect(Self.route(calculation, mode: .reliable, query: query) == .none)
        #expect(Self.route(calculation, mode: .quick, query: query) == .none)
        // Sans skipSearch, le classifieur a jugé qu'une recherche s'ajoutait au widget : inchangé.
        let withSearch = SearchOrchestratorTests.classification(calculation: true)
        #expect(Self.route(withSearch, mode: .reliable, query: query) == .web(.general))
    }

    @Test("Météo : pas dans la liste des exceptions, la recherche web est forcée en Fiable (le widget tourne en parallèle)")
    func weatherSearchesInReliable() {
        let weather = SearchOrchestratorTests.classification(skip: true, weather: true)
        let query = "Quel temps à Lyon ?"

        #expect(Self.route(weather, mode: .reliable, query: query) == .web(.general))
        #expect(Self.route(weather, mode: .quick, query: query) == .webUnlessWeatherAnswered)
    }

    @Test("Famille de recherche respectée quand la recherche est forcée (académique, forums)")
    func forcedSearchKeepsTheSearchFlavor() {
        #expect(Self.route(SearchOrchestratorTests.classification(skip: true, academic: true), mode: .reliable) == .web(.academic))
        #expect(Self.route(SearchOrchestratorTests.classification(skip: true, discussion: true), mode: .reliable) == .web(.discussion))
        #expect(Self.route(SearchOrchestratorTests.classification(skip: true, academic: true), mode: .deep) == .none)
    }

    @Test("Fichiers joints : la route reste « fichiers joints seuls » en Fiable")
    func attachmentsRouteIsUnchangedInReliable() {
        let personal = SearchOrchestratorTests.classification(skip: true, personal: true)

        #expect(Self.route(personal, mode: .reliable, hasAttachments: true) == .attachments)
    }

    @Test("Modes sans skipSearch : la route ne dépend pas du mode")
    func modeIsIrrelevantWithoutSkipSearch() {
        let classifications = [
            SearchOrchestratorTests.classification(),
            SearchOrchestratorTests.classification(academic: true),
            SearchOrchestratorTests.classification(discussion: true),
            SearchOrchestratorTests.classification(skip: true, stock: true),
        ]
        for classification in classifications {
            let reference = Self.route(classification, mode: .quick)
            #expect(Self.route(classification, mode: .reliable) == reference)
            #expect(Self.route(classification, mode: .deep) == reference)
        }
    }

    @Test("Hors connexion, la route web forcée devient « aucune recherche » : le comportement hors ligne reste prioritaire")
    func offlineStillWinsOverForcedSearch() {
        let skipped = SearchOrchestratorTests.classification(skip: true)
        let forced = Self.route(skipped, mode: .reliable)

        #expect(forced == .web(.general))
        #expect(SearchOrchestrator.routeAvailable(forced, isOffline: true, hasAttachments: false) == .none)
        #expect(SearchOrchestrator.routeAvailable(forced, isOffline: true, hasAttachments: true) == .attachments)
    }
}

// MARK: - Câblage dans l'orchestrateur

extension SearchOrchestratorTests {
    private func searchCount(mode: ResponseMode, query: String, classifyResponse: String) async throws -> Int {
        let client = PipelineMockSearXNGClient()
        let provider = PipelineMockAIGenerating(classifyResponse: classifyResponse)
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: provider,
            responseMode: mode
        )
        _ = try await orchestrator.answer(query: query)
        return await client.callCount
    }

    @Test("E2a : le classifieur dit « sans recherche » pour une vraie question, Fiable cherche quand même, Rapide non")
    func reliableModeSearchesDespiteSkipSearch() async throws {
        let skipJSON = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "hauteur de la tour Eiffel")
        let question = "Quelle est la hauteur de la tour Eiffel ?"

        #expect(try await searchCount(mode: .reliable, query: question, classifyResponse: skipJSON) > 0)
        #expect(try await searchCount(mode: .quick, query: question, classifyResponse: skipJSON) == 0)
        #expect(try await searchCount(mode: .deep, query: question, classifyResponse: skipJSON) == 0)
    }

    @Test("E2a : salutation et calcul ne cherchent jamais, même en Fiable")
    func reliableModeDoesNotSearchForGreetingOrCalculation() async throws {
        let greetingJSON = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "bonjour")
        let calculationJSON = Self.classificationJSON(skipSearch: true, showCalculationWidget: true, standaloneFollowUp: "15 % de 240")

        #expect(try await searchCount(mode: .reliable, query: "Bonjour !", classifyResponse: greetingJSON) == 0)
        #expect(try await searchCount(mode: .reliable, query: "Combien font 15 % de 240 ?", classifyResponse: calculationJSON) == 0)
    }
}

extension SearchOrchestratorTests {
    @Test("E2a : une demande sur la conversation (« Traduis ta réponse ») cherche en Fiable, ne cherche pas en Rapide")
    func conversationRequestSearchesInReliableOnly() async throws {
        let skipJSON = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "Traduire en anglais la réponse sur Tim Cook")
        let query = "Traduis ta réponse en anglais"

        #expect(try await searchCount(mode: .reliable, query: query, classifyResponse: skipJSON) > 0)
        #expect(try await searchCount(mode: .quick, query: query, classifyResponse: skipJSON) == 0)
    }
}
