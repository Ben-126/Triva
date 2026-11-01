//
//  ChatViewModel.swift
//  Triva
//
//  Created by ben podrojsky on 07/09/2026.
//

import Foundation
import os

/// Erreurs propres à `ChatViewModel`, distinctes de celles du provider IA ou
/// de la recherche.
enum ChatViewModelError: Error, Sendable, Equatable {
    /// Flux terminé sans aucun texte non vide (0 yield, ou dernier snapshot
    /// vide/blanc) : filtrage de contenu, complétion vide. Sans ce cas, la
    /// bulle sortirait du streaming vide et sans erreur — un échec silencieux.
    case emptyResponse
}

/// Logique du chat (0.8, branchée sur la V1 par I2) : un échange question ->
/// recherche -> génération en streaming, et ce qui l'entoure — mode (1.13),
/// widgets (1.5), médias à la demande (1.6), suggestions (1.7), historique
/// (1.9), favoris (1.10), fichiers joints (1.11), raisonnement (1.14) et
/// validateur de structure (1.4).
///
/// Ne connaît ni SwiftUI ni la résolution du moteur : tout est injecté par
/// closures (`SearchSession`, `ContentView.swift`), avec des défauts SÛRS pour
/// que l'appel existant compile inchangé — historique et favoris à `nil`
/// (jamais une seconde instance de store, dont la `revision` divergerait),
/// budget `.appleIntelligence` (le plus serré : un oubli dégrade une réponse
/// cloud, il ne fait jamais déborder un petit modèle), mode relu à chaque envoi.
///
/// ## Annulation
/// L'échange tourne dans une `Task` interne reliée à l'appelant par
/// `withTaskCancellationHandler` : le Stop de `ChatView` (annulation de sa
/// `sendTask`) et `startNewConversation()` aboutissent au même
/// `Task.isCancelled`, vérifié dans LES DEUX `catch` — une annulation n'est
/// jamais un échec ni une réponse vide. Le jeton `activeExchangeID` empêche un
/// échange remplacé, qui finit de se dérouler, de toucher l'état du suivant.
@Observable
@MainActor
final class ChatViewModel {
    /// Un message du fil, `Equatable` pour `MessageBubbleView.equatable()`.
    /// L'affichage y est PRÉ-CALCULÉ (segments, widgets typés).
    struct Message: Identifiable, Sendable, Equatable {
        enum Role: Sendable, Equatable {
            case user
            case assistant
        }

        /// Issue d'une réponse : l'historique du classifieur ne garde que les
        /// succès, `isStreaming` seul ne les distinguait pas.
        enum Status: Sendable, Equatable {
            case streaming
            case completed
            /// Texte partiel conservé, message dans `errorDescription`.
            case failed
            /// Stop, écran quitté, nouvelle conversation.
            case interrupted
            /// Décision (c) : mode Fiable sans source fiable, rien de généré.
            /// Afficher `noReliableSourcesMessage`, proposer `retryInQuickMode`.
            case noReliableSources
        }

        /// Fichier joint à la question : un résumé, jamais le texte indexé.
        struct AttachedFile: Sendable, Equatable, Identifiable {
            let id: UUID
            let fileName: String
            let kind: AttachmentKind
        }

        /// Widget abouti, au-dessus de la réponse. Typé ici :
        /// `SearchWidgetOutput` (charge utile existentielle) n'est pas `Equatable`.
        enum Widget: Sendable, Equatable {
            case weather(WeatherWidgetData)
            case calculation(CalculationWidgetData)

            init?(_ output: SearchWidgetOutput) {
                if let weather = output.weatherData {
                    self = .weather(weather)
                } else if let calculation = output.calculationData {
                    self = .calculation(calculation)
                } else {
                    return nil
                }
            }
        }

        let id: UUID
        let role: Role
        /// Texte BRUT, balises `<think>`/`<tldr>` comprises : c'est lui qui est
        /// persisté et mis en favori. La vue affiche `segments`.
        private(set) var text: String
        /// `ReasoningSegmenter` appliqué une fois par snapshot (passe linéaire).
        private(set) var segments: ReasoningSegments
        /// Pour « A réfléchi pendant N s » ; inconnu pour un message relu.
        private(set) var reasoningTiming = ReasoningTiming()
        private(set) var status: Status
        /// Ordre des citations : `[n]` désigne `sources[n - 1]`.
        var sources: [SearXNGSearchResult]
        /// Les N premières sources sont des fichiers joints (pas de lien).
        var attachmentSourceCount = 0
        var widgets: [Widget] = []
        /// À la demande (décision (a)) : `.idle` affiche le bouton.
        var images: ImageResultsPhase = .idle
        var videos: VideoResultsPhase = .idle
        /// Reformulation du classifieur, sujet des recherches médias.
        var searchQuery: String?
        /// Seule la dernière réponse terminée en porte.
        var suggestions: [String] = []
        var attachedFiles: [AttachedFile] = []
        /// `id` du `StoredMessage` : SEULE clé des favoris, stable d'un
        /// lancement à l'autre. `nil` pendant le streaming ou sans historique.
        var storedMessageID: UUID?
        var storedConversationID: UUID?
        /// Diagnostic du validateur de structure, sans UI.
        var structureReport: ResponseStructureReport?

