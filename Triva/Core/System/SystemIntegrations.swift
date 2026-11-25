//
//  SystemIntegrations.swift
//  Triva
//
//  Chantier 2.1 (mission A) : point unique où l'app prévient les intégrations système (widget, boîte de partage,
//  Spotlight, activité en direct). Mission C (widget) : instantané ; E (partage) : `sceneDidBecomeActive()` ;
//  F (Spotlight, effacement) : index Spotlight, `eraseAll()` complet, et la règle Mac ci-dessous.
//
//  `TrivaApp` appelle `start()` et les autres crochets en dehors des tests unitaires (l'app sert d'hôte aux tests) :
//  une mission qui remplit un crochet n'a PAS à ajouter sa propre garde.
//
//  Mac : le conteneur de l'App Group n'est PAS touché (ni créé, ni lu) tant que « Dernière question dans le widget »
//  n'a jamais été allumé (`AppGroupAccessPolicy`) ; la boîte de partage n'existe que sur iPhone et iPad. Le publieur
//  du widget et la boîte sont donc créés à la première utilisation seulement.
//

import Foundation

@MainActor
final class SystemIntegrations {
    static let shared = SystemIntegrations()

    /// Le publieur du widget et la boîte de partage, créés à la demande : les créer résout le conteneur de l'App
    /// Group (`containerURL`), ce que le Mac ne doit pas faire au lancement tant que le widget n'a jamais été
    /// allumé (voir `AppGroupAccessPolicy`).
    private let makeWidgetPublisher: @MainActor () -> WidgetSnapshotPublisher
    private var widgetPublisherStorage: WidgetSnapshotPublisher?
    private let makeSharedInbox: @MainActor () -> SharedInboxConsumer
    private var sharedInboxStorage: SharedInboxConsumer?
    private let spotlightClient: any SpotlightIndexing
    private let spotlightDelay: Duration
    private let endLiveActivities: @MainActor () async -> Void
    /// Termine les activités terminées dont la conversation a disparu ; reçoit « cette conversation existe-t-elle ? ».
    private let endOrphanedLiveActivities: @MainActor (@escaping @MainActor (UUID) -> Bool) async -> Void
    /// Le réglage « Afficher la question » a changé : l'activité en cours (et celles qui attendent de disparaître)
    /// s'alignent tout de suite.
    private let refreshLiveActivityQuestion: @MainActor () async -> Void
    private let routes: SystemRouteCenter
    private let accessPolicy: AppGroupAccessPolicy
    /// L'historique de l'app, relié au lancement par `bind(chatHistory:)`. Sans lui (tests, lancement précoce),
    /// il n'y a rien à publier : on ne publie surtout pas un historique « vide » qui serait faux.
    private var chatHistory: ChatHistoryStore?

    private let preferences: SystemIntegrationPreferences
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    /// Dernière valeur vue de « Dernière question dans le widget » : on ne republie que quand elle bascule.
    private var lastShowsLastQuestion: Bool
    private var lastSpotlightEnabled: Bool
    private var lastLiveActivityEnabled: Bool
    private var lastShowsLiveActivityQuestion: Bool
    private var defaultsObserver: (any NSObjectProtocol)?
    private var shareSignal: ShareInboxSignal.Observation?

