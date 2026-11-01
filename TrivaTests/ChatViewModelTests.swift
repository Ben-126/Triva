//
//  ChatViewModelTests.swift
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
    case providerResolutionFailed
    case mediaFailed
}

// MARK: - Doublures réseau

/// Client SearXNG factice, même principe que `MockSearXNGClient` de
/// `SearchOrchestratorTests.swift` (dupliqué ici, `private` est scopé au
/// fichier) : réponse fixe, ou erreur si configuré pour échouer. Compte les
/// requêtes : un chemin « sans recherche » doit le laisser à zéro.
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

/// Client SearXNG dont `search` reste en vol jusqu'à `fail(with:)` : simule
/// une annulation PENDANT `failoverManager.search(query:)`, avant même que
/// `streamAnswer` ait créé un `textStream` (finding ChatViewModel.swift:166
/// de la revue 0.8).
private actor ControllableSearXNGClient: SearXNGSearching {
    private(set) var continuation: CheckedContinuation<SearXNGSearchResponse, Error>?

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func fail(with error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

// MARK: - Doublures IA

/// Provider IA qui streame une suite fixe de snapshots, avec une erreur
/// optionnelle en fin de flux. `generate(prompt:)` sert à la classification
/// et aux tours planner (jamais à la génération finale, qui passe par
/// `streamGenerate`) : deux tableaux séparés. Sans `classification`, la
/// sortie n'est jamais du JSON valide et le classifieur retombe sur son repli
/// sûr (recherche web, aucun widget).
private final class MockStreamingAIGenerating: AIGenerating {
    private(set) var receivedGeneratePrompts: [String] = []
    private(set) var receivedStreamPrompts: [String] = []
    private let chunks: [String]
    private let midStreamFailure: (any Error)?
    private let classification: String?

    init(chunks: [String] = ["chunk"], midStreamFailure: (any Error)? = nil, classification: String? = nil) {
        self.chunks = chunks
        self.midStreamFailure = midStreamFailure
        self.classification = classification
    }

    /// Prompts de classification : marqueur `<user_query>` de `QueryClassifier.buildPrompt`.
    var classifierPrompts: [String] {
        receivedGeneratePrompts.filter { $0.contains("<user_query>") }
    }

    func generate(prompt: String) async throws -> String {
        receivedGeneratePrompts.append(prompt)
        if let classification, prompt.contains("<user_query>") {
            return classification
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

/// Provider dont le flux est piloté par le test (`continuation`), pour
/// observer le ViewModel ENTRE deux snapshots. Chaque `streamGenerate`
/// remplace `continuation` : un 2e envoi s'attend sur `receivedPrompts.count`.
private final class ControllableStreamingAIGenerating: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private(set) var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func generate(prompt: String) async throws -> String { "" }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        receivedPrompts.append(prompt)
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }
}

/// Provider dont tout appel HORS classification lève : la génération des
/// suggestions échoue (quota, réseau coupé) APRÈS une réponse réussie.
private final class SuggestionsFailingProvider: AIGenerating {
    private(set) var failedSuggestionCalls = 0

    func generate(prompt: String) async throws -> String {
        guard prompt.contains("<user_query>") else {
            failedSuggestionCalls += 1
            throw MockError.midStreamFailure
        }
        return ""
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("Réponse complète.")
            continuation.finish()
        }
    }
}

// MARK: - Doublures du pipeline

/// Similarité identique partout : le classement garde l'ordre du moteur.
private struct ConstantSimilarityScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

/// Rien n'est un quasi-doublon : des extraits de test courts se
/// ressemblent trop pour le vrai scorer lexical.
private struct NeverDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

/// Aucune langue reconnue : un seul groupe, aucune fusion FR/EN.
private struct UnknownLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

/// Classement déterministe, sans modèle système : le vrai `SourceRanker`
/// charge des embeddings `NaturalLanguage` à froid, cause probable de
/// l'intermittence de `sourcesAttachedBeforeFirstChunk` (risque 2 d'I1a-3).
private func orderPreservingRanker() -> SourceRanker {
    SourceRanker(
        relevanceScorer: ConstantSimilarityScorer(),
        duplicateScorer: NeverDuplicateScorer(),
        languageIdentifier: UnknownLanguageIdentifier()
    )
}

/// Aucun scrape réel : le mode Rapide n'a pas de planner, et le planner des
/// autres modes retombe sur `done` (sortie non JSON des doublures).
private struct FailingScrapeService: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

/// Widget à sortie fixe, déclenché par le drapeau de son type.
private struct FixedOutputWidget: SearchWidget {
    let output: SearchWidgetOutput

    var kind: SearchWidgetKind { output.kind }

    func shouldExecute(for classification: QueryClassification) -> Bool {
        switch output.kind {
        case .weather: classification.showWeatherWidget
        case .calculation: classification.showCalculationWidget
        }
    }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        output
    }
}

/// Recherche média factice : enregistre chaque requête, rend une liste fixe
/// ou lève. Sert AUSSI de recherche média de l'orchestrateur, pour prouver
/// que l'envoi ne cherche jamais de médias (décision (a)).
private actor RecordingMediaSearcher: MediaSearching {
    private(set) var imageQueries: [String] = []
    private(set) var videoQueries: [String] = []
    private let images: [ImageSearchResult]
    private let videos: [VideoSearchResult]
    private let failure: MockError?

    init(images: [ImageSearchResult] = [], videos: [VideoSearchResult] = [], failure: MockError? = nil) {
        self.images = images
        self.videos = videos
        self.failure = failure
    }

    func searchImages(query: String) async throws -> [ImageSearchResult] {
        imageQueries.append(query)
        if let failure { throw failure }
        return images
    }

    func searchVideos(query: String) async throws -> [VideoSearchResult] {
        videoQueries.append(query)
        if let failure { throw failure }
        return videos
    }
}

/// Lecture de fichier factice : un fragment texte fixe, sans disque.
private struct StubAttachmentPreparer: AttachmentPreparing {
    static let text = "Le rapport annuel indique une hausse de 12 % des ventes."

    func prepareAttachment(fileAt url: URL, characterLimit: Int) async throws -> IndexedAttachment {
        IndexedAttachment(
            fileName: url.lastPathComponent,
            kind: .plainText,
            pageCount: nil,
            characterCount: Self.text.count,
            isTruncated: false,
            isCopyRestricted: false,
            chunks: [AttachmentChunk(index: 0, text: Self.text, pageRange: nil)]
        )
    }
}

// MARK: - Enregistreurs

/// Ce que le ViewModel relit à CHAQUE envoi (mode mémorisé, budget du
/// moteur), modifiable entre deux envois — sans jamais toucher
/// `UserDefaults.standard`, que l'app hôte des tests partage.
@MainActor
private final class SendSettings {
    var mode: ResponseMode = .quick
    var configuration: SearchPipelineConfiguration = .cloud
}

/// Entrées reçues par la fabrique d'orchestrateur, une par échange : la
/// preuve que mode et budget arrivent au pipeline (bug 6, 1.13).
@MainActor
private final class OrchestratorFactoryRecorder {
    private(set) var modes: [ResponseMode] = []
    private(set) var configurations: [SearchPipelineConfiguration] = []

    func record(_ inputs: ChatViewModel.OrchestratorInputs) {
        modes.append(inputs.responseMode)
        configurations.append(inputs.configuration)
    }
}

/// Générateur de suggestions injecté PARTOUT : le service réel ferait des
/// appels `generate` après le retour de `send`, et décalerait les comptes de
/// prompts. `delays` retarde les appels successifs (annulation par l'envoi
/// suivant) ; `cancellationByQuestion` dit si la tâche était annulée au
/// moment de rendre la main.
@MainActor
private final class SuggestionsRecorder {
    private(set) var histories: [[ClassifierChatMessage]] = []
    private(set) var cancellationByQuestion: [String: Bool] = [:]
    private let result: [String]
    private var delays: [Duration]

    init(result: [String] = [], delays: [Duration] = []) {
        self.result = result
        self.delays = delays
    }

    func generate(_ provider: any AIGenerating, _ history: [ClassifierChatMessage]) async -> [String] {
        histories.append(history)
        if !delays.isEmpty {
            let delay = delays.removeFirst()
            try? await Task.sleep(for: delay)
        }
        let question = history.last { $0.role == .user }?.content ?? ""
        cancellationByQuestion[question] = Task.isCancelled
        return result
    }
}

/// Historique et favoris de l'app, sur le MÊME conteneur en mémoire neuf
/// (comme `TrivaSharedStores`) — jamais `TrivaModelContainer.shared`.
@MainActor
private struct PersistenceStores {
    let history: ChatHistoryStore
    let favorites: FavoritesStore

    init() throws {
        let container = try TrivaModelContainer.makeInMemory()
        let locale = Locale(identifier: "fr_FR")
        history = ChatHistoryStore(container: container, locale: locale)
        favorites = FavoritesStore(container: container, locale: locale)
    }

    func onlyConversation() throws -> StoredConversation? {
        let conversations = try history.conversations()
        return conversations.count == 1 ? conversations.first : nil
    }
}

// MARK: - Utilitaires

/// Sortie de classification valide (format de `QueryClassifier.buildPrompt`).
private func classificationJSON(
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
private func taggedBlock(_ tag: String, in prompt: String?) -> String? {
    guard let prompt,
          let start = prompt.range(of: "<\(tag)>")?.upperBound,
          let end = prompt.range(of: "</\(tag)>", range: start..<prompt.endIndex)?.lowerBound else { return nil }
    return String(prompt[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
@Suite("ChatViewModel")
struct ChatViewModelTests {
    private static let instance = URL(string: "https://searxng.example")!

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

    private static func response(_ results: [SearXNGSearchResult]) -> SearXNGSearchResponse {
        SearXNGSearchResponse(results: results, suggestions: [])
    }

    /// Hors de la liste des domaines fiables : le mode Fiable les filtre tous.
    private static let untrustedResults = [
        makeResult(title: "Forum A", url: "https://a.example/fil", content: "Avis A"),
        makeResult(title: "Forum B", url: "https://b.example/fil", content: "Avis B"),
    ]

    /// ViewModel déterministe : mode et budget lus dans `settings`, pipeline
    /// réel mais sans modèle système ni réseau (`deterministicOrchestrator`),
    /// suggestions et médias enregistrés, persistance seulement si `stores`.
    private func makeViewModel(
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
    private static func deterministicOrchestrator(
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
    private func waitUntil(
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

    private func waitForContinuation(
        _ provider: ControllableStreamingAIGenerating
    ) async -> AsyncThrowingStream<String, Error>.Continuation? {
        await waitUntil("continuation assignée par streamGenerate") { provider.continuation != nil }
        return provider.continuation
    }

    // MARK: - Cas nominal

    @Test("Cas nominal : le texte final est le DERNIER snapshot reçu (cumulatif), jamais une concaténation")
    func happyPathStreamsToFinalSnapshot() async throws {
        let results = [
            Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A"),
            Self.makeResult(title: "Titre B", url: "https://b.example", content: "Contenu B"),
        ]
        let aiProvider = MockStreamingAIGenerating(chunks: ["Voici", "Voici la", "Voici la réponse complète."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, client: MockSearXNGClient(response: Self.response(results)))

        await viewModel.send(query: "  Quelle est la question ?  ")

        let messages = viewModel.messages
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].text == "Quelle est la question ?")
        #expect(messages[0].isStreaming == false)

        let assistantMessage = messages[1]
        #expect(assistantMessage.role == .assistant)
        #expect(assistantMessage.text == "Voici la réponse complète.")
        #expect(assistantMessage.text != "VoiciVoici laVoici la réponse complète.")
        #expect(assistantMessage.isStreaming == false)
        #expect(assistantMessage.status == .completed)
        #expect(assistantMessage.sources == results)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.errorDescription == nil)

        // Un seul `streamGenerate` (génération finale) ; classification et
        // planner passent par `generate`.
        #expect(aiProvider.receivedStreamPrompts.count == 1)
        #expect(aiProvider.receivedStreamPrompts.first?.contains("Quelle est la question ?") == true)
    }

    @Test("Chaque snapshot REMPLACE le texte du message assistant, à chaque étape")
    func eachStreamValueReplacesTextAtEachStep() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        let task = Task { await viewModel.send(query: "requête") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }

        continuation.yield("Voici")
        await waitUntil("le message reflète le 1er snapshot") { viewModel.messages.last?.text == "Voici" }
        #expect(viewModel.messages.last?.text == "Voici")
        #expect(viewModel.messages.last?.isStreaming == true)

        continuation.yield("Voici la réponse complète.")
        await waitUntil("le message reflète le 2e snapshot") { viewModel.messages.last?.text == "Voici la réponse complète." }
        #expect(viewModel.messages.last?.text == "Voici la réponse complète.")

        continuation.finish()
        await task.value

        #expect(viewModel.messages.last?.text == "Voici la réponse complète.")
        #expect(viewModel.messages.last?.isStreaming == false)
    }

    // MARK: - Sources et widgets

    @Test("Les sources sont attachées dès qu'elles sont connues, avant le premier morceau de texte")
    func sourcesAttachedBeforeFirstChunk() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, client: MockSearXNGClient(response: Self.response(results)))

        let task = Task { await viewModel.send(query: "requête") }
        await waitUntil("les sources sont attachées") { viewModel.messages.last?.sources.isEmpty == false }

        let messageWithSources = viewModel.messages.last
        #expect(messageWithSources?.sources == results)
        #expect(messageWithSources?.text == "")
        #expect(messageWithSources?.isStreaming == true)

        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.finish()
        await task.value
    }

    @Test("Un widget calcul abouti est attaché, typé, au message ; un calcul pur ne lance aucune recherche (1.5)")
    func calculationWidgetIsAttachedWithoutAnySearch() async throws {
        let data = CalculationWidgetData(expression: "12 × 7", result: 84, formattedResult: "84")
        let widget = FixedOutputWidget(output: SearchWidgetOutput(kind: .calculation, llmContext: "12 × 7 = 84", payload: data))
        let client = MockSearXNGClient(shouldFail: true)
        let aiProvider = MockStreamingAIGenerating(
            chunks: ["Cela fait 84."],
            classification: classificationJSON(standaloneFollowUp: "12 × 7", skipSearch: true, showCalculationWidget: true)
        )
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, client: client, widgets: [widget])

        await viewModel.send(query: "Combien font 12 × 7 ?")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.widgets == [.calculation(data)])
        #expect(answer.sources.isEmpty)
        #expect(viewModel.errorDescription == nil)
        #expect(await client.receivedQueries.isEmpty)
    }

    // MARK: - Erreurs

    @Test("Une erreur de recherche est reportée dans errorDescription, sans laisser isStreaming/isGenerating bloqués")
    func searchErrorIsReportedOnAssistantMessage() async {
        let aiProvider = MockStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, client: MockSearXNGClient(shouldFail: true))

        await viewModel.send(query: "requête")

        let messages = viewModel.messages
        #expect(messages.count == 2)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].isStreaming == false)
        #expect(messages[1].status == .failed)
        // Erreur UNIQUEMENT dans `errorDescription` (bandeau de `ChatView`),
        // jamais recopiée dans la bulle.
        #expect(messages[1].text.isEmpty)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.errorDescription == "Aucune instance de recherche n'a répondu. Réessaie dans un instant.")

        // Échec avant la génération finale : seule la classification a eu lieu.
        #expect(aiProvider.receivedGeneratePrompts.count == 1)
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
    }

    @Test("Une erreur PENDANT le stream est reportée, texte déjà streamé conservé, aucun rapport de structure")
    func midStreamErrorIsReportedOnAssistantMessage() async {
        let aiProvider = MockStreamingAIGenerating(chunks: ["premier morceau"], midStreamFailure: MockError.midStreamFailure)
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        await viewModel.send(query: "requête")

        let messages = viewModel.messages
        #expect(messages.count == 2)
        #expect(messages[1].isStreaming == false)
        #expect(messages[1].status == .failed)
        #expect(messages[1].text == "premier morceau")
        #expect(messages[1].structureReport == nil)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.errorDescription?.contains("midStreamFailure") == true)
    }

    @Test("Une erreur de résolution du provider est reportée, sans crash")
    func providerResolutionErrorIsReportedOnAssistantMessage() async {
        let viewModel = makeViewModel(resolveProvider: { throw MockError.providerResolutionFailed })

        await viewModel.send(query: "requête")

        let messages = viewModel.messages
        #expect(messages.count == 2)
        #expect(messages[1].isStreaming == false)
        #expect(messages[1].text.isEmpty)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.errorDescription?.contains("providerResolutionFailed") == true)
    }

    // MARK: - Requêtes vides / envoi concurrent

    @Test("Une requête vide ou faite d'espaces est ignorée silencieusement", arguments: ["", "    "])
    func blankQueryIsIgnored(query: String) async {
        let aiProvider = MockStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        await viewModel.send(query: query)

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isGenerating == false)
        #expect(aiProvider.receivedGeneratePrompts.isEmpty)
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
    }

    @Test("Un envoi concurrent est ignoré tant que isGenerating est vrai")
    func concurrentSendIsIgnoredWhileGenerating() async {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        let firstTask = Task { await viewModel.send(query: "premier") }
        await waitUntil("la 1re génération est en cours") { viewModel.isGenerating }
        #expect(viewModel.isGenerating, "précondition : la 1re génération doit être en cours")

        await viewModel.send(query: "second")
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages[0].text == "premier")

        guard let continuation = await waitForContinuation(aiProvider) else {
            firstTask.cancel()
            return
        }
        continuation.yield("réponse")
        continuation.finish()
        await firstTask.value

        #expect(viewModel.messages.count == 2)
        #expect(viewModel.isGenerating == false)
    }

    // MARK: - Flux vide

    @Test("Un flux à 0 yield, ou à un unique snapshot vide, est un échec explicite (emptyResponse), jamais une bulle vide silencieuse",
          arguments: [[String](), [""]])
    func emptyStreamIsReportedAsFailure(chunks: [String]) async {
        let aiProvider = MockStreamingAIGenerating(chunks: chunks)
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        await viewModel.send(query: "requête")

        let messages = viewModel.messages
        #expect(messages.count == 2)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].isStreaming == false)
        #expect(messages[1].status == .failed)
        #expect(messages[1].text.isEmpty)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.errorDescription == "Le moteur IA n'a renvoyé aucune réponse. Réessaie.")
    }

    // MARK: - Annulation

    @Test("Annuler la Task englobante pendant le streaming : texte conservé, aucune erreur, aucune suggestion")
    func cancellingEnclosingTaskStopsStreamingWithoutError() async {
        let aiProvider = ControllableStreamingAIGenerating()
        let suggestions = SuggestionsRecorder(result: ["Suggestion"])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, suggestions: suggestions)

        // Comme `ChatView.send()` : c'est la `Task` englobante qu'on annule.
        let task = Task { await viewModel.send(query: "requête") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Voici un début")
        await waitUntil("le message reflète le 1er snapshot") { viewModel.messages.last?.text == "Voici un début" }

        task.cancel()
        await task.value

        #expect(viewModel.messages.last?.text == "Voici un début")
        #expect(viewModel.messages.last?.isStreaming == false)
        #expect(viewModel.messages.last?.status == .interrupted)
        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.isGenerating == false)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(suggestions.histories.isEmpty)
    }

    @Test("Annuler PENDANT la recherche (avant tout textStream) n'est pas une erreur (finding ChatViewModel.swift:166, revue 0.8)")
    func cancellingDuringInFlightSearchIsNotReportedAsError() async {
        let client = ControllableSearXNGClient()
        let aiProvider = MockStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, client: client)

        let task = Task { await viewModel.send(query: "requête") }
        await waitUntil("la recherche est en vol") { await client.continuation != nil }

        // Annulation PUIS échec de la recherche avec l'erreur qu'elle produit
        // (`FailoverManager.search` relance telle quelle quand la tâche est annulée).
        task.cancel()
        await client.fail(with: CancellationError())
        await task.value

        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages[1].isStreaming == false)
        #expect(viewModel.messages[1].status == .interrupted)
        #expect(viewModel.messages[1].text.isEmpty)
        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.isGenerating == false)
    }

    @Test("Une erreur du flux levée AU MOMENT de l'annulation n'est pas un échec (finding ChatViewModel.swift:163, revue 0.8)")
    func streamErrorDuringCancellationIsNotReportedAsError() async {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        let task = Task { await viewModel.send(query: "requête") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Voici un début")
        await waitUntil("le message reflète le 1er snapshot") { viewModel.messages.last?.text == "Voici un début" }

        // Le provider échoue de son côté au moment exact où l'écran se ferme.
        task.cancel()
        continuation.finish(throwing: MockError.midStreamFailure)
        await task.value

        #expect(viewModel.messages.last?.text == "Voici un début")
        #expect(viewModel.messages.last?.isStreaming == false)
        #expect(viewModel.errorDescription == nil)
    }

    // MARK: - Messages d'erreur compréhensibles

    @Test("Une ActiveAIProviderResolverError connue est traduite en français clair")
    func knownResolverErrorIsTranslatedToFriendlyMessage() async {
        let viewModel = makeViewModel(resolveProvider: { throw ActiveAIProviderResolverError.noCloudSelectionStored })

        await viewModel.send(query: "Test")

        #expect(viewModel.errorDescription == "Aucun fournisseur configuré. Va dans Réglages pour en choisir un.")
        #expect(viewModel.errorDescription?.contains("noCloudSelectionStored") == false)
    }

    @Test("MLXProviderError.simulatorUnsupported est traduit, pas le nom brut du cas")
    func simulatorUnsupportedErrorIsTranslatedToFriendlyMessage() async {
        let viewModel = makeViewModel(resolveProvider: { throw MLXProviderError.simulatorUnsupported })

        await viewModel.send(query: "Test")

        #expect(viewModel.errorDescription == "Les modèles locaux (MLX) ne fonctionnent pas sur le Simulateur — teste sur un appareil réel.")
        #expect(viewModel.errorDescription?.contains("simulatorUnsupported") == false)
    }

    @Test("Une erreur inconnue retombe sur String(describing:) plutôt qu'un message inventé")
    func unknownErrorFallsBackToRawDescription() async {
        let viewModel = makeViewModel(resolveProvider: { throw MockError.providerResolutionFailed })

        await viewModel.send(query: "Test")

        #expect(viewModel.errorDescription?.contains("providerResolutionFailed") == true)
    }

    @Test("SearchSessionError.sessionEnded a son message français")
    func sessionEndedHasAFrenchMessage() {
        #expect(ChatViewModel.userFacingMessage(for: SearchSessionError.sessionEnded)
            == "Réponse interrompue : la fenêtre a été fermée ou le moteur IA a changé.")
    }

    @Test("Les erreurs des moteurs, du cloud et de la persistance n'affichent JAMAIS leur texte brut (clé BYOK renvoyée par un serveur)")
    func engineAndCloudErrorsNeverEchoTheirRawText() {
        let secret = "Bearer sk-SECRET-42"
        let errors: [any Error] = [
            OpenAICompatibleProviderError.generationFailed(description: secret),
            CloudBYOKError.generationFailed(description: secret),
            AppleIntelligenceError.generationFailed(description: secret),
            MLXProviderError.generationFailed(description: secret),
            MLXProviderError.downloadFailed(description: secret),
            ChatHistoryStoreError.saveFailed(operation: "ajout d'un message", reason: secret),
            FavoritesStoreError.fetchFailed(reason: secret),
        ]
        for error in errors {
            let message = ChatViewModel.userFacingMessage(for: error)
            #expect(!message.contains("SECRET"), "texte brut affiché pour \(type(of: error))")
            #expect(!message.contains("generationFailed"))
        }
        let missingKey = "Aucune clé API n'est enregistrée pour ce fournisseur. Ajoute-la dans les Réglages."
        #expect(ChatViewModel.userFacingMessage(for: OpenAICompatibleProviderError.missingAPIKey) == missingKey)
        #expect(ChatViewModel.userFacingMessage(for: CloudBYOKError.missingAPIKey) == missingKey)
    }

    @Test("Bug 6 : un échec de génération donne un message neutre et actionnable, qui n'accuse plus la clé d'emblée")
    func generationFailuresGetNeutralActionableMessages() {
        let cloud = "Le fournisseur IA n'a pas pu répondre. Réessaie dans un instant ; si ça continue, vérifie ta clé API dans les Réglages."
        #expect(ChatViewModel.userFacingMessage(for: OpenAICompatibleProviderError.generationFailed(description: "429")) == cloud)
        #expect(ChatViewModel.userFacingMessage(for: CloudBYOKError.generationFailed(description: "503")) == cloud)
        #expect(ChatViewModel.userFacingMessage(for: AppleIntelligenceError.generationFailed(description: "exceededContextWindowSize"))
            == "Apple Intelligence n'a pas pu répondre. Si la conversation est longue, commence-en une nouvelle.")
        #expect(ChatViewModel.userFacingMessage(for: MLXProviderError.generationFailed(description: "boom"))
            == "Le modèle local n'a pas pu répondre. Si la conversation est longue, commence-en une nouvelle.")
    }

    // MARK: - Historique passé au classifieur et au prompt final (bug 1)

    @Test("Le classifieur ET le prompt final reçoivent les tours précédents, jamais le message courant (bug 1)")
    func chatHistoryPassedToClassifierExcludesCurrentTurn() async throws {
        let aiProvider = MockStreamingAIGenerating(chunks: ["réponse fixe"])
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        await viewModel.send(query: "premier message")
        await viewModel.send(query: "second message")

        // Classifieur : le 2e prompt porte le 1er tour, sans le message courant
        // (qui est dans <user_query>, hors du bloc).
        #expect(aiProvider.classifierPrompts.count == 2)
        let classifierHistory = try #require(taggedBlock("conversation_history", in: aiProvider.classifierPrompts.last))
        #expect(classifierHistory.contains("premier message"))
        #expect(classifierHistory.contains("réponse fixe"))
        #expect(!classifierHistory.contains("second message"))

        // Prompt FINAL (ce que le prompt de revue demandait en plus) :
        // l'historique borné y est, la question courante n'est posée qu'une fois.
        #expect(aiProvider.receivedStreamPrompts.count == 2)
        #expect(taggedBlock("historique_conversation", in: aiProvider.receivedStreamPrompts.first) == "Aucun échange précédent.")
        let finalHistory = try #require(taggedBlock("historique_conversation", in: aiProvider.receivedStreamPrompts.last))
        #expect(finalHistory.contains("Utilisateur : premier message"))
        #expect(finalHistory.contains("Assistant : réponse fixe"))
        #expect(!finalHistory.contains("second message"))
        #expect(aiProvider.receivedStreamPrompts.last?.contains("second message") == true)
    }

    @Test("Seuls les tours ABOUTIS entrent dans l'historique, par leur texte visible (sans <think>, TL;DR seul s'il n'y a pas de corps)")
    func historyKeepsOnlyCompletedTurns() {
        typealias Message = ChatViewModel.Message
        func answer(_ text: String, _ status: Message.Status) -> Message {
            var message = Message(role: .assistant, isStreaming: true)
            message.apply(snapshot: text, at: .now)
            message.finish(status, at: .now)
            return message
        }
        let messages = [
            Message(role: .user, text: "Q1"), answer("<think>caché</think>R1", .completed),
            Message(role: .user, text: "Q2"), answer("partiel", .failed),
            Message(role: .user, text: "Q3"), answer("coupé", .interrupted),
            Message(role: .user, text: "Q4"), answer("", .noReliableSources),
            Message(role: .user, text: "Q5"), answer("<tldr>Résumé seul</tldr>", .completed),
            Message(role: .user, text: "Q6"), Message(role: .assistant, isStreaming: true),
        ]

        let history = ChatViewModel.classifierHistory(from: messages)

        #expect(history.map(\.content) == ["Q1", "R1", "Q5", "Résumé seul"])
        #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test("Le raisonnement est segmenté pendant le flux et reste HORS des prompts suivants ; le texte brut est conservé (1.14)")
    func reasoningIsSegmentedAndKeptOutOfTheNextPrompts() async throws {
        let aiProvider = MockStreamingAIGenerating(chunks: [
            "<think>Je pèse le sujet secret",
            "<think>Je pèse le sujet secret</think>Réponse visible.",
        ])
        let viewModel = makeViewModel(resolveProvider: { aiProvider })

        await viewModel.send(query: "Première question")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.text.hasPrefix("<think>"))
        #expect(answer.segments.body == "Réponse visible.")
        #expect(answer.segments.reasoning.contains("sujet secret"))
        #expect(answer.segments.reasoningPhase == .completed)
        #expect(answer.reasoningTiming.startedAt != nil)
        #expect(answer.reasoningTiming.endedAt != nil)

        await viewModel.send(query: "Seconde question")

        let classifierHistory = try #require(taggedBlock("conversation_history", in: aiProvider.classifierPrompts.last))
        let finalHistory = try #require(taggedBlock("historique_conversation", in: aiProvider.receivedStreamPrompts.last))
        #expect(classifierHistory.contains("Réponse visible."))
        #expect(finalHistory.contains("Réponse visible."))
        #expect(!classifierHistory.contains("sujet secret"))
        #expect(!finalHistory.contains("sujet secret"))
    }

    // MARK: - Mode de réponse et budget du moteur (1.13, bug 6)

    @Test("Le mode mémorisé et le budget du moteur sont relus à CHAQUE envoi et transmis au pipeline")
    func modeAndBudgetAreReadAtEachSend() async {
        let settings = SendSettings()
        settings.configuration = .appleIntelligence
        let factory = OrchestratorFactoryRecorder()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, settings: settings, factory: factory)

        await viewModel.send(query: "premier")
        settings.mode = .deep
        settings.configuration = .mlxCompact
        await viewModel.send(query: "second")

        #expect(factory.modes == [.quick, .deep])
        #expect(factory.configurations == [.appleIntelligence, .mlxCompact])
    }

    @Test("Sans injection : budget le plus serré (.appleIntelligence), conversation vierge, rien de persisté")
    func defaultsAreSafe() async throws {
        let factory = OrchestratorFactoryRecorder()
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager },
            readResponseMode: { .quick },
            makeOrchestrator: { inputs in
                factory.record(inputs)
                return Self.deterministicOrchestrator(inputs)
            },
            generateSuggestions: { _, _ in [] }
        )
        // Décision 1 de Ben : au lancement, conversation vierge.
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.currentConversationID == nil)
        #expect(viewModel.attachmentController.attachments.isEmpty)

        await viewModel.send(query: "Bonjour")

        #expect(factory.configurations == [.appleIntelligence])
        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.storedMessageID == nil)
        #expect(viewModel.currentConversationID == nil)
        #expect(!viewModel.canToggleFavorite(answer))
        #expect(!viewModel.loadConversation(id: UUID()))
    }

    @Test("Mode mémorisé : Rapide par défaut, puis celui que le sélecteur a écrit (décision 6)")
    func persistedModeDefaultsToQuickThenFollowsTheSelector() throws {
        let suiteName = "ChatViewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ChatViewModel.persistedResponseMode(in: defaults) == .quick)
        ResponseModeSettingsStore(userDefaults: defaults).selectedMode = .reliable
        #expect(ChatViewModel.persistedResponseMode(in: defaults) == .reliable)
    }

    // MARK: - Mode Fiable sans source fiable (décision (c))

    @Test("Mode Fiable, toutes les sources filtrées : état .noReliableSources, aucune génération, aucune erreur, état persisté")
    func reliableModeWithoutTrustedSourceShowsTheFixedState() async throws {
        let stores = try PersistenceStores()
        let settings = SendSettings()
        settings.mode = .reliable
        let suggestions = SuggestionsRecorder(result: ["Suggestion"])
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse sans source."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(Self.untrustedResults)),
            settings: settings,
            stores: stores,
            suggestions: suggestions
        )

        await viewModel.send(query: "Que pensent les gens de ce film ?")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .noReliableSources)
        #expect(answer.text.isEmpty)
        #expect(answer.sources.isEmpty)
        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.canRetryInQuickMode(answer))
        #expect(ChatViewModel.noReliableSourcesMessage == "Aucune source fiable pour ce type de question.")
        try? await Task.sleep(for: .milliseconds(10))
        #expect(suggestions.histories.isEmpty)
        // Aucune requête au moteur (l'orchestrateur ne génère pas).
        #expect(aiProvider.receivedStreamPrompts.isEmpty)
        // Décision de Ben (2026-10-30) : l'état est persisté après la question.
        let conversation = try #require(try stores.onlyConversation())
        #expect(conversation.orderedMessages.map(\.role) == [.user, .assistant])
        #expect(conversation.orderedMessages.last?.reportsNoReliableSources == true)
        #expect(answer.storedMessageID == conversation.orderedMessages.last?.id)
        #expect(!viewModel.canToggleFavorite(answer))
    }

    @Test("Une conversation relue montre l'état « Aucune source fiable » et propose encore la relance")
    func reloadedNoReliableSourcesStateIsShownWithItsRetry() async throws {
        let stores = try PersistenceStores()
        let conversation = try stores.history.createConversation(firstQuestion: "Que pensent les gens de ce film ?")
        try stores.history.appendUserMessage(to: conversation, text: "Que pensent les gens de ce film ?")
        let stored = try stores.history.appendNoReliableSourcesMessage(
            to: conversation, text: ChatViewModel.noReliableSourcesMessage
        )
        let viewModel = makeViewModel(resolveProvider: { MockStreamingAIGenerating(chunks: ["x"]) }, stores: stores)

        #expect(viewModel.loadConversation(id: conversation.id))

        let restored = try #require(viewModel.messages.last)
        #expect(restored.status == .noReliableSources)
        #expect(restored.text.isEmpty)
        #expect(restored.storedMessageID == stored.id)
        #expect(viewModel.canRetryInQuickMode(restored))
        #expect(!viewModel.canToggleFavorite(restored))
        // Jamais dans l'historique du classifieur.
        #expect(ChatViewModel.classifierHistory(from: viewModel.messages).isEmpty)
    }

    @Test("« Relancer en mode Rapide » répond à la MÊME question en Rapide, sans la réécrire ni changer le mode mémorisé")
    func retryInQuickModeAnswersTheSameQuestion() async throws {
        let stores = try PersistenceStores()
        let settings = SendSettings()
        settings.mode = .reliable
        let factory = OrchestratorFactoryRecorder()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse rapide[1]."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(Self.untrustedResults)),
            settings: settings,
            stores: stores,
            factory: factory
        )
        await viewModel.send(query: "Que pensent les gens de ce film ?")
        let answerID = try #require(viewModel.messages.last?.id)

        await viewModel.retryInQuickMode(messageID: answerID)

        #expect(factory.modes == [.reliable, .quick])
        #expect(settings.mode == .reliable)
        #expect(viewModel.messages.count == 2)
        let answer = try #require(viewModel.messages.last)
        #expect(answer.id == answerID)
        #expect(answer.status == .completed)
        #expect(answer.text == "Réponse rapide[1].")
        #expect(answer.sources == Self.untrustedResults)
        #expect(aiProvider.receivedStreamPrompts.last?.contains("Que pensent les gens de ce film ?") == true)
        let conversation = try #require(try stores.onlyConversation())
        #expect(conversation.orderedMessages.map(\.text) == ["Que pensent les gens de ce film ?", "Réponse rapide[1]."])
    }

    @Test("La relance n'est proposée que sur la DERNIÈRE réponse (sinon elle serait persistée hors ordre)")
    func retryIsOnlyOfferedOnTheLastAnswer() async throws {
        let settings = SendSettings()
        settings.mode = .reliable
        let factory = OrchestratorFactoryRecorder()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(Self.untrustedResults)),
            settings: settings,
            factory: factory
        )
        await viewModel.send(query: "Question discussion")
        settings.mode = .quick
        await viewModel.send(query: "Question suivante")

        let olderAnswer = viewModel.messages[1]
        #expect(olderAnswer.status == .noReliableSources)
        #expect(!viewModel.canRetryInQuickMode(olderAnswer))
        #expect(!viewModel.canRetryInQuickMode(viewModel.messages[3]))

        await viewModel.retryInQuickMode(messageID: olderAnswer.id)

        #expect(viewModel.messages[1].status == .noReliableSources)
        #expect(factory.modes == [.reliable, .quick])
    }

    @Test("L'état sans source fiable exige le mode Fiable, une vraie recherche, et rien à montrer (ni source ni widget)")
    func lacksReliableSourcesRequiresAnEmptyReliableSearch() {
        func artifacts(
            mode: ResponseMode = .reliable,
            searched: Bool = true,
            sources: [SearXNGSearchResult] = [],
            widgets: [SearchWidgetOutput] = []
        ) -> SearchArtifacts {
            SearchArtifacts(
                sources: sources, attachmentSourceCount: 0, widgets: widgets,
                images: .notRequested, videos: .notRequested, mode: mode, promptComplexity: .full,
                citableSourceCount: sources.count, searchPerformed: searched, searchQuery: "q"
            )
        }
        #expect(ChatViewModel.lacksReliableSources(artifacts()))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(mode: .quick)))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(mode: .deep)))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(searched: false)))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(sources: Self.untrustedResults)))
        #expect(!ChatViewModel.lacksReliableSources(artifacts(widgets: [SearchWidgetOutput(kind: .calculation, llmContext: "84")])))
    }

    // MARK: - Historique persistant (1.9)

    @Test("La question est écrite à l'envoi, la réponse UNE fois à la fin (aucune écriture par snapshot)")
    func questionIsSavedAtSendAndTheAnswerOnceAtTheEnd() async throws {
        let stores = try PersistenceStores()
        let results = [Self.makeResult(title: "Japon", url: "https://ja.example", content: "Tokyo")]
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(results)),
            stores: stores
        )

        let task = Task { await viewModel.send(query: "Quelle est la capitale du Japon ?") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        let conversation = try #require(try stores.onlyConversation())
        #expect(conversation.orderedMessages.map(\.role) == [.user])
        #expect(viewModel.currentConversationID == conversation.id)
        let revisionWhileStreaming = stores.history.revision

        for snapshot in ["Tokyo", "Tokyo est", "Tokyo est la capitale[1]."] {
            continuation.yield(snapshot)
            await waitUntil("snapshot « \(snapshot) » affiché") { viewModel.messages.last?.text == snapshot }
        }
        #expect(stores.history.revision == revisionWhileStreaming)

        continuation.finish()
        await task.value

        #expect(stores.history.revision == revisionWhileStreaming + 1)
        let saved = try #require(try stores.history.conversation(with: conversation.id)).orderedMessages
        #expect(saved.map(\.role) == [.user, .assistant])
        #expect(saved.last?.text == "Tokyo est la capitale[1].")
        #expect(saved.last?.orderedSources.map(\.url) == results.map(\.url))
        let answer = try #require(viewModel.messages.last)
        #expect(answer.storedMessageID == saved.last?.id)
        #expect(answer.storedConversationID == conversation.id)
    }

    @Test("Une réponse arrêtée est persistée telle quelle ; une réponse vide ne l'est jamais")
    func stoppedAnswerIsSavedButAnEmptyOneIsNot() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)

        let task = Task { await viewModel.send(query: "Question longue") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Début de réponse")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Début de réponse" }
        task.cancel()
        await task.value

        let stopped = try #require(try stores.onlyConversation())
        #expect(stopped.orderedMessages.map(\.text) == ["Question longue", "Début de réponse"])

        let emptyStores = try PersistenceStores()
        let emptyProvider = MockStreamingAIGenerating(chunks: [])
        let emptyViewModel = makeViewModel(resolveProvider: { emptyProvider }, stores: emptyStores)
        await emptyViewModel.send(query: "Question sans réponse")
        let unanswered = try #require(try emptyStores.onlyConversation())
        #expect(unanswered.orderedMessages.map(\.role) == [.user])
    }

    @Test("Une conversation relue s'affiche terminée, sources dans l'ordre, et la suite s'y ajoute avec son contexte")
    func reloadedConversationIsShownAndContinued() async throws {
        let stores = try PersistenceStores()
        let conversation = try stores.history.createConversation(firstQuestion: "Qui a écrit Germinal ?")
        try stores.history.appendUserMessage(to: conversation, text: "Qui a écrit Germinal ?")
        let attachmentSource = Self.makeResult(
            title: "notes.txt", url: UploadsSearchResultBuilder.sourceURL(for: UUID()), content: "Mes notes de lecture."
        )
        let webSource = Self.makeResult(title: "Germinal", url: "https://fr.wikipedia.org/wiki/Germinal", content: "Roman d'Émile Zola.")
        let storedAnswer = try stores.history.appendAssistantMessage(
            to: conversation, text: "<think>Je vérifie.</think>Émile Zola[2].", sources: [attachmentSource, webSource]
        )
        let aiProvider = MockStreamingAIGenerating(chunks: ["En 1885."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)

        let loaded = viewModel.loadConversation(id: conversation.id)

        #expect(loaded)
        #expect(viewModel.currentConversationID == conversation.id)
        #expect(viewModel.messages.map(\.role) == [.user, .assistant])
        let restored = viewModel.messages[1]
        #expect(restored.status == .completed)
        #expect(restored.storedMessageID == storedAnswer.id)
        #expect(restored.sources.map(\.url) == [attachmentSource.url, webSource.url])
        #expect(restored.attachmentSourceCount == 1)
        #expect(restored.segments.body == "Émile Zola[2].")

        await viewModel.send(query: "Et en quelle année ?")

        let classifierHistory = try #require(taggedBlock("conversation_history", in: aiProvider.classifierPrompts.last))
        #expect(classifierHistory.contains("Qui a écrit Germinal ?"))
        #expect(classifierHistory.contains("Émile Zola"))
        #expect(!classifierHistory.contains("Je vérifie"))
        let continued = try #require(try stores.onlyConversation())
        #expect(continued.id == conversation.id)
        #expect(continued.orderedMessages.count == 4)
    }

    @Test("Recharger une conversation introuvable échoue sans toucher au fil, avec un message")
    func loadingAMissingConversationKeepsTheThread() async throws {
        let stores = try PersistenceStores()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        await viewModel.send(query: "Bonjour")
        let thread = viewModel.messages

        let loaded = viewModel.loadConversation(id: UUID())

        #expect(!loaded)
        #expect(viewModel.persistenceErrorDescription == ChatViewModel.missingConversationMessage)
        #expect(viewModel.messages == thread)
    }

    @Test("Supprimer la conversation du fil depuis la Bibliothèque fait repartir le chat à neuf ; une autre suppression n'y touche pas")
    func deletingTheOpenConversationResetsTheChat() async throws {
        let stores = try PersistenceStores()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        await viewModel.send(query: "Bonjour")
        let openID = try #require(viewModel.currentConversationID)

        viewModel.conversationWasDeleted(id: UUID())
        #expect(viewModel.messages.count == 2)

        try stores.history.delete(try #require(try stores.history.conversation(with: openID)))
        viewModel.conversationWasDeleted(id: openID)
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.currentConversationID == nil)

        await viewModel.send(query: "Nouvelle question")
        let fresh = try #require(try stores.onlyConversation())
        #expect(fresh.id != openID)
        #expect(viewModel.currentConversationID == fresh.id)
    }

    // MARK: - Nouvelle conversation (décision 1 de Ben)

    @Test("« Nouvelle conversation » en plein flux : arrêt sans erreur, fil vidé, réponse partielle dans l'ANCIENNE conversation")
    func newConversationStopsTheAnswerAndKeepsItInTheOldOne() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)

        let task = Task { await viewModel.send(query: "Première question") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Réponse partielle")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Réponse partielle" }
        let oldID = try #require(viewModel.currentConversationID)

        viewModel.startNewConversation()

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.currentConversationID == nil)
        // L'échange annulé finit de se dérouler : rien ne fuit dans le nouveau
        // fil, sa réponse partielle rejoint l'ancienne conversation.
        await task.value
        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.errorDescription == nil)
        let old = try #require(try stores.history.conversation(with: oldID))
        #expect(old.orderedMessages.map(\.text) == ["Première question", "Réponse partielle"])

        let nextTask = Task { await viewModel.send(query: "Deuxième question") }
        await waitUntil("2e flux ouvert") { aiProvider.receivedPrompts.count == 2 }
        aiProvider.continuation?.yield("Autre réponse")
        aiProvider.continuation?.finish()
        await nextTask.value

        #expect(viewModel.messages.map(\.text) == ["Deuxième question", "Autre réponse"])
        #expect(try stores.history.conversations().count == 2)
        #expect(viewModel.currentConversationID != oldID)
        // Le 2e prompt ne contient rien de l'ancienne conversation.
        #expect(aiProvider.receivedPrompts.last?.contains("Première question") == false)
    }

    // MARK: - Favoris (1.10)

    @Test("Un favori est rattaché à l'id PERSISTANT de la réponse, jamais à l'UUID de la bulle ; retirer le défait")
    func favoriteIsKeyedToTheStoredMessage() async throws {
        let stores = try PersistenceStores()
        let results = [Self.makeResult(title: "Japon", url: "https://ja.example", content: "Tokyo")]
        let aiProvider = MockStreamingAIGenerating(chunks: ["<think>Je cherche.</think>Tokyo[1]."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(results)),
            stores: stores
        )
        await viewModel.send(query: "Capitale du Japon ?")
        let answer = try #require(viewModel.messages.last)
        let storedID = try #require(answer.storedMessageID)
        #expect(storedID != answer.id)
        #expect(viewModel.canToggleFavorite(answer))
        #expect(!viewModel.canToggleFavorite(viewModel.messages[0]))
        #expect(!viewModel.isFavorite(answer))

        viewModel.toggleFavorite(messageID: answer.id)

        #expect(viewModel.isFavorite(answer))
        #expect(try stores.favorites.favoritedMessageIDs() == [storedID])
        let favorite = try #require(try stores.favorites.favorite(forMessageID: storedID))
        #expect(favorite.question == "Capitale du Japon ?")
        #expect(favorite.answer == "<think>Je cherche.</think>Tokyo[1].")
        #expect(favorite.conversationID == viewModel.currentConversationID)
        #expect(favorite.orderedSources.map(\.url) == results.map(\.url))

        viewModel.toggleFavorite(messageID: answer.id)

        #expect(!viewModel.isFavorite(answer))
        #expect(try stores.favorites.favoritedMessageIDs().isEmpty)
    }

    @Test("Pas de favori pendant le streaming, ni sans historique (rien de persistant à quoi le rattacher)")
    func favoriteIsRefusedWhileStreamingAndWithoutHistory() async throws {
        let stores = try PersistenceStores()
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        let task = Task { await viewModel.send(query: "Question") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Début")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Début" }
        let streaming = try #require(viewModel.messages.last)

        #expect(!viewModel.canToggleFavorite(streaming))
        viewModel.toggleFavorite(messageID: streaming.id)
        #expect(try stores.favorites.favoritedMessageIDs().isEmpty)
        continuation.finish()
        await task.value

        let plainProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let withoutHistory = makeViewModel(resolveProvider: { plainProvider })
        await withoutHistory.send(query: "Question")
        let answer = try #require(withoutHistory.messages.last)
        #expect(answer.storedMessageID == nil)
        #expect(!withoutHistory.canToggleFavorite(answer))
    }

    @Test("L'étoile survit au rechargement de la conversation, et se retire depuis le fil relu")
    func favoriteSurvivesAReload() async throws {
        let stores = try PersistenceStores()
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, stores: stores)
        await viewModel.send(query: "Question")
        viewModel.toggleFavorite(messageID: try #require(viewModel.messages.last?.id))
        let conversationID = try #require(viewModel.currentConversationID)

        viewModel.startNewConversation()
        let loaded = viewModel.loadConversation(id: conversationID)

        #expect(loaded)
        let reloaded = try #require(viewModel.messages.last)
        #expect(viewModel.isFavorite(reloaded))
        viewModel.toggleFavorite(messageID: reloaded.id)
        #expect(try stores.favorites.favoritedMessageIDs().isEmpty)
    }

    // MARK: - Suggestions (1.7)

    @Test("Les suggestions arrivent APRÈS une réponse aboutie, à partir de la question et de la réponse VISIBLE")
    func suggestionsFollowACompletedAnswer() async throws {
        let suggestions = SuggestionsRecorder(result: ["Et à Osaka ?", "Quelle population ?"])
        let aiProvider = MockStreamingAIGenerating(chunks: ["<think>Réflexion privée.</think>Tokyo."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, suggestions: suggestions)

        await viewModel.send(query: "Capitale du Japon ?")
        await waitUntil("suggestions affichées") { viewModel.messages.last?.suggestions == ["Et à Osaka ?", "Quelle population ?"] }

        let history = try #require(suggestions.histories.first)
        #expect(suggestions.histories.count == 1)
        #expect(history.map(\.role) == [.user, .assistant])
        #expect(history.map(\.content) == ["Capitale du Japon ?", "Tokyo."])
        #expect(viewModel.errorDescription == nil)
    }

    @Test("Pas de suggestions après un échec ou une réponse vide")
    func noSuggestionsWithoutACompletedAnswer() async {
        let failing = MockStreamingAIGenerating(chunks: ["partiel"], midStreamFailure: MockError.midStreamFailure)
        let empty = MockStreamingAIGenerating(chunks: [])
        for aiProvider in [failing, empty] {
            let suggestions = SuggestionsRecorder(result: ["Suggestion"])
            let viewModel = makeViewModel(resolveProvider: { aiProvider }, suggestions: suggestions)

            await viewModel.send(query: "requête")
            try? await Task.sleep(for: .milliseconds(10))

            #expect(suggestions.histories.isEmpty)
            #expect(viewModel.messages.last?.suggestions.isEmpty == true)
        }
    }

    @Test("La question suivante annule les suggestions encore en cours : elles n'apparaissent jamais sous l'ancienne réponse")
    func nextQuestionCancelsPendingSuggestions() async throws {
        let suggestions = SuggestionsRecorder(result: ["Suggestion"], delays: [.seconds(30)])
        let aiProvider = MockStreamingAIGenerating(chunks: ["Réponse."])
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, suggestions: suggestions)

        await viewModel.send(query: "Première question")
        await waitUntil("1res suggestions demandées") { suggestions.histories.count == 1 }
        await viewModel.send(query: "Deuxième question")
        await waitUntil("suggestions de la 2e réponse") { viewModel.messages.last?.suggestions == ["Suggestion"] }
        await waitUntil("1re demande rendue") { suggestions.cancellationByQuestion.count == 2 }

        #expect(suggestions.cancellationByQuestion["Première question"] == true)
        #expect(suggestions.cancellationByQuestion["Deuxième question"] == false)
        #expect(viewModel.messages[1].suggestions.isEmpty)
    }

    @Test("Des suggestions en échec n'affichent JAMAIS d'erreur : le service réel rend [] et la réponse reste aboutie")
    func failingSuggestionsNeverShowAnError() async {
        let aiProvider = SuggestionsFailingProvider()
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let viewModel = ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager },
            readResponseMode: { .quick },
            makeOrchestrator: { Self.deterministicOrchestrator($0) }
        )

        await viewModel.send(query: "requête")
        await waitUntil("le service réel a interrogé le provider") { aiProvider.failedSuggestionCalls == 1 }
        try? await Task.sleep(for: .milliseconds(10))

        #expect(viewModel.errorDescription == nil)
        #expect(viewModel.messages.last?.status == .completed)
        #expect(viewModel.messages.last?.suggestions.isEmpty == true)
    }

    // MARK: - Médias à la demande (1.6, décision (a))

    @Test("Aucun média n'est cherché pendant l'envoi ; le bouton lance la recherche sur la reformulation du classifieur")
    func mediaIsOnlySearchedOnDemand() async throws {
        let image = ImageSearchResult(
            imageURL: try #require(URL(string: "https://img.example/tour.jpg")),
            sourceURL: try #require(URL(string: "https://img.example/page")),
            title: "Tour Eiffel"
        )
        let media = RecordingMediaSearcher(images: [image])
        let aiProvider = MockStreamingAIGenerating(
            chunks: ["Elle mesure 330 mètres."],
            classification: classificationJSON(standaloneFollowUp: "hauteur tour Eiffel")
        )
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, media: media)

        await viewModel.send(query: "Elle mesure combien ?")

        #expect(await media.imageQueries.isEmpty)
        #expect(await media.videoQueries.isEmpty)
        let answer = try #require(viewModel.messages.last)
        #expect(answer.images == .idle)
        #expect(answer.videos == .idle)
        #expect(answer.searchQuery == "hauteur tour Eiffel")

        viewModel.searchImages(messageID: answer.id)

        #expect(viewModel.messages.last?.images == .loading)
        await waitUntil("images chargées") { viewModel.messages.last?.images == .loaded([image]) }
        #expect(await media.imageQueries == ["hauteur tour Eiffel"])
        #expect(viewModel.messages.last?.videos == .idle)
    }

    @Test("Une recherche média en échec affiche .failed, jamais d'erreur ; aucune recherche média pendant le streaming")
    func mediaFailureAndStreamingGuard() async throws {
        let media = RecordingMediaSearcher(failure: .mediaFailed)
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider }, media: media)
        let task = Task { await viewModel.send(query: "Vidéos de chats") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Début")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Début" }
        let answerID = try #require(viewModel.messages.last?.id)

        viewModel.searchVideos(messageID: answerID)
        #expect(viewModel.messages.last?.videos == .idle)

        continuation.finish()
        await task.value
        #expect(await media.videoQueries.isEmpty)

        viewModel.searchVideos(messageID: answerID)
        await waitUntil("échec affiché") { viewModel.messages.last?.videos == .failed }
        #expect(viewModel.errorDescription == nil)
    }

    // MARK: - Fichiers joints (1.11, décision (b))

    @Test("Un fichier joint s'affiche sous SA question, puis est consulté à chaque question (Rapide, sans personalSearch)")
    func attachedFilesGoWithTheirQuestionAndAreAlwaysConsulted() async throws {
        let store = AttachmentStore(scorer: ConstantSimilarityScorer(), preparer: StubAttachmentPreparer())
        let attachment = try await store.attach(fileAt: URL(fileURLWithPath: "/Tests/rapport.txt"))
        let controller = FileAttachmentController(store: store)
        let results = [Self.makeResult(title: "Web", url: "https://web.example", content: "Contenu web")]
        let aiProvider = MockStreamingAIGenerating(chunks: ["Hausse de 12 %[1]."])
        let viewModel = makeViewModel(
            resolveProvider: { aiProvider },
            client: MockSearXNGClient(response: Self.response(results)),
            attachmentController: controller
        )

        await viewModel.send(query: "Que dit le rapport ?")

        #expect(viewModel.messages[0].attachedFiles == [
            ChatViewModel.Message.AttachedFile(id: attachment.id, fileName: "rapport.txt", kind: .plainText),
        ])
        let first = viewModel.messages[1]
        #expect(first.attachmentSourceCount == 1)
        #expect(first.sources.first.flatMap { UploadsSearchResultBuilder.attachmentID(fromSourceURL: $0.url) } == attachment.id)
        #expect(first.sources.dropFirst().map(\.url) == results.map(\.url))

        await viewModel.send(query: "Et le chiffre d'affaires ?")

        #expect(viewModel.messages[2].attachedFiles.isEmpty)
        #expect(viewModel.messages[3].attachmentSourceCount == 1)

        viewModel.startNewConversation()
        #expect(viewModel.attachmentController.attachments.isEmpty)
    }

    // MARK: - Validateur de structure (1.4)

    @Test("Le diagnostic de structure n'existe qu'une fois la réponse terminée")
    func structureReportIsComputedOnceTheAnswerIsComplete() async throws {
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(resolveProvider: { aiProvider })
        let task = Task { await viewModel.send(query: "requête") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            task.cancel()
            return
        }
        continuation.yield("Début")
        await waitUntil("1er snapshot affiché") { viewModel.messages.last?.text == "Début" }
        #expect(viewModel.messages.last?.structureReport == nil)

        continuation.yield("Réponse complète.")
        continuation.finish()
        await task.value

        #expect(viewModel.messages.last?.structureReport != nil)
    }
}
