//
//  OfflineModeTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Network
import Synchronization
import Testing
@testable import Triva

// MARK: - Doublures

/// Source de connexion pilotée à la main : le test pousse les états.
private struct ManualConnectivitySource: ConnectivitySource {
    let stream: AsyncStream<ConnectivityStatus>

    func updates() -> AsyncStream<ConnectivityStatus> { stream }
}

/// Client SearXNG qui compte ses appels : hors connexion, ce compte doit rester à zéro.
private final class CountingSearXNGClient: SearXNGSearching, Sendable {
    private let calls = Mutex(0)
    private let results: [SearXNGSearchResult]

    init(results: [SearXNGSearchResult] = []) {
        self.results = results
    }

    var callCount: Int { calls.withLock { $0 } }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        calls.withLock { $0 += 1 }
        return SearXNGSearchResponse(results: results, suggestions: [])
    }
}

/// Modèle qui répond toujours la même chose ; `classification` sert aux appels de classification.
private final class OfflineScriptedProvider: AIGenerating {
    private(set) var streamPrompts: [String] = []
    private let answer: String
    private let classification: String

    init(answer: String = "Réponse du modèle local.", classification: String = "") {
        self.answer = answer
        self.classification = classification
    }

    func generate(prompt: String) async throws -> String {
        prompt.contains("<user_query>") ? classification : ""
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        streamPrompts.append(prompt)
        let answer = answer
        return AsyncThrowingStream { continuation in
            continuation.yield(answer)
            continuation.finish()
        }
    }
}

private struct OfflineUnreadableScrape: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

private struct OfflineConstantSimilarity: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

private struct OfflineNoDuplicate: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

private struct OfflineNoLanguage: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

/// Widget factice : compte ses exécutions (la météo ne doit JAMAIS tourner hors connexion).
private final class CountingWidget: SearchWidget, Sendable {
    let kind: SearchWidgetKind
    private let executions = Mutex(0)
    private let output: SearchWidgetOutput

    init(kind: SearchWidgetKind, llmContext: String) {
        self.kind = kind
        self.output = SearchWidgetOutput(kind: kind, llmContext: llmContext)
    }

    var executionCount: Int { executions.withLock { $0 } }

    func shouldExecute(for classification: QueryClassification) -> Bool {
        switch kind {
        case .weather: classification.showWeatherWidget
        case .calculation: classification.showCalculationWidget
        }
    }

    func execute(_ input: SearchWidgetInput) async throws -> SearchWidgetOutput? {
        executions.withLock { $0 += 1 }
        return output
    }
}

/// JSON valide pour `QueryClassifier.parse`.
private func offlineClassification(weather: Bool = false, calculation: Bool = false) -> String {
    """
    {"classification":{"skipSearch":false,"personalSearch":false,"academicSearch":false,\
    "discussionSearch":false,"showWeatherWidget":\(weather),"showStockWidget":false,\
    "showCalculationWidget":\(calculation)},"standaloneFollowUp":"question"}
    """
}

@MainActor
private func waitFor(_ message: String, _ condition: () -> Bool) async {
    for _ in 0..<2_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timeout : \(message)")
}

// MARK: - Moniteur de connexion

@MainActor
@Suite("ConnectivityMonitor — détection native, source injectée (tâche 1.16)")
struct ConnectivityMonitorTests {
    @Test("Les états du système sont traduits : seul « non satisfait » vaut hors connexion")
    func pathStatusMapping() {
        #expect(ConnectivityStatus(.satisfied) == .online)
        #expect(ConnectivityStatus(.unsatisfied) == .offline)
        #expect(ConnectivityStatus(.requiresConnection) == .unknown)
    }

    @Test("Avant toute mesure, l'état est inconnu et n'est PAS hors connexion")
    func unknownIsNotOffline() {
        let monitor = ConnectivityMonitor(
            source: FixedConnectivitySource(status: .unknown), startsImmediately: false
        )
        #expect(monitor.status == .unknown)
        #expect(!monitor.isOffline)
    }

