//
//  DiscoverViewModel.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation

/// État de l'écran Découvrir (tâche 1.8) : cache, chargement, rafraîchissement et
/// sujet sélectionné, au-dessus de `DiscoverService`.
///
/// ## Pourquoi un objet détenu AU-DESSUS de la vue
/// En `@State` dans la vue, tout serait relancé à chaque retour sur l'onglet : en
/// présentation `NavigationSplitView` (iPad, Mac), changer de destination démonte
/// la vue (même constat que `SearchSession`, voir `ContentView.swift`). D'où :
/// - `TrivaRootCoordinator` crée CE modèle une seule fois par fenêtre ;
/// - `loadIfNeeded()` ne charge qu'au premier affichage (ou après un échec) ;
/// - rien ne se recharge tout seul ensuite : seul l'utilisateur rafraîchit
///   (tirer pour actualiser, ⌘R sur Mac, « Réessayer »).
///
/// ## Ce que voit l'utilisateur, dans l'ordre
/// 1. Si le cache a des articles (`DiscoverContentCaching`) : ils s'affichent tout
///    de suite, et la mise à jour part en arrière-plan.
/// 2. Sinon, chaque sujet apparaît dès qu'il est prêt (`pendingTopics`).
/// 3. Du contenu déjà à l'écran ne change qu'À LA FIN d'un chargement, en une
///    fois : un sujet remplacé pendant la lecture déplacerait le texte plusieurs
///    fois de suite sous les yeux de l'utilisateur, pour un gain nul puisqu'il a
///    déjà quelque chose à lire.
///
/// ## Le chargement survit à la vue
/// La `Task` de chargement appartient au modèle, pas à la vue : `.task` et
/// `.refreshable` ne font qu'attendre sa fin (`await task.value`), et annuler
/// celui qui attend n'annule pas une `Task` non structurée. Quitter l'onglet en
/// plein chargement ne jette donc pas les requêtes déjà parties. Deux demandes
/// simultanées (tirer pour actualiser pendant le premier chargement, ⌘R répété)
/// partagent le même chargement au lieu d'en lancer un second.
///
/// ## Échecs
/// `fetchTrending` ne lève jamais d'erreur : un sujet en échec finit dans
/// `failedTopics`. « Erreur réseau » veut donc dire « AUCUN sujet n'a rendu
/// d'article » (ou le chargement a levé, p. ex. fenêtre fermée). Un échec partiel
/// n'est jamais une erreur plein écran : un sujet en échec garde ses anciens
/// articles s'il en avait (`staleTopics`, signalé par `staleNotice`), sinon sa
/// puce mène à un état « Aucun article » local. Le détail d'une erreur n'est
/// jamais affiché (même règle que `ChatViewModel.userFacingMessage(for:)`).
///
/// ## Un fil qui ne saute pas
/// - L'ordre des articles est celui des dates de publication (`DiscoverService`), plus un
///   mélange : un fil restauré du cache et le fil actualisé s'ordonnent de la même façon, et
///   seuls les articles vraiment nouveaux changent de place.
/// - L'avertissement « Actualisation impossible » (`refreshDidFail`, `staleTopics`) n'est
///   remplacé qu'AVEC le résultat du chargement, pas à son lancement : il restait sinon
///   affiché une seconde de moins, puis revenait, sous les yeux de l'utilisateur (Q1).
/// - Un article restauré qui a dépassé l'âge maximal est retiré avant l'affichage.
///
/// ## Hors connexion (tâche 1.16)
/// Quand l'appareil est hors connexion (`isOffline`, `ConnectivityMonitor`), un chargement ne lance
/// AUCUNE requête : il restaure le cache s'il y en a un (articles de la dernière visite, avec leur âge
/// dans la ligne « Hors connexion. Dernière mise à jour : … »), sinon il affiche l'état « Hors
/// connexion ». Au retour de la connexion, `connectionDidReturn()` relance ce qui attendait. Même
/// règle que partout : le moniteur n'est qu'un raccourci, un chargement lancé « en ligne » qui
/// échoue garde son traitement habituel (`update(after:previous:)`).
///
/// Isolé au main actor (implicite) : il pilote l'interface. La logique lourde n'est pas
/// ici : les flux sont lus et analysés hors du main actor (`HTTPFeedFetcher`) et le disque
/// dans `DiscoverDiskCache` (`@concurrent`).
@Observable
@MainActor
final class DiscoverViewModel {
    /// Phase de chargement. `.loaded` contient toujours du contenu déjà filtré
    /// (`sanitized(_:)`) ; il n'est vide que si le catalogue lui-même est vide
    /// (aucun sujet demandé), ce qui donne l'état « Aucun article », ou le temps
    /// que `pendingTopics` se vide.
    enum Phase: Equatable, Sendable {
        /// Jamais chargé : `loadIfNeeded()` n'a pas encore tourné, ou lit le cache.
        case idle
        /// Premier chargement, ou nouvel essai après un échec : aucun sujet n'est
        /// encore prêt.
        case loading
        case loaded(DiscoverContent)
        /// Aucun sujet n'a répondu, ou le chargement a levé une erreur.
        case failed
    }

