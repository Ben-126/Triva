//
//  SearchOrchestratorStreamingTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 07/09/2026.
//

import Testing
import Foundation
@testable import Triva

private enum MockError: Error, Sendable, Equatable {
    case searchFailed
    case midStreamFailure
}

/// Même principe que `MockSearXNGClient` de `SearchOrchestratorTests.swift`,
/// dupliqué ici (`private` est scopé au fichier) : renvoie une réponse fixe,
/// ou lève une erreur si configuré pour échouer. `receivedQueries` (bug 1)
/// prouve QUELLE requête atteint SearXNG : la reformulation, pas la question
/// brute d'un suivi.
private actor MockSearXNGClient: SearXNGSearching {
    private let response: SearXNGSearchResponse
    private let shouldFail: Bool
    private(set) var receivedQueries: [String] = []

    init(response: SearXNGSearchResponse = SearXNGSearchResponse(results: [], suggestions: []), shouldFail: Bool = false) {
        self.response = response
        self.shouldFail = shouldFail
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        receivedQueries.append(query)
        if shouldFail {
            throw MockError.searchFailed
        }
        return response
    }
}

/// Provider IA factice qui streame une suite de morceaux de texte fixe, avec
/// une erreur optionnelle en fin de flux (pour simuler un échec survenant
/// PENDANT le streaming, après un ou plusieurs yields).
///
/// Depuis 1.2, `SearchOrchestrator` appelle `generate(prompt:)` pour la
/// classification ET pour chaque tour planner (JAMAIS pour la génération
/// finale, qui passe exclusivement par `streamGenerate(prompt:)`) : les deux
/// méthodes enregistrent donc leurs prompts dans des tableaux SÉPARÉS —
/// mélanger les deux dans un seul tableau rendrait `receivedPrompts.first`
/// ambigu (tantôt le prompt de classification, tantôt celui du planner,
/// selon le chemin emprunté) là où seul `receivedStreamPrompts` représente
/// sans ambiguïté LE prompt de génération finale envoyé au flux. Les chunks
/// fixes ne sont jamais du JSON valide : classification et planner retombent
/// systématiquement sur leur repli sûr respectif (`.webSearch` / "done"),
/// donc le comportement observable du pipeline reste inchangé par ce
/// branchement — seul le suivi des prompts est plus précis qu'avant 1.2.
///
/// `plannerResponse` (1.13) : réponse renvoyée à CHAQUE tour planner
/// (prompt contenant `<planner_context>`), pour compter les tours qu'un mode
/// autorise — un planner qui ne dit jamais "done" ne s'arrête qu'à la borne.
/// `classifyResponse` (bug 1) : sortie du classifieur (prompt contenant
/// `<user_query>`), pour imposer une reformulation ou `.skip`.
/// `classificationError` / `plannerError` (bug 3) : erreur levée par ces
/// étapes auxiliaires, pour distinguer repli (échec) et propagation
/// (annulation).
private final class MockStreamingAIGenerating: AIGenerating {
    private(set) var receivedGeneratePrompts: [String] = []
    private(set) var receivedStreamPrompts: [String] = []
    private let chunks: [String]
    private let midStreamFailure: (any Error)?
    private let plannerResponse: String?
    private let classifyResponse: String?
    private let classificationError: (any Error)?
    private let plannerError: (any Error)?

    init(
        chunks: [String] = ["chunk"],
        midStreamFailure: (any Error)? = nil,
        plannerResponse: String? = nil,
        classifyResponse: String? = nil,
        classificationError: (any Error)? = nil,
        plannerError: (any Error)? = nil
    ) {
        self.chunks = chunks
        self.midStreamFailure = midStreamFailure
        self.plannerResponse = plannerResponse
        self.classifyResponse = classifyResponse
        self.classificationError = classificationError
        self.plannerError = plannerError
    }

    var plannerPromptCount: Int {
        receivedGeneratePrompts.filter { $0.contains("<planner_context>") }.count
    }

    func generate(prompt: String) async throws -> String {
        receivedGeneratePrompts.append(prompt)
        if prompt.contains("<user_query>") {
            if let classificationError { throw classificationError }
            if let classifyResponse { return classifyResponse }
        }
        if prompt.contains("<planner_context>") {
            if let plannerError { throw plannerError }
            if let plannerResponse { return plannerResponse }
        }
        return chunks.joined()
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        receivedStreamPrompts.append(prompt)
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            if let midStreamFailure {
                continuation.finish(throwing: midStreamFailure)
            } else {
                continuation.finish()
            }
        }
    }
}

/// Scraping factice : aucun test ne touche le réseau.
private struct MockScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "Titre scrapé", content: "Contenu scrapé pour \(url)", succeeded: true)
    }
}

/// Journal des URLs réellement demandées au scraping (bugs 8 et 11) : un
/// acteur, car les scrapes d'un tour tournent en parallèle (`TaskGroup`).
private actor ScrapeLog {
    private(set) var urls: [String] = []

    func record(_ url: String) {
        urls.append(url)
    }
}

/// Scraping factice qui journalise chaque URL. `suspendsUntilCancelled`
/// (bug 3) : le scrape reste suspendu jusqu'à l'annulation de la tâche,
/// comme une page lente au moment où l'utilisateur touche Stop — puis rend
/// une page en échec, exactement comme `ScrapeService` (qui ne lève jamais).
private struct RecordingScrapeService: ScrapeServing {
    let log: ScrapeLog
    var suspendsUntilCancelled = false

    func scrape(url: String) async -> ScrapedPage {
        await log.record(url)
        if suspendsUntilCancelled {
            try? await Task.sleep(for: .seconds(10))
        }
        return ScrapedPage(url: url, title: "Titre scrapé", content: "Contenu scrapé pour \(url)", succeeded: !Task.isCancelled)
    }
}

/// Borne d'un tour de scrape : les `slowURLs` ne finissent jamais d'elles-
/// mêmes (30 s), seule l'annulation les arrête — journalisée — puis elles
/// rendent quand même une page « réussie » tardive, qui doit être ignorée.
private struct SlowScrapeService: ScrapeServing {
    let slowURLs: Set<String>
    let cancellations: ScrapeLog

    func scrape(url: String) async -> ScrapedPage {
        guard slowURLs.contains(url) else {
            return ScrapedPage(url: url, title: "Titre scrapé", content: "Contenu scrapé pour \(url)", succeeded: true)
        }
        try? await Task.sleep(for: .seconds(30))
        if Task.isCancelled { await cancellations.record(url) }
        return ScrapedPage(url: url, title: "Titre tardif", content: "Contenu tardif pour \(url)", succeeded: true)
    }
}

/// Lu par une fonction SYNCHRONE : `Thread.isMainThread` est indisponible en
/// contexte async en Swift 6, une fonction synchrone répond pour son appelant.
private func isRunningOnMainThread() -> Bool {
    Thread.isMainThread
}

