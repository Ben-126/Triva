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
}

/// Client SearXNG factice, même principe que `MockSearXNGClient` de
/// `SearchOrchestratorTests.swift` (dupliqué ici, `private` est scopé au
/// fichier) : renvoie une réponse fixe, ou lève une erreur si configuré pour
/// échouer.
private actor MockSearXNGClient: SearXNGSearching {
    private let response: SearXNGSearchResponse
    private let shouldFail: Bool

    init(response: SearXNGSearchResponse = SearXNGSearchResponse(results: [], suggestions: []), shouldFail: Bool = false) {
        self.response = response
        self.shouldFail = shouldFail
    }

    func search(query: String, options: SearXNGSearchOptions, instance: URL) async throws -> SearXNGSearchResponse {
        if shouldFail {
            throw MockError.searchFailed
        }
        return response
    }
}

/// Client SearXNG factice dont `search` reste en vol jusqu'à ce que le test
/// appelle explicitement `fail(with:)` — nécessaire pour simuler une Task
/// annulée PENDANT que `failoverManager.search(query:)` est en vol (avant
/// même que `streamAnswer` ait pu créer un `textStream`), le scénario exact
/// du finding ChatViewModel.swift:166 de la revue 0.8.
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

/// Provider IA factice qui streame une suite de morceaux fixe, avec une
/// erreur optionnelle en fin de flux — même principe que
/// `MockStreamingAIGenerating` dans `SearchOrchestratorStreamingTests.swift`
/// (dupliqué ici, `private` est scopé au fichier).
private final class MockStreamingAIGenerating: AIGenerating {
    private(set) var receivedPrompts: [String] = []
    private let chunks: [String]
    private let midStreamFailure: (any Error)?

    init(chunks: [String] = ["chunk"], midStreamFailure: (any Error)? = nil) {
        self.chunks = chunks
        self.midStreamFailure = midStreamFailure
    }

