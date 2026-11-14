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

    @Test("Calcul : le widget répond d'abord ; en Fiable, s'il ne produit rien, la recherche prend le relais (K2)")
    func calculationAnswersFirstInReliable() {
        let calculation = SearchOrchestratorTests.classification(skip: true, calculation: true)
        let query = "Combien font 15 % de 240 ?"

        #expect(Self.route(calculation, mode: .reliable, query: query) == .webUnlessCalculationAnswered)
        #expect(Self.route(calculation, mode: .quick, query: query) == .none)
        #expect(Self.route(calculation, mode: .deep, query: query) == .none)
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
    private func searchCount(
        mode: ResponseMode,
        query: String,
        classifyResponse: String,
        widgets: [any SearchWidget] = []
    ) async throws -> Int {
        let client = PipelineMockSearXNGClient()
        let provider = PipelineMockAIGenerating(classifyResponse: classifyResponse)
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: provider,
            responseMode: mode,
            widgets: widgets
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

    @Test("E2a : une salutation ne cherche jamais, même en Fiable")
    func reliableModeDoesNotSearchForGreeting() async throws {
        let greetingJSON = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "bonjour")

        #expect(try await searchCount(mode: .reliable, query: "Bonjour !", classifyResponse: greetingJSON) == 0)
    }
}

extension SearchOrchestratorTests {
    @Test("C1 K1 : « Traduis ta réponse » classée sans recherche SANS textTask : Fiable cherche (doute), Rapide non")
    func conversationRequestWithoutTextTaskSearchesInReliableOnly() async throws {
        let skipJSON = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "Traduire en anglais la réponse sur Tim Cook")
        let query = "Traduis ta réponse en anglais"

        #expect(try await searchCount(mode: .reliable, query: query, classifyResponse: skipJSON) > 0)
        #expect(try await searchCount(mode: .quick, query: query, classifyResponse: skipJSON) == 0)
    }

    @Test("C1 K1 : « Traduis ta réponse » (skipSearch ET textTask) ne cherche jamais, Fiable compris")
    func conversationRequestWithTextTaskNeverSearches() async throws {
        let json = Self.classificationJSON(skipSearch: true, textTask: true, standaloneFollowUp: "Traduire en anglais la réponse sur Tim Cook")
        let query = "Traduis ta réponse en anglais"

        #expect(try await searchCount(mode: .reliable, query: query, classifyResponse: json) == 0)
        #expect(try await searchCount(mode: .quick, query: query, classifyResponse: json) == 0)
    }

    @Test("C1 K1 : une vraie question marquée textTask SANS skipSearch cherche toujours, Fiable compris")
    func textTaskAloneDoesNotSkipTheSearch() async throws {
        let json = Self.classificationJSON(textTask: true, standaloneFollowUp: "hauteur de la tour Eiffel")
        let question = "Quelle est la hauteur de la tour Eiffel ?"

        #expect(try await searchCount(mode: .reliable, query: question, classifyResponse: json) > 0)
    }
}

extension SearchOrchestratorTests {
    private static let calculationJSON = classificationJSON(
        skipSearch: true, showCalculationWidget: true, standaloneFollowUp: "15 % de 240"
    )
    private static let calculationQuery = "Combien de jours avant Noël ?"

    @Test("C1 K2 : calcul dont le widget ne produit rien, Fiable cherche (il répondrait de mémoire sinon) ; Rapide non")
    func reliableCalculationWithoutWidgetOutputSearches() async throws {
        let silent = StubSearchWidget(kind: .calculation, llmContext: nil, log: WidgetCallLog())

        #expect(try await searchCount(mode: .reliable, query: Self.calculationQuery, classifyResponse: Self.calculationJSON, widgets: [silent]) > 0)
        #expect(try await searchCount(mode: .quick, query: Self.calculationQuery, classifyResponse: Self.calculationJSON, widgets: [silent]) == 0)
        #expect(try await searchCount(mode: .deep, query: Self.calculationQuery, classifyResponse: Self.calculationJSON, widgets: [silent]) == 0)
    }

    @Test("C1 K2 : calcul dont le widget répond, aucune recherche, Fiable compris")
    func reliableCalculationAnsweredByTheWidgetDoesNotSearch() async throws {
        let answering = StubSearchWidget(kind: .calculation, llmContext: "Résultat : 36", log: WidgetCallLog())

        #expect(try await searchCount(mode: .reliable, query: "Combien font 15 % de 240 ?", classifyResponse: Self.calculationJSON, widgets: [answering]) == 0)
    }

