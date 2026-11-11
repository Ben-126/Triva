//
//  ChatViewModelReliableModeTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 10/11/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Doublures (celles de `ChatViewModelTests.swift` sont privées à leur fichier)

private actor FixedResultsSearXNGClient: SearXNGSearching {
    private let results: [SearXNGSearchResult]

    init(_ results: [SearXNGSearchResult]) {
        self.results = results
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        SearXNGSearchResponse(results: results, suggestions: [])
    }
}

/// Flux d'instantanés CUMULATIFS fixes. `generate` sert à la classification
/// (`classification`, ou une sortie non JSON : repli sûr, recherche web) et au
/// planner (sortie non JSON : `done`).
private final class ScriptedStreamProvider: AIGenerating {
    private(set) var streamPrompts: [String] = []
    private let snapshots: [String]
    private let classification: String

    init(snapshots: [String], classification: String = "") {
        self.snapshots = snapshots
        self.classification = classification
    }

    func generate(prompt: String) async throws -> String {
        prompt.contains("<user_query>") ? classification : ""
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        streamPrompts.append(prompt)
        let snapshots = snapshots
        return AsyncThrowingStream { continuation in
            for snapshot in snapshots {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }
}

/// Flux piloté par le test, pour observer le fil ENTRE deux instantanés.
private final class ControlledStreamProvider: AIGenerating {
    private(set) var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func generate(prompt: String) async throws -> String { "" }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }
}

private struct UnreadableScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

private struct ConstantSimilarity: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

private struct NoDuplicate: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

private struct NoLanguage: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

private struct FixedCalculationWidget: SearchWidget {
    let output: SearchWidgetOutput

    var kind: SearchWidgetKind { .calculation }

    func shouldExecute(for classification: QueryClassification) -> Bool {
        classification.showCalculationWidget
    }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        output
    }
}

// MARK: - Suite

/// Mission A1, décision de Ben : en mode Fiable, une réponse qui n'est que le
/// refus exact, ou qui ne cite aucune page lue, devient l'état
/// `.noReliableSources` — avec le bouton « Relancer en mode Rapide » — PAR LE
/// CODE (rapport T2, scénario t3 : le refus arrivait en texte, sans bouton).
/// Un widget abouti suspend ce contrôle : sa donnée est une source.
@MainActor
@Suite("ChatViewModel — mode Fiable, contrôle de la réponse (mission A1)")
struct ChatViewModelReliableModeTests {
    private static let trustedResults = [
        SearXNGSearchResult(
            title: "TypeScript — Wikipédia", url: "https://fr.wikipedia.org/wiki/TypeScript",
            content: "TypeScript est un sur-ensemble typé de JavaScript.",
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        ),
    ]

    private static let question = "Quelles sont les différences entre JavaScript et TypeScript ?"