/// Lectures de `ThreadProbeClock.now` : `@unchecked Sendable` + `NSLock`,
/// même principe que `FetchJournal` (`ScrapeServiceFetchTests`).
private final class ThreadJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [Bool] = []

    var mainThreadReadings: [Bool] {
        lock.withLock { readings }
    }

    func record(onMainThread: Bool) {
        lock.withLock { readings.append(onMainThread) }
    }
}

/// Horloge réelle qui note sur quel thread `now` est lu. `scrapeAll` le lit
/// sur l'exécuteur de l'orchestrateur : c'est la sonde du `@concurrent`.
private struct ThreadProbeClock: Clock {
    let journal: ThreadJournal
    private let base = ContinuousClock()

    init(journal: ThreadJournal) {
        self.journal = journal
    }

    var now: ContinuousClock.Instant {
        journal.record(onMainThread: isRunningOnMainThread())
        return base.now
    }

    var minimumResolution: Duration {
        base.minimumResolution
    }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}

/// Attente coopérative bornée : `Task.sleep`, JAMAIS `Task.yield()` — avec
/// l'isolation main actor, `yield()` ne garantit pas que l'autre tâche
/// progresse (piège documenté, voir `waitUntil` de ChatViewModelTests).
@MainActor
private func waitUntil(_ timeoutMessage: String, maxAttempts: Int = 2_000, _ condition: () async -> Bool) async {
    for _ in 0..<maxAttempts {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timeout en attendant : \(timeoutMessage)")
}

/// Similarité constante : le classement retombe sur la seule position du
/// moteur, l'ordre de sortie est donc l'ordre d'entrée.
private struct ConstantSimilarityScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

/// Aucun quasi-doublon : le vrai scorer lexical fusionnerait des extraits
/// de test qui ne diffèrent que d'un caractère (« Contenu 1 » / « Contenu 2 »).
private struct NeverDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

/// Aucune langue reconnue : un seul groupe, pas de fusion par langue.
private struct UnknownLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

/// Même convention que `makeOrchestrator` de `SearchOrchestratorTests.swift`
/// (dupliqué, `private` étant scopé au fichier) : mode Approfondi par défaut
/// — les valeurs historiques que vérifient les tests d'avant 1.13 —,
/// classement qui conserve l'ordre du moteur, scraping factice.
@MainActor
private func makeOrchestrator(
    failoverManager: FailoverManager,
    aiProvider: any AIGenerating,
    responseMode: ResponseMode = .deep,
    scrapeService: any ScrapeServing = MockScrapeService(),
    maxResultsUsedForContext: Int = 5,
    maxIterations: Int = 3,
    maxHistoryMessages: Int = PromptTemplates.defaultMaxHistoryMessages,
    maxHistoryMessageCharacters: Int = PromptTemplates.defaultMaxHistoryMessageCharacters,
    scrapeRoundTimeout: Duration = SearchOrchestrator.defaultScrapeRoundTimeout,
    clock: any Clock<Duration> = ContinuousClock(),
    widgets: [any SearchWidget] = [],
    mediaSearcher: (any MediaSearching)? = nil,
    mediaGracePeriod: Duration = SearchOrchestrator.defaultMediaGracePeriod
) -> SearchOrchestrator {
    // `widgets: []` par défaut : la liste de production lancerait le vrai
    // service météo (réseau) sur une classification météo.
    SearchOrchestrator(
        failoverManager: failoverManager,
        aiProvider: aiProvider,
        responseMode: responseMode,
        scrapeService: scrapeService,
        sourceRanker: orderPreservingRanker(),
        maxResultsUsedForContext: maxResultsUsedForContext,
        maxIterations: maxIterations,
        maxHistoryMessages: maxHistoryMessages,
        maxHistoryMessageCharacters: maxHistoryMessageCharacters,
        scrapeRoundTimeout: scrapeRoundTimeout,
        clock: clock,
        widgets: widgets,
        mediaSearcher: mediaSearcher,
        mediaGracePeriod: mediaGracePeriod
    )
}

// MARK: - Médias et widgets factices (I1b)

/// Point de rendez-vous de deux tâches : chacune signale son arrivée puis
/// attend l'autre. Si elles tournaient EN SÉRIE, la première attendrait en
/// vain (borne de 2 s) : la seule preuve de parallélisme qui ne dépende pas
/// d'une mesure de durée.
private actor Rendezvous {
    private var arrived: Set<String> = []
    private(set) var sawPartner: [String: Bool] = [:]

    func arrive(_ name: String) {
        arrived.insert(name)
    }

    func hasArrived(_ name: String) -> Bool {
        arrived.contains(name)
    }

    func record(_ name: String, sawPartner value: Bool) {
        sawPartner[name] = value
    }

    /// Arrive sous `name`, attend `partner` au plus ~2 s, et note s'il est venu.
    func meet(_ name: String, partner: String) async {
        arrive(name)
        var met = false
        for _ in 0..<2_000 where !met {
            met = hasArrived(partner)
            if !met { try? await Task.sleep(for: .milliseconds(1)) }
        }
        record(name, sawPartner: met)
    }
}

/// Client SearXNG qui rejoint le rendez-vous « texte » avant de répondre.
private actor RendezvousSearXNGClient: SearXNGSearching {
    private let response: SearXNGSearchResponse
    private let rendezvous: Rendezvous

    init(response: SearXNGSearchResponse, rendezvous: Rendezvous) {
        self.response = response
        self.rendezvous = rendezvous
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        await rendezvous.meet("texte", partner: "médias")
        return response
    }
}

/// Client SearXNG qui note les options et requêtes reçues.
private actor OptionsRecordingSearXNGClient: SearXNGSearching {
    private let response: SearXNGSearchResponse
    private(set) var receivedOptions: [SearXNGSearchOptions] = []
    private(set) var receivedQueries: [String] = []

    init(response: SearXNGSearchResponse) {
        self.response = response
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        receivedOptions.append(options)
        receivedQueries.append(query)
        return response
    }
}

/// Journal des recherches média reçues (type et requête).
private actor MediaCallLog {
    private(set) var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }
}

private enum MediaStubError: Error, Sendable {
    case unavailable
}

/// Recherche média factice, sans réseau.
private struct StubMediaSearcher: MediaSearching {
    enum Behavior: Sendable {
        case results
        case failure
        case sleep(Duration)
        case rendezvous(Rendezvous)
    }

    let images: [ImageSearchResult]
    let videos: [VideoSearchResult]
    let behavior: Behavior
    let log: MediaCallLog

    func searchImages(query: String) async throws -> [ImageSearchResult] {
        await log.record("images:\(query)")
        try await behave()
        return images
    }

    func searchVideos(query: String) async throws -> [VideoSearchResult] {
        await log.record("vidéos:\(query)")
        try await behave()
        return videos
    }

