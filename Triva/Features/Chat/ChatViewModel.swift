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
/// closures (`SearchSession`, `SearchSession.swift`), avec des défauts SÛRS pour
/// que l'appel existant compile inchangé — historique et favoris à `nil`
/// (jamais une seconde instance de store, dont la `revision` divergerait),
/// budget `.appleIntelligence` (le plus serré : un oubli dégrade une réponse
/// cloud, il ne fait jamais déborder un petit modèle), mode relu à chaque envoi.
///
/// ## Annulation
/// L'échange tourne dans une `Task` interne reliée à l'appelant par
/// `withTaskCancellationHandler` : `stop()` (le bouton Stop de `ChatView`) et
/// `startNewConversation()` (remise à zéro qui annule) aboutissent au même
/// `Task.isCancelled`, vérifié dans LES DEUX `catch` — une annulation n'est
/// jamais un échec ni une réponse vide.
///
/// ## Réponse qui continue en arrière-plan (mission C5, décision R3-2 de Ben)
/// Ouvrir une autre conversation (Bibliothèque, favori) n'annule plus la génération en cours : elle
/// passe en arrière-plan (`ChatViewModel+Background.swift`), finit, et écrit sa réponse dans SA
/// conversation de l'historique. « Nouvelle conversation » (bouton, ⇧⌘O, widget, Siri…) fait de même (décision de
/// Ben du 25/11) : plusieurs générations peuvent tourner en même temps, une question envoyée ailleurs n'arrête
/// PAS celles restées en arrière-plan ; Stop n'arrête que le fil affiché, `stopEverything()` toutes.
///
/// ## La génération appartient au modèle, pas à la vue
/// `startSend(query:)` (et `startRetryInQuickMode`, `startRetryAfterOffline`)
/// lance l'échange dans une `Task` GARDÉE ICI (`sendTask`). `ChatView` est
/// démontée à chaque bascule de classe de taille (iPhone Duo ouvert ou fermé,
/// Split View, Stage Manager) et à chaque changement de destination : si la
/// `Task` était à elle, ce démontage coupait la réponse en plein milieu
/// (revue R3-1). Seuls Stop (sur le fil affiché), la fin de la session
/// (`SearchSession.deinit`, changement de moteur ou fenêtre fermée) et la suppression de
/// leur conversation les annulent. Le jeton `activeExchangeID` empêche un
/// échange remplacé, qui finit de se dérouler, de toucher l'état du suivant.
///
/// Extensions, pour garder ce fichier sous les 600 lignes :
/// `ChatViewModel+Exchange.swift` (déroulé d'un échange), `ChatViewModel+Launch.swift` (lancer et arrêter
/// un envoi), `ChatViewModel+Transcript.swift` (fil relu, historique du classifieur),
/// `ChatViewModel+Message.swift` (un message du fil),
/// `ChatViewModel+ErrorMessages.swift` (messages du bandeau d'erreur),
/// `ChatViewModel+ReliableMode.swift` (mode Fiable), `ChatViewModel+Offline.swift` (mode hors
/// connexion, tâche 1.16), `ChatViewModel+Favorites.swift` et `ChatViewModel+Media.swift`.
@Observable
@MainActor
final class ChatViewModel {
    /// Dépendances de l'orchestrateur d'UN envoi : moteur, budget, mode figé.
    struct OrchestratorInputs {
        let failoverManager: FailoverManager
        let provider: any AIGenerating
        let responseMode: ResponseMode
        let configuration: SearchPipelineConfiguration
        /// Chaîne de repli de la recherche web (RI1b), construite sur ce
        /// `failoverManager` ; `nil` = SearXNG seul.
        let webSearchChain: WebSearchChain?
        /// Appareil hors connexion (tâche 1.16) : l'orchestrateur ne cherche pas sur le web. `var` avec
        /// défaut : les appels existants (dont les tests) compilent inchangés.
        var isOffline = false
        /// Enquêteur de la recherche web (tâche 2.4), `nil` = boucle actuelle. Même forme que `isOffline`.
        var agenticResearcher: (any AgenticResearching)? = nil
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
    /// Toutes les sources de recherche ont échoué, ou SearXNG n'a rien donné
    /// (mission A2) : invitation à gérer ses clés, en bas du fil. Même durée de vie que `errorDescription`.
    private(set) var searchKeyInvitation: SearchKeyInvitation?
    /// Mission A5 : l'invitation « après un repli » (SearXNG laissé de côté, une source de
    /// secours a répondu) n'est faite qu'UNE fois par conversation, pas à chaque réponse de
    /// secours : répétée, elle devient un reproche. Remise à `false` par `startNewConversation()`
    /// (donc aussi par `loadConversation`, qui passe par elle) et quand l'invitation posée est
    /// effacée avant d'avoir pu être vue (`fail`). L'invitation d'une ERREUR (toutes les sources
    /// en échec) n'est pas concernée : elle explique un échec, elle reste affichée à chaque fois.
    var fallbackInvitationOffered = false
    /// Échec d'écriture de l'historique ou des favoris : séparé, la réponse a
    /// abouti — n'écrase jamais `errorDescription`.
    private(set) var persistenceErrorDescription: String?
    /// Envoi bloqué hors connexion (tâche 1.16) : bandeau et bouton « Relancer » en bas du fil. Même
    /// durée de vie que `errorDescription`. Voir `ChatViewModel+Offline.swift`.
    private(set) var offlineNotice: OfflineNotice?

