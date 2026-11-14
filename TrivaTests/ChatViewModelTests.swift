//
//  ChatViewModelTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 07/09/2026.
//

import Testing
import Foundation
@testable import Triva

@MainActor
@Suite("ChatViewModel")
struct ChatViewModelTests {
}

extension ChatViewModelTests {
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

        // Événement plutôt que délai : une seconde question aboutit, ses suggestions sont demandées ; la
        // question annulée n'a laissé aucune demande dans l'enregistreur.
        let secondTask = Task { await viewModel.send(query: "seconde question") }
        await waitUntil("la seconde question atteint le provider") { aiProvider.receivedPrompts.count == 2 }
        aiProvider.continuation?.yield("Fin.")
        aiProvider.continuation?.finish()
        await secondTask.value
        await waitUntil("suggestions de la seconde question demandées") { suggestions.histories.count >= 1 }
        #expect(suggestions.histories.count == 1)
        #expect(suggestions.histories.first?.last { $0.role == .user }?.content == "seconde question")
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

}
