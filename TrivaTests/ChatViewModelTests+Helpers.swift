//
//  ChatViewModelTests+Helpers.swift
//  TrivaTests
//
//  Created by ben podrojsky on 07/09/2026.
//

import Testing
import Foundation
@testable import Triva

extension ChatViewModelTests {
    static let instance = URL(string: "https://searxng.example")!

    static func makeResult(title: String, url: String, content: String?) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title,
            url: url,
            content: content,
            imgSrc: nil,
            thumbnailSrc: nil,
            thumbnail: nil,
            author: nil,
            iframeSrc: nil
        )
    }

    static func response(_ results: [SearXNGSearchResult]) -> SearXNGSearchResponse {
        SearXNGSearchResponse(results: results, suggestions: [])
    }

    /// Hors de la liste des domaines fiables : le mode Fiable les filtre tous.
    static let untrustedResults = [
        makeResult(title: "Forum A", url: "https://a.example/fil", content: "Avis A"),
        makeResult(title: "Forum B", url: "https://b.example/fil", content: "Avis B"),
    ]

    /// ViewModel déterministe : mode et budget lus dans `settings`, pipeline
    /// réel mais sans modèle système ni réseau (`deterministicOrchestrator`),
    /// suggestions et médias enregistrés, persistance seulement si `stores`.
    func makeViewModel(
        resolveProvider: @escaping () async throws -> any AIGenerating,
        client: any SearXNGSearching = MockSearXNGClient(),
        settings: SendSettings = SendSettings(),
        stores: PersistenceStores? = nil,
        attachmentController: FileAttachmentController? = nil,
        widgets: [any SearchWidget] = [],
        factory: OrchestratorFactoryRecorder = OrchestratorFactoryRecorder(),
        suggestions: SuggestionsRecorder = SuggestionsRecorder(),
        media: RecordingMediaSearcher = RecordingMediaSearcher()
    ) -> ChatViewModel {
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        return ChatViewModel(
            resolveProvider: resolveProvider,
            resolveFailoverManager: { failoverManager },
            resolvePipelineConfiguration: { settings.configuration },
            readResponseMode: { settings.mode },
            historyStore: stores?.history,
            favoritesStore: stores?.favorites,
            attachmentController: attachmentController,
            makeOrchestrator: { inputs in
                factory.record(inputs)
                return Self.deterministicOrchestrator(inputs, widgets: widgets, media: media)
            },
            generateSuggestions: { provider, history in
                await suggestions.generate(provider, history)
            },
            makeMediaSearcher: { _ in media }
        )
    }

    /// Orchestrateur RÉEL (mode et budget reçus du ViewModel), rendu
    /// déterministe : classement qui garde l'ordre du moteur, aucun scrape
    /// réseau, widgets choisis par le test (`[]` : la liste de production
    /// appellerait le vrai service météo).
    static func deterministicOrchestrator(
        _ inputs: ChatViewModel.OrchestratorInputs,
        widgets: [any SearchWidget] = [],
        media: any MediaSearching = RecordingMediaSearcher()
    ) -> SearchOrchestrator {
        SearchOrchestrator(
            failoverManager: inputs.failoverManager,
            aiProvider: inputs.provider,
            responseMode: inputs.responseMode,
            configuration: inputs.configuration,
            scrapeService: FailingScrapeService(),
            sourceRanker: orderPreservingRanker(),
            widgets: widgets,
            mediaSearcher: media
        )
    }

    /// Poll coopératif jusqu'à ce que `condition` soit vraie : observe un
    /// état intermédiaire pendant qu'un envoi tourne dans une autre `Task`.
    /// Un timeout est un `Issue.record`, pas un échec silencieux plus loin.
    ///
    /// `Task.sleep` (1 ms), JAMAIS `Task.yield()` — bug du 2026-09-15 sur
    /// `cancellingDuringInFlightSearchIsNotReportedAsError` : sous
    /// `-default-isolation=MainActor`, `yield()` ne rend pas la main de façon
    /// fiable à la tâche productrice qui se dispute la même file MainActor
    /// (200 puis 2 000 tentatives épuisées en 20-30 ms sans progrès). Plafond
    /// à 2 000 (2 s, comme les tests de l'orchestrateur) et non plus 200 :
    /// sous charge (clones de simulateur en parallèle), 200 ms ne suffisaient
    /// pas toujours (risque 2 d'I1a-3).
    func waitUntil(
        _ timeoutMessage: String,
        maxAttempts: Int = 2_000,
        _ condition: @MainActor () async -> Bool
    ) async {
        for _ in 0..<maxAttempts {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timeout en attendant : \(timeoutMessage)")
    }

    func waitForContinuation(
        _ provider: ControllableStreamingAIGenerating
    ) async -> AsyncThrowingStream<String, Error>.Continuation? {
        await waitUntil("continuation assignée par streamGenerate") { provider.continuation != nil }
        return provider.continuation
    }


    /// Classement déterministe, sans modèle système : le vrai `SourceRanker`
    /// charge des embeddings `NaturalLanguage` à froid, cause probable de
    /// l'intermittence de `sourcesAttachedBeforeFirstChunk` (risque 2 d'I1a-3).
    static func orderPreservingRanker() -> SourceRanker {
        SourceRanker(
            relevanceScorer: ConstantSimilarityScorer(),
            duplicateScorer: NeverDuplicateScorer(),
            languageIdentifier: UnknownLanguageIdentifier()
        )
    }

    // MARK: - Utilitaires

    /// Sortie de classification valide (format de `QueryClassifier.buildPrompt`).
    func classificationJSON(
        standaloneFollowUp: String,
        skipSearch: Bool = false,
        showCalculationWidget: Bool = false
    ) -> String {
        """
        {"classification": {"skipSearch": \(skipSearch), "personalSearch": false, "academicSearch": false, \
        "discussionSearch": false, "showWeatherWidget": false, "showStockWidget": false, \
        "showCalculationWidget": \(showCalculationWidget)}, "standaloneFollowUp": "\(standaloneFollowUp)"}
        """
    }

    /// Contenu de `<tag>…</tag>` dans un prompt, sans les blancs de bord ;
    /// `nil` si la balise manque (distinct d'un bloc vide).
    func taggedBlock(_ tag: String, in prompt: String?) -> String? {
        guard let prompt,
              let start = prompt.range(of: "<\(tag)>")?.upperBound,
              let end = prompt.range(of: "</\(tag)>", range: start..<prompt.endIndex)?.lowerBound else { return nil }
        return String(prompt[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