    /// Seul point d'écriture de `offlineNotice` hors de ce fichier (`private(set)`).
    func setOfflineNotice(_ notice: OfflineNotice?) {
        offlineNotice = notice
    }

    /// Demande de consentement cloud affichée, avec l'envoi qu'elle a interrompu (mission I1) : détenue ici,
    /// pas par `ChatView`, pour que la feuille et l'envoi survivent au remontage de la vue quand
    /// l'iPhone Duo se plie ou se déplie. Voir `ChatViewModel+CloudConsent`.
    private(set) var pendingConsent: PendingCloudConsent?

    /// Seul point d'écriture de `pendingConsent` hors de ce fichier (`ChatViewModel+CloudConsent`).
    func setPendingConsent(_ pending: PendingCloudConsent?) {
        pendingConsent = pending
    }

    /// Seul point d'écriture de `errorDescription` hors de ce fichier (`ChatViewModel+CloudConsent`, `ChatViewModel+Exchange`).
    func setErrorDescription(_ text: String?) {
        errorDescription = text
    }

    /// Seul point d'écriture de `searchKeyInvitation` hors de ce fichier (`ChatViewModel+Exchange`).
    func setSearchKeyInvitation(_ invitation: SearchKeyInvitation?) {
        searchKeyInvitation = invitation
    }

    /// `StoredConversation.id` du fil. Jamais la référence SwiftData :
    /// supprimée depuis la Bibliothèque, elle resterait lisible.
    private(set) var currentConversationID: UUID?
    /// Fichiers joints de la conversation (1.11), même durée de vie : à
    /// brancher tel quel sur `FileAttachmentPicker` / `FileAttachmentTray`.
    let attachmentController: FileAttachmentController

    let resolveProvider: () async throws -> any AIGenerating
    let resolveFailoverManager: () throws -> FailoverManager
    let resolveWebSearchChain: @MainActor (FailoverManager) throws -> WebSearchChain?
    /// Enquêteur de l'envoi (tâche 2.4), relu à CHAQUE envoi juste après `resolveProvider`.
    let resolveAgenticResearcher: @MainActor () -> (any AgenticResearching)?
    /// `nil` = connecté (pipeline normal) ; sinon ce que l'envoi doit faire hors connexion (tâche 1.16,
    /// `SearchSession.resolveOfflinePlan`). Relue à CHAQUE envoi, jamais mémorisée.
    let resolveOfflinePlan: @MainActor () -> OfflinePlan?
    let resolvePipelineConfiguration: @MainActor () -> SearchPipelineConfiguration
    let readResponseMode: @MainActor () -> ResponseMode
    let makeOrchestrator: @MainActor (OrchestratorInputs) -> SearchOrchestrator
    let generateSuggestions: @MainActor (any AIGenerating, [ClassifierChatMessage]) async -> [String]
    let makeMediaSearcher: @MainActor (FailoverManager) -> any MediaSearching
    let historyStore: ChatHistoryStore?
    let favoritesStore: FavoritesStore?
    let now: @MainActor () -> Date
    /// Consentement cloud (mission C2) : la demande à montrer avant d'envoyer, `nil` si rien à demander.
    let resolveConsentRequest: @MainActor () -> CloudAIConsentRequest?
    let grantConsent: @MainActor (CloudAIConsentRequest) -> Void