        var isStreaming: Bool { status == .streaming }

        init(
            id: UUID = UUID(),
            role: Role,
            text: String = "",
            sources: [SearXNGSearchResult] = [],
            isStreaming: Bool = false
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.sources = sources
            self.status = isStreaming ? .streaming : .completed
            self.segments = ReasoningSegmenter.segment(text, isStreaming: isStreaming)
        }

        /// Snapshot CUMULATIF : il remplace le texte, jamais de concaténation.
        mutating func apply(snapshot: String, at date: Date) {
            text = snapshot
            segments = ReasoningSegmenter.segment(snapshot, isStreaming: true)
            reasoningTiming = reasoningTiming.updated(for: segments.reasoningPhase, at: date)
        }

        /// Fin de flux : relâche les fragments retenus et fige la phase (un
        /// bloc resté ouvert devient `.interrupted`, jamais replié).
        mutating func finish(_ newStatus: Status, at date: Date) {
            status = newStatus
            segments = ReasoningSegmenter.segment(text, isStreaming: false)
            reasoningTiming = reasoningTiming.updated(for: segments.reasoningPhase, at: date)
        }

        mutating func attach(_ artifacts: SearchArtifacts) {
            sources = artifacts.sources
            attachmentSourceCount = artifacts.attachmentSourceCount
            widgets = artifacts.widgets.compactMap { Widget($0) }
            searchQuery = artifacts.searchQuery
        }

        mutating func markNoReliableSources(searchQuery: String, at date: Date) {
            self.searchQuery = searchQuery
            finish(.noReliableSources, at: date)
        }
    }

    /// Dépendances de l'orchestrateur d'UN envoi : moteur, budget, mode figé.
    struct OrchestratorInputs {
        let failoverManager: FailoverManager
        let provider: any AIGenerating
        let responseMode: ResponseMode
        let configuration: SearchPipelineConfiguration
    }

    /// Décision (c) de Ben : textes fixes de l'état `.noReliableSources`.
    static let noReliableSourcesMessage = "Aucune source fiable pour ce type de question."
    static let retryInQuickModeTitle = "Relancer en mode Rapide"
    static let missingConversationMessage = "Cette conversation n'existe plus."

    private(set) var messages: [Message] = []
    private(set) var isGenerating = false
    /// Échec de l'échange : SEULE source du bandeau d'erreur, jamais recopiée
    /// dans la bulle (le même texte deux fois à l'écran).
    private(set) var errorDescription: String?
    /// Échec d'écriture de l'historique ou des favoris : séparé, la réponse a
    /// abouti — n'écrase jamais `errorDescription`.
    private(set) var persistenceErrorDescription: String?
    /// `StoredConversation.id` du fil. Jamais la référence SwiftData :
    /// supprimée depuis la Bibliothèque, elle resterait lisible.
    private(set) var currentConversationID: UUID?
    /// Fichiers joints de la conversation (1.11), même durée de vie : à
    /// brancher tel quel sur `FileAttachmentPicker` / `FileAttachmentTray`.
    let attachmentController: FileAttachmentController

    private let resolveProvider: () async throws -> any AIGenerating
    private let resolveFailoverManager: () throws -> FailoverManager
    private let resolvePipelineConfiguration: @MainActor () -> SearchPipelineConfiguration
    private let readResponseMode: @MainActor () -> ResponseMode
    private let makeOrchestrator: @MainActor (OrchestratorInputs) -> SearchOrchestrator
    private let generateSuggestions: @MainActor (any AIGenerating, [ClassifierChatMessage]) async -> [String]
    private let makeMediaSearcher: @MainActor (FailoverManager) -> any MediaSearching
    private let historyStore: ChatHistoryStore?
    private let favoritesStore: FavoritesStore?
    private let now: @MainActor () -> Date

    @ObservationIgnored private var activeExchangeID: UUID?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionsTask: Task<Void, Never>?
    @ObservationIgnored private var mediaTasks: [MediaRequest: Task<Void, Never>] = [:]
    @ObservationIgnored private var favoritesCache: (revision: Int, ids: Set<UUID>)?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Triva", category: "ChatViewModel")