    @Test("Les états poussés par la source sont suivis, dans les deux sens")
    func followsTheSource() async {
        let (stream, continuation) = AsyncStream<ConnectivityStatus>.makeStream()
        let monitor = ConnectivityMonitor(source: ManualConnectivitySource(stream: stream))

        continuation.yield(.offline)
        await waitFor("passage hors connexion") { monitor.isOffline }
        #expect(monitor.status == .offline)

        continuation.yield(.online)
        await waitFor("retour de la connexion") { !monitor.isOffline }
        #expect(monitor.status == .online)
        monitor.stop()
    }

    @Test("Arrêté, le moniteur garde son dernier état et n'écoute plus")
    func stopKeepsLastStatus() async {
        let (stream, continuation) = AsyncStream<ConnectivityStatus>.makeStream()
        let monitor = ConnectivityMonitor(source: ManualConnectivitySource(stream: stream))
        continuation.yield(.offline)
        await waitFor("hors connexion") { monitor.isOffline }

        monitor.stop()
        continuation.yield(.online)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(monitor.status == .offline)
    }

    @Test("Source figée : l'état donné, et le moniteur partagé est figé sur « inconnu » sous les tests")
    func fixedSourceAndSharedUnderTests() async {
        let monitor = ConnectivityMonitor(source: FixedConnectivitySource(status: .offline))
        await waitFor("état figé") { monitor.isOffline }
        monitor.stop()
        #expect(ConnectivityMonitor.shared.status == .unknown)
    }
}

// MARK: - Plan hors connexion et modèle MLX sur disque

@Suite("OfflinePlan — que faire sans connexion, selon le moteur")
struct OfflinePlanTests {
    @Test("Apple Intelligence répond sans recherche ; MLX seulement si le modèle est là ; le cloud est bloqué")
    func planPerEngine() {
        #expect(OfflinePlan.resolve(engine: .appleIntelligence, localModelAvailable: false) == .answerWithoutSearch)
        #expect(OfflinePlan.resolve(engine: .mlxLocal, localModelAvailable: true) == .answerWithoutSearch)
        #expect(OfflinePlan.resolve(engine: .mlxLocal, localModelAvailable: false) == .blocked(.localModelUnavailable))
        #expect(OfflinePlan.resolve(engine: .cloudBYOK, localModelAvailable: true) == .blocked(.cloudKey))
    }

    @Test("Seul le mode Fiable propose de répondre sans source")
    func onlyReliableOffersQuickAnswer() {
        #expect(OfflineBlockReason.reliableMode.offersQuickModeAnswer)
        #expect(!OfflineBlockReason.cloudKey.offersQuickModeAnswer)
        #expect(!OfflineBlockReason.localModelUnavailable.offersQuickModeAnswer)
        #expect(!OfflineBlockReason.weather.offersQuickModeAnswer)
    }

    @Test("Chaque message est fixe, commence par « Hors connexion » et ne laisse aucun détail technique")
    func messagesAreFixed() {
        let reasons: [OfflineBlockReason] = [.cloudKey, .localModelUnavailable, .reliableMode, .weather]
        for reason in reasons {
            #expect(reason.message.hasPrefix("Hors connexion"))
            #expect(!reason.message.contains("http"))
            #expect(!reason.message.contains("Error"))
        }
        #expect(Set(reasons.map(\.message)).count == reasons.count)
    }

    @Test("La ligne d'état dit la vérité de chaque plan")
    func statusLineMentionsTheTruth() {
        #expect(OfflinePlan.answerWithoutSearch.statusText.contains("sans source"))
        #expect(OfflinePlan.blocked(.cloudKey).statusText.contains("fournisseur"))
        #expect(OfflinePlan.blocked(.localModelUnavailable).statusText.contains("modèle local"))
    }
}

