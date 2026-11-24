//
//  HeadlessQuestionRunnerTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission B) : une question posée sans fenêtre, de bout en bout, avec de faux fournisseurs
//  (aucun réseau, aucun modèle). Ce qui compte : la réponse rendue, la conversation rangée dans l'historique, les
//  échecs dits clairement, et RIEN d'envoyé sans l'accord de l'utilisateur pour une IA cloud.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Question sans fenêtre : lanceur")
struct HeadlessQuestionRunnerTests {
    private typealias Base = ChatViewModelTests

    private func makeRunner(
        provider: any AIGenerating,
        client: any SearXNGSearching = Base.MockSearXNGClient(),
        settings: Base.SendSettings = Base.SendSettings(),
        stores: Base.PersistenceStores? = nil
    ) -> (HeadlessQuestionRunner, ChatViewModel) {
        let viewModel = Base().makeViewModel(
            resolveProvider: { provider },
            client: client,
            settings: settings,
            stores: stores
        )
        return (HeadlessQuestionRunner(chatViewModel: viewModel, pollInterval: .milliseconds(1)), viewModel)
    }

    private func results() -> [SearXNGSearchResult] {
        [
            Base.makeResult(title: "Titre A", url: "https://a.example/page", content: "Contenu A"),
            Base.makeResult(title: "Titre B", url: "https://b.example/page", content: "Contenu B"),
        ]
    }

    // MARK: - Réponse

    @Test("Réponse : texte sans marques [n], extrait lu, sources, et la conversation est dans l'historique")
    func answeredAndStoredInHistory() async throws {
        let stores = try Base.PersistenceStores()
        let provider = Base.MockStreamingAIGenerating(chunks: ["Paris est la capitale[1]. ", "Paris est la capitale[1]. Elle est belle [2]."])
        let client = Base.MockSearXNGClient(response: Base.response(results()))
        let (runner, viewModel) = makeRunner(provider: provider, client: client, stores: stores)

        let outcome = await runner.run(question: "  Capitale de la France ?  ") { _ in }

        guard case .answered(let answer) = outcome else {
            Issue.record("Réponse attendue, obtenu \(outcome)")
            return
        }
        #expect(answer.question == "Capitale de la France ?")
        #expect(answer.text == "Paris est la capitale. Elle est belle.")
        #expect(answer.spoken == "Paris est la capitale. Elle est belle. La réponse complète est dans Triva.")
        #expect(answer.sourceTitles == ["Titre A", "Titre B"])
        #expect(answer.sourceLinks == [URL(string: "https://a.example/page")!, URL(string: "https://b.example/page")!])
        // Rangée dans l'historique : une conversation, question puis réponse.
        let conversationID = try #require(answer.conversationID)
        #expect(conversationID == viewModel.currentConversationID)
        let stored = try #require(try stores.history.conversation(with: conversationID))
        #expect(stored.orderedMessages.count == 2)
        #expect(stored.orderedMessages.first?.text == "Capitale de la France ?")
    }

    @Test("Un lien de source qui n'est pas http(s) n'est jamais rendu à Raccourcis")
    func onlyWebLinksAreReturned() async throws {
        let odd = [
            Base.makeResult(title: "Web", url: "https://a.example/page", content: "A"),
            Base.makeResult(title: "Local", url: "file:///etc/passwd", content: "B"),
            Base.makeResult(title: "Script", url: "javascript:alert(1)", content: "C"),
        ]
        let provider = Base.MockStreamingAIGenerating(chunks: ["Réponse."])
        let (runner, _) = makeRunner(provider: provider, client: Base.MockSearXNGClient(response: Base.response(odd)))

        let outcome = await runner.run(question: "q") { _ in }

        guard case .answered(let answer) = outcome else {
            Issue.record("Réponse attendue, obtenu \(outcome)")
            return
        }
        #expect(answer.sourceLinks == [URL(string: "https://a.example/page")!])
    }

    @Test("Le mode de réponse de la session est celui qui part au pipeline")
    func modeReachesPipeline() async {
        let settings = Base.SendSettings()
        settings.mode = .deep
        let (runner, viewModel) = makeRunner(provider: Base.MockStreamingAIGenerating(chunks: ["Ok."]), settings: settings)

        _ = await runner.run(question: "q") { _ in }

        #expect(viewModel.readResponseMode() == .deep)
    }