    /// Ce qu'un résultat de chargement fait de l'état. Type nommé plutôt qu'un
    /// tuple : `update(after:previous:)` est la règle centrale du rafraîchissement,
    /// et des tests la comparent telle quelle.
    struct Update: Equatable, Sendable {
        let phase: Phase
        let refreshDidFail: Bool
        /// Sujets en échec qui gardent leurs anciens articles.
        let staleTopics: [DiscoverTopic]

        init(phase: Phase, refreshDidFail: Bool, staleTopics: [DiscoverTopic] = []) {
            self.phase = phase
            self.refreshDidFail = refreshDidFail
            self.staleTopics = staleTopics
        }
    }

    /// Reçoit chaque sujet dès qu'il est terminé (articles vides : échec).
    typealias TopicHandler = @MainActor (DiscoverTopic, [DiscoverArticle]) -> Void

    private(set) var phase: Phase = .idle
    /// Vrai pendant un rafraîchissement lancé alors qu'un contenu est déjà
    /// affiché : ce contenu reste à l'écran pendant ce temps.
    private(set) var isRefreshing = false
    /// Vrai quand le dernier chargement n'a rien rapporté d'exploitable : l'ancien
    /// contenu reste affiché, avec une ligne d'avertissement.
    private(set) var refreshDidFail = false
    /// Sujets affichés avec leurs anciens articles : leur mise à jour a échoué.
    private(set) var staleTopics: [DiscoverTopic] = []
    /// Sujets attendus pour la première fois : chacun a sa place réservée à l'écran.
    /// Vide dès qu'un contenu était déjà affiché au début du chargement.
    private(set) var pendingTopics: Set<DiscoverTopic> = []
    /// Date de récupération de chaque sujet affiché.
    private(set) var sectionDates: [DiscoverTopic: Date] = [:]
    /// Vrai pendant la mise à jour automatique d'articles restaurés du cache.
    private(set) var isUpdatingRestoredContent = false
    /// Vrai quand ce qui est affiché (articles du cache, ou l'état d'échec) l'est parce que l'appareil
    /// est hors connexion, pas parce que les sources n'ont pas répondu (tâche 1.16).
    private(set) var isShowingOfflineState = false
    /// Phase au début du dernier chargement, pour son annonce VoiceOver.
    private var phaseBeforeLoad: Phase = .idle
    /// Sujet affiché, `nil` pour « Tout ». Ici plutôt qu'en `@State` dans la
    /// vue : revenir sur l'onglet retrouve le sujet qu'on y avait laissé.
    var selectedTopic: DiscoverTopic?

    private let loadContent: (@escaping TopicHandler) async throws -> DiscoverContent
    private let cache: any DiscoverContentCaching
    private let topics: [DiscoverTopic]
    private let now: () -> Date
    private let isOffline: @MainActor () -> Bool
    @ObservationIgnored private var inFlightLoad: Task<Void, Never>?