    private static func stores() throws -> ChatHistoryStore {
        ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))
    }

    private func makeViewModel(
        provider: any AIGenerating,
        history: ChatHistoryStore? = nil,
        widgets: [any SearchWidget] = []
    ) -> ChatViewModel {
        let failoverManager = FailoverManager(
            client: FixedResultsSearXNGClient(Self.trustedResults),
            instances: [URL(string: "https://searxng.example")!]
        )
        return ChatViewModel(
            resolveProvider: { provider },
            resolveFailoverManager: { failoverManager },
            resolvePipelineConfiguration: { .cloud },
            readResponseMode: { .reliable },
            historyStore: history,
            makeOrchestrator: { inputs in
                SearchOrchestrator(
                    failoverManager: inputs.failoverManager,
                    aiProvider: inputs.provider,
                    responseMode: inputs.responseMode,
                    configuration: inputs.configuration,
                    scrapeService: UnreadableScrapeService(),
                    sourceRanker: SourceRanker(relevanceScorer: ConstantSimilarity(), duplicateScorer: NoDuplicate(), languageIdentifier: NoLanguage()),
                    widgets: widgets
                )
            },
            generateSuggestions: { _, _ in [] }
        )
    }

    /// Poll coopératif : `Task.sleep`, jamais `Task.yield()` (voir `waitUntil`
    /// de `ChatViewModelTests`, échecs intermittents sous l'isolation main actor).
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    /// L'état fixe, tel que la vue l'affiche : rien d'autre que le message.
    private func expectFixedState(_ viewModel: ChatViewModel, history: ChatHistoryStore) throws {
        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .noReliableSources)
        #expect(answer.text.isEmpty)
        #expect(answer.sources.isEmpty)
        #expect(answer.webSourceKind == nil)
        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.canRetryInQuickMode(answer))
        let conversation = try #require(try history.conversations().first)
        #expect(conversation.orderedMessages.map(\.role) == [.user, .assistant])
        #expect(conversation.orderedMessages.last?.reportsNoReliableSources == true)
        #expect(answer.storedMessageID == conversation.orderedMessages.last?.id)
    }

    /// Sans délai ni flux : la règle de la porte elle-même, que les deux tests de
    /// rétention plus bas n'observent qu'à travers un `Task.sleep`.
    @Test("Porte d'affichage : ouverte d'emblée hors contrôle ; en Fiable, fermée jusqu'à une page lue citée, puis ouverte pour de bon")
    func citedAnswerGateRules() {
        func artifacts(mode: ResponseMode, uncitable: Set<Int> = []) -> SearchArtifacts {
            SearchArtifacts(
                sources: Self.trustedResults, attachmentSourceCount: 0, widgets: [],
                images: .notRequested, videos: .notRequested, mode: mode, promptComplexity: .full,
                citableSourceCount: 1, searchPerformed: true, searchQuery: "q",
                uncitableSourceNumbers: uncitable
            )
        }

        // `admits` est `mutating` : résultats lus hors de `#expect`, qui capture
        // son expression dans une fermeture où la porte serait immuable.
        var quick = ChatViewModel.CitedAnswerGate(artifacts: artifacts(mode: .quick))
        let quickAdmitsUncited = quick.admits("Sans citation.")
        #expect(quickAdmitsUncited)

        var reliable = ChatViewModel.CitedAnswerGate(artifacts: artifacts(mode: .reliable))
        let startsOpen = reliable.isOpen
        let admitsStart = reliable.admits("TypeScript ajoute")
        let admitsUnclosedMarker = reliable.admits("TypeScript ajoute des types[1")
        let admitsCitation = reliable.admits("TypeScript ajoute des types[1].")
        let admitsFollowingText = reliable.admits("TypeScript ajoute des types[1]. Suite sans citation")
        #expect(!startsOpen)
        #expect(!admitsStart)
        #expect(!admitsUnclosedMarker)
        #expect(admitsCitation)
        #expect(admitsFollowingText)

        var unread = ChatViewModel.CitedAnswerGate(artifacts: artifacts(mode: .reliable, uncitable: [1]))
        let admitsUnreadCitation = unread.admits("Page jamais lue[1].")
        unread.open()
        let admitsAfterOpen = unread.admits("Texte final")
        #expect(!admitsUnreadCitation)
        #expect(admitsAfterOpen)
    }

    @Test("Refus exact en fin de flux : état « Aucune source fiable » avec relance, persisté tel quel, aucun texte")
    func exactRefusalEndsInTheFixedState() async throws {
        let history = try Self.stores()
        let provider = ScriptedStreamProvider(snapshots: ["Je n'ai pas", PromptTemplates.noRelevantInformationAnswer])
        let viewModel = makeViewModel(provider: provider, history: history)

        await viewModel.send(query: Self.question)

        #expect(provider.streamPrompts.count == 1)
        try expectFixedState(viewModel, history: history)
    }

    @Test("Réponse sans aucune citation d'une page lue : même état, jamais de texte non sourcé")
    func uncitedAnswerEndsInTheFixedState() async throws {
        let history = try Self.stores()
        let provider = ScriptedStreamProvider(snapshots: ["TypeScript ajoute des types statiques à JavaScript."])
        let viewModel = makeViewModel(provider: provider, history: history)

        await viewModel.send(query: Self.question)

        try expectFixedState(viewModel, history: history)
        #expect(ChatViewModel.classifierHistory(from: viewModel.messages).isEmpty)
    }

    @Test("Réponse qui cite une page lue : réponse normale, sources attachées, texte persisté")
    func citedAnswerIsKept() async throws {
        let history = try Self.stores()
        let text = "TypeScript est un sur-ensemble typé de JavaScript[1]."
        let viewModel = makeViewModel(provider: ScriptedStreamProvider(snapshots: [text]), history: history)

        await viewModel.send(query: Self.question)

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.text == text)
        #expect(answer.sources == Self.trustedResults)
        let conversation = try #require(try history.conversations().first)
        #expect(conversation.orderedMessages.map(\.text) == [Self.question, text])
    }

    @Test("Widget abouti + recherche web : une réponse sans citation n'est jamais refusée (la donnée du widget est une source)")
    func validWidgetIsNeverRefused() async throws {
        let data = CalculationWidgetData(expression: "1284 × 37", result: 47_508, formattedResult: "47 508")
        let widget = FixedCalculationWidget(output: SearchWidgetOutput(kind: .calculation, llmContext: "1284 × 37 = 47 508", payload: data))
        let classification = """
        {"classification": {"skipSearch": false, "personalSearch": false, "academicSearch": false, \
        "discussionSearch": false, "showWeatherWidget": false, "showStockWidget": false, \
        "showCalculationWidget": true}, "standaloneFollowUp": "1284 × 37"}
        """
        let provider = ScriptedStreamProvider(snapshots: ["Le résultat est 47 508."], classification: classification)
        let viewModel = makeViewModel(provider: provider, widgets: [widget])

        await viewModel.send(query: "Combien font 1284 × 37 ?")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.text == "Le résultat est 47 508.")
        #expect(answer.widgets == [.calculation(data)])
        // Le rappel Fiable du prompt est la variante « widgets », sans refus exact.
        let prompt = try #require(provider.streamPrompts.first)
        #expect(prompt.contains("Réponds à partir des données des widgets plus bas"))
    }

    @Test("Pendant le flux : texte et sources retenus jusqu'à la première citation d'une page lue, puis montrés ensemble")
    func textIsHeldBackUntilTheFirstCitation() async throws {
        let provider = ControlledStreamProvider()
        let viewModel = makeViewModel(provider: provider)
        let task = Task { await viewModel.send(query: Self.question) }

        #expect(await waitUntil { provider.continuation != nil })
        let continuation = try #require(provider.continuation)
        continuation.yield("TypeScript ajoute")
        try? await Task.sleep(for: .milliseconds(50))
        let held = try #require(viewModel.messages.last)
        #expect(held.status == .streaming)
        #expect(held.text.isEmpty)
        #expect(held.sources.isEmpty)

        continuation.yield("TypeScript ajoute des types[1].")
        #expect(await waitUntil { viewModel.messages.last?.text.isEmpty == false })
        #expect(viewModel.messages.last?.text == "TypeScript ajoute des types[1].")
        #expect(viewModel.messages.last?.sources == Self.trustedResults)

        continuation.finish()
        await task.value
        #expect(viewModel.messages.last?.status == .completed)
    }

    @Test("Stop pendant la rétention : rien n'a été montré, rien n'est persisté (pas de réponse non sourcée relue plus tard)")
    func stopDuringHoldBackShowsAndStoresNothing() async throws {
        let history = try Self.stores()
        let provider = ControlledStreamProvider()
        let viewModel = makeViewModel(provider: provider, history: history)
        let task = Task { await viewModel.send(query: Self.question) }

        #expect(await waitUntil { provider.continuation != nil })
        provider.continuation?.yield("Réponse encore sans citation")
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .interrupted)
        #expect(answer.text.isEmpty)
        #expect(answer.sources.isEmpty)
        let conversation = try #require(try history.conversations().first)
        #expect(conversation.orderedMessages.map(\.role) == [.user])
    }
}