    // MARK: - Échecs

    @Test("Question vide ou faite de caractères invisibles : rien n'est envoyé, message clair")
    func emptyQuestion() async {
        let provider = Base.MockStreamingAIGenerating(chunks: ["Ok."])
        let (runner, viewModel) = makeRunner(provider: provider)

        let outcome = await runner.run(question: " \u{200B}\n ") { _ in }

        #expect(outcome == .failed(message: HeadlessQuestionOutcome.unreadableQuestionMessage))
        #expect(viewModel.messages.isEmpty)
        #expect(provider.receivedGeneratePrompts.isEmpty)
    }

    @Test("Question démesurée : assainie à 2 000 caractères avant d'être envoyée")
    func longQuestionIsSanitized() async {
        let provider = Base.MockStreamingAIGenerating(chunks: ["Ok."])
        let (runner, viewModel) = makeRunner(provider: provider)

        _ = await runner.run(question: String(repeating: "a", count: 5_000)) { _ in }

        #expect(viewModel.messages.first?.text.count == ExternalQuerySanitizer.maxLength)
    }

    @Test("Le fournisseur échoue : le message de l'app est repris tel quel")
    func providerFailure() async {
        struct Boom: Error {}
        let provider = Base.MockStreamingAIGenerating(chunks: ["Début"], midStreamFailure: Boom())
        let (runner, viewModel) = makeRunner(provider: provider)

        let outcome = await runner.run(question: "q") { _ in }

        let message = viewModel.errorDescription
        #expect(message != nil)
        #expect(outcome == .failed(message: message ?? ""))
    }

    @Test("Mode Fiable sans source fiable : « aucune source fiable », jamais une réponse inventée")
    func noReliableSources() async {
        let settings = Base.SendSettings()
        settings.mode = .reliable
        let client = Base.MockSearXNGClient(response: Base.response(Base.untrustedResults))
        let (runner, _) = makeRunner(provider: Base.MockStreamingAIGenerating(chunks: ["Une réponse."]), client: client, settings: settings)

        let outcome = await runner.run(question: "q") { _ in }

        #expect(outcome == .noReliableSources)
    }

    // MARK: - Consentement cloud

    private func makeConsentViewModel(
        request: CloudAIConsentRequest?,
        providerResolutions: Counter,
        stores: Base.PersistenceStores
    ) -> ChatViewModel {
        let failoverManager = FailoverManager(client: Base.MockSearXNGClient(), instances: [Base.instance])
        return ChatViewModel(
            resolveProvider: {
                providerResolutions.value += 1
                return Base.MockStreamingAIGenerating(chunks: ["Ne devrait jamais être lu."])
            },
            resolveFailoverManager: { failoverManager },
            historyStore: stores.history,
            favoritesStore: stores.favorites,
            makeOrchestrator: { Base.deterministicOrchestrator($0) },
            resolveConsentRequest: { request }
        )
    }

    @MainActor
    final class Counter {
        var value = 0
    }

    @Test("Cloud sans accord : RIEN n'est envoyé, aucun fournisseur résolu, aucun message, historique vide")
    func consentRequiredSendsNothing() async throws {
        let stores = try Base.PersistenceStores()
        let counter = Counter()
        let request = try #require(CloudAIConsentCatalog.request(providerID: "openai", customPresets: []))
        let viewModel = makeConsentViewModel(request: request, providerResolutions: counter, stores: stores)
        let runner = HeadlessQuestionRunner(chatViewModel: viewModel, pollInterval: .milliseconds(1))

        let outcome = await runner.run(question: "Une question privée") { _ in }

        #expect(outcome == .consentRequired(providerName: request.displayName))
        #expect(counter.value == 0)
        #expect(viewModel.messages.isEmpty)
        #expect(try stores.history.conversations().isEmpty)
    }

    @Test("Cloud avec accord : la question part")
    func consentGrantedSends() async throws {
        let stores = try Base.PersistenceStores()
        let counter = Counter()
        let viewModel = makeConsentViewModel(request: nil, providerResolutions: counter, stores: stores)
        let runner = HeadlessQuestionRunner(chatViewModel: viewModel, pollInterval: .milliseconds(1))

        let outcome = await runner.run(question: "Une question") { _ in }

        #expect(counter.value == 1)
        guard case .answered = outcome else {
            Issue.record("Réponse attendue, obtenu \(outcome)")
            return
        }
    }