    private func behave() async throws {
        switch behavior {
        case .results:
            return
        case .failure:
            throw MediaStubError.unavailable
        case .sleep(let duration):
            try await Task.sleep(for: duration)
        case .rendezvous(let rendezvous):
            await rendezvous.meet("médias", partner: "texte")
        }
    }
}

/// Widget factice à sortie fixe, déclenché par le drapeau de son type.
private struct FixedOutputWidget: SearchWidget {
    let kind: SearchWidgetKind
    let llmContext: String

    func shouldExecute(for classification: QueryClassification) -> Bool {
        switch kind {
        case .weather: classification.showWeatherWidget
        case .calculation: classification.showCalculationWidget
        }
    }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        SearchWidgetOutput(kind: kind, llmContext: llmContext)
    }
}

/// Classement qui conserve l'ordre du moteur, sans doublon ni langue.
private func orderPreservingRanker() -> SourceRanker {
    SourceRanker(
        relevanceScorer: ConstantSimilarityScorer(),
        duplicateScorer: NeverDuplicateScorer(),
        languageIdentifier: UnknownLanguageIdentifier()
    )
}

@MainActor
@Suite("SearchOrchestrator.streamAnswer")
struct SearchOrchestratorStreamingTests {
    private static func makeResult(title: String, url: String, content: String?) -> SearXNGSearchResult {
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

    private static let instance = URL(string: "https://searxng.example")!

    @Test("Cas nominal : les sources sont renvoyées immédiatement, le flux produit les morceaux du provider dans l'ordre")
    func happyPathReturnsSourcesAndStreamsChunks() async throws {
        let results = [
            Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A"),
            Self.makeResult(title: "Titre B", url: "https://b.example", content: "Contenu B"),
        ]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: ["Voici ", "la ", "réponse."])
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let streamingAnswer = try await orchestrator.streamAnswer(query: "quelle est la question ?")

        #expect(streamingAnswer.sources == results)

        var received: [String] = []
        for try await chunk in streamingAnswer.textStream {
            received.append(chunk)
        }
        #expect(received == ["Voici ", "la ", "réponse."])

        // Un seul appel à `streamGenerate` : la génération finale, jamais la
        // classification ni le planner (qui passent par `generate`).
        let streamPrompts = aiProvider.receivedStreamPrompts
        #expect(streamPrompts.count == 1)
        let prompt = try #require(streamPrompts.first)
        #expect(prompt.contains("quelle est la question ?"))
        #expect(prompt.contains("Titre A"))
        #expect(prompt.contains("Titre B"))
    }

    @Test("La limite maxResultsUsedForContext restreint les sources renvoyées, comme answer(query:)")
    func maxResultsLimitsReturnedSources() async throws {
        let results = (1...7).map { Self.makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating()
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.count == 5)
        #expect(streamingAnswer.sources.map(\.title) == ["Titre 1", "Titre 2", "Titre 3", "Titre 4", "Titre 5"])
    }

    @Test("Une erreur de recherche remonte AVANT que le flux final soit sollicité : streamAnswer() lève, streamGenerate() n'est jamais appelé (seule la classification, via generate(), a eu lieu)")
    func searchErrorPropagatesBeforeCallingAIProvider() async {
        let client = MockSearXNGClient(shouldFail: true)
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating()
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        await #expect(throws: FailoverError.allInstancesUnavailable) {
            _ = try await orchestrator.streamAnswer(query: "requête")
        }