    @ObservationIgnored var activeExchangeID: UUID?
    /// Générations passées en arrière-plan (« Nouvelle conversation », ouverture d'une autre conversation), par
    /// conversation : plusieurs peuvent tourner à la fois (`ChatViewModel+Background`).
    @ObservationIgnored var backgroundExchanges: [UUID: BackgroundExchange] = [:]
    /// Réponse affichée coupée par le passage de l'app en arrière-plan (modèle local, iPhone et iPad), à reprendre au
    /// retour (F3, `ChatViewModel+AutoResume.swift`). `nil` sinon.
    @ObservationIgnored var backgroundInterruptedAnswerID: UUID?
    /// Réponses déjà reprises automatiquement : une seule reprise par réponse (jamais de boucle arrière-plan, reprise, arrière-plan…).
    @ObservationIgnored var autoResumedAnswerIDs: Set<UUID> = []
    /// Faux pour une session sans fenêtre (Siri, Raccourcis) : une reprise y génèrerait pour personne.
    @ObservationIgnored var resumesAfterBackgroundInterruption = true
    @ObservationIgnored var generationTask: Task<Void, Never>?
    /// `Task` de l'envoi en cours lancé par `startSend` et consorts : voir « La génération appartient
    /// au modèle ». L'annuler annule `generationTask` via `runExchange`.
    @ObservationIgnored var sendTask: Task<Void, Never>?
    @ObservationIgnored var suggestionsTask: Task<Void, Never>?
    @ObservationIgnored var mediaTasks: [MediaRequest: Task<Void, Never>] = [:]
    @ObservationIgnored var favoritesCache: (revision: Int, ids: Set<UUID>)?
    /// Avancement de l'échange, raconté à l'activité en direct (mission D, `ChatViewModel+Progress`).
    @ObservationIgnored var progressEmitter = SearchProgressEmitter()

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Triva", category: "ChatViewModel")

