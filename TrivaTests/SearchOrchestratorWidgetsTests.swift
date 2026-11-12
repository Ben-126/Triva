//
//  SearchOrchestratorWidgetsTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Widgets et bug 15 (I1b) de `SearchOrchestratorTests`.

extension SearchOrchestratorTests {
    // MARK: - Widgets et bug 15 (I1b)

    /// Bug 15 — sur le code d'avant I1b, `primaryAction` valait
    /// `.calculationWidget` et `action(for:)` l'envoyait sur `WebSearchAction` :
    /// 1 appel SearXNG, un tour planner, et ce test levait (SearXNG en panne).
    @Test("Bug 15 : calcul pur (calcul + skipSearch) — aucun appel SearXNG ni planner, répond hors ligne, widget dans la réponse et le prompt")
    func pureCalculationNeverTouchesTheNetwork() async throws {
        let client = PipelineMockSearXNGClient(shouldFail: true)
        let log = WidgetCallLog()
        let calculationJSON = Self.classificationJSON(skipSearch: true, showCalculationWidget: true, standaloneFollowUp: "15 % de 240")
        let aiProvider = PipelineMockAIGenerating(classifyResponse: calculationJSON, finalAnswerResponse: "36")
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [StubSearchWidget(kind: .calculation, llmContext: "Résultat du calcul « 15% * 240 » : 36.", log: log)]
        )

        let result = try await orchestrator.answer(query: "Combien font 15 % de 240 ?")