    func generate(prompt: String) async throws -> String {
        receivedPrompts.append(prompt)
        return chunks.joined()
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        receivedPrompts.append(prompt)
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

/// Provider IA factice dont le flux est piloté manuellement par le test (via
/// `continuation`), pour observer l'état de `ChatViewModel` ENTRE deux
/// valeurs du flux plutôt que seulement à la fin — nécessaire pour vérifier
/// que les sources sont attachées avant tout texte, et que chaque valeur
/// REMPLACE le texte affiché (pas de concaténation) à chaque étape.
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

@Suite("ChatViewModel")
struct ChatViewModelTests {
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

    /// Poll coopératif : cède la main (`Task.yield()`) jusqu'à ce que
    /// `condition` soit vraie ou que `maxAttempts` soit atteint — nécessaire
    /// pour observer un état intermédiaire de `ChatViewModel` pendant qu'un
    /// `send(query:)` est en cours dans une autre `Task`, sans dépendre d'un
    /// délai fixe (non déterministe). Un timeout enregistre un échec via
    /// `Issue.record` (plutôt que d'échouer silencieusement plus loin) : un
    /// test dont la précondition n'est jamais atteinte doit se voir comme un
    /// timeout, pas comme un mismatch d'assertion sans rapport.
    private func waitUntil(
        _ timeoutMessage: String,
        maxAttempts: Int = 200,
        _ condition: () async -> Bool
    ) async {
        var attempts = 0
        while attempts < maxAttempts {
            if await condition() { return }
            await Task.yield()
            attempts += 1
        }
        Issue.record("Timeout en attendant : \(timeoutMessage)")
    }

    /// Attend qu'une `continuation` ait été assignée par `streamGenerate`
    /// puis la renvoie — évite de relire la propriété `@MainActor` à chaque
    /// `yield`/`finish` dans les tests ci-dessous.
    private func waitForContinuation(
        _ provider: ControllableStreamingAIGenerating
    ) async -> AsyncThrowingStream<String, Error>.Continuation? {
        await waitUntil("continuation assignée par streamGenerate") { await provider.continuation != nil }
        return await provider.continuation
    }

    // MARK: - Cas nominal

    @Test("Cas nominal : plusieurs valeurs de stream successives, le texte final est la DERNIÈRE valeur reçue (snapshot cumulatif), pas une concaténation")
    func happyPathStreamsToFinalSnapshot() async throws {
        let results = [
            Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A"),
            Self.makeResult(title: "Titre B", url: "https://b.example", content: "Contenu B"),
        ]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: ["Voici", "Voici la", "Voici la réponse complète."])
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "  Quelle est la question ?  ")

        let messages = await viewModel.messages
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].text == "Quelle est la question ?")
        #expect(messages[0].isStreaming == false)

        let assistantMessage = messages[1]
        #expect(assistantMessage.role == .assistant)
        #expect(assistantMessage.text == "Voici la réponse complète.")
        #expect(assistantMessage.text != "VoiciVoici laVoici la réponse complète.")
        #expect(assistantMessage.isStreaming == false)
        #expect(assistantMessage.sources == results)

        let isGenerating = await viewModel.isGenerating
        let errorDescription = await viewModel.errorDescription
        #expect(isGenerating == false)
        #expect(errorDescription == nil)

        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("Quelle est la question ?") == true)
    }

    @Test("Chaque valeur du stream REMPLACE le texte du message assistant à chaque étape, jamais de concaténation")
    func eachStreamValueReplacesTextAtEachStep() async throws {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        let task = Task { await viewModel.send(query: "requête") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            Issue.record("continuation jamais assignée")
            task.cancel()
            return
        }

        continuation.yield("Voici")
        await waitUntil("le message assistant reflète le 1er chunk") { await viewModel.messages.last?.text == "Voici" }
        let afterFirstChunk = await viewModel.messages.last
        #expect(afterFirstChunk?.text == "Voici")
        #expect(afterFirstChunk?.isStreaming == true)

        continuation.yield("Voici la réponse complète.")
        await waitUntil("le message assistant reflète le 2e chunk") { await viewModel.messages.last?.text == "Voici la réponse complète." }
        // Si le code concaténait au lieu de remplacer, ce texte contiendrait
        // deux fois "Voici" — jamais le cas ici.
        let afterSecondChunk = await viewModel.messages.last
        #expect(afterSecondChunk?.text == "Voici la réponse complète.")

        continuation.finish()
        await task.value

        let lastMessage = await viewModel.messages.last
        #expect(lastMessage?.text == "Voici la réponse complète.")
        #expect(lastMessage?.isStreaming == false)
    }

    // MARK: - Sources

    @Test("Les sources sont attachées au message assistant dès qu'elles sont connues, avant même le premier morceau de texte")
    func sourcesAttachedBeforeFirstChunk() async throws {
        let results = [Self.makeResult(title: "Titre A", url: "https://a.example", content: "Contenu A")]
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: results, suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        let task = Task { await viewModel.send(query: "requête") }
        await waitUntil("les sources sont attachées au message assistant") {
            await viewModel.messages.last?.sources.isEmpty == false
        }

        let messageWithSources = await viewModel.messages.last
        #expect(messageWithSources?.sources == results)
        // Sources connues, mais aucun morceau de texte encore reçu.
        #expect(messageWithSources?.text == "")
        #expect(messageWithSources?.isStreaming == true)

        guard let continuation = await waitForContinuation(aiProvider) else {
            Issue.record("continuation jamais assignée")
            task.cancel()
            return
        }
        continuation.finish()
        await task.value
    }

    // MARK: - Erreurs

    @Test("Une erreur de recherche (FailoverManager) est reportée sur le message assistant, sans laisser isStreaming/isGenerating bloqués")
    func searchErrorIsReportedOnAssistantMessage() async {
        let client = MockSearXNGClient(shouldFail: true)
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating()
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "requête")

        let messages = await viewModel.messages
        #expect(messages.count == 2)
        let assistantMessage = messages[1]
        #expect(assistantMessage.role == .assistant)
        #expect(assistantMessage.isStreaming == false)
        // La recherche a échoué avant tout texte streamé : la bulle reste
        // vide, l'erreur est reportée UNIQUEMENT via `errorDescription`
        // (`ChatView` l'affiche dans son bandeau — jamais en plus dans la
        // bulle, pour ne pas dupliquer le même texte technique).
        #expect(assistantMessage.text.isEmpty)

        let isGenerating = await viewModel.isGenerating
        let errorDescription = await viewModel.errorDescription
        #expect(isGenerating == false)
        // Message français clair, pas le nom brut de l'enum `FailoverError`
        // (voir `ChatViewModel.userFacingMessage(for:)`, finding 19 de la
        // revue 0.8).
        #expect(errorDescription == "Aucune instance de recherche n'a répondu. Réessaie dans un instant.")

        // La recherche a échoué avant tout appel au provider IA.
        let prompts = await aiProvider.receivedPrompts
        #expect(prompts.isEmpty)
    }

    @Test("Une erreur survenant PENDANT le stream du provider IA est reportée sur le message assistant, texte déjà streamé conservé")
    func midStreamErrorIsReportedOnAssistantMessage() async {
        let client = MockSearXNGClient(response: SearXNGSearchResponse(results: [], suggestions: []))
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: ["premier morceau"], midStreamFailure: MockError.midStreamFailure)
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "requête")

        let messages = await viewModel.messages
        #expect(messages.count == 2)
        let assistantMessage = messages[1]
        #expect(assistantMessage.isStreaming == false)
        // Le texte déjà streamé avant l'échec est conservé tel quel — sans
        // texte d'erreur ajouté dedans (reporté UNIQUEMENT via
        // `errorDescription`, voir plus bas, pour ne rien dupliquer dans la
        // bulle).
        #expect(assistantMessage.text == "premier morceau")

        let isGenerating = await viewModel.isGenerating
        let errorDescription = await viewModel.errorDescription
        #expect(isGenerating == false)
        #expect(errorDescription?.contains("midStreamFailure") == true)
    }

    @Test("Une erreur de résolution du provider IA est reportée sur le message assistant, sans crash")
    func providerResolutionErrorIsReportedOnAssistantMessage() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let viewModel = await ChatViewModel(
            resolveProvider: { throw MockError.providerResolutionFailed },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "requête")

        let messages = await viewModel.messages
        #expect(messages.count == 2)
        let assistantMessage = messages[1]
        #expect(assistantMessage.isStreaming == false)
        // Aucun texte n'a jamais été streamé (échec avant même d'appeler le
        // provider) : la bulle reste vide, l'erreur est reportée UNIQUEMENT
        // via `errorDescription`.
        #expect(assistantMessage.text.isEmpty)

        let isGenerating = await viewModel.isGenerating
        let errorDescription = await viewModel.errorDescription
        #expect(isGenerating == false)
        #expect(errorDescription?.contains("providerResolutionFailed") == true)
    }

    // MARK: - Requêtes vides / envoi concurrent

    @Test("Une requête vide est ignorée silencieusement : aucun message ajouté")
    func emptyQueryIsIgnored() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating()
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "")

        let messages = await viewModel.messages
        let isGenerating = await viewModel.isGenerating
        let prompts = await aiProvider.receivedPrompts
        #expect(messages.isEmpty)
        #expect(isGenerating == false)
        #expect(prompts.isEmpty)
    }

    @Test("Une requête composée uniquement d'espaces est ignorée silencieusement : aucun message ajouté")
    func whitespaceOnlyQueryIsIgnored() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating()
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "    ")

        let messages = await viewModel.messages
        let isGenerating = await viewModel.isGenerating
        let prompts = await aiProvider.receivedPrompts
        #expect(messages.isEmpty)
        #expect(isGenerating == false)
        #expect(prompts.isEmpty)
    }

    @Test("Un envoi concurrent est ignoré tant que isGenerating est true : aucun message ajouté pour le 2e envoi")
    func concurrentSendIsIgnoredWhileGenerating() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        let firstTask = Task { await viewModel.send(query: "premier") }
        // Attend que la première génération soit réellement en cours
        // (isGenerating == true) avant de tenter le 2e envoi concurrent —
        // sinon un timeout silencieux ferait passer ce test pour de
        // mauvaises raisons (le 2e envoi n'aurait alors rien à ignorer).
        await waitUntil("la 1re génération est en cours (isGenerating == true)") { await viewModel.isGenerating }
        let wasGenerating = await viewModel.isGenerating
        #expect(wasGenerating, "précondition requise : la 1re génération doit être en cours avant le 2e envoi")

        await viewModel.send(query: "second")

        // Le 2e envoi n'a rien ajouté : toujours seulement le message
        // utilisateur + le message assistant en cours du premier envoi.
        var messages = await viewModel.messages
        #expect(messages.count == 2)
        #expect(messages[0].text == "premier")

        guard let continuation = await waitForContinuation(aiProvider) else {
            Issue.record("continuation jamais assignée")
            firstTask.cancel()
            return
        }
        continuation.yield("réponse")
        continuation.finish()
        await firstTask.value

        messages = await viewModel.messages
        let isGenerating = await viewModel.isGenerating
        #expect(messages.count == 2)
        #expect(isGenerating == false)
    }

    // MARK: - Flux vide (0 yield)

    @Test("Un flux IA qui se termine sans avoir jamais streamé de texte (0 yield) est traité comme un échec explicite (ChatViewModelError.emptyResponse), jamais comme un message assistant vide silencieux")
    func emptyStreamIsReportedAsFailure() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: [])
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "requête")

        let messages = await viewModel.messages
        #expect(messages.count == 2)
        let assistantMessage = messages[1]
        #expect(assistantMessage.role == .assistant)
        #expect(assistantMessage.isStreaming == false)
        #expect(assistantMessage.text.isEmpty)

        let isGenerating = await viewModel.isGenerating
        let errorDescription = await viewModel.errorDescription
        #expect(isGenerating == false)
        // Message français clair, pas le nom brut de l'enum
        // `ChatViewModelError` (voir `userFacingMessage(for:)`, finding 19).
        #expect(errorDescription == "Le moteur IA n'a renvoyé aucune réponse. Réessaie.")
    }

    @Test("Un flux IA qui produit un UNIQUE yield vide (chaîne \"\") est traité comme un échec explicite (ChatViewModelError.emptyResponse), pas seulement le cas 0 yield — sinon la bulle assistant resterait vide et silencieuse (isStreaming == false, text == \"\", errorDescription == nil)")
    func singleEmptySnapshotIsReportedAsFailure() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating(chunks: [""])
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "requête")

        let messages = await viewModel.messages
        #expect(messages.count == 2)
        let assistantMessage = messages[1]
        #expect(assistantMessage.role == .assistant)
        #expect(assistantMessage.isStreaming == false)
        #expect(assistantMessage.text.isEmpty)

        let isGenerating = await viewModel.isGenerating
        let errorDescription = await viewModel.errorDescription
        #expect(isGenerating == false)
        // Message français clair, pas le nom brut de l'enum
        // `ChatViewModelError` (voir `userFacingMessage(for:)`, finding 19).
        #expect(errorDescription == "Le moteur IA n'a renvoyé aucune réponse. Réessaie.")
    }

    // MARK: - Annulation

    @Test("Annuler la Task englobante pendant le streaming arrête proprement la génération : le texte déjà reçu est conservé, ce n'est PAS traité comme une erreur (errorDescription reste nil)")
    func cancellingEnclosingTaskStopsStreamingWithoutError() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        // Comme `ChatView.send()`, on englobe l'appel dans une `Task` — c'est
        // CETTE `Task` qu'on annule, pas `viewModel.send(query:)` directement
        // (sinon `Task.isCancelled` lu à l'intérieur de `send(query:)` serait
        // faux, et ce test exercerait par erreur la branche
        // `.emptyResponse`).
        let task = Task { await viewModel.send(query: "requête") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            Issue.record("continuation jamais assignée")
            task.cancel()
            return
        }

        continuation.yield("Voici un début")
        await waitUntil("le message assistant reflète le 1er chunk") {
            await viewModel.messages.last?.text == "Voici un début"
        }

        task.cancel()
        await task.value

        let lastMessage = await viewModel.messages.last
        #expect(lastMessage?.text == "Voici un début")
        #expect(lastMessage?.isStreaming == false)

        let errorDescription = await viewModel.errorDescription
        #expect(errorDescription == nil)

        let isGenerating = await viewModel.isGenerating
        #expect(isGenerating == false)
    }

    @Test("Annuler la Task englobante PENDANT la recherche (avant même que streamAnswer crée un textStream) n'est PAS traité comme une erreur — errorDescription reste nil (finding ChatViewModel.swift:166 de la revue 0.8)")
    func cancellingDuringInFlightSearchIsNotReportedAsError() async {
        let client = ControllableSearXNGClient()
        let failoverManager = FailoverManager(client: client, instances: [Self.instance])
        let aiProvider = MockStreamingAIGenerating()
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        let task = Task { await viewModel.send(query: "requête") }
        await waitUntil("la recherche est en vol dans FailoverManager.search") {
            await client.continuation != nil
        }

        // Annule la Task englobante PUIS fait échouer la recherche en cours
        // avec l'erreur que produirait cette annulation (voir
        // `FailoverManager.search`, qui rethrow directement quand
        // `Task.isCancelled` est vrai) — reproduit l'ordonnancement exact du
        // scénario du finding.
        task.cancel()
        await client.fail(with: CancellationError())
        await task.value

        let messages = await viewModel.messages
        #expect(messages.count == 2)
        let assistantMessage = messages[1]
        #expect(assistantMessage.isStreaming == false)
        #expect(assistantMessage.text.isEmpty)

        let errorDescription = await viewModel.errorDescription
        #expect(errorDescription == nil)

        let isGenerating = await viewModel.isGenerating
        #expect(isGenerating == false)
    }

    @Test("Une erreur levée par le flux du provider EXACTEMENT au moment de l'annulation n'est pas traitée comme un échec — Task.isCancelled vérifié avant fail() dans le catch qui entoure textStream (finding ChatViewModel.swift:163 de la revue 0.8)")
    func streamErrorDuringCancellationIsNotReportedAsError() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let aiProvider = ControllableStreamingAIGenerating()
        let viewModel = await ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { failoverManager }
        )

        let task = Task { await viewModel.send(query: "requête") }
        guard let continuation = await waitForContinuation(aiProvider) else {
            Issue.record("continuation jamais assignée")
            task.cancel()
            return
        }

        continuation.yield("Voici un début")
        await waitUntil("le message assistant reflète le 1er chunk") {
            await viewModel.messages.last?.text == "Voici un début"
        }

        // Annule la Task englobante PUIS fait échouer le flux lui-même (pas
        // une terminaison normale) : simule le provider dont la session
        // réseau échoue de son côté exactement au moment où l'utilisateur
        // quitte l'écran.
        task.cancel()
        continuation.finish(throwing: MockError.midStreamFailure)
        await task.value

        let lastMessage = await viewModel.messages.last
        #expect(lastMessage?.text == "Voici un début")
        #expect(lastMessage?.isStreaming == false)

        let errorDescription = await viewModel.errorDescription
        #expect(errorDescription == nil)
    }

    // MARK: - Messages d'erreur compréhensibles (finding 19 de la revue 0.8)

    @Test("Une ActiveAIProviderResolverError connue (ex. noCloudSelectionStored) est traduite en message français clair, pas le nom brut de l'enum")
    func knownResolverErrorIsTranslatedToFriendlyMessage() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let viewModel = await ChatViewModel(
            resolveProvider: { throw ActiveAIProviderResolverError.noCloudSelectionStored },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "Test")

        let errorDescription = await viewModel.errorDescription
        #expect(errorDescription == "Aucun fournisseur configuré. Va dans Réglages pour en choisir un.")
        #expect(errorDescription?.contains("noCloudSelectionStored") == false)
    }

    @Test("MLXProviderError.simulatorUnsupported (garde-fou anti-crash sur le Simulateur) est traduit en message clair, pas le nom brut du cas")
    func simulatorUnsupportedErrorIsTranslatedToFriendlyMessage() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let viewModel = await ChatViewModel(
            resolveProvider: { throw MLXProviderError.simulatorUnsupported },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "Test")

        let errorDescription = await viewModel.errorDescription
        #expect(errorDescription == "Les modèles locaux (MLX) ne fonctionnent pas sur le Simulateur — teste sur un appareil réel.")
        #expect(errorDescription?.contains("simulatorUnsupported") == false)
    }

    @Test("Une erreur inconnue du mapping (ex. erreur de test) retombe sur String(describing:) plutôt qu'un message inventé")
    func unknownErrorFallsBackToRawDescription() async {
        let failoverManager = FailoverManager(client: MockSearXNGClient(), instances: [Self.instance])
        let viewModel = await ChatViewModel(
            resolveProvider: { throw MockError.providerResolutionFailed },
            resolveFailoverManager: { failoverManager }
        )

        await viewModel.send(query: "Test")

        let errorDescription = await viewModel.errorDescription
        #expect(errorDescription?.contains("providerResolutionFailed") == true)
    }
}