    @Test("Dernier rempart : même sans la garde du lanceur, le fournisseur cloud refuse sans accord")
    func providerGateStillHolds() async throws {
        struct NoKeys: APIKeyStoring {
            func apiKey(account: String) throws -> String? { nil }
            func save(apiKey: String, account: String) throws {}
            func deleteAPIKey(account: String) throws {}
        }
        let defaults = try #require(TestDefaults.suite(named: "test.headlessGate.\(UUID().uuidString)"))
        let sessionStores = TrivaSharedStores(
            userDefaults: defaults,
            container: try TrivaModelContainer.makeInMemory(),
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: defaults),
            keyStore: NoKeys()
        )
        sessionStores.cloudSelection.selection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")
        let session = SearchSession(engine: .cloudBYOK, stores: sessionStores)
        let failoverManager = FailoverManager(client: Base.MockSearXNGClient(), instances: [Base.instance])
        // Garde du lanceur et du modèle de chat volontairement ABSENTES (`resolveConsentRequest: { nil }`).
        let viewModel = ChatViewModel(
            resolveProvider: { try await session.resolveProviderForSending() },
            resolveFailoverManager: { failoverManager },
            makeOrchestrator: { Base.deterministicOrchestrator($0) },
            resolveConsentRequest: { nil }
        )
        let runner = HeadlessQuestionRunner(chatViewModel: viewModel, pollInterval: .milliseconds(1))

        let outcome = await runner.run(question: "Une question privée") { _ in }

        #expect(outcome == .failed(message: CloudAIConsentText.blocked))
    }

    // MARK: - Annulation et progression

    @Test("Annuler : la recherche s'arrête, la réponse partielle est gardée, résultat « interrompu »")
    func cancel() async {
        let provider = Base.ControllableStreamingAIGenerating()
        let (runner, viewModel) = makeRunner(provider: provider)
        let task = Task { await runner.run(question: "q") { _ in } }
        await Base().waitUntil("le flux démarre") { provider.continuation != nil }

        runner.cancel()
        let outcome = await task.value

        #expect(outcome == .interrupted)
        #expect(viewModel.isGenerating == false)
    }

    @Test("Annuler la tâche appelante arrête aussi la recherche")
    func cancellingTheCallingTask() async {
        let provider = Base.ControllableStreamingAIGenerating()
        let (runner, viewModel) = makeRunner(provider: provider)
        let task = Task { await runner.run(question: "q") { _ in } }
        await Base().waitUntil("le flux démarre") { provider.continuation != nil }

        task.cancel()
        let outcome = await task.value

        #expect(outcome == .interrupted)
        #expect(viewModel.isGenerating == false)
    }

    @Test("Progression : « Rédaction » est annoncée dès que le texte arrive")
    func progressReachesWriting() async {
        let provider = Base.ControllableStreamingAIGenerating()
        let (runner, _) = makeRunner(provider: provider)
        let recorder = StageRecorder()
        let task = Task { await runner.run(question: "q") { recorder.updates.append($0) } }
        guard let continuation = await Base().waitForContinuation(provider) else {
            task.cancel()
            Issue.record("Flux jamais démarré")
            return
        }

        continuation.yield("Début de réponse")
        await Base().waitUntil("l'étape Rédaction est annoncée") { recorder.stages.contains(.writing) }
        continuation.yield("Début de réponse complète.")
        continuation.finish()
        _ = await task.value

        #expect(recorder.stages.contains(.writing))
        #expect(recorder.stages.first == .searching)
    }

    @Test("Heartbeat : l'avancement monte à chaque battement même sans changer d'étape")
    func heartbeatMovesWithinAStage() async {
        let provider = Base.ControllableStreamingAIGenerating()
        let (runner, _) = makeRunner(provider: provider)
        let recorder = StageRecorder()
        let task = Task { await runner.run(question: "q") { recorder.updates.append($0) } }
        guard let continuation = await Base().waitForContinuation(provider) else {
            task.cancel()
            Issue.record("Flux jamais démarré")
            return
        }

        continuation.yield("Début de réponse")
        await Base().waitUntil("la rédaction est annoncée et la barre bouge encore") {
            let writing = recorder.updates.filter { $0.stage == .writing }
            return writing.count >= 6
        }
        continuation.finish()
        _ = await task.value

        let units = recorder.updates.filter { $0.stage == .writing }.map(\.completedUnits)
        #expect(zip(units, units.dropFirst()).allSatisfy { $0 < $1 })
        #expect(recorder.updates.map(\.completedUnits) == recorder.updates.map(\.completedUnits).sorted())
    }

    @MainActor
    final class StageRecorder {
        var updates: [HeadlessProgressUpdate] = []
        var stages: [HeadlessProgressStage] { updates.map(\.stage) }
    }
}

