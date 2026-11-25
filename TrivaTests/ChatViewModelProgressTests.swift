//
//  ChatViewModelProgressTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission D) : ce que `ChatViewModel` raconte de l'avancement d'un échange à l'activité en direct, avec
//  le vrai pipeline et de faux fournisseurs. Et la règle « une séance sans fenêtre n'a PAS d'activité maison ».
//

import Foundation
import Testing
@testable import Triva

@MainActor
private final class RecordingProgressObserver: SearchProgressObserving {
    private(set) var events: [SearchProgressEvent] = []
    private(set) var answerIDs: [UUID] = []

    func searchProgress(_ event: SearchProgressEvent, answerID: UUID) {
        events.append(event)
        answerIDs.append(answerID)
    }

    var terminalCount: Int {
        events.filter { $0 == .completed || $0 == .interrupted || $0 == .failed }.count
    }
}

@MainActor
@Suite("Avancement d'un échange (activité en direct)")
struct ChatViewModelProgressTests {
    private typealias Base = ChatViewModelTests

    private let observer = RecordingProgressObserver()

    private func results() -> [SearXNGSearchResult] {
        [
            Base.makeResult(title: "Titre A", url: "https://a.example/page", content: "Contenu A"),
            Base.makeResult(title: "Titre B", url: "https://b.example/page", content: "Contenu B"),
        ]
    }

    private func makeViewModel(
        provider: any AIGenerating,
        client: any SearXNGSearching? = nil,
        settings: Base.SendSettings = Base.SendSettings(),
        stores: Base.PersistenceStores? = nil
    ) -> ChatViewModel {
        let viewModel = Base().makeViewModel(
            resolveProvider: { provider },
            client: client ?? Base.MockSearXNGClient(response: Base.response(results())),
            settings: settings,
            stores: stores
        )
        viewModel.progressObserver = observer
        return viewModel
    }