    /// - Parameters:
    ///   - resolvePipelineConfiguration: budget du moteur qui a produit le
    ///     provider (bug 6), `SearchPipelineConfiguration.preset(for:mlxModel:)` ;
    ///     appelée juste après `resolveProvider`, dans le même envoi.
    ///   - readResponseMode: mode mémorisé, lu à CHAQUE envoi.
    ///   - historyStore, favoritesStore: instances UNIQUES de l'app
    ///     (`TrivaSharedStores`), ou `nil` : rien n'est persisté.
    ///   - makeOrchestrator, generateSuggestions, makeMediaSearcher, now:
    ///     coutures de test ; défauts de production.
    init(
        resolveProvider: @escaping () async throws -> any AIGenerating,
        resolveFailoverManager: @escaping () throws -> FailoverManager,
        resolvePipelineConfiguration: @escaping @MainActor () -> SearchPipelineConfiguration = { .appleIntelligence },
        readResponseMode: @escaping @MainActor () -> ResponseMode = { ChatViewModel.persistedResponseMode() },
        historyStore: ChatHistoryStore? = nil,
        favoritesStore: FavoritesStore? = nil,
        attachmentController: FileAttachmentController? = nil,
        makeOrchestrator: @escaping @MainActor (OrchestratorInputs) -> SearchOrchestrator = { inputs in
            SearchOrchestrator(
                failoverManager: inputs.failoverManager,
                aiProvider: inputs.provider,
                responseMode: inputs.responseMode,
                configuration: inputs.configuration
            )
        },
        generateSuggestions: @escaping @MainActor (any AIGenerating, [ClassifierChatMessage]) async -> [String] = { provider, history in
            await SuggestionsService(aiProvider: provider).generateSuggestions(chatHistory: history)
        },
        makeMediaSearcher: @escaping @MainActor (FailoverManager) -> any MediaSearching = { SearXNGMediaSearcher(failoverManager: $0) },
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.resolveProvider = resolveProvider
        self.resolveFailoverManager = resolveFailoverManager
        self.resolvePipelineConfiguration = resolvePipelineConfiguration
        self.readResponseMode = readResponseMode
        self.historyStore = historyStore
        self.favoritesStore = favoritesStore
        self.attachmentController = attachmentController ?? FileAttachmentController(store: AttachmentStore())
        self.makeOrchestrator = makeOrchestrator
        self.generateSuggestions = generateSuggestions
        self.makeMediaSearcher = makeMediaSearcher
        self.now = now
    }

    // MARK: - Envoi

    /// Un envoi, figé au départ : changer le mode ou les fichiers pendant la
    /// génération ne concerne que la question suivante.
    private struct Exchange: Sendable {
        let question: String
        let history: [ClassifierChatMessage]
        let mode: ResponseMode
        let attachments: AttachmentSearchIndex?
        let conversationID: UUID?
        let answerID: UUID
    }

    /// Ce que l'échange a produit, tenu HORS du fil : `startNewConversation()`
    /// peut retirer le message, la réponse partielle doit quand même être persistée.
    private struct AnswerDraft {
        var text = ""
        var sources: [SearXNGSearchResult] = []
        var isComplete = false
    }

    /// Envoie `query` (ignorée si vide/blanche ou si un envoi est en cours).
    /// Ajoute la question (texte trimmé, fichiers joints apparus depuis la
    /// précédente) puis une réponse en streaming ; sources et widgets sont
    /// attachés AVANT le premier morceau de texte. Toute erreur va dans
    /// `errorDescription`, et la réponse sort TOUJOURS du streaming.
    func send(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !isGenerating else { return }

        // Avant d'ajouter la question, qui serait sinon en double dans le prompt.
        let history = Self.classifierHistory(from: messages)
        var question = Message(role: .user, text: trimmedQuery)
        question.attachedFiles = newlyAttachedFiles()
        messages.append(question)
        // Contrat de `FileAttachmentController` : les avis partent à l'envoi,
        // les capsules restent (chaque question consulte encore les fichiers).
        attachmentController.dismissAllNotices()
        persistenceErrorDescription = nil
        let conversationID = persistQuestion(trimmedQuery)

        let answerID = UUID()
        messages.append(Message(id: answerID, role: .assistant, isStreaming: true))
        await runExchange(Exchange(
            question: trimmedQuery,
            history: history,
            mode: readResponseMode(),
            attachments: attachmentSnapshot(),
            conversationID: conversationID,
            answerID: answerID
        ))
    }

    /// Le bouton « Relancer en mode Rapide » n'a de sens que sur la DERNIÈRE
    /// réponse du fil, restée `.noReliableSources`, hors génération : une
    /// réponse plus ancienne serait écrite en FIN de conversation
    /// (`ChatHistoryStore` ajoute toujours après le dernier message), donc
    /// après des échanges qui l'ont suivie — un ordre faux à la relecture.
    func canRetryInQuickMode(_ message: Message) -> Bool {
        !isGenerating && message.status == .noReliableSources && messages.last?.id == message.id
    }