    /// - Parameters:
    ///   - cache: articles de la dernière visite ; aucun par défaut (tests, aperçus).
    ///   - topics: sujets attendus, ceux du catalogue par défaut.
    ///   - now: horloge injectable, pour les dates des sujets.
    ///   - isOffline: l'appareil est-il hors connexion ? (`{ false }` par défaut : aucun changement.)
    ///   - loadContent: même forme que les closures de `ChatViewModel` : la vue ne
    ///     sait rien du réseau, les tests injectent un contenu factice.
    init(
        selectedTopic: DiscoverTopic? = nil,
        cache: any DiscoverContentCaching = DiscoverNoCache(),
        topics: [DiscoverTopic] = DiscoverTopicCatalog.all.map(\.topic),
        now: @escaping () -> Date = { Date() },
        isOffline: @escaping @MainActor () -> Bool = { false },
        loadContent: @escaping (@escaping TopicHandler) async throws -> DiscoverContent
    ) {
        self.selectedTopic = selectedTopic
        self.cache = cache
        self.topics = topics
        self.now = now
        self.isOffline = isOffline
        self.loadContent = loadContent
    }

    /// Lu par la vue : l'état d'écran « Hors connexion » et le retour de la connexion.
    var isDeviceOffline: Bool { isOffline() }

    /// La connexion revient : relance ce qui attendait (cache affiché hors connexion, ou rien à
    /// afficher). Sans effet si un contenu à jour est déjà là ou si un chargement est en cours.
    func connectionDidReturn() async {
        guard !isDeviceOffline, isShowingOfflineState, !isLoading else { return }
        await load()
    }

    /// Source qui ne signale pas ses sujets un par un (aperçus, tests).
    convenience init(
        selectedTopic: DiscoverTopic? = nil,
        fetchContent: @escaping () async throws -> DiscoverContent
    ) {
        self.init(selectedTopic: selectedTopic, loadContent: { _ in try await fetchContent() })
    }

    /// Un chargement est en cours, quel qu'il soit (bouton ⌘R désactivé,
    /// « Réessayer » désactivé).
    var isLoading: Bool {
        if case .loading = phase { return true }
        return isRefreshing || !pendingTopics.isEmpty
    }

    /// Pour `.task` : charge au premier affichage, ou retente après un
    /// échec (l'utilisateur revient peut-être avec du réseau). Sans effet si
    /// un contenu est déjà là ou en route.
    func loadIfNeeded() async {
        switch phase {
        case .idle, .failed:
            await load()
        case .loading, .loaded:
            return
        }
    }

    /// Pour tirer pour actualiser, ⌘R et « Réessayer » : relit tous les flux.
    func refresh() async {
        await load()
    }

    /// Un seul chargement à la fois : un appel qui arrive pendant un
    /// chargement attend celui-ci au lieu d'en lancer un autre.
    /// `inFlightLoad` est remis à `nil` DANS la `Task`, avant qu'elle ne se
    /// termine : un appel arrivé juste après la fin repart bien sur un
    /// chargement neuf au lieu de réattendre l'ancien.
    private func load() async {
        if let inFlightLoad {
            await inFlightLoad.value
            return
        }
        let task = Task {
            await self.performLoad()
            self.inFlightLoad = nil
        }
        inFlightLoad = task
        await task.value
    }

    private func performLoad() async {
        phaseBeforeLoad = phase
        let restored = await restoreFromCacheIfNeeded()
        guard !isOffline() else {
            showOfflineState()
            return
        }
        if case .loaded = phase {
            isRefreshing = true
            isUpdatingRestoredContent = restored
        } else {
            pendingTopics = Set(topics)
            phase = .loading
        }

        let outcome: Result<DiscoverContent, any Error>
        do {
            outcome = .success(try await loadContent { [weak self] topic, articles in
                self?.topicDidFinish(topic, articles: articles)
            })
        } catch {
            // Détail volontairement abandonné : l'écran n'affiche qu'un
            // message générique (voir le commentaire de tête).
            outcome = .failure(error)
        }

        apply(Self.update(after: outcome, previous: phase))
        // Après `apply` seulement : la ligne « Hors connexion. » ne devient pas « Actualisation impossible. »
        // pendant le chargement qui suit le retour de la connexion.
        isShowingOfflineState = false
        pendingTopics = []
        isRefreshing = false
        isUpdatingRestoredContent = false
        await saveToCacheIfUseful()
    }