    /// - Parameters:
    ///   - makeWidgetPublisher, makeSharedInbox: fabriques appelées à la première utilisation seulement (`nil` = les
    ///     vrais éléments, sur l'App Group réel). Les tests passent des éléments sur un dossier temporaire.
    ///   - spotlightClient: `nil` = l'index Spotlight réel de l'app. Les tests passent un faux client.
    ///   - endLiveActivities: `nil` = termine les activités en direct réelles.
    ///   - endOrphanedLiveActivities: `nil` = retire les activités en direct réelles dont la conversation a disparu.
    ///   - refreshLiveActivityQuestion: `nil` = aligne les activités en direct réelles sur le réglage « Afficher la question ».
    ///   - routes: le routeur de l'app (Mac : on lui apprend à reconnaître les conversations existantes).
    ///   - isMac: décide de l'accès au conteneur de l'App Group (voir `AppGroupAccessPolicy`).
    init(
        makeWidgetPublisher: (@MainActor () -> WidgetSnapshotPublisher)? = nil,
        makeSharedInbox: (@MainActor () -> SharedInboxConsumer)? = nil,
        spotlightClient: (any SpotlightIndexing)? = nil,
        spotlightDelay: Duration = .seconds(2),
        endLiveActivities: (@MainActor () async -> Void)? = nil,
        endOrphanedLiveActivities: (@MainActor (@escaping @MainActor (UUID) -> Bool) async -> Void)? = nil,
        refreshLiveActivityQuestion: (@MainActor () async -> Void)? = nil,
        routes: SystemRouteCenter = .shared,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        isMac: Bool = SystemIntegrations.runsOnMac
    ) {
        self.makeWidgetPublisher = makeWidgetPublisher ?? { .live() }
        self.makeSharedInbox = makeSharedInbox ?? { .shared }
        self.spotlightClient = spotlightClient ?? CoreSpotlightIndexClient()
        self.spotlightDelay = spotlightDelay
        self.endLiveActivities = endLiveActivities ?? { await SearchLiveActivityController.shared.endAll() }
        self.endOrphanedLiveActivities = endOrphanedLiveActivities ?? { exists in
            await SearchLiveActivityController.shared.endActivities(whereConversationIsMissing: exists)
        }
        self.refreshLiveActivityQuestion = refreshLiveActivityQuestion ?? {
            await SearchLiveActivityController.shared.questionVisibilityDidChange()
        }
        self.routes = routes
        self.accessPolicy = AppGroupAccessPolicy(isMac: isMac, defaults: defaults)
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        let preferences = SystemIntegrationPreferences(defaults: defaults)
        self.preferences = preferences
        self.lastShowsLastQuestion = preferences.showsLastQuestionInWidget
        self.lastSpotlightEnabled = preferences.isSpotlightEnabled
        self.lastLiveActivityEnabled = preferences.isLiveActivityEnabled
        self.lastShowsLiveActivityQuestion = preferences.showsQuestionInLiveActivity
    }

    static var runsOnMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    // MARK: Éléments créés à la demande

    private var widgetPublisher: WidgetSnapshotPublisher {
        if let widgetPublisherStorage { return widgetPublisherStorage }
        let made = makeWidgetPublisher()
        widgetPublisherStorage = made
        return made
    }

    private var sharedInbox: SharedInboxConsumer {
        if let sharedInboxStorage { return sharedInboxStorage }
        let made = makeSharedInbox()
        sharedInboxStorage = made
        return made
    }

    private lazy var spotlight = SpotlightIndexer(
        client: spotlightClient,
        preferences: preferences,
        defaults: defaults,
        delay: spotlightDelay,
        loadEntries: { [weak self] in
            // Intégrations disparues (tests) : on lève, jamais « liste vide », qui ferait tout retirer de l'index.
            guard let self else { throw SpotlightLoadError.historyNotBound }
            return try self.loadSpotlightEntries()
        }
    )

    /// Relie l'historique de l'app (appelé une fois par `TrivaApp`, avant `start()`).
    func bind(chatHistory: ChatHistoryStore) {
        self.chatHistory = chatHistory
    }

    /// Une fois, au lancement de l'app.
    func start() {
        // Mac : le conteneur de l'App Group n'est touché que si le widget a déjà été allumé un jour.
        if preferences.showsLastQuestionInWidget { accessPolicy.noteWidgetEnabled() }
        routes.conversationExists = { [weak self] id in self?.conversationExists(id) ?? true }
        observeShareSignal()
        refreshWidget()
        observePreferences()
        Task { await spotlight.settingChanged() }
        // Une activité en direct laissée par un lancement précédent n'a plus personne pour la mettre à jour.
        // (Au lancement aucun échange n'est suivi : `endAll()` revient à `closeOrphans()`.)
        Task { [endLiveActivities] in await endLiveActivities() }
    }

    /// L'app (une de ses scènes) passe au premier plan.
    ///
    /// Mission E : reprend le partage déposé par l'extension « Rechercher avec Triva » (une extension de partage ne
    /// peut pas ouvrir l'app). Texte = brouillon, fichier = pièce jointe, jamais envoyés.
    /// iPhone et iPad seulement : l'extension de partage n'existe pas sur Mac, qui n'a donc pas à ouvrir le conteneur
    /// de l'App Group (sur Mac, un groupe hors préfixe d'équipe peut déclencher une invite d'accès).
    func sceneDidBecomeActive() {
        // Une conversation supprimée alors que l'app était en arrière-plan : son activité ne reste pas à l'écran.
        reapOrphanedLiveActivities()
        #if os(iOS)
        guard accessPolicy.mayTouchShareInbox else { return }
        let inbox = sharedInbox
        Task { await inbox.takeOver() }
        #endif
    }

