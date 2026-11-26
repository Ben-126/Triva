//
//  SearchOrchestratorAgenticWidgetTests.swift
//  TrivaTests
//
//  F3 (26/11), spec 2.4 §7.2 témoins 19 et 20 : l'enquêteur n'est JAMAIS appelé quand un widget (météo, calcul) a
//  répondu. Le classifieur d'Apple Intelligence demande souvent une recherche web EN PLUS du widget (route `.web`, le
//  widget tourne en parallèle) : avant ce correctif, l'enquêteur cherchait alors 15 à 30 s pour rien.
//

import Testing
import Foundation
@testable import Triva

@MainActor
@Suite("SearchOrchestrator : enquêteur et widgets (F3)")
struct SearchOrchestratorAgenticWidgetTests {
    static let agentQuery = "requête de l'enquêteur"

    private func routedClient() -> QueryRoutedSearXNGClient {
        QueryRoutedSearXNGClient(seededResults: agenticSeededResults(), agentQuery: Self.agentQuery, agentResults: agenticFoundResults())
    }

    private func orchestrator(
        weather: Bool = false,
        calculation: Bool = false,
        widget: StubSearchWidget?,
        mode: ResponseMode = .deep,
        researcher: StubAgenticResearcher,
        client: QueryRoutedSearXNGClient
    ) -> SearchOrchestrator {
        let json = SearchOrchestratorTests.classificationJSON(
            showWeatherWidget: weather, showCalculationWidget: calculation, standaloneFollowUp: "question test"
        )
        return makeAgenticOrchestrator(
            client: client,
            aiProvider: PipelineMockAIGenerating(classifyResponse: json, finalAnswerResponse: "réponse"),
            responseMode: mode,
            researcher: researcher,
            widgets: widget.map { [$0] } ?? []
        )
    }

    @Test("Météo : le widget a répondu (et la classification veut aussi le web) : enquêteur jamais appelé, chemin .classic")
    func weatherAnsweredSkipsInvestigator() async throws {
        let log = WidgetCallLog()
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [4]))
        let client = routedClient()
        let sut = orchestrator(
            weather: true, widget: StubSearchWidget(kind: .weather, llmContext: "Lyon : 14 °C.", log: log),
            researcher: researcher, client: client
        )

        let result = try await sut.answer(query: "Quel temps fait-il à Lyon aujourd'hui ?")

        #expect(researcher.requests.isEmpty)
        #expect(result.artifacts.researchPath == .classic)
        #expect(result.artifacts.widgets.map(\.kind) == [.weather])
        #expect(await log.executedKinds == [.weather])
        // La recherche web de la boucle actuelle a bien eu lieu, une seule fois, sans la recherche de l'enquêteur.
        #expect(await client.receivedQueries.count == 1)
        #expect(result.artifacts.searchPerformed)
    }

    @Test("Calcul : le widget a répondu : enquêteur jamais appelé, chemin .classic")
    func calculationAnsweredSkipsInvestigator() async throws {
        let log = WidgetCallLog()
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [4]))
        let sut = orchestrator(
            calculation: true, widget: StubSearchWidget(kind: .calculation, llmContext: "17 % de 240 = 40,8.", log: log),
            researcher: researcher, client: routedClient()
        )

        let result = try await sut.answer(query: "Combien font 17 % de 240 ?")

        #expect(researcher.requests.isEmpty)
        #expect(result.artifacts.researchPath == .classic)
        #expect(result.artifacts.widgets.map(\.kind) == [.calculation])
    }

    @Test("Widget éligible mais sans résultat (lieu introuvable) : l'enquêteur est appelé, comme avant")
    func widgetWithoutOutputStillInvestigates() async throws {
        let log = WidgetCallLog()
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [4]))
        let sut = orchestrator(
            weather: true, widget: StubSearchWidget(kind: .weather, llmContext: nil, log: log),
            researcher: researcher, client: routedClient()
        )

        let result = try await sut.answer(query: "Quel temps fait-il à Lyon ?")

        #expect(researcher.requests.count == 1)
        #expect(result.artifacts.researchPath == .agentic)
        #expect(result.artifacts.widgets.isEmpty)
        #expect(await log.executedKinds == [.weather])
    }

    @Test("Aucun widget demandé par la classification : l'enquêteur tourne, le widget n'est même pas lancé")
    func noWidgetRequestedStillInvestigates() async throws {
        let log = WidgetCallLog()
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [4]))
        let sut = orchestrator(
            widget: StubSearchWidget(kind: .weather, llmContext: "inutile", log: log), researcher: researcher, client: routedClient()
        )

        let result = try await sut.answer(query: "question test")

        #expect(researcher.requests.count == 1)
        #expect(result.artifacts.researchPath == .agentic)
        #expect(await log.executedKinds.isEmpty)
    }

    @Test("Mode Rapide avec widget abouti : chemin d'avant, enquêteur jamais appelé")
    func quickModeWithWidgetIsUnchanged() async throws {
        let log = WidgetCallLog()
        let researcher = StubAgenticResearcher(.searchAndRead(query: Self.agentQuery, reads: [4]))
        let sut = orchestrator(
            weather: true, widget: StubSearchWidget(kind: .weather, llmContext: "Lyon : 14 °C.", log: log),
            mode: .quick, researcher: researcher, client: routedClient()
        )

        let result = try await sut.answer(query: "Quel temps fait-il à Lyon ?")

        #expect(researcher.requests.isEmpty)
        #expect(result.artifacts.researchPath == .classic)
        #expect(result.artifacts.widgets.map(\.kind) == [.weather])
    }

    @Test("Sans enquêteur : widgets et recherche en parallèle, comme avant")
    func noResearcherKeepsParallelism() async throws {
        let log = WidgetCallLog()
        let json = SearchOrchestratorTests.classificationJSON(showWeatherWidget: true, standaloneFollowUp: "question test")
        let client = routedClient()
        let sut = makeAgenticOrchestrator(
            client: client,
            aiProvider: PipelineMockAIGenerating(classifyResponse: json),
            researcher: nil,
            widgets: [StubSearchWidget(kind: .weather, llmContext: "Lyon : 14 °C.", log: log)]
        )

        let result = try await sut.answer(query: "Quel temps fait-il à Lyon ?")

        #expect(result.artifacts.researchPath == .classic)
        #expect(result.artifacts.widgets.map(\.kind) == [.weather])
        #expect(await client.receivedQueries.count == 1)
    }

    @Test("WidgetExecutor.hasEligibleWidget : même filtre que l'exécution (shouldExecute)")
    func eligibilityMatchesExecution() {
        let log = WidgetCallLog()
        let executor = WidgetExecutor(widgets: [StubSearchWidget(kind: .weather, llmContext: "x", log: log)])
        let weather = QueryClassification(
            skipSearch: false, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: true, showStockWidget: false, showCalculationWidget: false, standaloneFollowUp: "q"
        )
        let calculation = QueryClassification(
            skipSearch: false, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: false, showStockWidget: false, showCalculationWidget: true, standaloneFollowUp: "q"
        )
        #expect(executor.hasEligibleWidget(for: weather))
        #expect(!executor.hasEligibleWidget(for: calculation))
        #expect(!WidgetExecutor(widgets: []).hasEligibleWidget(for: weather))
    }
}