@Suite("MLXProvider.hasDownloadedWeights — modèle entièrement sur le disque ?")
struct MLXWeightsAvailabilityTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mlx-weights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Dossier absent ou vide : pas de modèle")
    func missingOrEmpty() throws {
        let empty = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(!MLXProvider.hasDownloadedWeights(in: empty))
        #expect(!MLXProvider.hasDownloadedWeights(in: empty.appending(path: "inexistant")))
    }

    @Test("Un fichier .safetensors lisible suffit, même rangé dans un sous-dossier")
    func weightsFileCounts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appending(path: "snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data([0]).write(to: snapshot.appending(path: "model.safetensors"))
        #expect(MLXProvider.hasDownloadedWeights(in: root))
    }

    @Test("Téléchargement interrompu (.incomplete) ou lien cassé : pas de modèle")
    func partialDownloadDoesNotCount() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root.appending(path: "model.safetensors.incomplete"))
        try Data([0]).write(to: root.appending(path: "config.json"))
        let target = root.appending(path: "absent-blob")
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "model.safetensors"), withDestinationURL: target
        )
        #expect(!MLXProvider.hasDownloadedWeights(in: root))
    }
}

// MARK: - Orchestrateur et artefacts

@Suite("SearchOrchestrator — aiguillage hors connexion")
struct OfflineRoutingTests {
    @Test("Hors connexion, les routes web deviennent « aucune recherche » ; les fichiers joints gardent la main")
    func webRoutesAreDropped() {
        let offlineWeb = SearchOrchestrator.routeAvailable(.web(.general), isOffline: true, hasAttachments: false)
        let offlineWeather = SearchOrchestrator.routeAvailable(.webUnlessWeatherAnswered, isOffline: true, hasAttachments: false)
        #expect(offlineWeb == .none)
        #expect(offlineWeather == .none)
        #expect(SearchOrchestrator.routeAvailable(.web(.general), isOffline: true, hasAttachments: true) == .attachments)
        #expect(SearchOrchestrator.routeAvailable(.none, isOffline: true, hasAttachments: false) == .none)
        #expect(SearchOrchestrator.routeAvailable(.attachments, isOffline: true, hasAttachments: true) == .attachments)
    }

    @Test("En ligne, la route est inchangée")
    func onlineRouteUntouched() {
        #expect(SearchOrchestrator.routeAvailable(.web(.general), isOffline: false, hasAttachments: false) == .web(.general))
        #expect(SearchOrchestrator.routeAvailable(.webUnlessWeatherAnswered, isOffline: false, hasAttachments: false) == .webUnlessWeatherAnswered)
    }

    @Test("Hors connexion, la météo quitte la liste des widgets, le calcul reste")
    func weatherWidgetIsRemoved() {
        let widgets: [any SearchWidget] = [
            CountingWidget(kind: .weather, llmContext: "météo"),
            CountingWidget(kind: .calculation, llmContext: "calcul"),
        ]
        #expect(SearchOrchestrator.widgetsAvailable(widgets, isOffline: true).map(\.kind) == [.calculation])
        #expect(SearchOrchestrator.widgetsAvailable(widgets, isOffline: false).map(\.kind) == [.weather, .calculation])
    }
}

// MARK: - ChatViewModel hors connexion (moniteur remplacé par un plan injecté)

/// Pilote le « réseau » d'un test : le plan courant (`nil` = connecté) et ce que le ViewModel a sollicité.
@MainActor
private final class OfflineHarness {
    var plan: OfflinePlan?
    var mode: ResponseMode = .quick
    var providerResolutions = 0
    var providerError: (any Error)?
    let client: CountingSearXNGClient
    let provider: OfflineScriptedProvider
    let widgets: [any SearchWidget]

    init(
        plan: OfflinePlan?,
        mode: ResponseMode = .quick,
        provider: OfflineScriptedProvider = OfflineScriptedProvider(),
        client: CountingSearXNGClient = CountingSearXNGClient(),
        widgets: [any SearchWidget] = []
    ) {
        self.plan = plan
        self.mode = mode
        self.provider = provider
        self.client = client
        self.widgets = widgets
    }