    /// Un partage vient d'être déposé alors que l'app est peut-être déjà au premier plan (Safari intégré, iPad en
    /// Split View) : sans ce signal, rien ne le reprendrait avant le prochain passage au premier plan.
    private func observeShareSignal() {
        #if os(iOS)
        guard shareSignal == nil, accessPolicy.mayTouchShareInbox else { return }
        shareSignal = ShareInboxSignal.observe { [weak self] in
            Task { @MainActor in self?.shareInboxChanged() }
        }
        #endif
    }

    /// Reprise déclenchée par le signal de l'extension (même reprise que `sceneDidBecomeActive`).
    func shareInboxChanged() {
        #if os(iOS)
        guard accessPolicy.mayTouchShareInbox else { return }
        let inbox = sharedInbox
        Task { await inbox.takeOver() }
        #endif
    }

    /// L'historique a changé (ajout, renommage, suppression), dans n'importe quelle fenêtre.
    func historyDidChange() {
        refreshWidget()
        spotlight.scheduleSync()
        reapOrphanedLiveActivities()
    }

    /// Un réglage de la section « Intégrations » a changé (l'écran de la mission F l'appelle à chaque bascule) :
    /// éteindre « Dernière question dans le widget » efface l'instantané tout de suite, éteindre Spotlight vide
    /// l'index.
    ///
    /// Filet de sécurité : `start()` observe déjà les réglages (voir `observePreferences()`), donc cet appel
    /// explicite n'est qu'un chemin direct, sans danger s'il double l'observation (rien n'est réécrit si rien n'a changé).
    func preferencesDidChange() {
        lastShowsLastQuestion = preferences.showsLastQuestionInWidget
        lastSpotlightEnabled = preferences.isSpotlightEnabled
        lastLiveActivityEnabled = preferences.isLiveActivityEnabled
        if lastShowsLastQuestion { accessPolicy.noteWidgetEnabled() }
        refreshWidget()
        Task { await spotlight.settingChanged() }
        if !lastLiveActivityEnabled { Task { [endLiveActivities] in await endLiveActivities() } }
        lastShowsLiveActivityQuestion = preferences.showsQuestionInLiveActivity
        Task { [refreshLiveActivityQuestion] in await refreshLiveActivityQuestion() }
    }

    /// Le système demande de reconstruire l'index Spotlight (`IndexedEntityQuery.reindexAllEntities`).
    func reindexSpotlight() {
        Task { await spotlight.reindexAll() }
    }

    /// « Tout effacer » : vide aussi ce que les intégrations ont publié hors de l'app. `true` si TOUT a été retiré.
    ///
    /// Chaque intégration est vidée même si une autre échoue. Sur Mac, le conteneur de l'App Group n'est pas touché
    /// tant que le widget n'a jamais été allumé (rien n'y a jamais été écrit) ; la boîte de partage n'existe que sur
    /// iPhone et iPad.
    @discardableResult
    func eraseAll() async -> Bool {
        var complete = true
        if accessPolicy.mayTouchWidgetContainer {
            if case .failed = widgetPublisher.erase() { complete = false }
        }
        if accessPolicy.mayTouchShareInbox {
            // Une suppression refusée (ou une extension qui écrit pendant l'effacement) laisse un fichier privé
            // dans l'App Group : on ne dit pas « tout est effacé ».
            if !sharedInbox.eraseAll() { complete = false }
        }
        if await spotlight.eraseAll() == false { complete = false }
        await endLiveActivities()
        return complete
    }

    // MARK: Réglages