    @Test("C1 K2 : hors connexion, la route de repli du calcul devient « aucune recherche » (fichiers joints gardés)")
    func offlineReducesTheCalculationFallbackRoute() {
        #expect(SearchOrchestrator.routeAvailable(.webUnlessCalculationAnswered, isOffline: true, hasAttachments: false) == .none)
        #expect(SearchOrchestrator.routeAvailable(.webUnlessCalculationAnswered, isOffline: true, hasAttachments: true) == .attachments)
        #expect(SearchOrchestrator.routeAvailable(.webUnlessCalculationAnswered, isOffline: false, hasAttachments: false) == .webUnlessCalculationAnswered)
    }

    @Test("C1 K2 : widgetAwaitedBeforeSearching ne vise que les deux routes « web sauf widget abouti »")
    func awaitedWidgetKinds() {
        #expect(SearchOrchestrator.widgetAwaitedBeforeSearching(.webUnlessWeatherAnswered) == .weather)
        #expect(SearchOrchestrator.widgetAwaitedBeforeSearching(.webUnlessCalculationAnswered) == .calculation)
        #expect(SearchOrchestrator.widgetAwaitedBeforeSearching(.web(.general)) == nil)
        #expect(SearchOrchestrator.widgetAwaitedBeforeSearching(.attachments) == nil)
        #expect(SearchOrchestrator.widgetAwaitedBeforeSearching(SearchRoute.none) == nil)
    }
}

@Suite("SearchRoute — travail sur du texte en mode Fiable (mission C1, K1)")
struct SearchRouteTextTaskTests {
    private static func route(_ classification: QueryClassification, mode: ResponseMode, query: String = "Écris un poème sur la mer") -> SearchRoute {
        SearchRoute.resolve(for: classification, hasAttachments: false, mode: mode, query: query)
    }

    @Test("skipSearch ET textTask : aucune recherche dans tous les modes")
    func textTaskSkipsTheSearchInEveryMode() {
        let writing = SearchOrchestratorTests.classification(skip: true, textTask: true)

        for mode in ResponseMode.allCases {
            #expect(Self.route(writing, mode: mode) == .none)
        }
    }

    @Test("skipSearch seul (pas de textTask) : Fiable cherche, les autres modes non (en cas de doute, Fiable cherche)")
    func skipSearchAloneStillSearchesInReliable() {
        let doubtful = SearchOrchestratorTests.classification(skip: true)

        #expect(Self.route(doubtful, mode: .reliable) == .web(.general))
        #expect(Self.route(doubtful, mode: .quick) == .none)
    }

    @Test("textTask seul (sans skipSearch) : jamais de dispense, quel que soit le mode")
    func textTaskWithoutSkipSearchSearches() {
        let inconsistent = SearchOrchestratorTests.classification(textTask: true)

        for mode in ResponseMode.allCases {
            #expect(Self.route(inconsistent, mode: mode) == .web(.general))
        }
    }

    @Test("Écriture sur la météo (« poème sur la pluie à Lyon ») : aucune recherche en Fiable malgré le drapeau météo")
    func textTaskBeatsTheWeatherFlagInReliable() {
        let poem = SearchOrchestratorTests.classification(skip: true, weather: true, textTask: true)

        #expect(Self.route(poem, mode: .reliable) == .none)
        #expect(Self.route(poem, mode: .quick) == .webUnlessWeatherAnswered)
    }

    @Test("Cours de bourse marqué textTask : donnée en direct, la recherche web reste forcée")
    func stockWidgetStillSearches() {
        let stock = SearchOrchestratorTests.classification(skip: true, stock: true, textTask: true)

        #expect(Self.route(stock, mode: .reliable) == .web(.general))
    }

    @Test("Vraie question : recherche web en Fiable, même classée sans recherche et marquée textTask par erreur ET sans skipSearch")
    func realQuestionStillSearches() {
        let question = "Quelle est la hauteur de la tour Eiffel ?"

        #expect(Self.route(SearchOrchestratorTests.classification(skip: true), mode: .reliable, query: question) == .web(.general))
        #expect(Self.route(SearchOrchestratorTests.classification(textTask: true), mode: .reliable, query: question) == .web(.general))
    }
}