        #expect(result.answer == "36")
        #expect(await client.callCount == 0)
        #expect(!aiProvider.receivedPrompts.contains { $0.contains("<planner_context>") })
        #expect(result.artifacts.widgets.map(\.kind) == [.calculation])
        #expect(result.artifacts.searchPerformed == false)
        #expect(result.artifacts.citableSourceCount == 0)
        #expect(result.sources.isEmpty)
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Aucune recherche web n'a été lancée"))
        #expect(finalPrompt.contains("<donnees_widgets>"))
        #expect(finalPrompt.contains("Résultat du calcul « 15% * 240 » : 36."))
        #expect(finalPrompt.hasSuffix("Combien font 15 % de 240 ?"))
    }

    @Test("Météo + skipSearch, widget abouti : aucune recherche web, la météo est dans la réponse et le prompt")
    func weatherAnsweredByWidgetSkipsSearch() async throws {
        let client = PipelineMockSearXNGClient()
        let log = WidgetCallLog()
        let weatherJSON = Self.classificationJSON(skipSearch: true, showWeatherWidget: true, standaloneFollowUp: "météo à Paris")
        let aiProvider = PipelineMockAIGenerating(classifyResponse: weatherJSON, finalAnswerResponse: "il fait beau")
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [StubSearchWidget(kind: .weather, llmContext: "Météo à Paris : 21 °C, ensoleillé.", log: log)]
        )

        let result = try await orchestrator.answer(query: "Quel temps fait-il à Paris ?")

        #expect(result.answer == "il fait beau")
        #expect(await client.callCount == 0)
        #expect(result.artifacts.widgets.map(\.kind) == [.weather])
        #expect(result.artifacts.searchPerformed == false)
        #expect(try #require(aiProvider.receivedPrompts.last).contains("Météo à Paris : 21 °C, ensoleillé."))
    }

    @Test("Météo + skipSearch, widget sans résultat (lieu introuvable, Open-Meteo injoignable) : repli sur UNE recherche web générale")
    func weatherWithoutWidgetResultFallsBackToWebSearch() async throws {
        let results = [Self.makeResult(title: "Météo Paris", url: "https://meteo.example", content: "21 °C")]
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let log = WidgetCallLog()
        let weatherJSON = Self.classificationJSON(skipSearch: true, showWeatherWidget: true, standaloneFollowUp: "météo à Paris")
        let aiProvider = PipelineMockAIGenerating(classifyResponse: weatherJSON)
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [StubSearchWidget(kind: .weather, llmContext: nil, log: log)]
        )

        let result = try await orchestrator.answer(query: "Quel temps fait-il à Paris ?")

        #expect(await log.executedKinds == [.weather])
        #expect(await client.callCount == 1)
        #expect(await client.receivedOptions == [SearXNGSearchOptions()])
        #expect(await client.receivedQueries == ["météo à Paris"])
        #expect(result.sources == results)
        #expect(result.artifacts.widgets.isEmpty)
        #expect(result.artifacts.searchPerformed)
    }

    @Test("Bourse + skipSearch : aucun widget bourse (hors champ), la recherche web reste lancée — donnée en direct")
    func stockWithSkipSearchStillSearchesTheWeb() async throws {
        let client = PipelineMockSearXNGClient()
        let stockJSON = Self.classificationJSON(skipSearch: true, showStockWidget: true, standaloneFollowUp: "cours de l'action Apple")
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: PipelineMockAIGenerating(classifyResponse: stockJSON)
        )

        _ = try await orchestrator.answer(query: "Combien vaut l'action Apple ?")

        #expect(await client.callCount == 1)
        #expect(await client.receivedOptions == [SearXNGSearchOptions()])
    }

    @Test("Météo sans skipSearch : recherche web ET widget, la météo s'ajoute aux sources dans le prompt")
    func weatherWithSearchRunsWidgetAndSearch() async throws {
        let results = [Self.makeResult(title: "Canicule", url: "https://actu.example", content: "Alerte canicule")]
        let client = PipelineMockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let log = WidgetCallLog()
        let weatherJSON = Self.classificationJSON(showWeatherWidget: true, standaloneFollowUp: "canicule à Paris")
        let aiProvider = PipelineMockAIGenerating(classifyResponse: weatherJSON)
        let orchestrator = makePipelineOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [StubSearchWidget(kind: .weather, llmContext: "Météo à Paris : 38 °C.", log: log)]
        )

        let result = try await orchestrator.answer(query: "La canicule à Paris va-t-elle durer ?")

        #expect(await client.callCount == 1)
        #expect(result.sources == results)
        #expect(result.artifacts.widgets.map(\.kind) == [.weather])
        let finalPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(finalPrompt.contains("Alerte canicule"))
        #expect(finalPrompt.contains("Météo à Paris : 38 °C."))
    }

    /// Les VRAIS adaptateurs de production, branchés sur des services
    /// factices : la classification seule décide quel service est appelé.
    @Test("Aucun appel inutile : sans demande de la classification, ni extraction de lieu ni extraction d'expression")
    func widgetsRunOnlyWhenClassificationAsks() async throws {
        let counter = ServiceCallCounter()
        let widgets: [any SearchWidget] = [
            WeatherSearchWidget(service: CountingWeatherService(counter: counter)),
            CalculationSearchWidget(service: CountingCalculationService(counter: counter)),
        ]
        let failoverManager = FailoverManager(client: PipelineMockSearXNGClient(), instances: [Self.instance])

        let plain = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: PipelineMockAIGenerating(), widgets: widgets)
        let plainResult = try await plain.answer(query: "Qui a écrit Germinal ?")
        #expect(await counter.weatherCalls == 0)
        #expect(await counter.calculationCalls == 0)
        #expect(plainResult.artifacts.widgets.isEmpty)

        let calculationJSON = Self.classificationJSON(skipSearch: true, showCalculationWidget: true, standaloneFollowUp: "15 % de 240")
        let calculation = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: PipelineMockAIGenerating(classifyResponse: calculationJSON), widgets: widgets)
        let calculationResult = try await calculation.answer(query: "Combien font 15 % de 240 ?")
        #expect(await counter.weatherCalls == 0)
        #expect(await counter.calculationCalls == 1)
        let data = try #require(calculationResult.artifacts.widgets.first?.calculationData)
        #expect(data.result == 36)
        #expect(calculationResult.artifacts.widgets.first?.weatherData == nil)
    }

    @Test("Liste de production : météo puis calcul, chacun sur son seul drapeau de classification")
    func productionWidgetListIsWeatherThenCalculation() {
        let widgets = SearchOrchestrator.defaultWidgets(aiProvider: PipelineMockAIGenerating())
        let weatherOnly = QueryClassification(
            skipSearch: true, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: true, showStockWidget: false, showCalculationWidget: false, standaloneFollowUp: "météo"
        )
        let calculationOnly = QueryClassification(
            skipSearch: true, personalSearch: false, academicSearch: false, discussionSearch: false,
            showWeatherWidget: false, showStockWidget: true, showCalculationWidget: true, standaloneFollowUp: "calcul"
        )

        #expect(widgets.map(\.kind) == [.weather, .calculation])
        #expect(widgets.map { $0.shouldExecute(for: weatherOnly) } == [true, false])
        #expect(widgets.map { $0.shouldExecute(for: calculationOnly) } == [false, true])
    }

    @Test("Classification personalSearch SANS fichier joint : retombe sur une recherche web classique, sans crash")
    func personalSearchFallsBackToWebSearch() async throws {
        let client = PipelineMockSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let personalJSON = Self.classificationJSON(personalSearch: true, standaloneFollowUp: "résume mon document")
        let aiProvider = PipelineMockAIGenerating(classifyResponse: personalJSON)
        let orchestrator = makePipelineOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        _ = try await orchestrator.answer(query: "résume le document que j'ai importé")

        let callCount = await client.callCount
        #expect(callCount == 1)
        let receivedOptions = await client.receivedOptions
        #expect(receivedOptions.first == SearXNGSearchOptions())
    }
}