    /// Hors connexion : pas de requête. Le contenu affiché (cache) reste, signalé ; sans contenu, l'état
    /// d'échec, que la vue dit « Hors connexion ». Rien n'est enregistré : le fichier a déjà ces articles.
    private func showOfflineState() {
        isShowingOfflineState = true
        if case .loaded(let content) = phase, !content.sections.isEmpty {
            refreshDidFail = true
            staleTopics = []
        } else {
            phase = .failed
        }
        pendingTopics = []
        isRefreshing = false
        isUpdatingRestoredContent = false
    }

    /// `true` si des articles restaurés sont désormais à l'écran. Ne lit le disque
    /// qu'une fois, avant le tout premier chargement.
    private func restoreFromCacheIfNeeded() async -> Bool {
        guard case .idle = phase, let snapshot = await cache.load() else { return false }
        let restored = snapshot.restored()
        let usable = Self.sanitized(Self.recent(restored.content, now: now()))
        guard !usable.sections.isEmpty else { return false }
        phase = .loaded(DiscoverContent(sections: usable.sections, failedTopics: []))
        sectionDates = restored.dates
        return true
    }

    /// Un sujet attendu pour la première fois prend sa place. Sans effet sur du
    /// contenu déjà affiché (voir le commentaire de tête).
    private func topicDidFinish(_ topic: DiscoverTopic, articles: [DiscoverArticle]) {
        guard pendingTopics.remove(topic) != nil else { return }
        let usable = articles.filter { Self.isDisplayable($0) }
        guard !usable.isEmpty else { return }
        var sections: [DiscoverTopicSection] = []
        if case .loaded(let current) = phase {
            sections = current.sections
        }
        sections.append(DiscoverTopicSection(topic: topic, articles: usable))
        phase = .loaded(DiscoverContent(sections: Self.inCatalogOrder(sections), failedTopics: []))
        sectionDates[topic] = now()
    }

    private func apply(_ update: Update) {
        phase = update.phase
        refreshDidFail = update.refreshDidFail
        staleTopics = update.staleTopics
        guard !update.refreshDidFail, case .loaded(let content) = update.phase else { return }
        let date = now()
        var dates: [DiscoverTopic: Date] = [:]
        for section in content.sections {
            dates[section.topic] = update.staleTopics.contains(section.topic)
                ? sectionDates[section.topic] ?? date
                : date
        }
        sectionDates = dates
    }

    /// Rien à sauver après un chargement raté : le fichier a déjà ces articles.
    private func saveToCacheIfUseful() async {
        guard !refreshDidFail, case .loaded(let content) = phase, !content.sections.isEmpty else { return }
        await cache.save(DiscoverCacheSnapshot(content: content, dates: sectionDates, fallbackDate: now()))
    }

    // MARK: Règles pures (testables)

    /// Règle centrale du rafraîchissement :
    /// - contenu exploitable (au moins un sujet garde un article après
    ///   `sanitized(_:)`, ou catalogue vide) : il remplace l'état, sauf les sujets
    ///   en échec qui avaient déjà des articles et les gardent ;
    /// - rien d'exploitable (erreur, ou tous les sujets en échec) alors qu'un
    ///   contenu était affiché : on GARDE l'ancien et on le signale. Un
    ///   rafraîchissement hors ligne ne doit pas effacer ce qu'on lisait ;
    /// - rien d'exploitable sans contenu préalable : `.failed`.
    static func update(after outcome: Result<DiscoverContent, any Error>, previous: Phase) -> Update {
        if case .success(let content) = outcome {
            let usable = sanitized(content)
            let everyTopicFailed = usable.sections.isEmpty && !usable.failedTopics.isEmpty
            if !everyTopicFailed {
                return merged(usable, previous: previous)
            }
        }
        if case .loaded(let previousContent) = previous, !previousContent.sections.isEmpty {
            return Update(phase: .loaded(previousContent), refreshDidFail: true)
        }
        return Update(phase: .failed, refreshDidFail: false)
    }

