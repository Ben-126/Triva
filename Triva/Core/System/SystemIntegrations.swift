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
    private var defaultsObserver: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - makeWidgetPublisher, makeSharedInbox: fabriques appelées à la première utilisation seulement (`nil` = les
    ///     vrais éléments, sur l'App Group réel). Les tests passent des éléments sur un dossier temporaire.
    ///   - spotlightClient: `nil` = l'index Spotlight réel de l'app. Les tests passent un faux client.
    ///   - endLiveActivities: `nil` = termine les activités en direct réelles.
    ///   - isMac: décide de l'accès au conteneur de l'App Group (voir `AppGroupAccessPolicy`).
    init(
        makeWidgetPublisher: (@MainActor () -> WidgetSnapshotPublisher)? = nil,
        makeSharedInbox: (@MainActor () -> SharedInboxConsumer)? = nil,
        spotlightClient: (any SpotlightIndexing)? = nil,
        spotlightDelay: Duration = .seconds(2),
        endLiveActivities: (@MainActor () async -> Void)? = nil,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        isMac: Bool = SystemIntegrations.runsOnMac
    ) {
        self.makeWidgetPublisher = makeWidgetPublisher ?? { .live() }
        self.makeSharedInbox = makeSharedInbox ?? { .shared }
        self.spotlightClient = spotlightClient ?? CoreSpotlightIndexClient()
        self.spotlightDelay = spotlightDelay
        self.endLiveActivities = endLiveActivities ?? { await SearchLiveActivityController.shared.endAll() }
        self.accessPolicy = AppGroupAccessPolicy(isMac: isMac, defaults: defaults)
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        let preferences = SystemIntegrationPreferences(defaults: defaults)
        self.preferences = preferences
        self.lastShowsLastQuestion = preferences.showsLastQuestionInWidget
        self.lastSpotlightEnabled = preferences.isSpotlightEnabled
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
        if lastShowsLastQuestion { accessPolicy.noteWidgetEnabled() }
        refreshWidget()
        Task { await spotlight.settingChanged() }
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
            sharedInbox.eraseAll()
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
    }

    // MARK: Widget

    private func refreshWidget() {
        guard accessPolicy.mayTouchWidgetContainer, let chatHistory else { return }
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
