//
//  SystemIntegrations.swift
//  Triva
//
//  Chantier 2.1 (mission A) : point unique où l'app prévient les intégrations système (widget, boîte de partage,
//  Spotlight, activité en direct). Chaque mission remplit son crochet : C (widget) a rempli `start()`,
//  `historyDidChange()`, `preferencesDidChange()` et `eraseAll()` ; E remplit `sceneDidBecomeActive()` ; F ajoute les
//  siens à `historyDidChange()` et `eraseAll()`.
//
//  `TrivaApp` appelle `start()` et les autres crochets en dehors des tests unitaires (l'app sert d'hôte aux tests) :
//  une mission qui remplit un crochet n'a PAS à ajouter sa propre garde.
//

import Foundation

@MainActor
final class SystemIntegrations {
    static let shared = SystemIntegrations()

    private let widgetPublisher: WidgetSnapshotPublisher
    /// L'historique de l'app, relié au lancement par `bind(chatHistory:)`. Sans lui (tests, lancement précoce),
    /// il n'y a rien à publier : on ne publie surtout pas un historique « vide » qui serait faux.
    private var chatHistory: ChatHistoryStore?

    private let preferences: SystemIntegrationPreferences
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    /// Dernière valeur vue de « Dernière question dans le widget » : on ne republie que quand elle bascule.
    private var lastShowsLastQuestion: Bool
    private var defaultsObserver: (any NSObjectProtocol)?

    init(
        widgetPublisher: WidgetSnapshotPublisher? = nil,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.widgetPublisher = widgetPublisher ?? .live()
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        let preferences = SystemIntegrationPreferences(defaults: defaults)
        self.preferences = preferences
        self.lastShowsLastQuestion = preferences.showsLastQuestionInWidget
    }

    /// Relie l'historique de l'app (appelé une fois par `TrivaApp`, avant `start()`).
    func bind(chatHistory: ChatHistoryStore) {
        self.chatHistory = chatHistory
    }

    /// Une fois, au lancement de l'app.
    func start() {
        refreshWidget()
        observePreferences()
    }

    /// L'app (une de ses scènes) passe au premier plan.
    func sceneDidBecomeActive() {}

    /// L'historique a changé (ajout, renommage, suppression), dans n'importe quelle fenêtre.
    func historyDidChange() {
        refreshWidget()
    }

    /// Un réglage de la section « Intégrations » a changé (l'écran de la mission F l'appelle à chaque bascule) :
    /// éteindre « Dernière question dans le widget » efface l'instantané tout de suite.
    ///
    /// Filet de sécurité : `start()` observe déjà les réglages (voir `observePreferences()`), donc cet appel
    /// explicite n'est qu'un chemin direct, sans danger s'il double l'observation (rien n'est réécrit si rien n'a changé).
    func preferencesDidChange() {
        lastShowsLastQuestion = preferences.showsLastQuestionInWidget
        refreshWidget()
    }

    /// « Tout effacer » : vide aussi ce que les intégrations ont publié hors de l'app.
    func eraseAll() async {
        widgetPublisher.erase()
    }

    // MARK: Réglages

    /// Règle de Ben : éteindre « Dernière question dans le widget » efface l'instantané tout de suite, quel que
    /// soit l'écran qui change le réglage (Réglages de l'app, Raccourcis, tests). On ne compte donc pas sur l'appel
    /// d'un écran : on écoute les `UserDefaults` de l'app et on ne réagit que si CE réglage bascule.
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
        let current = preferences.showsLastQuestionInWidget
        guard current != lastShowsLastQuestion else { return }
        lastShowsLastQuestion = current
        refreshWidget()
    }

    // MARK: Widget

    private func refreshWidget() {
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
}
