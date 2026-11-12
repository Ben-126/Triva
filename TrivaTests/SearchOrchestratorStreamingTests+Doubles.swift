//
//  SearchOrchestratorStreamingTests+Doubles.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Doublures et fabriques des suites `SearchOrchestratorStreamingTests` (découpage E1b : partagées par
/// les fichiers `SearchOrchestrator*Tests.swift`). Noms préfixés `Streaming` là où un nom identique existe
/// ailleurs dans la cible de test, maintenant que ces types ne sont plus `private` à un fichier.

enum StreamingMockError: Error, Sendable, Equatable {
    case searchFailed
    case midStreamFailure
}

/// Même principe que `MockSearXNGClient` de `SearchOrchestratorTests.swift`,
/// dupliqué ici (`private` est scopé au fichier) : renvoie une réponse fixe,
/// ou lève une erreur si configuré pour échouer. `receivedQueries` (bug 1)
/// prouve QUELLE requête atteint SearXNG : la reformulation, pas la question
/// brute d'un suivi.
actor StreamingMockSearXNGClient {
    private let response: SearXNGSearchResponse
    private let shouldFail: Bool
    private(set) var receivedQueries: [String] = []

    init(response: SearXNGSearchResponse = SearXNGSearchResponse(results: [], suggestions: []), shouldFail: Bool = false) {
        self.response = response
        self.shouldFail = shouldFail
    }
}

extension StreamingMockSearXNGClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        receivedQueries.append(query)
        if shouldFail {
            throw StreamingMockError.searchFailed
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
final class StreamingMockAIGenerating: AIGenerating {
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
struct StreamingMockScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "Titre scrapé", content: "Contenu scrapé pour \(url)", succeeded: true)
    }
}

/// Journal des URLs réellement demandées au scraping (bugs 8 et 11) : un
/// acteur, car les scrapes d'un tour tournent en parallèle (`TaskGroup`).
actor ScrapeLog {
    private(set) var urls: [String] = []

    func record(_ url: String) {
        urls.append(url)
    }
}

/// Scraping factice qui journalise chaque URL. `suspendsUntilCancelled`
/// (bug 3) : le scrape reste suspendu jusqu'à l'annulation de la tâche,
/// comme une page lente au moment où l'utilisateur touche Stop — puis rend
/// une page en échec, exactement comme `ScrapeService` (qui ne lève jamais).
struct RecordingScrapeService: ScrapeServing {
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
struct SlowScrapeService: ScrapeServing {
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
func streamingIsRunningOnMainThread() -> Bool {
    Thread.isMainThread
}

/// Lectures de `ThreadProbeClock.now` : `@unchecked Sendable` + `NSLock`,
/// même principe que `FetchJournal` (`ScrapeServiceFetchTests`).
final class ThreadJournal: @unchecked Sendable {
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
struct ThreadProbeClock: Clock {
    let journal: ThreadJournal
    private let base = ContinuousClock()

    init(journal: ThreadJournal) {
        self.journal = journal
    }

    var now: ContinuousClock.Instant {
        journal.record(onMainThread: streamingIsRunningOnMainThread())
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
func streamingWaitUntil(_ timeoutMessage: String, maxAttempts: Int = 2_000, _ condition: () async -> Bool) async {
    for _ in 0..<maxAttempts {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timeout en attendant : \(timeoutMessage)")
}

/// Similarité constante : le classement retombe sur la seule position du
/// moteur, l'ordre de sortie est donc l'ordre d'entrée.
struct StreamingConstantSimilarityScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

/// Aucun quasi-doublon : le vrai scorer lexical fusionnerait des extraits
/// de test qui ne diffèrent que d'un caractère (« Contenu 1 » / « Contenu 2 »).
struct StreamingNeverDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

/// Aucune langue reconnue : un seul groupe, pas de fusion par langue.
struct StreamingUnknownLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

/// Même convention que `makeOrchestrator` de `SearchOrchestratorTests.swift`
/// (dupliqué, `private` étant scopé au fichier) : mode Approfondi par défaut
/// — les valeurs historiques que vérifient les tests d'avant 1.13 —,
/// classement qui conserve l'ordre du moteur, scraping factice.
@MainActor
func makeStreamingOrchestrator(
    failoverManager: FailoverManager,
    aiProvider: any AIGenerating,
    responseMode: ResponseMode = .deep,
    scrapeService: any ScrapeServing = StreamingMockScrapeService(),
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
        sourceRanker: streamingOrderPreservingRanker(),
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
actor Rendezvous {
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
actor RendezvousSearXNGClient {
    private let response: SearXNGSearchResponse
    private let rendezvous: Rendezvous

    init(response: SearXNGSearchResponse, rendezvous: Rendezvous) {
        self.response = response
        self.rendezvous = rendezvous
    }
}

extension RendezvousSearXNGClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        await rendezvous.meet("texte", partner: "médias")
        return response
    }
}

/// Client SearXNG qui note les options et requêtes reçues.
actor OptionsRecordingSearXNGClient {
    private let response: SearXNGSearchResponse
    private(set) var receivedOptions: [SearXNGSearchOptions] = []
    private(set) var receivedQueries: [String] = []

    init(response: SearXNGSearchResponse) {
        self.response = response
    }
}

extension OptionsRecordingSearXNGClient: SearXNGSearching {
    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        receivedOptions.append(options)
        receivedQueries.append(query)
        return response
    }
}

/// Journal des recherches média reçues (type et requête).
actor MediaCallLog {
    private(set) var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }
}

enum MediaStubError: Error, Sendable {
    case unavailable
}

/// Recherche média factice, sans réseau.
struct StubMediaSearcher: MediaSearching {
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
struct StreamingFixedOutputWidget: SearchWidget {
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
func streamingOrderPreservingRanker() -> SourceRanker {
    SourceRanker(
        relevanceScorer: StreamingConstantSimilarityScorer(),
        duplicateScorer: StreamingNeverDuplicateScorer(),
        languageIdentifier: StreamingUnknownLanguageIdentifier()
    )
}