        let generatePrompts = aiProvider.receivedGeneratePrompts
        let streamPrompts = aiProvider.receivedStreamPrompts
        #expect(generatePrompts.count == 1)
        #expect(streamPrompts.isEmpty)
    }

    @Test("Une erreur survenant DANS le stream du provider IA (après des yields) est propagée par le flux, pas par streamAnswer() elle-même")
    func errorInsideProviderStreamPropagatesThroughTextStream() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: ["premier morceau"], midStreamFailure: MockError.midStreamFailure)
        let orchestrator = makeOrchestrator(failoverManager: failoverManager, aiProvider: aiProvider)

        // streamAnswer() elle-même ne lève pas : la recherche a réussi, seul le
        // flux de texte (consommé séparément ci-dessous) porte l'échec.
        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        var received: [String] = []
        await #expect(throws: MockError.midStreamFailure) {
            for try await chunk in streamingAnswer.textStream {
                received.append(chunk)
            }
        }
        #expect(received == ["premier morceau"])
    }

    // MARK: - Mode de réponse (1.13) : il traverse tout le pipeline

    private static let neverDonePlanner = """
    {"action":"scrapeURL","urls":["https://1.example"],"reasoning":"encore"}
    """

    private static func sevenResults() -> [SearXNGSearchResult] {
        (1...7).map { makeResult(title: "Titre \($0)", url: "https://\($0).example", content: "Contenu \($0)") }
    }

    @Test("Sans mode explicite : mode Rapide (défaut produit) — 3 sources, aucun tour planner, 2 appels LLM, consignes Rapide")
    func defaultModeIsQuick() async throws {
        // Le défaut de l'init est écrit en littéral (`.quick`) : ce test
        // échoue si le défaut produit change sans que l'orchestrateur suive.
        #expect(ResponseModeSettingsStore.defaultMode == .quick)
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = MockStreamingAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = SearchOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: MockScrapeService(),
            sourceRanker: SourceRanker(
                relevanceScorer: ConstantSimilarityScorer(),
                duplicateScorer: NeverDuplicateScorer(),
                languageIdentifier: UnknownLanguageIdentifier()
            )
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.map(\.title) == ["Titre 1", "Titre 2", "Titre 3"])
        // 1 classification + 0 planner (+ la génération finale, en streaming).
        #expect(aiProvider.receivedGeneratePrompts.count == 1)
        #expect(aiProvider.plannerPromptCount == 0)
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("mode Rapide"))
        #expect(!finalPrompt.contains("[4] Titre 4"))
    }

    @Test("Mode Approfondi : 5 sources, jusqu'à 2 tours planner (4 appels LLM), consignes Approfondi")
    func deepModeAllowsTwoPlannerRounds() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = MockStreamingAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .deep
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.count == 5)
        #expect(aiProvider.plannerPromptCount == 2)
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("mode Approfondi"))
    }

    @Test("Mode Fiable : seules les sources de domaines fiables atteignent le planner, le prompt et l'interface ; 1 seul tour planner")
    func reliableModeKeepsTrustedDomainsOnly() async throws {
        let results = [
            Self.makeResult(title: "Wiki", url: "https://fr.wikipedia.org/wiki/Photosynthese", content: "Contenu wiki"),
            Self.makeResult(title: "Pin", url: "https://www.pinterest.com/pin/123", content: "Contenu pin"),
            Self.makeResult(title: "Blog", url: "https://blog.example.com/article", content: "Contenu blog"),
            Self.makeResult(title: "Nasa", url: "https://www.nasa.gov/photosynthesis", content: "Contenu nasa"),
        ]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = MockStreamingAIGenerating(plannerResponse: Self.neverDonePlanner)
        let scrapeLog = ScrapeLog()
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .reliable,
            scrapeService: RecordingScrapeService(log: scrapeLog)
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "photosynthèse")

        #expect(streamingAnswer.sources.map(\.title) == ["Wiki", "Nasa"])
        #expect(aiProvider.plannerPromptCount == 1)
        // Le planner demande https://1.example, absent des sources affichées
        // (bug 8) : avant, cette page non fiable était téléchargée et injectée.
        #expect(await scrapeLog.urls.isEmpty)
        let plannerPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<planner_context>") })
        #expect(!plannerPrompt.contains("pinterest.com"))
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("mode Fiable"))
        #expect(!finalPrompt.contains("pinterest.com"))
        #expect(!finalPrompt.contains("blog.example.com"))
    }

    @Test("Mode Fiable sans aucun domaine fiable : aucune source (jamais de repli non fiable) et AUCUNE génération lancée")
    func reliableModeWithoutTrustedDomainReturnsNoSource() async throws {
        let results = [
            Self.makeResult(title: "Pin", url: "https://www.pinterest.com/pin/123", content: "Contenu pin"),
            Self.makeResult(title: "Quora", url: "https://www.quora.com/question", content: "Contenu quora"),
        ]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = MockStreamingAIGenerating()
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .reliable
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "question")

        #expect(streamingAnswer.sources.isEmpty)
        #expect(streamingAnswer.artifacts.searchPerformed)
        // Décision (c) : pas de requête au moteur lancée puis annulée.
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
        var chunks: [String] = []
        for try await chunk in streamingAnswer.textStream { chunks.append(chunk) }
        #expect(chunks.isEmpty)
        // Même règle sur le chemin non streamé.
        let result = try await orchestrator.answer(query: "question")
        #expect(result.answer.isEmpty)
        #expect(!aiProvider.receivedGeneratePrompts.contains { $0.contains("Question de l'utilisateur") })
    }

    @Test("Les plafonds de l'appelant bornent le mode sans jamais l'élargir")
    func callerCapsNarrowButNeverWidenTheMode() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])

        // Plafond large en mode Rapide : le mode (3 sources) l'emporte.
        let quickAI = MockStreamingAIGenerating(plannerResponse: Self.neverDonePlanner)
        let quick = makeOrchestrator(failoverManager: failoverManager, aiProvider: quickAI, responseMode: .quick, maxResultsUsedForContext: 10)
        #expect(try await quick.streamAnswer(query: "q").sources.count == 3)
        #expect(quickAI.plannerPromptCount == 0)

        // Plafonds serrés en mode Approfondi : 2 sources, aucun tour planner.
        let deepAI = MockStreamingAIGenerating(plannerResponse: Self.neverDonePlanner)
        let deep = makeOrchestrator(failoverManager: failoverManager, aiProvider: deepAI, responseMode: .deep, maxResultsUsedForContext: 2, maxIterations: 1)
        #expect(try await deep.streamAnswer(query: "q").sources.count == 2)
        #expect(deepAI.plannerPromptCount == 0)
    }

    // MARK: - Bug 1 : une question de suivi garde son contexte

    /// JSON de classification valide pour `QueryClassifier.parse` : tous les
    /// booléens à `false` (donc `.webSearch`), sauf `skipSearch` si demandé.
    private static func classificationJSON(skipSearch: Bool = false, standaloneFollowUp: String) -> String {
        #"{"classification":{"skipSearch":\#(skipSearch),"personalSearch":false,"academicSearch":false,"discussionSearch":false,"#
            + #""showWeatherWidget":false,"showStockWidget":false,"showCalculationWidget":false},"standaloneFollowUp":"\#(standaloneFollowUp)"}"#
    }

    private static let appleHistory = [
        ClassifierChatMessage(role: .user, content: "Qui est le PDG d'Apple ?"),
        ClassifierChatMessage(role: .assistant, content: "Tim Cook dirige Apple depuis 2011[1]."),
    ]

    @Test("Bug 1 : un suivi interroge SearXNG et le planner avec la reformulation ; le prompt final garde la question d'origine, la reformulation et l'historique")
    func followUpSearchesWithStandaloneReformulation() async throws {
        let results = [Self.makeResult(title: "Salaire", url: "https://salaire.example", content: "Contenu salaire")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = MockStreamingAIGenerating(classifyResponse: Self.classificationJSON(standaloneFollowUp: "Salaire de Tim Cook, PDG d'Apple"))
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        _ = try await orchestrator.streamAnswer(query: "Et quel est son salaire ?", chatHistory: Self.appleHistory)

        // Avant le correctif, SearXNG recevait « Et quel est son salaire ? ».
        #expect(await client.receivedQueries == ["Salaire de Tim Cook, PDG d'Apple"])
        let plannerPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<planner_context>") })
        #expect(plannerPrompt.contains("Requête de l'utilisateur : Salaire de Tim Cook, PDG d'Apple"))
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("Assistant : Tim Cook dirige Apple depuis 2011[1]."))
        #expect(finalPrompt.contains("Question reformulée d'après la conversation : Salaire de Tim Cook, PDG d'Apple\n"))
        #expect(finalPrompt.hasSuffix("Question de l'utilisateur : Et quel est son salaire ?"))
    }

    @Test("Bug 1 : reformulation blanche — la recherche repart de la question d'origine, sans ligne de reformulation")
    func blankReformulationFallsBackToOriginalQuery() async throws {
        let client = MockSearXNGClient()
        let aiProvider = MockStreamingAIGenerating(classifyResponse: Self.classificationJSON(standaloneFollowUp: "  "))
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        _ = try await orchestrator.streamAnswer(query: "Prix du cuivre aujourd'hui")

        #expect(await client.receivedQueries == ["Prix du cuivre aujourd'hui"])
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(!finalPrompt.contains("Question reformulée"))
    }

    @Test("effectiveQuery : reformulation nettoyée ; repli sur la question si elle est vide, blanche ou anormalement longue", arguments: [
        (standalone: "  Salaire de Tim Cook \n", expected: "Salaire de Tim Cook"),
        (standalone: "", expected: "Et son salaire ?"),
        (standalone: " \n\t", expected: "Et son salaire ?"),
        (standalone: String(repeating: "a", count: SearchOrchestrator.maxStandaloneQueryCharacters + 1), expected: "Et son salaire ?"),
    ])
    func effectiveQueryFallsBackOnUnusableReformulation(standalone: String, expected: String) {
        #expect(SearchOrchestrator.effectiveQuery(for: "Et son salaire ?", standaloneFollowUp: standalone) == expected)
    }

    @Test("effectiveQuery : une question déjà longue garde une reformulation de même longueur")
    func longQueryKeepsEquallyLongReformulation() {
        let reformulation = String(repeating: "r", count: 400)
        #expect(SearchOrchestrator.effectiveQuery(for: String(repeating: "q", count: 400), standaloneFollowUp: reformulation) == reformulation)
    }

    @Test("Bug 1 : chemin .skip (« Traduis ta réponse ») — prompt de conversation avec la réponse précédente, sans sources exigées ni phrase de refus")
    func skipPathAnswersFromConversation() async throws {
        let client = MockSearXNGClient()
        let classification = Self.classificationJSON(skipSearch: true, standaloneFollowUp: "Traduire en anglais la réponse sur Tim Cook")
        let aiProvider = MockStreamingAIGenerating(classifyResponse: classification)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .reliable
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "Traduis ta réponse en anglais", chatHistory: Self.appleHistory)

        #expect(streamingAnswer.sources.isEmpty)
        #expect(await client.receivedQueries.isEmpty)
        #expect(aiProvider.plannerPromptCount == 0)
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("Assistant : Tim Cook dirige Apple depuis 2011[1]."))
        #expect(finalPrompt.contains("Aucune recherche web n'a été lancée"))
        // Avant : le prompt exigeait « les sources numérotées » absentes, puis
        // imposait le refus ou, en Fiable, l'avertissement « aucune source ».
        #expect(!finalPrompt.contains("sources numérotées"))
        #expect(!finalPrompt.contains("<contexte>"))
        #expect(!finalPrompt.contains(PromptTemplates.noRelevantInformationAnswer))
        #expect(finalPrompt.hasSuffix("Question de l'utilisateur : Traduis ta réponse en anglais"))
    }

    @Test("Bug 1 : l'historique du prompt final est borné en nombre ET en longueur par message, selon les réglages de l'init")
    func finalPromptHistoryIsBoundedByInitSettings() async throws {
        let history = [
            ClassifierChatMessage(role: .user, content: "Premier sujet abandonné"),
            ClassifierChatMessage(role: .assistant, content: "Réponse au premier sujet."),
            ClassifierChatMessage(role: .user, content: "Parle-moi de la photosynthèse"),
            ClassifierChatMessage(role: .assistant, content: String(repeating: "La photosynthèse produit du glucose. ", count: 100)),
        ]
        let aiProvider = MockStreamingAIGenerating()
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: MockSearXNGClient(), instances: [Self.instance]),
            aiProvider: aiProvider,
            maxHistoryMessages: 2,
            maxHistoryMessageCharacters: 80
        )

        _ = try await orchestrator.streamAnswer(query: "Et le rendement ?", chatHistory: history)

        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(!finalPrompt.contains("Premier sujet abandonné"))
        #expect(finalPrompt.contains("Utilisateur : Parle-moi de la photosynthèse"))
        // 80 caractères : coupe à la dernière fin de phrase (74), marquée « […] ».
        #expect(finalPrompt.contains("Assistant : La photosynthèse produit du glucose. La photosynthèse produit du glucose. […]"))
        #expect(finalPrompt.components(separatedBy: "produit du glucose").count == 3)
    }

    // MARK: - Bug 3 : planner facultatif, annulation jamais avalée

    @Test("Bug 3 : le bouton Stop pendant un tour de scrape lève CancellationError — ni nouveau tour planner, ni génération finale")
    func cancellationDuringScrapeRoundStopsThePipeline() async throws {
        let scrapeLog = ScrapeLog()
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = MockStreamingAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: RecordingScrapeService(log: scrapeLog, suspendsUntilCancelled: true)
        )

        let task = Task { try await orchestrator.streamAnswer(query: "requête") }
        await waitUntil("début du premier scrape") { await !scrapeLog.urls.isEmpty }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        // Avant : la page annulée revenait « en échec », le tour 3 relançait
        // le planner, puis la génération finale partait quand même.
        #expect(aiProvider.plannerPromptCount == 1)
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
        #expect(await scrapeLog.urls == ["https://1.example"])
    }

    @Test("Bug 3 : une annulation levée PAR le planner (URLError .cancelled d'un provider cloud coupé) remonte, au lieu du repli « done »")
    func plannerCancellationPropagates() async {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = MockStreamingAIGenerating(plannerError: URLError(.cancelled))
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        let error = await #expect(throws: URLError.self) { _ = try await orchestrator.streamAnswer(query: "requête") }

        #expect(error?.code == .cancelled)
        #expect(aiProvider.plannerPromptCount == 1)
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
    }

    @Test("Bug 3 : une annulation pendant la classification remonte — aucune recherche lancée sur le repli « sûr »")
    func classificationCancellationPropagates() async {
        let client = MockSearXNGClient()
        let aiProvider = MockStreamingAIGenerating(classificationError: CancellationError())
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: client, instances: [Self.instance]), aiProvider: aiProvider)

        await #expect(throws: CancellationError.self) { _ = try await orchestrator.streamAnswer(query: "requête") }

        #expect(await client.receivedQueries.isEmpty)
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
    }

    @Test("isCancellation : CancellationError et URLError(.cancelled) sont des annulations ; un timeout ou une erreur de provider, non")
    func isCancellationRecognisesOnlyCancellations() {
        #expect(SearchOrchestrator.isCancellation(CancellationError()))
        #expect(SearchOrchestrator.isCancellation(URLError(.cancelled)))
        #expect(!SearchOrchestrator.isCancellation(URLError(.timedOut)))
        #expect(!SearchOrchestrator.isCancellation(MockError.searchFailed))
    }

    // MARK: - Bug 11 : chaque page scrapée au plus une fois

    @Test("Bug 11 : un planner qui redemande la même page ne la télécharge qu'une fois ; elle est annoncée « déjà récupérée » et figure une seule fois dans le prompt")
    func repeatedPlannerURLIsScrapedOnce() async throws {
        let scrapeLog = ScrapeLog()
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = MockStreamingAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: RecordingScrapeService(log: scrapeLog)
        )

        _ = try await orchestrator.streamAnswer(query: "requête")

        // Tour 2 : scrape de 1.example ; tour 3 : même demande, rien de neuf -> fin.
        #expect(await scrapeLog.urls == ["https://1.example"])
        #expect(aiProvider.plannerPromptCount == 2)
        let lastPlannerPrompt = try #require(aiProvider.receivedGeneratePrompts.last { $0.contains("<planner_context>") })
        #expect(lastPlannerPrompt.contains("https://1.example (page déjà récupérée)"))
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.components(separatedBy: "Contenu scrapé pour https://1.example").count == 2)
    }

    @Test("Bug 11 : doublons internes d'une même demande (www, slash final, fragment) — un seul téléchargement, à l'URL exacte de la source, puis fin de boucle")
    func duplicateURLsWithinOneDecisionAreScrapedOnce() async throws {
        let scrapeLog = ScrapeLog()
        let source = Self.makeResult(title: "Wiki", url: "https://www.wiki.example/page", content: "Contenu wiki")
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [source], suggestions: []))
        let planner = #"{"action":"scrapeURL","urls":["https://wiki.example/page/","https://www.wiki.example/page#histoire","https://www.wiki.example/page"]}"#
        let aiProvider = MockStreamingAIGenerating(plannerResponse: planner)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: RecordingScrapeService(log: scrapeLog)
        )

        _ = try await orchestrator.streamAnswer(query: "requête")

        #expect(await scrapeLog.urls == ["https://www.wiki.example/page"])
        // L'unique source est déjà lue : plus rien à proposer, pas de tour 3.
        #expect(aiProvider.plannerPromptCount == 1)
    }

    @Test("scrapableURLs : sources affichées seulement, sans doublon ni page déjà tentée, limite comptée APRÈS le filtre, URL exacte de la source")
    func scrapableURLsFiltersBeforeLimiting() {
        let sources = ["https://a.example/x", "https://b.example", "https://c.example"].map { Self.makeResult(title: "T", url: $0, content: nil) }
        let requested = ["https://inventee.example", "https://a.example/x/#intro", "https://a.example/x", "https://b.example", "https://c.example"]
        let attempted: Set<String> = [SearchOrchestrator.urlKey("https://b.example")]

        let selected = SearchOrchestrator.scrapableURLs(requested, displayedSources: sources, alreadyAttempted: attempted, limit: 2)

        #expect(selected == ["https://a.example/x", "https://c.example"])
        #expect(SearchOrchestrator.scrapableURLs(requested, displayedSources: sources, alreadyAttempted: [], limit: 0).isEmpty)
    }

    @Test("Bug 11 : accumulate ne garde qu'un résultat par URL, y compris au sein d'un même lot")
    func accumulateDeduplicatesWithinOneBatch() {
        var sources = [Self.makeResult(title: "Déjà là", url: "https://a.example", content: nil)]
        var pages: [ScrapedPage] = []
        let batch = [
            Self.makeResult(title: "B", url: "https://b.example", content: nil),
            Self.makeResult(title: "B bis", url: "https://www.b.example/", content: nil),
            Self.makeResult(title: "A bis", url: "https://a.example#suite", content: nil),
        ]

        SearchOrchestrator.accumulate(.searchResults(batch), sources: &sources, scrapedPages: &pages)

        #expect(sources.map(\.title) == ["Déjà là", "B"])
    }

    // MARK: - Bug 8 : le planner limité aux sources affichées

    @Test("Bug 8 : le planner ne voit et ne fait télécharger que les sources affichées — ni résultat hors du top N, ni URL inventée")
    func plannerCannotScrapeUndisplayedURLs() async throws {
        let scrapeLog = ScrapeLog()
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let planner = #"{"action":"scrapeURL","urls":["https://7.example","https://inventee.example/secret","https://2.example"]}"#
        let aiProvider = MockStreamingAIGenerating(plannerResponse: planner)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: RecordingScrapeService(log: scrapeLog)
        )

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.count == 5)
        #expect(await scrapeLog.urls == ["https://2.example"])
        let plannerPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<planner_context>") })
        #expect(plannerPrompt.contains("https://5.example"))
        #expect(!plannerPrompt.contains("https://6.example"))
        // Invariant des citations : aucun document au-delà des 5 sources affichées.
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("Contenu scrapé pour https://2.example"))
        #expect(!finalPrompt.contains("inventee.example"))
        #expect(!finalPrompt.contains("[6]"))
    }

    @Test("Bug 8 : sans aucune source, aucun tour planner — il n'aurait rien à choisir")
    func noSourceMeansNoPlannerRound() async throws {
        let aiProvider = MockStreamingAIGenerating(plannerResponse: Self.neverDonePlanner)
        let orchestrator = makeOrchestrator(failoverManager: FailoverManager(client: MockSearXNGClient(), instances: [Self.instance]), aiProvider: aiProvider)

        let streamingAnswer = try await orchestrator.streamAnswer(query: "requête")

        #expect(streamingAnswer.sources.isEmpty)
        #expect(aiProvider.plannerPromptCount == 0)
        #expect(aiProvider.receivedStreamPrompts.count == 1)
    }

    @Test("pagesBackedBySources : écarte toute page hors des sources affichées et recopie l'URL exacte de sa source")
    func pagesBackedBySourcesKeepsDisplayedSourcesOnly() {
        let sources = [Self.makeResult(title: "A", url: "https://www.a.example/doc", content: nil)]
        let pages = [
            ScrapedPage(url: "https://a.example/doc/#intro", title: "A", content: "contenu A", succeeded: true),
            ScrapedPage(url: "https://ailleurs.example", title: "X", content: "contenu X", succeeded: true),
        ]

        let kept = SearchOrchestrator.pagesBackedBySources(pages, sources: sources)

        #expect(kept == [ScrapedPage(url: "https://www.a.example/doc", title: "A", content: "contenu A", succeeded: true)])
    }

    @Test("plannerPrompt : sources affichées annotées (récupérée / en échec), plafond par tour interpolé, plus aucun champ reasoning demandé")
    func plannerPromptAnnotatesAttemptedSources() {
        let sources = ["https://a.example", "https://b.example", "https://c.example"].map { Self.makeResult(title: "T", url: $0, content: nil) }
        let attempted = [
            ScrapedPage(url: "https://a.example", title: "A", content: "contenu", succeeded: true),
            ScrapedPage(url: "https://b.example", title: "B", content: "", succeeded: false),
        ]

        let prompt = SearchOrchestrator.plannerPrompt(
            query: "requête",
            displayedSources: sources,
            scrapedPages: attempted,
            availableActionNames: ["scrapeURL", "done"],
            iteration: 3,
            maxIterations: 3,
            maxURLsPerIteration: 2
        )

        #expect(prompt.contains("1. T — https://a.example (page déjà récupérée)"))
        #expect(prompt.contains("2. T — https://b.example (récupération échouée, ne la redemande pas)"))
        #expect(prompt.contains("3. T — https://c.example\n"))
        #expect(prompt.contains("au plus 2 à la fois"))
        #expect(!prompt.contains("reasoning"))
    }

    // MARK: - Borne d'un tour de scrape, @concurrent, budgets par moteur

    @Test("Borne d'un tour de scrape : à l'échéance, la page finie est gardée ; la lente est annulée, annoncée en échec au planner et jamais injectée")
    func scrapeRoundDeadlineKeepsFinishedPages() async throws {
        let cancellations = ScrapeLog()
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let planner = #"{"action":"scrapeURL","urls":["https://1.example","https://2.example"]}"#
        let aiProvider = MockStreamingAIGenerating(plannerResponse: planner)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            scrapeService: SlowScrapeService(slowURLs: ["https://2.example"], cancellations: cancellations),
            scrapeRoundTimeout: .milliseconds(200)
        )

        let start = ContinuousClock.now
        _ = try await orchestrator.streamAnswer(query: "requête")

        // Sans échéance : 30 s d'attente sur la page lente, puis son contenu injecté.
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(await cancellations.urls == ["https://2.example"])
        let lastPlannerPrompt = try #require(aiProvider.receivedGeneratePrompts.last { $0.contains("<planner_context>") })
        #expect(lastPlannerPrompt.contains("https://1.example (page déjà récupérée)"))
        #expect(lastPlannerPrompt.contains("https://2.example (récupération échouée, ne la redemande pas)"))
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.contains("Contenu scrapé pour https://1.example"))
        #expect(!finalPrompt.contains("Contenu tardif"))
    }

    /// SANS `@concurrent`, `answer`/`streamAnswer` (méthodes `nonisolated
    /// async`) tourneraient sur l'acteur de l'appelant — le main actor ici,
    /// comme pour `ChatViewModel` — et la sonde y serait lue.
    @Test("@concurrent : appelés depuis le main actor, answer et streamAnswer exécutent le pipeline hors du thread principal")
    func pipelineRunsOffTheMainThread() async throws {
        #expect(isRunningOnMainThread(), "prémisse : l'appelant est bien sur le thread principal")
        let journal = ThreadJournal()
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: MockStreamingAIGenerating(plannerResponse: Self.neverDonePlanner),
            clock: ThreadProbeClock(journal: journal)
        )

        _ = try await orchestrator.streamAnswer(query: "requête")
        _ = try await orchestrator.answer(query: "requête")

        #expect(journal.mainThreadReadings == [false, false])
    }

    @Test("Bug 6 : préréglage Apple Intelligence — classifieur et rédaction en version courte, historique borné dans LES DEUX prompts, 2 pages par tour")
    func appleIntelligencePresetDrivesEveryPrompt() async throws {
        let scrapeLog = ScrapeLog()
        let longAnswer = String(repeating: "La photosynthèse produit du glucose. ", count: 100)
        let history = (1...3).flatMap { turn in
            [ClassifierChatMessage(role: .user, content: "Question \(turn)"), ClassifierChatMessage(role: .assistant, content: longAnswer)]
        }
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let planner = #"{"action":"scrapeURL","urls":["https://1.example","https://2.example","https://3.example"]}"#
        let aiProvider = MockStreamingAIGenerating(plannerResponse: planner)
        let orchestrator = SearchOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .deep,
            configuration: .appleIntelligence,
            scrapeService: RecordingScrapeService(log: scrapeLog),
            sourceRanker: orderPreservingRanker(),
            maxIterations: 2
        )

        _ = try await orchestrator.streamAnswer(query: "Et le rendement ?", chatHistory: history)

        // Classifieur : prompt court, 4 derniers messages, chacun coupé à 600 caractères.
        let budget = SearchPipelineConfiguration.appleIntelligence
        let classifierPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<user_query>") })
        let expectedClassifierPrompt = QueryClassifier.buildPrompt(
            query: "Et le rendement ?",
            chatHistory: SearchOrchestrator.boundedHistory(history, maxMessages: 4, maxCharacters: 600),
            maxHistoryMessages: 4,
            promptComplexity: .concise
        )
        #expect(classifierPrompt == expectedClassifierPrompt)
        #expect(!classifierPrompt.contains("Question 1"))
        #expect(classifierPrompt.contains("[…]"))

        // Planner et scraping : 2 pages par tour, annoncées et exécutées.
        let plannerPrompt = try #require(aiProvider.receivedGeneratePrompts.first { $0.contains("<planner_context>") })
        #expect(plannerPrompt.contains("au plus \(budget.maxScrapedURLsPerIteration) à la fois"))
        #expect(Set(await scrapeLog.urls) == ["https://1.example", "https://2.example"])

        // Rédaction : prompt court, historique borné de la même façon.
        let finalPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(finalPrompt.hasPrefix("Tu es Triva. Réponds"))
        #expect(!finalPrompt.contains("Question 1"))
        #expect(finalPrompt.contains("Utilisateur : Question 2"))
        #expect(finalPrompt.components(separatedBy: "produit du glucose").count - 1 <= 2 * (600 / 37))
    }
}