    /// - Parameters:
    ///   - resolveWebSearchChain: chaîne de repli de la recherche web de
    ///     l'envoi (RI1b), construite sur le `FailoverManager` qu'il vient de
    ///     résoudre (`SearchSession.resolveWebSearchChain(failoverManager:)`),
    ///     transmise par `OrchestratorInputs` au `makeOrchestrator` par
    ///     défaut. `nil` (défaut) : SearXNG seul, comportement d'avant la chaîne.
    ///   - resolveOfflinePlan: `nil` (défaut, et quand l'appareil est connecté) = pipeline normal ;
    ///     sinon le plan hors connexion (tâche 1.16) : répondre sans recherche, ou bloquer avec un message.
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
        resolveWebSearchChain: @escaping @MainActor (FailoverManager) throws -> WebSearchChain? = { _ in nil },
        resolveOfflinePlan: @escaping @MainActor () -> OfflinePlan? = { nil },
        resolveAgenticResearcher: @escaping @MainActor () -> (any AgenticResearching)? = { nil },
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
                configuration: inputs.configuration,
                webSearchChain: inputs.webSearchChain,
                isOffline: inputs.isOffline,
                agenticResearcher: inputs.agenticResearcher
            )
        },
        generateSuggestions: @escaping @MainActor (any AIGenerating, [ClassifierChatMessage]) async -> [String] = { provider, history in
            await SuggestionsService(aiProvider: provider).generateSuggestions(chatHistory: history)
        },
        makeMediaSearcher: @escaping @MainActor (FailoverManager) -> any MediaSearching = { SearXNGMediaSearcher(failoverManager: $0) },
        now: @escaping @MainActor () -> Date = { .now },
        resolveConsentRequest: @escaping @MainActor () -> CloudAIConsentRequest? = { nil },
        grantConsent: @escaping @MainActor (CloudAIConsentRequest) -> Void = { _ in }
    ) {
        self.resolveConsentRequest = resolveConsentRequest
        self.grantConsent = grantConsent
        self.resolveProvider = resolveProvider
        self.resolveFailoverManager = resolveFailoverManager
        self.resolveWebSearchChain = resolveWebSearchChain
        self.resolveAgenticResearcher = resolveAgenticResearcher
        self.resolveOfflinePlan = resolveOfflinePlan
        self.resolvePipelineConfiguration = resolvePipelineConfiguration
        self.readResponseMode = readResponseMode
        self.historyStore = historyStore
        self.favoritesStore = favoritesStore
        self.attachmentController = attachmentController ?? FileAttachmentController(store: AttachmentStore())
        self.makeOrchestrator = makeOrchestrator
        self.generateSuggestions = generateSuggestions
        self.makeMediaSearcher = makeMediaSearcher
        self.now = now
        // Les autres fenêtres écrivent dans l'historique commun : celle-ci doit le savoir (mission F2).
        ActiveExchangeRegistry.shared.addListener(self)
    }

    // MARK: - Envoi

    /// Un envoi, figé au départ : changer le mode ou les fichiers pendant la
    /// génération ne concerne que la question suivante.
    struct Exchange: Sendable {
        let question: String
        let history: [ClassifierChatMessage]
        let mode: ResponseMode
        let attachments: AttachmentSearchIndex?
        let conversationID: UUID?
        let answerID: UUID
    }

    /// Ce que l'échange a produit, tenu HORS du fil : `startNewConversation()`
    /// peut retirer le message, la réponse partielle doit quand même être persistée.
    struct AnswerDraft {
        var text = ""
        var sources: [SearXNGSearchResult] = []
        /// Mentions sur les sources, persistées avec la réponse (mission E1a).
        var notes = StoredAnswerNotes()
        var isComplete = false
    }

    /// Envoie `query` (ignorée si vide/blanche ou si un envoi est en cours).
    /// Ajoute la question (texte trimmé, fichiers joints apparus depuis la
    /// précédente) puis une réponse en streaming ; sources et widgets sont
    /// attachés AVANT le premier morceau de texte (en Fiable sans widget : AVEC
    /// le premier texte montré, voir `consume`). Toute erreur va dans
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

    /// Refait la réponse `index` : MÊME question, même historique, même bulle (identifiant gardé),
    /// l'ancienne réponse retirée de l'historique persisté. Partagé par « Relancer en mode Rapide »
    /// et « Lire cette page » (`ChatViewModel+ReadPage`) ; défini ici car il écrit dans `messages`.
    func rerunAnswer(at index: Int, questionIndex: Int, mode: ResponseMode) async {
        let question = messages[questionIndex].text
        let replaced = messages[index]
        let messageID = replaced.id
        messages[index] = Message(id: messageID, role: .assistant, isStreaming: true)
        persistenceErrorDescription = nil
        deleteStoredMessage(id: replaced.storedMessageID, conversationID: replaced.storedConversationID)
        await runExchange(Exchange(
            question: question,
            history: Self.classifierHistory(from: Array(messages[..<questionIndex])),
            mode: mode,
            attachments: attachmentSnapshot(),
            conversationID: currentConversationID,
            answerID: messageID
        ))
    }

    func runExchange(_ exchange: Exchange) async {
        // Une réponse restée en arrière-plan n'est PAS arrêtée par cette question : elle finit dans sa conversation.
        let exchangeID = UUID()
        activeExchangeID = exchangeID
        isGenerating = true
        ActiveExchangeRegistry.shared.begin(exchange.conversationID, by: self)
        defer { ActiveExchangeRegistry.shared.end(exchange.conversationID, by: self) }
        emitProgress(.started(question: exchange.question, conversationID: exchange.conversationID), answerID: exchange.answerID)
        errorDescription = nil
        searchKeyInvitation = nil
        offlineNotice = nil
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
        // Filet de sécurité : un échange que rien n'a terminé finit « interrompu » (sans effet s'il est déjà fini).
        progressEmitter.closeIfOpen(answerID: exchange.answerID)
        guard activeExchangeID == exchangeID else {
            backgroundExchangeDidEnd(exchangeID: exchangeID)
            return
        }
        activeExchangeID = nil
        generationTask = nil
        isGenerating = false
    }

    // MARK: - Conversation

    /// Remise à zéro du fil : ANNULE ce qui est en cours (la réponse partielle est persistée dans l'ancienne
    /// conversation, qui reste dans la Bibliothèque), vide le fil et retire les fichiers joints avec leur copie.
    /// `isGenerating` repasse à `false` sans attendre la fin de l'échange annulé.
    ///
    /// Ce n'est PAS ce que fait l'utilisateur en touchant « Nouvelle conversation » : ce chemin-là met d'abord la réponse
    /// de côté pour qu'elle finisse (`startNewConversationFromUser`). Ici : conversation supprimée, ouverture d'une
    /// autre conversation (après `moveGenerationToBackground`), et réponse qui n'a aucune conversation d'historique
    /// pour la recevoir.
    func startNewConversation() {
        sendTask?.cancel()
        generationTask?.cancel()
        suggestionsTask?.cancel()
        for task in mediaTasks.values {
            task.cancel()
        }
        generationTask = nil
        sendTask = nil
        suggestionsTask = nil
        mediaTasks = [:]
        activeExchangeID = nil
        isGenerating = false
        messages = []
        // L'envoi qui attendait l'accord cloud appartenait à l'ancien fil : « Autoriser » l'enverrait sinon dans
        // celui-ci, avec son historique et ses fichiers joints (X2, C1). Le brouillon n'est pas touché.
        pendingConsent = nil
        errorDescription = nil
        searchKeyInvitation = nil
        fallbackInvitationOffered = false
        offlineNotice = nil
        persistenceErrorDescription = nil
        currentConversationID = nil
        // Par le contrôleur, jamais `store.removeAll()` seul : un fichier en
        // cours de lecture s'attacherait sinon à la nouvelle conversation. Les fichiers PAS ENCORE ENVOYÉS partent
        // aussi, avec leur copie (décision de Ben du 25/11, quel que soit le chemin) ; la réponse restée en
        // arrière-plan n'en dépend plus : le pipeline a reçu un instantané en mémoire (`attachmentSnapshot()`).
        attachmentController.removeAll()
    }

    /// Une ouverture demandée de l'extérieur (widget, Spotlight, raccourci) vise une conversation supprimée : même
    /// message que `loadConversation`, sans toucher au fil affiché (X2, R2-19).
    func reportMissingConversation() {
        persistenceErrorDescription = Self.missingConversationMessage
    }

    /// Nombre de fois où l'utilisateur a demandé une nouvelle conversation (bouton de la barre d'outils ou
    /// menu ⇧⌘O), par opposition à celles que l'app remet à zéro d'elle-même (conversation supprimée).
    /// `ChatView` l'observe pour ramener le curseur dans le champ de saisie, sans que ces remises à zéro
    /// automatiques n'ouvrent le clavier.
    private(set) var userNewConversationCount = 0

    /// « Nouvelle conversation » (bouton de la barre d'outils, menu ⇧⌘O) : voir `startNewConversationLettingAnswerFinish()`.
    func startNewConversationFromUser() {
        startNewConversationLettingAnswerFinish()
    }

    /// Dernière valeur de `userNewConversationCount` dont la vue a déjà tenu compte (clavier ouvert). Ici et non
    /// dans la vue : `ChatView` est recréée quand on change de destination, la demande doit survivre à ce rechargement
    /// et n'être servie qu'une fois.
    @ObservationIgnored private var servedFocusRequestCount = 0

    /// Une demande de clavier attend la vue (faite quand `ChatView` n'était pas montée : lancement à froid depuis un
    /// widget, arrivée d'une autre destination).
    var hasPendingFocusRequest: Bool { userNewConversationCount > servedFocusRequestCount }

    /// La vue ouvre le clavier : `true` UNE seule fois par demande (plusieurs demandes faites avant son apparition
    /// n'ouvrent le clavier qu'une fois).
    func consumePendingFocusRequest() -> Bool {
        guard hasPendingFocusRequest else { return false }
        servedFocusRequestCount = userNewConversationCount
        return true
    }

    /// « Nouvelle question » demandée par le système (widget, Siri, bouton Action, `triva://new`) : même chemin que le
    /// bouton, voir `startNewConversationLettingAnswerFinish()`.
    func startNewConversationFromSystem() {
        startNewConversationLettingAnswerFinish()
    }

    /// LE chemin de toute nouvelle conversation (décision de Ben du 25/11, qui remplace sa décision 1) : une réponse en
    /// cours n'est PAS arrêtée, elle finit en arrière-plan dans SA conversation, reste dans l'historique, son activité
    /// en direct la suit et « Arrêter » redevient possible en y revenant (`moveGenerationToBackground`). Plusieurs
    /// réponses peuvent ainsi finir en même temps ; un modèle MLX les sert l'une après l'autre (file d'attente de
    /// l'app). Sans conversation d'historique pour la recevoir (historique absent ou illisible), la réponse est arrêtée,
    /// début gardé. Les fichiers joints, envoyés ou non, sont retirés avec leur copie ; un partage ou un texte qui arrive
    /// ENSUITE est traité normalement. Puis la vue est avertie (clavier).
    private func startNewConversationLettingAnswerFinish() {
        moveGenerationToBackground()
        startNewConversation()
        userNewConversationCount += 1
    }

    /// Rouvre une conversation de la Bibliothèque (ou d'un favori,
    /// `StoredFavorite.conversationID`) ; les envois suivants s'y ajoutent.
    /// Sans effet si c'est déjà celle du fil. `false` si elle n'existe plus ou
    /// si l'historique est illisible (`persistenceErrorDescription`). Les
    /// fichiers joints ne survivent pas à leur conversation.
    @discardableResult
    func loadConversation(id: UUID) -> Bool {
        if id == currentConversationID { return true }
        // Sa génération tourne encore en arrière-plan : on la retrouve en direct, pas depuis l'historique.
        if reattachBackgroundGeneration(conversationID: id) { return true }
        guard let historyStore else { return false }
        let restored: [Message]
        do {
            guard let conversation = try historyStore.conversation(with: id) else {
                persistenceErrorDescription = Self.missingConversationMessage
                return false
            }
            restored = Self.markingUnansweredQuestions(
                conversation.orderedMessages.map { Self.restoredMessage($0, conversationID: id) },
                isAnswerComing: ActiveExchangeRegistry.shared.isAnswering(id),
                at: now()
            )
        } catch {
            reportPersistenceFailure(error)
            return false
        }
        moveGenerationToBackground()
        startNewConversation()
        messages = restored
        currentConversationID = id
        return true
    }

    /// Contrat de `LibraryView.onConversationDeleted` : conversation du fil
    /// supprimée -> le chat repart à neuf. Après « tout effacer » :
    /// `startNewConversation()`.
    func conversationWasDeleted(id: UUID) {
        cancelBackgroundGeneration(conversationID: id)
        guard id == currentConversationID else { return }
        startNewConversation()
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

    func reportPersistenceFailure(_ error: any Error) {
        persistenceErrorDescription = Self.userFacingMessage(for: error)
    }

    // MARK: - Utilitaires


    /// Un message du fil affiché ; à défaut, celui d'une génération passée en arrière-plan. Jamais
    /// d'écriture dans le fil affiché pour un message d'une autre conversation : les identifiants
    /// de réponse sont uniques, un message absent du fil est simplement ignoré.
    func updateMessage(id: UUID, _ update: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            for conversationID in backgroundExchanges.keys {
                if backgroundExchanges[conversationID]?.update(id: id, update) == true { return }
            }
            return
        }
        update(&messages[index])
    }

    /// Remplace le fil affiché (`ChatViewModel+Background`, `messages` étant `private(set)` ici).
    func displayThread(_ thread: [Message], conversationID: UUID, isGenerating generating: Bool) {
        messages = thread
        currentConversationID = conversationID
        isGenerating = generating
    }

}