    /// Décision (c) : relance la MÊME question en mode Rapide, à la place de
    /// la réponse `.noReliableSources` (voir `canRetryInQuickMode(_:)`).
    /// Question non réécrite dans l'historique, mode mémorisé inchangé.
    /// `async` comme `send`, annulable de même (même `Task` côté vue).
    func retryInQuickMode(messageID: UUID) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              canRetryInQuickMode(messages[index]),
              let questionIndex = messages[..<index].lastIndex(where: { $0.role == .user }) else { return }
        let question = messages[questionIndex].text
        let replaced = messages[index]
        messages[index] = Message(id: messageID, role: .assistant, isStreaming: true)
        persistenceErrorDescription = nil
        deleteStoredMessage(id: replaced.storedMessageID, conversationID: replaced.storedConversationID)
        await runExchange(Exchange(
            question: question,
            history: Self.classifierHistory(from: Array(messages[..<questionIndex])),
            mode: .quick,
            attachments: attachmentSnapshot(),
            conversationID: currentConversationID,
            answerID: messageID
        ))
    }

    private func runExchange(_ exchange: Exchange) async {
        let exchangeID = UUID()
        activeExchangeID = exchangeID
        isGenerating = true
        errorDescription = nil
        suggestionsTask?.cancel()
        for index in messages.indices where !messages[index].suggestions.isEmpty {
            messages[index].suggestions = []
        }

        let task = Task { await self.perform(exchange, exchangeID: exchangeID) }
        generationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard activeExchangeID == exchangeID else { return }
        activeExchangeID = nil
        generationTask = nil
        isGenerating = false
    }

    private func perform(_ exchange: Exchange, exchangeID: UUID) async {
        var answer = AnswerDraft()
        defer { persistAnswer(answer, exchange: exchange) }
        do {
            let provider = try await resolveProvider()
            let orchestrator = makeOrchestrator(OrchestratorInputs(
                failoverManager: try resolveFailoverManager(),
                provider: provider,
                responseMode: exchange.mode,
                configuration: resolvePipelineConfiguration()
            ))
            // `media: []` : images et vidéos À LA DEMANDE (décision (a)).
            let streamingAnswer = try await orchestrator.streamAnswer(
                query: exchange.question,
                chatHistory: exchange.history,
                attachments: exchange.attachments,
                media: []
            )
            let artifacts = streamingAnswer.artifacts
            if Self.lacksReliableSources(artifacts) {
                // Décision (c) : jamais de réponse sans source en mode Fiable.
                // Flux non lu ; relâché, son `onTermination` annule la génération.
                let date = now()
                updateMessage(id: exchange.answerID) { $0.markNoReliableSources(searchQuery: artifacts.searchQuery, at: date) }
                persistNoReliableSources(exchange: exchange)
                return
            }
            answer.sources = artifacts.sources
            updateMessage(id: exchange.answerID) { $0.attach(artifacts) }
            answer = await consume(streamingAnswer.textStream, into: answer, exchange: exchange, exchangeID: exchangeID)
            if answer.isComplete {
                didComplete(exchange, exchangeID: exchangeID, text: answer.text, artifacts: artifacts, orchestrator: orchestrator, provider: provider)
            }
        } catch {
            // Échec AVANT le flux (résolution, recherche encore en vol) : même
            // garde que dans `consume`, une erreur due à l'annulation n'est pas un échec.
            if Task.isCancelled {
                finishAnswer(exchange.answerID, as: .interrupted)
            } else {
                fail(answerID: exchange.answerID, exchangeID: exchangeID, error: error)
            }
        }
    }

    /// Lit le flux. C'est le CONTENU du dernier snapshot qui dit si le modèle a
    /// répondu : un unique yield de `""` vaut un flux à 0 yield (`.emptyResponse`).
    private func consume(
        _ textStream: AsyncThrowingStream<String, Error>,
        into draft: AnswerDraft,
        exchange: Exchange,
        exchangeID: UUID
    ) async -> AnswerDraft {
        var answer = draft
        do {
            for try await snapshot in textStream {
                answer.text = snapshot
                let date = now()
                updateMessage(id: exchange.answerID) { $0.apply(snapshot: snapshot, at: date) }
            }
            let hasContent = !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if Task.isCancelled {
                finishAnswer(exchange.answerID, as: .interrupted)
            } else if hasContent {
                answer.isComplete = true
                finishAnswer(exchange.answerID, as: .completed)
            } else {
                fail(answerID: exchange.answerID, exchangeID: exchangeID, error: ChatViewModelError.emptyResponse)
            }
        } catch {
            // Erreur levée alors que la tâche est déjà annulée (le provider
            // ferme sa session quand l'écran se ferme) : arrêt volontaire.
            if Task.isCancelled {
                finishAnswer(exchange.answerID, as: .interrupted)
            } else {
                fail(answerID: exchange.answerID, exchangeID: exchangeID, error: error)
            }
        }
        return answer
    }

    /// Réponse terminée et non vide : diagnostic de structure, puis
    /// suggestions dans une tâche à part — rien n'attend, annulées par l'envoi
    /// suivant ; le service ne lève jamais (échec = `[]`), aucune erreur affichée.
    private func didComplete(
        _ exchange: Exchange,
        exchangeID: UUID,
        text: String,
        artifacts: SearchArtifacts,
        orchestrator: SearchOrchestrator,
        provider: any AIGenerating
    ) {
        let report = ResponseStructureValidator().validate(
            text,
            mode: artifacts.mode,
            complexity: artifacts.promptComplexity,
            citableSourceCount: artifacts.citableSourceCount
        )
        updateMessage(id: exchange.answerID) { $0.structureReport = report }
        guard activeExchangeID == exchangeID else { return }

        let history = orchestrator.suggestionsHistory(previousTurns: exchange.history, query: exchange.question, answer: text)
        let answerID = exchange.answerID
        suggestionsTask = Task {
            let suggestions = await self.generateSuggestions(provider, history)
            guard !Task.isCancelled else { return }
            self.updateMessage(id: answerID) { $0.suggestions = suggestions }
        }
    }

    /// Échec : `errorDescription` (seulement par l'échange actif), texte
    /// déjà streamé conservé tel quel.
    private func fail(answerID: UUID, exchangeID: UUID, error: any Error) {
        if activeExchangeID == exchangeID {
            errorDescription = Self.userFacingMessage(for: error)
        }
        finishAnswer(answerID, as: .failed)
    }

    private func finishAnswer(_ answerID: UUID, as status: Message.Status) {
        let date = now()
        updateMessage(id: answerID) { $0.finish(status, at: date) }
    }

    // MARK: - Conversation

    /// Décision 1 de Ben, « Nouvelle conversation » : annule ce qui est en
    /// cours (la réponse partielle est persistée dans l'ANCIENNE conversation,
    /// qui reste dans la Bibliothèque), vide le fil et les fichiers joints.
    /// `isGenerating` repasse à `false` sans attendre la fin de l'échange annulé.
    func startNewConversation() {
        generationTask?.cancel()
        suggestionsTask?.cancel()
        for task in mediaTasks.values {
            task.cancel()
        }
        generationTask = nil
        suggestionsTask = nil
        mediaTasks = [:]
        activeExchangeID = nil
        isGenerating = false
        messages = []
        errorDescription = nil
        persistenceErrorDescription = nil
        currentConversationID = nil
        // Par le contrôleur, jamais `store.removeAll()` seul : un fichier en
        // cours de lecture s'attacherait sinon à la nouvelle conversation.
        attachmentController.removeAll()
    }

    /// Rouvre une conversation de la Bibliothèque (ou d'un favori,
    /// `StoredFavorite.conversationID`) ; les envois suivants s'y ajoutent.
    /// Sans effet si c'est déjà celle du fil. `false` si elle n'existe plus ou
    /// si l'historique est illisible (`persistenceErrorDescription`). Les
    /// fichiers joints ne survivent pas à leur conversation.
    @discardableResult
    func loadConversation(id: UUID) -> Bool {
        if id == currentConversationID { return true }
        guard let historyStore else { return false }
        let restored: [Message]
        do {
            guard let conversation = try historyStore.conversation(with: id) else {
                persistenceErrorDescription = Self.missingConversationMessage
                return false
            }
            restored = conversation.orderedMessages.map { Self.restoredMessage($0, conversationID: id) }
        } catch {
            reportPersistenceFailure(error)
            return false
        }
        startNewConversation()
        messages = restored
        currentConversationID = id
        return true
    }

    /// Contrat de `LibraryView.onConversationDeleted` : conversation du fil
    /// supprimée -> le chat repart à neuf. Après « tout effacer » :
    /// `startNewConversation()`.
    func conversationWasDeleted(id: UUID) {
        guard id == currentConversationID else { return }
        startNewConversation()
    }

    /// Message relu : terminé par construction (rien n'est persisté avant la
    /// fin du flux), sources dans l'ordre de citation, fichiers joints
    /// recomptés depuis leur URL synthétique, médias à `.idle`.
    private static func restoredMessage(_ stored: StoredMessage, conversationID: UUID) -> Message {
        let sources = stored.orderedSources.map { source in
            SearXNGSearchResult(
                title: source.title, url: source.url, content: source.snippet,
                imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
            )
        }
        if stored.role == .assistant && stored.reportsNoReliableSources {
            var message = Message(role: .assistant)
            message.finish(.noReliableSources, at: stored.createdAt)
            message.storedMessageID = stored.id
            message.storedConversationID = conversationID
            return message
        }
        var message = Message(role: stored.role == .user ? .user : .assistant, text: stored.text, sources: sources)
        message.attachmentSourceCount = sources.prefix { UploadsSearchResultBuilder.attachmentID(fromSourceURL: $0.url) != nil }.count
        if message.role == .assistant {
            message.storedMessageID = stored.id
            message.storedConversationID = conversationID
        }
        return message
    }

    // MARK: - Historique (1.9)

    /// Politique de `ChatHistoryStore`, point 1 : la question est écrite À
    /// L'ENVOI. Renvoie la conversation où l'échange écrira sa réponse.
    private func persistQuestion(_ question: String) -> UUID? {
        guard let historyStore else { return nil }
        do {
            let conversation = try writableConversation(in: historyStore, firstQuestion: question)
            try historyStore.appendUserMessage(to: conversation, text: question, now: now())
            currentConversationID = conversation.id
            return conversation.id
        } catch {
            reportPersistenceFailure(error)
            return nil
        }
    }

    /// Conversation du fil, ou une nouvelle si aucune n'est ouverte — ou si
    /// elle a été supprimée entre-temps.
    private func writableConversation(in store: ChatHistoryStore, firstQuestion: String) throws -> StoredConversation {
        if let currentConversationID, let existing = try store.conversation(with: currentConversationID) {
            return existing
        }
        return try store.createConversation(firstQuestion: firstQuestion, now: now())
    }

    /// Points 2 et 3 : réponse écrite AU PLUS UNE FOIS, en fin d'échange
    /// QUELLE QU'EN SOIT LA CAUSE (succès, erreur, annulation), texte partiel
    /// compris, jamais vide ; dans la conversation capturée à l'envoi.
    private func persistAnswer(_ answer: AnswerDraft, exchange: Exchange) {
        guard let historyStore, let conversationID = exchange.conversationID,
              !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            // Supprimée pendant la génération : rien à compléter.
            guard let conversation = try historyStore.conversation(with: conversationID) else { return }
            let stored = try historyStore.appendAssistantMessage(to: conversation, text: answer.text, sources: answer.sources, now: now())
            let storedID = stored.id
            updateMessage(id: exchange.answerID) { message in
                message.storedMessageID = storedID
                message.storedConversationID = conversationID
            }
        } catch {
            reportPersistenceFailure(error)
        }
    }

    /// Décision de Ben (2026-10-30) : l'état « Aucune source fiable » est
    /// persisté, pour qu'une conversation relue montre le message fixe et,
    /// sur la dernière réponse, le bouton de relance.
    private func persistNoReliableSources(exchange: Exchange) {
        guard let historyStore, let conversationID = exchange.conversationID else { return }
        do {
            guard let conversation = try historyStore.conversation(with: conversationID) else { return }
            let stored = try historyStore.appendNoReliableSourcesMessage(
                to: conversation, text: Self.noReliableSourcesMessage, now: now()
            )
            let storedID = stored.id
            updateMessage(id: exchange.answerID) { message in
                message.storedMessageID = storedID
                message.storedConversationID = conversationID
            }
        } catch {
            reportPersistenceFailure(error)
        }
    }

    /// Relance : la réponse « Aucune source fiable » persistée est remplacée
    /// par la nouvelle, pas laissée devant elle dans la conversation relue.
    private func deleteStoredMessage(id storedID: UUID?, conversationID: UUID?) {
        guard let historyStore, let storedID, let conversationID else { return }
        do {
            guard let conversation = try historyStore.conversation(with: conversationID),
                  let stored = conversation.messages.first(where: { $0.id == storedID }) else { return }
            try historyStore.delete(stored)
        } catch {
            reportPersistenceFailure(error)
        }
    }

    private func reportPersistenceFailure(_ error: any Error) {
        persistenceErrorDescription = Self.userFacingMessage(for: error)
    }

    // MARK: - Favoris (1.10)

    /// Étoile pleine ? Lit `favoritesStore.revision` : appelée dans un `body`,
    /// la vue se redessine quand un favori change ailleurs (écran Favoris à
    /// côté du chat sur iPad / Mac). Identifiants relus une fois par révision.
    func isFavorite(_ message: Message) -> Bool {
        guard let storedID = message.storedMessageID else { return false }
        return favoritedStoredMessageIDs().contains(storedID)
    }

    /// Réponse terminée ET persistée : le favori porte l'`id` du
    /// `StoredMessage`, jamais l'UUID éphémère de la bulle. Donc jamais
    /// pendant le streaming, ni sans historique.
    func canToggleFavorite(_ message: Message) -> Bool {
        favoritesStore != nil && message.role == .assistant && !message.isStreaming
            && message.status != .noReliableSources && message.storedMessageID != nil
    }

    /// Marque ou retire une réponse : question = celle qui la précède, réponse
    /// = texte brut et sources dans l'ordre de citation.
    func toggleFavorite(messageID: UUID) {
        guard let favoritesStore,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              canToggleFavorite(messages[index]),
              let storedID = messages[index].storedMessageID else { return }
        let message = messages[index]
        do {
            if favoritedStoredMessageIDs().contains(storedID) {
                try favoritesStore.unmark(messageID: storedID)
            } else {
                try favoritesStore.mark(
                    messageID: storedID,
                    conversationID: message.storedConversationID,
                    question: precedingQuestion(beforeIndex: index) ?? "",
                    answer: message.text,
                    sources: message.sources,
                    now: now()
                )
            }
        } catch {
            reportPersistenceFailure(error)
        }
    }

    private func favoritedStoredMessageIDs() -> Set<UUID> {
        guard let favoritesStore else { return [] }
        let revision = favoritesStore.revision
        if let favoritesCache, favoritesCache.revision == revision {
            return favoritesCache.ids
        }
        do {
            let ids = try favoritesStore.favoritedMessageIDs()
            favoritesCache = (revision, ids)
            return ids
        } catch {
            // Appelée depuis un `body` : aucune écriture d'état observé ici.
            Self.logger.error("Lecture des favoris impossible : \(String(describing: error), privacy: .private)")
            return favoritesCache?.ids ?? []
        }
    }

    // MARK: - Médias à la demande (1.6, décision (a))

    private enum MediaKind: Hashable {
        case images
        case videos
    }

    private struct MediaRequest: Hashable {
        let messageID: UUID
        let kind: MediaKind
    }

    /// Bouton de `ImageResultsView` : la recherche ne part QUE sur demande.
    /// Sujet : `searchQuery` de la réponse (pas d'appel LLM de plus), ou la
    /// question d'un message relu. Ignorée pendant le streaming ou si la même
    /// recherche est déjà en cours.
    func searchImages(messageID: UUID) {
        startMediaSearch(.images, messageID: messageID)
    }

    /// Bouton de `VideoResultsView`, mêmes règles que `searchImages(messageID:)`.
    func searchVideos(messageID: UUID) {
        startMediaSearch(.videos, messageID: messageID)
    }

    private func startMediaSearch(_ kind: MediaKind, messageID: UUID) {
        let request = MediaRequest(messageID: messageID, kind: kind)
        guard mediaTasks[request] == nil,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .assistant, !messages[index].isStreaming else { return }
        let query = messages[index].searchQuery ?? precedingQuestion(beforeIndex: index) ?? ""
        guard !query.isEmpty else { return }
        switch kind {
        case .images: messages[index].images = .loading
        case .videos: messages[index].videos = .loading
        }
        mediaTasks[request] = Task {
            await self.runMediaSearch(kind, query: query, messageID: messageID)
            self.mediaTasks[request] = nil
        }
    }

    /// Erreur -> `.failed`, jamais son texte (contrat de 1.6). Un résultat
    /// arrivé après une nouvelle conversation ne trouve plus son message.
    private func runMediaSearch(_ kind: MediaKind, query: String, messageID: UUID) async {
        do {
            let searcher = makeMediaSearcher(try resolveFailoverManager())
            switch kind {
            case .images:
                let images = try await searcher.searchImages(query: query)
                updateMessage(id: messageID) { $0.images = .loaded(images) }
            case .videos:
                let videos = try await searcher.searchVideos(query: query)
                updateMessage(id: messageID) { $0.videos = .loaded(videos) }
            }
        } catch {
            updateMessage(id: messageID) { message in
                switch kind {
                case .images: message.images = .failed
                case .videos: message.videos = .failed
                }
            }
        }
    }

    // MARK: - Utilitaires

    /// Fichiers apparus depuis la question précédente : un fichier reste
    /// attaché à toute la conversation, il ne s'affiche que sous la question
    /// avec laquelle il est parti.
    private func newlyAttachedFiles() -> [Message.AttachedFile] {
        let alreadyShown = Set(messages.flatMap(\.attachedFiles).map(\.id))
        return attachmentController.attachments
            .filter { !alreadyShown.contains($0.id) }
            .map { Message.AttachedFile(id: $0.id, fileName: $0.fileName, kind: $0.kind) }
    }

    /// Instantané `Sendable` pour le pipeline, `nil` sans fichier joint.
    private func attachmentSnapshot() -> AttachmentSearchIndex? {
        attachmentController.attachments.isEmpty ? nil : attachmentController.store.searchIndex
    }

    private func precedingQuestion(beforeIndex index: Int) -> String? {
        messages[..<index].last { $0.role == .user }?.text
    }

    private func updateMessage(id: UUID, _ update: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        update(&messages[index])
    }

    /// Historique du classifieur ET du prompt final (bug 1) : les tours
    /// PRÉCÉDENTS seulement (sinon la question serait dupliquée dans
    /// `<conversation_history>` en plus de `<user_query>`). Une réponse y
    /// entre par son texte VISIBLE — sans `<think>` ni `<tldr>`, contrat
    /// d'I1a — et seulement terminée et non vide : un échange en échec,
    /// interrompu, sans source fiable ou sans réponse est retiré EN ENTIER,
    /// question comprise — le modèle ne l'a jamais vu aboutir.
    static func classifierHistory(from messages: [Message]) -> [ClassifierChatMessage] {
        var history: [ClassifierChatMessage] = []
        var pendingQuestion: String?
        for message in messages {
            guard message.role == .assistant else {
                pendingQuestion = message.text
                continue
            }
            let answer = message.status == .completed ? visibleText(of: message.segments) : ""
            if let question = pendingQuestion, !answer.isEmpty {
                history.append(ClassifierChatMessage(role: .user, content: question))
                history.append(ClassifierChatMessage(role: .assistant, content: answer))
            }
            pendingQuestion = nil
        }
        return history
    }

    /// Ce que l'utilisateur lit : le corps, ou le TL;DR seul sans corps —
    /// même règle que `SearchOrchestrator.suggestionsHistory`.
    static func visibleText(of segments: ReasoningSegments) -> String {
        segments.body.isEmpty ? (segments.tldr ?? "") : segments.body
    }

    /// Décision (c) : mode Fiable, recherche faite, AUCUNE source (le filtre
    /// « domaines fiables » a tout retiré, ou rien trouvé). Sans
    /// `searchPerformed`, un « Bonjour » déclencherait l'état ; sans le test
    /// des widgets, un calcul juste serait caché (la donnée d'un widget est une
    /// source). Les fichiers joints comptent comme sources.
    static func lacksReliableSources(_ artifacts: SearchArtifacts) -> Bool {
        artifacts.mode.restrictsToTrustedDomains
            && artifacts.searchPerformed
            && artifacts.sources.isEmpty
            && artifacts.widgets.isEmpty
    }

    /// Mode MÉMORISÉ (1.13), relu à chaque envoi : `ResponseModeSettingsStore`
    /// ne lit `UserDefaults` qu'à son init, une instance gardée ici ne verrait
    /// pas ce que le sélecteur écrit. Rapide par défaut (décision 6 de Ben).
    static func persistedResponseMode(in userDefaults: UserDefaults = .standard) -> ResponseMode {
        ResponseModeSettingsStore(userDefaults: userDefaults).selectedMode
    }

    // MARK: - Messages d'erreur

    /// Erreur en français clair pour les cas connus ; sinon
    /// `String(describing:)` (un nom brut mais réel vaut mieux qu'un message
    /// inventé). Les erreurs des moteurs et du cloud ne sont JAMAIS
    /// interpolées : leur `generationFailed(description:)` peut porter le
    /// texte brut d'un serveur BYOK — pour un fournisseur « Personnalisé », un
    /// serveur quelconque, qui pourrait renvoyer l'en-tête
    /// `Authorization: Bearer <clé>` dans son JSON d'erreur. Messages fixes.
    static func userFacingMessage(for error: Error) -> String {
        pipelineMessage(for: error)
            ?? engineMessage(for: error)
            ?? cloudMessage(for: error)
            ?? String(describing: error)
    }

    private static func pipelineMessage(for error: Error) -> String? {
        if let resolverError = error as? ActiveAIProviderResolverError {
            return resolverMessage(for: resolverError)
        }
        if let failoverError = error as? FailoverError {
            switch failoverError {
            case .noInstancesConfigured:
                return "Aucune instance de recherche n'est configurée."
            case .allInstancesUnavailable:
                return "Aucune instance de recherche n'a répondu. Réessaie dans un instant."
            }
        }
        if error is ChatViewModelError {
            return "Le moteur IA n'a renvoyé aucune réponse. Réessaie."
        }
        if let sessionError = error as? SearchSessionError {
            // `switch` exhaustif : un nouveau cas exigera son propre message.
            switch sessionError {
            case .sessionEnded:
                // Fenêtre fermée ou moteur changé en pleine génération (voir `SearchSessionError`).
                return "Réponse interrompue : la fenêtre a été fermée ou le moteur IA a changé."
            }
        }
        if let historyError = error as? ChatHistoryStoreError {
            return historyError.userFacingMessage
        }
        if let favoritesError = error as? FavoritesStoreError {
            return favoritesError.userFacingMessage
        }
        return nil
    }

    private static func resolverMessage(for error: ActiveAIProviderResolverError) -> String {
        switch error {
        case .noEngineSelected:
            return "Aucun moteur IA sélectionné. Choisis-en un dans les Réglages."
        case .appleIntelligenceUnavailable:
            return "Apple Intelligence n'est pas disponible sur cet appareil."
        case .noMLXModelSelected:
            return "Aucun modèle local choisi. Sélectionne un modèle MLX dans les Réglages."
        case .mlxModelNotInCatalog:
            return "Le modèle local choisi n'est plus disponible. Choisis-en un autre dans les Réglages."
        case .noCloudSelectionStored:
            return "Aucun fournisseur configuré. Va dans Réglages pour en choisir un."
        case .cloudSelectionUnresolvable:
            return "Le fournisseur choisi n'est plus disponible. Vérifie tes Réglages."
        }
    }

    /// Moteurs sur l'appareil (bug 6) : sans ces cas, un échec affichait
    /// « generationFailed(description: "exceededContextWindowSize…") ». La
    /// cause précise n'est pas typée côté provider et analyser la description
    /// serait fragile : message neutre qui cite la cause la plus fréquente.
    private static func engineMessage(for error: Error) -> String? {
        if let appleError = error as? AppleIntelligenceError {
            switch appleError {
            case .generationFailed:
                return "Apple Intelligence n'a pas pu répondre. Si la conversation est longue, commence-en une nouvelle."
            case .modelNotReady:
                return "Apple Intelligence se prépare encore sur cet appareil. Réessaie dans quelques minutes."
            case .deviceNotEligible, .appleIntelligenceNotEnabled, .unavailableForOtherReason:
                return "Apple Intelligence n'est pas disponible sur cet appareil."
            }
        }
        if let mlxError = error as? MLXProviderError {
            switch mlxError {
            case .simulatorUnsupported:
                // Garde-fou anti-crash de `MLXProvider` (Metal absent du Simulateur).
                return "Les modèles locaux (MLX) ne fonctionnent pas sur le Simulateur — teste sur un appareil réel."
            case .generationFailed, .modelNotLoaded:
                return "Le modèle local n'a pas pu répondre. Si la conversation est longue, commence-en une nouvelle."
            case .downloadFailed:
                return "Le téléchargement du modèle local a échoué. Vérifie ta connexion et réessaie."
            }
        }
        return nil
    }

    /// Cloud (bug 6) : le statut HTTP est perdu dans `generationFailed`, donc
    /// un message qui n'accuse plus la clé d'emblée (un 429 ou une panne n'a
    /// rien à voir avec elle) mais la garde en piste, cause la plus probable
    /// en BYOK. Clé ABSENTE : cas typé, message précis.
    private static func cloudMessage(for error: Error) -> String? {
        let missingKey = "Aucune clé API n'est enregistrée pour ce fournisseur. Ajoute-la dans les Réglages."
        let neutral = "Le fournisseur IA n'a pas pu répondre. Réessaie dans un instant ; si ça continue, vérifie ta clé API dans les Réglages."
        if let openAIError = error as? OpenAICompatibleProviderError {
            return openAIError == .missingAPIKey ? missingKey : neutral
        }
        if let byokError = error as? CloudBYOKError {
            return byokError == .missingAPIKey ? missingKey : neutral
        }
        if let perplexityError = error as? PerplexityAgentError {
            // Déjà des messages français fixes (`LocalizedError`).
            return perplexityError.errorDescription ?? neutral
        }
        return nil
    }
}