    private func waitUntil(timeout: Duration = .seconds(60), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    // MARK: Cas nominal

    @Test("Réponse normale : début, recherche, sources lues, premier texte, réponse prête, dans cet ordre")
    func normalSequence() async throws {
        let stores = try Base.PersistenceStores()
        let viewModel = makeViewModel(
            provider: Base.MockStreamingAIGenerating(chunks: ["Paris", "Paris est la capitale."]),
            stores: stores
        )

        await viewModel.send(query: "  Capitale de la France ?  ")

        let conversationID = try #require(viewModel.currentConversationID)
        #expect(observer.events == [
            .started(question: "Capitale de la France ?", conversationID: conversationID),
            .searching,
            .sources(count: 2),
            .writing,
            .completed,
        ])
        // Tous les événements portent l'identifiant du message de réponse.
        #expect(Set(observer.answerIDs) == [try #require(viewModel.messages.last?.id)])
    }

    @Test("Sans historique (aucune conversation rangée), la conversation est absente de l'événement de début")
    func startedWithoutConversation() async {
        let viewModel = makeViewModel(provider: Base.MockStreamingAIGenerating(chunks: ["Réponse."]))

        await viewModel.send(query: "Question ?")

        #expect(observer.events.first == .started(question: "Question ?", conversationID: nil))
    }

    @Test("Le premier instantané VIDE ne compte pas : « Rédaction » attend un vrai texte")
    func emptySnapshotIsNotWriting() async {
        let provider = Base.MockStreamingAIGenerating(chunks: ["", "  ", "Texte."])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.send(query: "Question ?")

        #expect(observer.events.filter { $0 == .writing }.count == 1)
        let writingIndex = observer.events.firstIndex(of: .writing)
        let completedIndex = observer.events.firstIndex(of: .completed)
        #expect(writingIndex != nil)
        #expect(completedIndex != nil)
        if let writingIndex, let completedIndex { #expect(writingIndex < completedIndex) }
    }

    // MARK: Réflexion du modèle

    @Test("Le modèle réfléchit avant d'écrire : « réflexion » d'abord, « rédaction » seulement au premier mot de la réponse")
    func modelReasoningThenWriting() async {
        let provider = Base.MockStreamingAIGenerating(chunks: [
            "<think>Je cherche la capitale",
            "<think>Je cherche la capitale</think>",
            "<think>Je cherche la capitale</think>Paris est la capitale.",
        ])
        let viewModel = makeViewModel(provider: provider)

        await viewModel.send(query: "Capitale de la France ?")

        #expect(observer.events.filter { $0 == .reasoning }.count == 1)
        #expect(observer.events.filter { $0 == .writing }.count == 1)
        let reasoningIndex = observer.events.firstIndex(of: .reasoning)
        let writingIndex = observer.events.firstIndex(of: .writing)
        #expect(reasoningIndex != nil)
        #expect(writingIndex != nil)
        if let reasoningIndex, let writingIndex { #expect(reasoningIndex < writingIndex) }
        // Le CONTENU du raisonnement n'apparaît dans aucun événement : seulement le nom de l'étape.
        #expect(observer.events.allSatisfy { !String(describing: $0).contains("Je cherche") })
    }

    @Test("Un modèle qui ne réfléchit pas ne produit aucun événement de réflexion")
    func noReasoningEvent() async {
        let viewModel = makeViewModel(provider: Base.MockStreamingAIGenerating(chunks: ["Paris est la capitale."]))

        await viewModel.send(query: "Capitale de la France ?")

        #expect(!observer.events.contains(.reasoning))
    }

    @Test("Ce que dit un instantané du flux : rien, la réflexion du modèle, ou la rédaction", arguments: [
        ("", nil as SearchProgressEvent?),
        ("  \n ", nil),
        ("<", nil),
        ("<thi", nil),
        ("<think>", nil),
        ("<think></think>", nil),
        ("Paris", .writing),
        ("<think>Je dois chercher", .reasoning),
        ("<think>Je dois chercher</think>", .reasoning),
        ("<think>Je dois chercher</think>\n\nParis", .writing),
        ("<tldr>Paris, capitale.", .writing),
    ])
    func streamSnapshotEvent(snapshot: String, expected: SearchProgressEvent?) {
        #expect(SearchProgressEvent.forStreamSnapshot(snapshot) == expected)
    }

    // MARK: Échecs et arrêt

    @Test("Échec du moteur en cours de flux : l'échange finit « échoué », une seule fois")
    func midStreamFailure() async {
        let provider = Base.MockStreamingAIGenerating(chunks: ["Début"], midStreamFailure: Base.MockError.midStreamFailure)
        let viewModel = makeViewModel(provider: provider)

        await viewModel.send(query: "Question ?")

        #expect(observer.events.last == .failed)
        #expect(observer.terminalCount == 1)
        #expect(observer.events.contains(.writing))
    }

    @Test("Moteur impossible à résoudre : « échoué » sans passer par la lecture ni la rédaction")
    func providerResolutionFails() async {
        let viewModel = Base().makeViewModel(resolveProvider: { throw Base.MockError.midStreamFailure })
        viewModel.progressObserver = observer

        await viewModel.send(query: "Question ?")

        #expect(observer.events.count == 2)
        #expect(observer.events.last == .failed)
    }

    @Test("Stop pendant la rédaction : l'échange finit « interrompu », une seule fois")
    func stopInterrupts() async throws {
        let provider = Base.ControllableStreamingAIGenerating()
        let viewModel = makeViewModel(provider: provider)

        viewModel.startSend(query: "Question ?")
        #expect(await waitUntil { provider.continuation != nil })
        provider.continuation?.yield("Un début")
        #expect(await waitUntil { observer.events.contains(.writing) })
        viewModel.stop()
        #expect(await waitUntil { observer.terminalCount > 0 })
        provider.continuation?.finish()
        await viewModel.sendTask?.value

        #expect(observer.events.last == .interrupted)
        #expect(observer.terminalCount == 1)
    }

    @Test("Mode Fiable sans source fiable : « échoué », sans jamais annoncer de rédaction")
    func noReliableSources() async {
        let settings = Base.SendSettings()
        settings.mode = .reliable
        let viewModel = makeViewModel(
            provider: Base.MockStreamingAIGenerating(chunks: ["Une réponse."]),
            client: Base.MockSearXNGClient(response: Base.response(Base.untrustedResults)),
            settings: settings
        )

        await viewModel.send(query: "Question ?")

        #expect(observer.events.last == .failed)
        #expect(!observer.events.contains(.writing))
        #expect(observer.terminalCount == 1)
    }

    @Test("Mode Fiable : le texte retenu par la porte annonce quand même « Rédaction » au premier instantané")
    func reliableRetainedTextStillWriting() async {
        let settings = Base.SendSettings()
        settings.mode = .reliable
        let trusted = [SearXNGSearchResult(
            title: "TypeScript — Wikipédia", url: "https://fr.wikipedia.org/wiki/TypeScript",
            content: "TypeScript est un sur-ensemble typé de JavaScript.",
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )]
        let viewModel = makeViewModel(
            provider: Base.MockStreamingAIGenerating(chunks: ["Une réponse sans aucune citation."]),
            client: Base.MockSearXNGClient(response: Base.response(trusted)),
            settings: settings
        )

        await viewModel.send(query: "Qu'est-ce que TypeScript ?")

        // Le texte n'a jamais été montré (aucune citation), mais le premier instantané non vide du flux
        // a bien fait passer l'activité à « Rédaction » avant la fin.
        let writingIndex = observer.events.firstIndex(of: .writing)
        #expect(writingIndex != nil)
        #expect(observer.terminalCount == 1)
        #expect(writingIndex.map { $0 < observer.events.count - 1 } == true)
    }

    // MARK: Observateur

    @Test("Sans observateur, l'échange se déroule exactement comme avant")
    func noObserver() async {
        let viewModel = Base().makeViewModel(resolveProvider: { Base.MockStreamingAIGenerating(chunks: ["Réponse."]) })
        #expect(viewModel.progressObserver == nil)

        await viewModel.send(query: "Question ?")

        #expect(viewModel.messages.last?.status == .completed)
    }

    @Test("Deux questions à la suite : deux échanges, chacun commence et finit une fois")
    func twoExchangesInARow() async {
        let viewModel = makeViewModel(provider: Base.MockStreamingAIGenerating(chunks: ["Réponse."]))

        await viewModel.send(query: "Première ?")
        await viewModel.send(query: "Seconde ?")

        let starts = observer.events.filter { if case .started = $0 { true } else { false } }
        #expect(starts.count == 2)
        #expect(observer.terminalCount == 2)
        #expect(Set(observer.answerIDs).count == 2)
    }

    // MARK: Séance sans fenêtre

    @Test("Une séance sans fenêtre (Siri, Raccourcis) n'a pas d'observateur : jamais d'activité en doublon")
    func headlessSessionHasNoObserver() throws {
        let defaults = try #require(TestDefaults.suite(named: "test.progress.headless.\(UUID().uuidString)"))
        let stores = TrivaSharedStores(
            userDefaults: defaults,
            container: try TrivaModelContainer.makeInMemory(),
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: defaults),
            keyStore: ProgressKeyStore()
        )
        stores.engineSettings.selectedOption = .appleIntelligence

        let setup = HeadlessQuestionSetup.prepare(stores: stores, responseMode: nil, noticeAcknowledged: true, platform: .iOS)

        let session = try #require(setup.session)
        #expect(session.progressObserver == nil)
        #expect(try #require(session.chatViewModel).progressObserver == nil)
    }

    @Test("Une séance de fenêtre rapporte à l'activité en direct de l'app")
    func windowSessionReportsToTheSharedController() throws {
        let defaults = try #require(TestDefaults.suite(named: "test.progress.window.\(UUID().uuidString)"))
        let stores = TrivaSharedStores(
            userDefaults: defaults,
            container: try TrivaModelContainer.makeInMemory(),
            searchInstances: CustomInstanceStore(defaultInstances: [URL(string: "https://searx.example")!], userDefaults: defaults),
            keyStore: ProgressKeyStore()
        )
        let session = SearchSession(engine: .appleIntelligence, stores: stores)

        session.ensureChatViewModel()

        #expect(session.progressObserver === SearchLiveActivityController.shared)
        #expect(session.chatViewModel?.progressObserver === SearchLiveActivityController.shared)
    }
}

private struct ProgressKeyStore: APIKeyStoring {
    func apiKey(account: String) throws -> String? { nil }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}