    func makeViewModel() -> ChatViewModel {
        let failoverManager = FailoverManager(client: client, instances: [URL(string: "https://searxng.example")!])
        let widgets = widgets
        return ChatViewModel(
            resolveProvider: { [self] in
                providerResolutions += 1
                if let providerError { throw providerError }
                return provider
            },
            resolveFailoverManager: { failoverManager },
            resolveOfflinePlan: { [self] in plan },
            resolvePipelineConfiguration: { .cloud },
            readResponseMode: { [self] in mode },
            makeOrchestrator: { inputs in
                SearchOrchestrator(
                    failoverManager: inputs.failoverManager,
                    aiProvider: inputs.provider,
                    responseMode: inputs.responseMode,
                    configuration: inputs.configuration,
                    scrapeService: OfflineUnreadableScrape(),
                    sourceRanker: SourceRanker(
                        relevanceScorer: OfflineConstantSimilarity(),
                        duplicateScorer: OfflineNoDuplicate(),
                        languageIdentifier: OfflineNoLanguage()
                    ),
                    widgets: widgets,
                    isOffline: inputs.isOffline
                )
            },
            generateSuggestions: { _, _ in [] }
        )
    }
}

@MainActor
@Suite("ChatViewModel — mode hors connexion (tâche 1.16)")
struct ChatViewModelOfflineTests {
    private static let question = "Explique-moi la photosynthèse."