    private static func merged(_ usable: DiscoverContent, previous: Phase) -> Update {
        guard case .loaded(let previousContent) = previous else {
            return Update(phase: .loaded(usable), refreshDidFail: false)
        }
        let kept = previousContent.sections.filter { usable.failedTopics.contains($0.topic) }
        let keptTopics = kept.map(\.topic)
        let content = DiscoverContent(
            sections: inCatalogOrder(usable.sections + kept),
            failedTopics: usable.failedTopics.filter { !keptTopics.contains($0) }
        )
        return Update(phase: .loaded(content), refreshDidFail: false, staleTopics: keptTopics)
    }

    private static func inCatalogOrder(_ sections: [DiscoverTopicSection]) -> [DiscoverTopicSection] {
        DiscoverTopic.allCases.flatMap { topic in sections.filter { $0.topic == topic } }
    }

    /// Retire d'un contenu restauré les articles sans date ou plus vieux que l'âge maximal
    /// de `DiscoverService` : un fichier de cache peut dater de plusieurs semaines. Un sujet
    /// qui n'en garde aucun disparaît, comme avec `sanitized(_:)`.
    static func recent(
        _ content: DiscoverContent,
        now: Date,
        maximumAge: TimeInterval = DiscoverService.defaultMaximumArticleAge
    ) -> DiscoverContent {
        let oldest = now.addingTimeInterval(-maximumAge)
        let sections = content.sections.compactMap { section -> DiscoverTopicSection? in
            let articles = section.articles.filter { ($0.publishedAt ?? .distantPast) >= oldest }
            return articles.isEmpty ? nil : DiscoverTopicSection(topic: section.topic, articles: articles)
        }
        return DiscoverContent(sections: sections, failedTopics: content.failedTopics)
    }

    /// Retire les articles inaffichables (voir `isDisplayable(_:)`). Un sujet
    /// qui n'en garde aucun passe dans `failedTopics` : pour l'écran, c'est
    /// exactement un sujet qui n'a rien rendu.
    static func sanitized(_ content: DiscoverContent) -> DiscoverContent {
        var sections: [DiscoverTopicSection] = []
        var failedTopics = content.failedTopics
        for section in content.sections {
            let articles = section.articles.filter { isDisplayable($0) }
            if articles.isEmpty {
                failedTopics.append(section.topic)
            } else {
                sections.append(DiscoverTopicSection(topic: section.topic, articles: articles))
            }
        }
        return DiscoverContent(sections: sections, failedTopics: failedTopics)
    }

    /// Un article s'affiche s'il a un titre et une URL `http`/`https`
    /// ouvrable : sans l'un ou l'autre, la ligne ne mènerait nulle part.
    static func isDisplayable(_ article: DiscoverArticle) -> Bool {
        DiscoverArticlePresentation.articleURL(from: article.url) != nil
            && !DiscoverArticlePresentation.displayText(article.title).isEmpty
    }

    /// Places de la vue « Tout », dans l'ordre du catalogue : un sujet prêt, ou la
    /// place réservée d'un sujet en route. Un sujet déjà visible garde sa position
    /// relative quand un autre arrive.
    static func overviewSlots(
        content: DiscoverContent,
        pending: Set<DiscoverTopic>
    ) -> [DiscoverOverviewSlot] {
        DiscoverTopic.allCases.compactMap { topic in
            if let section = content.sections.first(where: { $0.topic == topic }) {
                return .ready(section)
            }
            return pending.contains(topic) ? .pending(topicID: topic.rawValue) : nil
        }
    }

