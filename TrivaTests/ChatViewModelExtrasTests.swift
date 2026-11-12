//
//  ChatViewModelExtrasTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 07/09/2026.
//

import Testing
import Foundation
@testable import Triva

extension ChatViewModelTests {
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