    @Test("Moteur local : réponse sans recherche, mention « Hors connexion », aucune citation, aucun appel réseau")
    func localEngineAnswersWithoutSearch() async throws {
        let harness = OfflineHarness(plan: .answerWithoutSearch)
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: Self.question)

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.text == "Réponse du modèle local.")
        #expect(answer.sources.isEmpty)
        #expect(answer.answeredOffline)
        #expect(viewModel.offlineNotice == nil)
        #expect(harness.client.callCount == 0)
        #expect(harness.provider.streamPrompts.count == 1)
    }

    @Test("La mention visible est « Hors connexion, sans source », et elle remplace « Réponse sans recherche »")
    func bubbleNoteIsOffline() throws {
        var message = ChatViewModel.Message(role: .assistant, text: "Texte.")
        message.answeredOffline = true
        message.answeredWithoutSearch = true
        let snapshot = MessageBubbleView.answerSnapshot(of: message)
        #expect(MessageBubblePresentation.answerNote(snapshot) == "Hors connexion, sans source")

        var online = ChatViewModel.Message(role: .assistant, text: "Texte.")
        online.answeredWithoutSearch = true
        #expect(MessageBubblePresentation.answerNote(MessageBubbleView.answerSnapshot(of: online)) == "Réponse sans recherche")
    }

    @Test("Clé cloud : aucune tentative (ni fournisseur, ni recherche), message clair, pas d'erreur réseau")
    func cloudKeyIsBlockedWithoutAnyAttempt() async throws {
        let harness = OfflineHarness(plan: .blocked(.cloudKey))
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: Self.question)

        #expect(harness.providerResolutions == 0)
        #expect(harness.client.callCount == 0)
        #expect(harness.provider.streamPrompts.isEmpty)
        #expect(viewModel.offlineNotice?.reason == .cloudKey)
        #expect(viewModel.errorDescription == nil)
        #expect(!viewModel.isGenerating)
        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .failed)
        #expect(answer.text.isEmpty)
        #expect(viewModel.messages.first?.text == Self.question)
    }

    @Test("Relance : refusée tant que le système annonce l'absence de connexion, acceptée au retour")
    func relaunchWaitsForTheConnection() async throws {
        let harness = OfflineHarness(plan: .blocked(.cloudKey))
        let viewModel = harness.makeViewModel()
        await viewModel.send(query: Self.question)
        #expect(!viewModel.canRelaunchAfterReconnect)

        await viewModel.retryAfterOffline()
        #expect(harness.providerResolutions == 0)
        #expect(viewModel.offlineNotice?.reason == .cloudKey)

        harness.plan = nil
        #expect(viewModel.canRelaunchAfterReconnect)
        await viewModel.retryAfterOffline()

        #expect(viewModel.offlineNotice == nil)
        #expect(harness.providerResolutions == 1)
        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(!answer.answeredOffline)
        // La MÊME question, pas un doublon : un seul message utilisateur.
        #expect(viewModel.messages.filter { $0.role == .user }.count == 1)
        #expect(viewModel.messages.count == 2)
    }

    @Test("MLX sans modèle téléchargé : bloqué, aucun chargement tenté")
    func missingLocalModelIsBlocked() async {
        let harness = OfflineHarness(plan: .blocked(.localModelUnavailable))
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: Self.question)

        #expect(harness.providerResolutions == 0)
        #expect(viewModel.offlineNotice?.reason == .localModelUnavailable)
    }

    @Test("MLX présumé présent mais impossible à charger sans Internet : même message, pas d'erreur brute")
    func downloadFailureBecomesTheOfflineMessage() async {
        let harness = OfflineHarness(plan: .answerWithoutSearch)
        harness.providerError = MLXProviderError.downloadFailed(description: "secret-technique")
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: Self.question)

        #expect(viewModel.offlineNotice?.reason == .localModelUnavailable)
        #expect(viewModel.errorDescription == nil)
    }

    @Test("La même erreur EN LIGNE reste une erreur de téléchargement ordinaire")
    func downloadFailureOnlineIsAnError() async {
        let harness = OfflineHarness(plan: nil)
        harness.providerError = MLXProviderError.downloadFailed(description: "x")
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: Self.question)

        #expect(viewModel.offlineNotice == nil)
        #expect(viewModel.errorDescription != nil)
    }

    @Test("Mode Fiable : aucune réponse sans source, état clair, bouton « Répondre sans source » (Rapide)")
    func reliableModeIsBlockedThenOffersQuickAnswer() async throws {
        let harness = OfflineHarness(plan: .answerWithoutSearch, mode: .reliable)
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: Self.question)

        #expect(harness.provider.streamPrompts.isEmpty)
        #expect(harness.client.callCount == 0)
        #expect(viewModel.offlineNotice?.reason == .reliableMode)
        #expect(viewModel.canAnswerWithoutSourceOffline)
        #expect(!viewModel.canRelaunchAfterReconnect)

        await viewModel.retryAfterOffline(quickMode: true)

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.answeredOffline)
        #expect(answer.sources.isEmpty)
        #expect(viewModel.offlineNotice == nil)
        #expect(harness.client.callCount == 0)
    }

    @Test("Le bouton « Répondre sans source » n'existe que pour le mode Fiable")
    func quickAnswerOnlyForReliable() async {
        let harness = OfflineHarness(plan: .blocked(.cloudKey))
        let viewModel = harness.makeViewModel()
        await viewModel.send(query: Self.question)
        #expect(!viewModel.canAnswerWithoutSourceOffline)
        await viewModel.retryAfterOffline(quickMode: true)
        #expect(viewModel.offlineNotice?.reason == .cloudKey)
        #expect(harness.providerResolutions == 0)
    }

    @Test("Météo hors connexion : message clair, le widget n'est pas lancé, le modèle n'invente rien")
    func weatherIsBlocked() async {
        let weather = CountingWidget(kind: .weather, llmContext: "Il fait 20 °C.")
        let provider = OfflineScriptedProvider(classification: offlineClassification(weather: true))
        let harness = OfflineHarness(plan: .answerWithoutSearch, provider: provider, widgets: [weather])
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: "Quel temps fait-il à Paris ?")

        #expect(viewModel.offlineNotice?.reason == .weather)
        #expect(weather.executionCount == 0)
        #expect(provider.streamPrompts.isEmpty)
        #expect(harness.client.callCount == 0)
    }

    @Test("Calculatrice hors connexion : le widget tourne, la réponse n'est pas marquée « sans source »")
    func calculationWorksOffline() async throws {
        let calculation = CountingWidget(kind: .calculation, llmContext: "1284 × 37 = 47 508")
        let provider = OfflineScriptedProvider(
            answer: "Le résultat est 47 508.", classification: offlineClassification(calculation: true)
        )
        let harness = OfflineHarness(plan: .answerWithoutSearch, provider: provider, widgets: [calculation])
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: "1284 × 37")

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.text == "Le résultat est 47 508.")
        #expect(calculation.executionCount == 1)
        #expect(!answer.answeredOffline)
        #expect(viewModel.offlineNotice == nil)
        #expect(harness.client.callCount == 0)
    }

    @Test("Mode Fiable avec un calcul hors connexion : le widget est une source, pas de blocage")
    func reliableWithCalculationIsNotBlocked() async throws {
        let calculation = CountingWidget(kind: .calculation, llmContext: "2 + 2 = 4")
        let provider = OfflineScriptedProvider(
            answer: "Le résultat est 4.", classification: offlineClassification(calculation: true)
        )
        let harness = OfflineHarness(plan: .answerWithoutSearch, mode: .reliable, provider: provider, widgets: [calculation])
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: "2 + 2")

        #expect(viewModel.offlineNotice == nil)
        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
    }

    @Test("Connecté : le pipeline normal cherche sur le web et ne pose aucune mention hors connexion")
    func onlineIsUnchanged() async throws {
        let result = SearXNGSearchResult(
            title: "Photosynthèse — Wikipédia", url: "https://fr.wikipedia.org/wiki/Photosynth%C3%A8se",
            content: "La photosynthèse est un processus bioénergétique.",
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
        let harness = OfflineHarness(plan: nil, client: CountingSearXNGClient(results: [result]))
        let viewModel = harness.makeViewModel()

        await viewModel.send(query: Self.question)

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(!answer.answeredOffline)
        #expect(harness.client.callCount > 0)
    }

    @Test("Un nouvel envoi efface le bandeau précédent")
    func newSendClearsTheNotice() async {
        let harness = OfflineHarness(plan: .blocked(.cloudKey))
        let viewModel = harness.makeViewModel()
        await viewModel.send(query: Self.question)
        #expect(viewModel.offlineNotice != nil)

        harness.plan = .answerWithoutSearch
        await viewModel.send(query: "Autre question")
        #expect(viewModel.offlineNotice == nil)
    }
}