// MARK: - Contrat étendu : widgets, médias, mode connus AVANT le flux (I1b)

extension SearchOrchestratorStreamingTests {
    private static func image(_ name: String) -> ImageSearchResult {
        ImageSearchResult(
            imageURL: URL(string: "https://img.example/\(name).jpg")!,
            sourceURL: URL(string: "https://source.example/\(name)")!,
            title: "Image \(name)"
        )
    }

    private static func video(_ name: String) -> VideoSearchResult {
        VideoSearchResult(
            thumbnailURL: URL(string: "https://img.example/\(name).jpg")!,
            sourceURL: URL(string: "https://video.example/\(name)")!,
            title: "Vidéo \(name)",
            embedURL: nil
        )
    }

    private static let weatherAndSearchJSON = #"{"classification":{"skipSearch":false,"personalSearch":false,"academicSearch":false,"discussionSearch":false,"showWeatherWidget":true,"showStockWidget":false,"showCalculationWidget":false},"standaloneFollowUp":"chats mignons sous la pluie"}"#

    @Test("Contrat 0.8 étendu : widgets, médias, mode et compte citable sont dans artifacts AVANT toute lecture du flux")
    func artifactsAreCompleteBeforeTheStreamIsRead() async throws {
        let results = Array(Self.sevenResults().prefix(2))
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let aiProvider = MockStreamingAIGenerating(chunks: ["Il ", "pleut."], classifyResponse: Self.weatherAndSearchJSON)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            widgets: [FixedOutputWidget(kind: .weather, llmContext: "Météo à Paris : pluie, 12 °C.")],
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [Self.video("b")], behavior: .results, log: MediaCallLog())
        )

        let answer = try await orchestrator.streamAnswer(query: "Des chats sous la pluie ?", media: .all)

        // Rien n'a encore été lu dans le flux : tout ce qui suit est déjà là.
        #expect(answer.sources == results)
        #expect(answer.artifacts.widgets.map(\.kind) == [.weather])
        #expect(answer.artifacts.images.items.map(\.title) == ["Image a"])
        #expect(answer.artifacts.videos.items.map(\.title) == ["Vidéo b"])
        #expect(answer.artifacts.mode == .deep)
        #expect(answer.artifacts.promptComplexity == .full)
        #expect(answer.artifacts.citableSourceCount == 2)
        #expect(answer.artifacts.attachmentSourceCount == 0)
        #expect(answer.artifacts.searchPerformed)
        #expect(answer.artifacts.searchQuery == "chats mignons sous la pluie")
        let streamPrompt = try #require(aiProvider.receivedStreamPrompts.first)
        #expect(streamPrompt.contains("Météo à Paris : pluie, 12 °C."))

        var lastChunk = ""
        for try await chunk in answer.textStream {
            lastChunk = chunk
        }
        #expect(lastChunk == "pleut.")
    }

    @Test("Médias EN PARALLÈLE de la recherche texte, jamais en série : les deux se rejoignent pendant leur exécution")
    func mediaRunsInParallelWithTextSearch() async throws {
        let rendezvous = Rendezvous()
        let client = RendezvousSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []), rendezvous: rendezvous)
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: MockStreamingAIGenerating(),
            responseMode: .quick,
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [], behavior: .rendezvous(rendezvous), log: MediaCallLog()),
            mediaGracePeriod: .seconds(5)
        )

        let answer = try await orchestrator.streamAnswer(query: "chats mignons", media: .images)

        #expect(await rendezvous.sawPartner == ["texte": true, "médias": true])
        #expect(answer.artifacts.images.items.map(\.title) == ["Image a"])
        #expect(answer.artifacts.videos.items.isEmpty)
    }

    @Test("Médias non demandés (défaut) : aucune recherche média, aucun appel de plus ; .notRequested")
    func mediaIsNotSearchedUnlessRequested() async throws {
        let log = MediaCallLog()
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: MockStreamingAIGenerating(),
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [Self.video("b")], behavior: .results, log: log)
        )

        let answer = try await orchestrator.streamAnswer(query: "chats mignons")

        #expect(await log.calls.isEmpty)
        #expect(await client.receivedQueries.count == 1)
        guard case .notRequested = answer.artifacts.images, case .notRequested = answer.artifacts.videos else {
            Issue.record("médias attendus .notRequested")
            return
        }
    }

    @Test("Seuls les médias demandés sont cherchés, avec la REFORMULATION du classifieur (aucun appel LLM de plus)")
    func onlyRequestedMediaAreSearchedWithTheReformulation() async throws {
        let log = MediaCallLog()
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let aiProvider = MockStreamingAIGenerating(classifyResponse: Self.classificationJSON(standaloneFollowUp: "chats mignons"))
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            responseMode: .quick,
            mediaSearcher: StubMediaSearcher(images: [], videos: [Self.video("b")], behavior: .results, log: log)
        )

        let answer = try await orchestrator.streamAnswer(query: "et en vidéo ?", media: .videos)

        #expect(await log.calls == ["vidéos:chats mignons"])
        #expect(answer.artifacts.videos.items.map(\.title) == ["Vidéo b"])
        guard case .notRequested = answer.artifacts.images else {
            Issue.record("images attendues .notRequested")
            return
        }
        // Classification seule : aucune reformulation média par LLM.
        #expect(aiProvider.receivedGeneratePrompts.count == 1)
    }

    @Test("Échec des médias : .failed, la réponse texte arrive quand même — jamais d'erreur levée pour un média")
    func mediaFailureNeverFailsTheAnswer() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: MockStreamingAIGenerating(chunks: ["réponse"]),
            responseMode: .quick,
            mediaSearcher: StubMediaSearcher(images: [], videos: [], behavior: .failure, log: MediaCallLog())
        )

        let answer = try await orchestrator.streamAnswer(query: "chats mignons", media: .all)

        guard case .failed = answer.artifacts.images, case .failed = answer.artifacts.videos else {
            Issue.record("médias attendus .failed")
            return
        }
        #expect(answer.sources.count == 3)
        var received: [String] = []
        for try await chunk in answer.textStream {
            received.append(chunk)
        }
        #expect(received == ["réponse"])
    }

    @Test("Médias trop lents : abandonnés après le délai de grâce (.failed), la réponse ne les attend pas")
    func slowMediaIsAbandonedAfterTheGracePeriod() async throws {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: Self.sevenResults(), suggestions: []))
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: MockStreamingAIGenerating(),
            responseMode: .quick,
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [], behavior: .sleep(.seconds(30)), log: MediaCallLog()),
            mediaGracePeriod: .milliseconds(20)
        )

        let start = ContinuousClock.now
        let answer = try await orchestrator.streamAnswer(query: "chats mignons", media: .images)
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(10))
        guard case .failed = answer.artifacts.images else {
            Issue.record("images attendues .failed")
            return
        }
        #expect(answer.sources.count == 3)
    }

    @Test("Sans recherche web (question conversationnelle), aucun média même demandé : .notRequested, aucun appel")
    func noMediaWithoutWebSearch() async throws {
        let log = MediaCallLog()
        let client = MockSearXNGClient()
        let aiProvider = MockStreamingAIGenerating(classifyResponse: Self.classificationJSON(skipSearch: true, standaloneFollowUp: "Bonjour"))
        let orchestrator = makeOrchestrator(
            failoverManager: FailoverManager(client: client, instances: [Self.instance]),
            aiProvider: aiProvider,
            mediaSearcher: StubMediaSearcher(images: [Self.image("a")], videos: [], behavior: .results, log: log)
        )

        let answer = try await orchestrator.streamAnswer(query: "Bonjour !", media: .all)

        #expect(await log.calls.isEmpty)
        #expect(await client.receivedQueries.isEmpty)
        #expect(answer.artifacts.searchPerformed == false)
        guard case .notRequested = answer.artifacts.images else {
            Issue.record("images attendues .notRequested")
            return
        }
    }

    @Test("SearXNGMediaSearcher : catégories et moteurs des services de 1.6, requête telle quelle, filtrage https des services")
    func searXNGMediaSearcherUsesMediaCategories() async throws {
        let results = [
            SearXNGSearchResult(
                title: "Chat", url: "https://chats.example/1", content: nil,
                imgSrc: "https://img.example/1.jpg", thumbnailSrc: nil, thumbnail: "https://img.example/1-small.jpg",
                author: nil, iframeSrc: nil
            ),
            SearXNGSearchResult(
                title: "Chat non sécurisé", url: "https://chats.example/2", content: nil,
                imgSrc: "http://img.example/2.jpg", thumbnailSrc: nil, thumbnail: "http://img.example/2-small.jpg",
                author: nil, iframeSrc: nil
            ),
        ]
        let client = OptionsRecordingSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let searcher = SearXNGMediaSearcher(failoverManager: FailoverManager(client: client, instances: [Self.instance]))

        let images = try await searcher.searchImages(query: "chats mignons")
        let videos = try await searcher.searchVideos(query: "chats mignons")

        #expect(images.map(\.title) == ["Chat"])
        #expect(videos.map(\.title) == ["Chat"])
        #expect(await client.receivedOptions == [SearXNGMediaSearcher.imageSearchOptions, SearXNGMediaSearcher.videoSearchOptions])
        #expect(SearXNGMediaSearcher.imageSearchOptions == SearXNGSearchOptions(categories: ["images"], engines: ["bing images", "google images"]))
        #expect(SearXNGMediaSearcher.videoSearchOptions == SearXNGSearchOptions(categories: ["videos"], engines: ["youtube"]))
        #expect(await client.receivedQueries == ["chats mignons", "chats mignons"])
    }
}