    /// Annonce VoiceOver d'un changement de phase : la fin d'un chargement ne
    /// se voit qu'à l'écran (le spinner disparaît), VoiceOver doit l'entendre.
    /// `nil` pour les phases de chargement, déjà portées par leur libellé.
    static func announcement(from oldPhase: Phase, to newPhase: Phase) -> String? {
        switch newPhase {
        case .loaded:
            if case .loaded = oldPhase { return "Actualité mise à jour" }
            return "Actualité chargée"
        case .failed:
            return "Actualité indisponible"
        case .idle, .loading:
            return nil
        }
    }

    /// Annonce de la fin du dernier chargement.
    var completionAnnouncement: String? {
        refreshDidFail
            ? "Actualisation impossible"
            : Self.announcement(from: phaseBeforeLoad, to: phase)
    }

    /// Ligne discrète sous les puces quand ce qui est affiché est ancien parce que
    /// la mise à jour a échoué, `nil` sinon.
    func staleNotice(calendar: Calendar) -> String? {
        let staleDates = refreshDidFail ? Array(sectionDates.values) : staleTopics.compactMap { sectionDates[$0] }
        let titles = staleTopics.map { topic in
            DiscoverTopicCatalog.all.first { $0.topic == topic }?.title ?? topic.rawValue.capitalized
        }
        return DiscoverStaleNotice.text(
            refreshDidFail: refreshDidFail,
            isOffline: isShowingOfflineState,
            staleTitles: titles,
            oldestDate: staleDates.min(),
            now: now(),
            calendar: calendar
        )
    }
}

/// Une place de la vue « Tout » : un sujet prêt, ou un sujet encore en route.
enum DiscoverOverviewSlot: Identifiable, Equatable {
    case ready(DiscoverTopicSection)
    case pending(topicID: String)

    var id: String {
        switch self {
        case .ready(let section): section.id
        case .pending(let topicID): topicID
        }
    }
}

/// Texte de l'avertissement de contenu ancien. `nonisolated` : uniquement des types
/// primitifs. Dit ce qui a échoué et depuis quand datent les articles : c'est ce qui
/// permet de juger s'ils valent encore la peine d'être lus.
nonisolated enum DiscoverStaleNotice {
    /// En dessous, l'âge n'apprend rien (« Maintenant ») : on ne l'écrit pas.
    static let minimumMeaningfulAge: TimeInterval = 60

    /// Espace insécable, dans toute l'expression de l'âge et devant le « : » (typographie française).
    /// Le retour à la ligne tombait en plein milieu : « il / y a 8 minutes » sur iPhone 18 Pro,
    /// « il y a / 8 minutes » sur iPad mini, en taille normale (constaté à l'écran, mission Q2). Si une
    /// très grande taille de texte ne loge pas l'expression sur une ligne, le système la coupe tout de
    /// même : le texte reste lisible, et ce cas est bien plus rare que la coupure évitée ici.
    private static let nonBreakingSpace = "\u{00A0}"

    static func text(
        refreshDidFail: Bool,
        isOffline: Bool = false,
        staleTitles: [String],
        oldestDate: Date?,
        now: Date,
        calendar: Calendar
    ) -> String? {
        let failure: String
        if refreshDidFail, isOffline {
            failure = "Hors connexion."
        } else if refreshDidFail {
            failure = "Actualisation impossible."
        } else if staleTitles.count == 1, let title = staleTitles.first {
            failure = "\(title) n'a pas pu être actualisé."
        } else if staleTitles.count > 1 {
            let titles = staleTitles.formatted(.list(type: .and).locale(RelativeDateLabel.locale))
            failure = "\(titles) n'ont pas pu être actualisés."
        } else {
            return nil
        }
        guard let oldestDate, now.timeIntervalSince(oldestDate) >= minimumMeaningfulAge else {
            return refreshDidFail && !isOffline ? "\(failure) Vérifie ta connexion." : failure
        }
        let age = RelativeDateLabel.text(for: oldestDate, relativeTo: now, calendar: calendar)
            .lowercased(with: RelativeDateLabel.locale)
            .replacingOccurrences(of: " ", with: nonBreakingSpace)
        return "\(failure) Dernière mise à jour\(nonBreakingSpace): \(age)."
    }
}