// MARK: - Entretien SearXNG

private final class OfflineCountingRefresher: SearXNGDirectoryRefreshing, Sendable {
    private let calls = Mutex(0)

    var callCount: Int { calls.withLock { $0 } }

    func refreshIfNeeded(now: Date, force: Bool) async -> SearXNGDirectoryRefreshOutcome {
        calls.withLock { $0 += 1 }
        return .skipped(until: now)
    }
}

@MainActor
private final class OfflineFlag {
    var isOffline: Bool

    init(_ isOffline: Bool) {
        self.isOffline = isOffline
    }
}

@MainActor
@Suite("SearXNGMaintenance — rien sur le réseau hors connexion")
struct SearXNGMaintenanceOfflineTests {
    @Test("Hors connexion : ni annuaire téléchargé ni sonde, aucun passage lancé ; au retour, le passage a lieu")
    func noPassWhileOffline() async throws {
        let refresher = OfflineCountingRefresher()
        let prober = ScriptedProber(healthy: [])
        let flag = OfflineFlag(true)
        let maintenance = SearXNGMaintenance(
            refresher: refresher, prober: prober, isOffline: { flag.isOffline }
        ) {
            FailoverManager(client: ScriptedInstanceClient(), instances: [])
        }

        #expect(maintenance.sceneDidBecomeActive() == nil)
        #expect(maintenance.inFlight == nil)
        #expect(refresher.callCount == 0)
        #expect(prober.probed.isEmpty)

        flag.isOffline = false
        let pass = try #require(maintenance.sceneDidBecomeActive())
        await pass.value
        #expect(refresher.callCount == 1)
    }
}

// MARK: - Découvrir