    /// Règle de Ben : éteindre « Dernière question dans le widget » efface l'instantané tout de suite, quel que
    /// soit l'écran qui change le réglage (Réglages de l'app, Raccourcis, tests). On ne compte donc pas sur l'appel
    /// d'un écran : on écoute les `UserDefaults` de l'app et on ne réagit que si CE réglage bascule.
    /// Même principe pour Spotlight.
    private func observePreferences() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { [weak self] _ in
            // La notification part du thread qui a écrit : le plus souvent le principal (réponse immédiate).
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.preferenceMayHaveChanged() }
            } else {
                Task { @MainActor in self?.preferenceMayHaveChanged() }
            }
        }
    }

    private func preferenceMayHaveChanged() {
        let showsLastQuestion = preferences.showsLastQuestionInWidget
        if showsLastQuestion != lastShowsLastQuestion {
            lastShowsLastQuestion = showsLastQuestion
            if showsLastQuestion { accessPolicy.noteWidgetEnabled() }
            refreshWidget()
        }
        let spotlightEnabled = preferences.isSpotlightEnabled
        if spotlightEnabled != lastSpotlightEnabled {
            lastSpotlightEnabled = spotlightEnabled
            Task { await spotlight.settingChanged() }
        }
        let liveActivityEnabled = preferences.isLiveActivityEnabled
        if liveActivityEnabled != lastLiveActivityEnabled {
            lastLiveActivityEnabled = liveActivityEnabled
            // Éteint : l'activité en cours (et celles qui attendent de disparaître) s'arrêtent tout de suite, la
            // question ne reste pas sur l'écran verrouillé.
            if !liveActivityEnabled { Task { [endLiveActivities] in await endLiveActivities() } }
        }
        let showsQuestion = preferences.showsQuestionInLiveActivity
        if showsQuestion != lastShowsLiveActivityQuestion {
            lastShowsLiveActivityQuestion = showsQuestion
            // Éteint : la question quitte tout de suite l'activité en cours et celles qui attendent de disparaître.
            Task { [refreshLiveActivityQuestion] in await refreshLiveActivityQuestion() }
        }
    }

    // MARK: Widget

    private func refreshWidget() {
        guard accessPolicy.mayTouchWidgetContainer else { return }
        // Réglage éteint : l'instantané est retiré SANS lire l'historique. Un historique illisible (état prévu) ne doit
        // pas laisser un titre dans le widget quand l'écran promet « retire tout de suite ».
        guard preferences.showsLastQuestionInWidget else {
            widgetPublisher.publish(latest: nil)
            return
        }
        guard let chatHistory else { return }
        let latest: StoredConversation?
        do {
            latest = try chatHistory.conversations(limit: 1).first
        } catch {
            // Historique illisible : on laisse l'instantané en l'état plutôt que d'annoncer un historique vide.
            return
        }
        widgetPublisher.publish(latest: latest.map {
            WidgetSnapshotPublisher.LatestConversation(id: $0.id, title: $0.title, updatedAt: $0.updatedAt)
        })
    }

    // MARK: Activité en direct

    /// Retire de l'écran les activités terminées dont la conversation a été supprimée (la toucher donnerait « Cette
    /// conversation n'existe plus. », et la question resterait jusqu'à 30 minutes sur l'écran verrouillé).
    private func reapOrphanedLiveActivities() {
        guard chatHistory != nil else { return }
        Task { [weak self, endOrphanedLiveActivities] in
            await endOrphanedLiveActivities { id in self?.conversationExists(id) ?? true }
        }
    }

    /// Vrai si la conversation existe. Une lecture qui échoue, ou un historique pas encore relié, comptent comme
    /// « existe » : on ne retire jamais quelque chose faute de pouvoir lire.
    private func conversationExists(_ id: UUID) -> Bool {
        guard let chatHistory else { return true }
        do {
            return try chatHistory.conversation(with: id) != nil
        } catch {
            return true
        }
    }

    // MARK: Spotlight

    /// Les conversations les plus récentes, titres et dates seulement. Sans historique relié, on LÈVE : rendre une
    /// liste vide ferait retirer de l'index tout ce qui y est.
    private func loadSpotlightEntries() throws -> [SpotlightEntry] {
        guard let chatHistory else { throw SpotlightLoadError.historyNotBound }
        return try chatHistory.conversations(limit: SpotlightIndexPlan.maxEntries).map {
            SpotlightEntry(id: $0.id, title: $0.title, updatedAt: $0.updatedAt)
        }
    }

    private enum SpotlightLoadError: Error { case historyNotBound }
}

extension SystemIntegrations: SystemIntegrationsErasing {}