// MARK: - Étapes de progression (pures)

@Suite("Question sans fenêtre : étapes de progression")
struct HeadlessProgressStageTests {
    @Test("Analyse et recherche : « Recherche… »")
    func searching() {
        #expect(HeadlessProgressStage.stage(generationStage: .analyzing, sourceCount: 0, hasText: false) == .searching)
        #expect(HeadlessProgressStage.stage(generationStage: .searching, sourceCount: 0, hasText: false) == .searching)
    }

    @Test("Sources trouvées mais pas encore de texte : « Lecture de N sources »")
    func reading() {
        #expect(HeadlessProgressStage.stage(generationStage: .writing, sourceCount: 4, hasText: false) == .reading(sourceCount: 4))
    }

    @Test("Du texte arrive : « Rédaction… »")
    func writing() {
        #expect(HeadlessProgressStage.stage(generationStage: .writing, sourceCount: 4, hasText: true) == .writing)
        #expect(HeadlessProgressStage.stage(generationStage: .writing, sourceCount: 0, hasText: false) == .writing)
    }

    @Test("Les textes de progression sont ceux de la spec, avec le singulier")
    func descriptions() {
        #expect(HeadlessProgressStage.searching.description == "Recherche…")
        #expect(HeadlessProgressStage.reading(sourceCount: 1).description == "Lecture d'une source")
        #expect(HeadlessProgressStage.reading(sourceCount: 3).description == "Lecture de 3 sources")
        #expect(HeadlessProgressStage.writing.description == "Rédaction…")
    }
}

@Suite("Question sans fenêtre : barre de progression")
struct HeadlessProgressMeterTests {
    @Test("Premier battement : la barre part du début de l'étape")
    func startsAtBandStart() {
        var meter = HeadlessProgressMeter()
        #expect(meter.tick(stage: .searching) == HeadlessProgressStage.searching.band.start)
    }

    @Test("Heartbeat : la barre bouge à CHAQUE battement tant qu'elle n'a pas touché le plafond de l'étape")
    func movesOnEveryTick() {
        var meter = HeadlessProgressMeter()
        var previous = meter.tick(stage: .writing)
        for _ in 0..<150 {
            let next = meter.tick(stage: .writing)
            #expect(next > previous)
            previous = next
        }
    }

    @Test("Elle ne dépasse jamais le plafond de l'étape, ni le total")
    func neverPastCap() {
        var meter = HeadlessProgressMeter()
        for _ in 0..<5_000 { meter.tick(stage: .writing) }
        #expect(meter.completedUnits <= HeadlessProgressStage.writing.band.cap)
        #expect(meter.completedUnits < HeadlessProgressMeter.totalUnits)
    }

    @Test("Elle ne recule jamais, même si l'étape revient en arrière")
    func neverGoesBack() {
        var meter = HeadlessProgressMeter()
        let stages: [HeadlessProgressStage] = [.searching, .searching, .reading(sourceCount: 3), .writing, .searching, .reading(sourceCount: 2), .writing]
        var previous: Int64 = 0
        for stage in stages {
            let value = meter.tick(stage: stage)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("Une nouvelle étape fait sauter la barre au début de sa plage")
    func jumpsToNextBand() {
        var meter = HeadlessProgressMeter()
        meter.tick(stage: .searching)
        #expect(meter.tick(stage: .writing) == HeadlessProgressStage.writing.band.start)
    }

    @Test("Les plages se suivent sans se chevaucher : recherche, lecture, rédaction")
    func bandsAreOrdered() {
        let searching = HeadlessProgressStage.searching.band
        let reading = HeadlessProgressStage.reading(sourceCount: 2).band
        let writing = HeadlessProgressStage.writing.band
        #expect(searching.start < searching.cap)
        #expect(searching.cap <= reading.start)
        #expect(reading.cap <= writing.start)
        #expect(writing.cap < HeadlessProgressMeter.totalUnits)
    }
}