private actor OfflineMemoryCache: DiscoverContentCaching {
    private var snapshot: DiscoverCacheSnapshot?
    private(set) var saveCount = 0

    init(_ snapshot: DiscoverCacheSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() async -> DiscoverCacheSnapshot? { snapshot }

    func save(_ snapshot: DiscoverCacheSnapshot) async {
        self.snapshot = snapshot
        saveCount += 1
    }
}

@MainActor
private final class DiscoverLoadCounter {
    private(set) var count = 0
    let content: DiscoverContent

    init(content: DiscoverContent = DiscoverContent(sections: [], failedTopics: [])) {
        self.content = content
    }

    func load(_ handler: @escaping DiscoverViewModel.TopicHandler) async throws -> DiscoverContent {
        count += 1
        return content
    }
}

@MainActor
@Suite("Découvrir — hors connexion : le cache s'affiche, aucune requête")
struct DiscoverOfflineTests {
    private static let date = Date(timeIntervalSince1970: 1_000_000)

    private static var cachedSnapshot: DiscoverCacheSnapshot {
        DiscoverCacheSnapshot(sections: [
            DiscoverCacheSnapshot.Section(
                topic: "tech", fetchedAt: date,
                articles: [.init(
                    title: "Ancien article", url: "https://ancien.example/a", snippet: nil,
                    imageURL: nil, publishedAt: date, sourceName: "Éditeur"
                )]
            ),
        ])
    }

    @Test("Avec un cache : les articles restent affichés, signalés, et le réseau n'est pas sollicité")
    func cachedArticlesShownWithoutRequest() async {
        let flag = OfflineFlag(true)
        let counter = DiscoverLoadCounter()
        let cache = OfflineMemoryCache(Self.cachedSnapshot)
        let model = DiscoverViewModel(
            cache: cache, now: { Self.date.addingTimeInterval(3_600) },
            isOffline: { flag.isOffline }, loadContent: counter.load
        )

        await model.loadIfNeeded()

        #expect(counter.count == 0)
        guard case .loaded(let content) = model.phase else {
            Issue.record("pas de contenu restauré : \(model.phase)")
            return
        }
        #expect(content.sections.map(\.topic) == [.tech])
        #expect(model.isShowingOfflineState)
        #expect(model.isDeviceOffline)
        #expect(!model.isLoading)
        #expect(await cache.saveCount == 0)
    }

    @Test("Sans cache : état d'échec que la vue dit « Hors connexion », toujours aucune requête")
    func noCacheNoRequest() async {
        let counter = DiscoverLoadCounter()
        let model = DiscoverViewModel(isOffline: { true }, loadContent: counter.load)

        await model.loadIfNeeded()

        #expect(counter.count == 0)
        #expect(model.phase == .failed)
        #expect(model.isShowingOfflineState)
    }

    @Test("Actualiser hors connexion ne lance rien non plus")
    func refreshOfflineDoesNothing() async {
        let counter = DiscoverLoadCounter()
        let model = DiscoverViewModel(isOffline: { true }, loadContent: counter.load)
        await model.refresh()
        #expect(counter.count == 0)
    }

    @Test("Au retour de la connexion : un chargement, l'état hors connexion disparaît")
    func connectionReturnReloads() async {
        let flag = OfflineFlag(true)
        let counter = DiscoverLoadCounter()
        let model = DiscoverViewModel(
            cache: OfflineMemoryCache(Self.cachedSnapshot), now: { Self.date.addingTimeInterval(3_600) },
            isOffline: { flag.isOffline }, loadContent: counter.load
        )
        await model.loadIfNeeded()
        #expect(counter.count == 0)

        await model.connectionDidReturn()
        #expect(counter.count == 0, "toujours hors connexion : rien à relancer")

        flag.isOffline = false
        await model.connectionDidReturn()
        #expect(counter.count == 1)
        #expect(!model.isShowingOfflineState)
    }

    @Test("Connecté d'emblée : comportement d'avant la tâche 1.16")
    func onlineLoadsNormally() async {
        let counter = DiscoverLoadCounter()
        let model = DiscoverViewModel(isOffline: { false }, loadContent: counter.load)
        await model.loadIfNeeded()
        #expect(counter.count == 1)
        #expect(!model.isShowingOfflineState)
    }
}
