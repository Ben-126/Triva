//
//  DiscoverView.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation
import SwiftUI

// MARK: - État (ViewModel)

/// État de l'écran Découvrir (tâche 1.8) : chargement, rafraîchissement et
/// sujet sélectionné, au-dessus de `DiscoverService` (déjà écrit, non modifié).
///
/// ## Pourquoi un objet détenu AU-DESSUS de la vue
/// Un chargement coûte cher : 5 sujets × 3 domaines × 3 à 4 requêtes, soit 45
/// à 60 combinaisons `site:domaine requête`, chacune pouvant faire DEUX
/// requêtes SearXNG (catégorie `news`, puis repli sans restriction, voir
/// `DiscoverService.searchOneCombo`). Jusqu'à ~120 requêtes vers des instances
/// publiques qui limitent leur débit. En `@State` dans la vue, tout serait
/// relancé à chaque retour sur l'onglet : en présentation
/// `NavigationSplitView` (iPad, Mac), changer de destination démonte la vue
/// (même constat que `SearchSession`, voir `ContentView.swift`). D'où :
/// - l'intégration crée CE modèle une seule fois, au niveau du shell de
///   `TrivaRootView`, et le passe à `DiscoverView(model:onSearch:)` ;
/// - `loadIfNeeded()` ne charge qu'au premier affichage (ou après un échec) ;
/// - rien ne se recharge tout seul ensuite : seul l'utilisateur rafraîchit
///   (tirer pour actualiser, ⌘R sur Mac, « Réessayer »).
///
/// ## Le chargement survit à la vue
/// La `Task` de chargement appartient au modèle, pas à la vue : `.task` et
/// `.refreshable` ne font qu'attendre sa fin (`await task.value`), et annuler
/// celui qui attend n'annule pas une `Task` non structurée. Quitter l'onglet
/// en plein chargement ne jette donc pas la centaine de requêtes déjà
/// parties : le résultat est là au retour. Deux demandes simultanées (tirer
/// pour actualiser pendant le premier chargement, ⌘R répété) partagent le
/// même chargement au lieu d'en lancer un second.
///
/// ## Échecs
/// `fetchTrending` ne lève jamais d'erreur : un sujet en échec finit dans
/// `failedTopics`. « Erreur réseau » veut donc dire « AUCUN sujet n'a rendu
/// d'article » (ou `fetchContent` a levé, p. ex. liste d'instances
/// illisible). Un échec partiel n'est jamais une erreur plein écran : la vue
/// « Tout » montre les sujets qui ont répondu, la puce d'un sujet en échec
/// mène à un état « Aucun article » local. Le détail d'une erreur n'est
/// jamais affiché (même règle que `ChatViewModel.userFacingMessage(for:)`).
///
/// Isolé au main actor (implicite) et pas `nonisolated` : il manipule
/// `DiscoverContent`, `DiscoverTopicSection` et `DiscoverArticle`, non
/// annotés dans `DiscoverService.swift`, donc isolés au main actor, conformance
/// `Equatable` comprise. La logique lourde n'est pas ici : les requêtes
/// tournent dans l'acteur `FailoverManager`, ce modèle ne fait qu'attendre.
@Observable
@MainActor
final class DiscoverViewModel {
    /// Phase de chargement. `.loaded` contient toujours du contenu déjà
    /// filtré (`sanitized(_:)`) ; il n'est vide que si le catalogue lui-même
    /// est vide (aucun sujet demandé), ce qui donne l'état « Aucun article ».
    enum Phase: Equatable, Sendable {
        /// Jamais chargé : `loadIfNeeded()` n'a pas encore tourné.
        case idle
        /// Premier chargement, ou nouvel essai après un échec : rien à
        /// montrer pendant ce temps.
        case loading
        case loaded(DiscoverContent)
        /// Aucun sujet n'a répondu, ou `fetchContent` a levé une erreur.
        case failed
    }

    /// Ce qu'un résultat de chargement fait de l'état. Type nommé plutôt
    /// qu'un tuple : `update(after:previous:)` est la règle centrale du
    /// rafraîchissement, et des tests la comparent telle quelle.
    struct Update: Equatable, Sendable {
        let phase: Phase
        let refreshDidFail: Bool
    }

    /// Repli autonome derrière `DiscoverView()` (sans modèle) : garde l'écran
    /// compilable et utilisable tant que l'intégration n'a pas injecté le
    /// modèle de la session. Partagé (`static`) pour ne pas tout recharger à
    /// chaque remontage de la vue. Deux limites, raisons de préférer
    /// l'injection : il crée son propre `FailoverManager` à chaque chargement
    /// (donc sans le cache de dernière instance fonctionnelle de la session),
    /// et sur Mac toutes les fenêtres partagent son état, sujet sélectionné
    /// compris.
    static let standalone = DiscoverViewModel(fetchContent: {
        // Faute de session à qui la demander, même liste et même mémoire de
        // fiabilité que la session, relues dans les stores persistés de l'app
        // (voir `TrivaSharedStores.searXNGInstances`).
        let instances = TrivaSharedStores.searXNGInstances(
            bundled: try PublicInstanceList.load(),
            directory: SearXNGDirectoryStore.shared.refreshedInstances,
            overrides: SearXNGInstanceOverrides.load(from: .standard)
        )
        let failoverManager = FailoverManager(instances: instances, reliability: .shared)
        return await DiscoverService(failoverManager: failoverManager).fetchTrending()
    })

    private(set) var phase: Phase = .idle
    /// Vrai pendant un rafraîchissement lancé alors qu'un contenu est déjà
    /// affiché : ce contenu reste à l'écran pendant ce temps.
    private(set) var isRefreshing = false
    /// Vrai quand le dernier rafraîchissement n'a rien rapporté d'exploitable :
    /// l'ancien contenu reste affiché, avec une ligne d'avertissement.
    private(set) var refreshDidFail = false
    /// Sujet affiché, `nil` pour « Tout ». Ici plutôt qu'en `@State` dans la
    /// vue : revenir sur l'onglet retrouve le sujet qu'on y avait laissé.
    var selectedTopic: DiscoverTopic?

    /// Même forme que les closures de `ChatViewModel` : la vue ne sait rien
    /// du réseau, les tests injectent un contenu factice.
    private let fetchContent: () async throws -> DiscoverContent
    @ObservationIgnored private var inFlightLoad: Task<Void, Never>?

    init(
        selectedTopic: DiscoverTopic? = nil,
        fetchContent: @escaping () async throws -> DiscoverContent
    ) {
        self.selectedTopic = selectedTopic
        self.fetchContent = fetchContent
    }

    /// Un chargement est en cours, quel qu'il soit (bouton ⌘R désactivé,
    /// « Réessayer » désactivé).
    var isLoading: Bool {
        if case .loading = phase { return true }
        return isRefreshing
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

    /// Pour tirer pour actualiser, ⌘R et « Réessayer » : relance toutes les
    /// recherches (le service remélange les articles à chaque appel).
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
        let previous = phase
        refreshDidFail = false
        if case .loaded = previous {
            isRefreshing = true
        } else {
            phase = .loading
        }

        let outcome: Result<DiscoverContent, any Error>
        do {
            outcome = .success(try await fetchContent())
        } catch {
            // Détail volontairement abandonné : l'écran n'affiche qu'un
            // message générique (voir le commentaire de tête).
            outcome = .failure(error)
        }

        let update = Self.update(after: outcome, previous: previous)
        phase = update.phase
        refreshDidFail = update.refreshDidFail
        isRefreshing = false
    }

    // MARK: Règles pures (testables)

    /// Règle centrale du rafraîchissement :
    /// - contenu exploitable (au moins un sujet garde un article après
    ///   `sanitized(_:)`, ou catalogue vide) : il remplace l'état ;
    /// - rien d'exploitable (erreur, ou tous les sujets en échec) alors qu'un
    ///   contenu était affiché : on GARDE l'ancien et on le signale. Un
    ///   rafraîchissement hors ligne ne doit pas effacer ce qu'on lisait ;
    /// - rien d'exploitable sans contenu préalable : `.failed`.
    static func update(after outcome: Result<DiscoverContent, any Error>, previous: Phase) -> Update {
        if case .success(let content) = outcome {
            let usable = sanitized(content)
            let everyTopicFailed = usable.sections.isEmpty && !usable.failedTopics.isEmpty
            if !everyTopicFailed {
                return Update(phase: .loaded(usable), refreshDidFail: false)
            }
        }
        if case .loaded(let previousContent) = previous {
            return Update(phase: .loaded(previousContent), refreshDidFail: true)
        }
        return Update(phase: .failed, refreshDidFail: false)
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
}

// MARK: - Mise en page (logique pure, testable)

/// Règles de mise en page du fil : nombre de colonnes, articles montrés par
/// sujet dans la vue « Tout ». `nonisolated` : uniquement des types primitifs.
nonisolated enum DiscoverLayout {
    /// En dessous, une colonne : à 320 pt, un titre garde une vingtaine de
    /// caractères par ligne à côté de la vignette.
    static let minimumColumnWidth: CGFloat = 320
    static let columnSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 24
    /// Plafond de colonnes : au-delà de 3, chaque article redevient une
    /// vignette perdue dans la largeur d'un grand écran Mac.
    static let maximumColumnCount = 3
    /// Largeur maximale du fil, centré au-delà : 3 colonnes de 320 pt et
    /// leurs espacements tiennent dedans (3 × 320 + 2 × 24 = 1 008).
    static let maximumContentWidth: CGFloat = 1080
    /// Vue « Tout » : deux rangées par sujet avant « Afficher les N autres
    /// articles », et jamais moins de 4 articles (à une colonne, deux rangées
    /// ne donneraient qu'un aperçu de 2 articles).
    static let overviewRowCount = 2
    static let minimumOverviewArticleCount = 4

    /// Colonnes pour une largeur de fil donnée : une seule aux tailles de
    /// texte d'accessibilité (les lignes y passent en colonne, voir
    /// `DiscoverArticleRow`), sinon autant de colonnes de 320 pt que la
    /// largeur en contient, entre 1 et 3. Une largeur nulle, négative ou non
    /// finie (premier rendu, avant toute mesure) donne 1. Le rapport est
    /// plafonné AVANT la conversion en `Int`, qui planterait sur une valeur
    /// aberrante.
    static func columnCount(availableWidth: CGFloat, isAccessibilitySize: Bool) -> Int {
        guard !isAccessibilitySize, availableWidth.isFinite, availableWidth > 0 else { return 1 }
        let ratio = (availableWidth + columnSpacing) / (minimumColumnWidth + columnSpacing)
        let fitting = Int(min(ratio, CGFloat(maximumColumnCount)).rounded(.down))
        return min(max(fitting, 1), maximumColumnCount)
    }

    /// Articles montrés par sujet dans « Tout » : deux rangées pleines (6 à
    /// trois colonnes plutôt qu'une rangée orpheline), 4 au minimum. Même
    /// principe que `MediaResultsPresentation.gridCapacity`.
    static func overviewArticleLimit(columnCount: Int) -> Int {
        let columns = min(max(1, columnCount), maximumColumnCount)
        return max(minimumOverviewArticleCount, columns * overviewRowCount)
    }

    /// Libellé du bouton qui déplie un sujet dans « Tout ».
    static func showMoreLabel(hiddenCount: Int) -> String {
        switch hiddenCount {
        case ...0: "Tout afficher"
        case 1: "Afficher 1 autre article"
        default: "Afficher les \(hiddenCount) autres articles"
        }
    }
}

// MARK: - Vue

/// Écran Découvrir (tâche 1.8) : l'actualité des 5 sujets du catalogue,
/// récupérée sans backend par `DiscoverService`. Port de
/// `src/app/discover/page.tsx` (web), refait selon DESIGN.md — étalon de
/// sobriété : l'app Actualités d'Apple.
///
/// ## Sélecteur de sujet : « Tout » puis les 5 sujets
/// `DiscoverService` charge TOUS les sujets d'un coup : c'est le modèle validé
/// par Ben, « plusieurs sections en une fois plutôt qu'un sélecteur de sujet +
/// rechargement » (voir sa documentation). D'où une rangée de puces en verre
/// qui FILTRE sur place, sans jamais rien recharger : « Tout » (par défaut)
/// montre chaque sujet en section, une puce de sujet ne montre que ses
/// articles. Une puce par sujet du catalogue, y compris en échec : la rangée
/// ne saute pas d'un rafraîchissement à l'autre. Pas de compteur sur les
/// puces (DESIGN.md : pas de chiffres qui ne servent à rien).
///
/// ## États, tous DANS le `ScrollView`
/// Chargement, erreur et liste vide occupent la hauteur visible
/// (`containerRelativeFrame`) à l'intérieur du `ScrollView` qui porte
/// `.refreshable` : tirer pour actualiser marche donc dans tous les états,
/// erreur comprise. Pendant un rafraîchissement, le contenu reste à l'écran
/// (le contrôle de rafraîchissement suffit) ; un rafraîchissement qui échoue
/// garde les articles et l'écrit sur une ligne sous les puces.
///
/// ## Plateformes
/// La largeur décide, pas l'appareil (`DiscoverLayout`) : une colonne sur
/// iPhone en portrait, deux le plus souvent en paysage, jusqu'à 3 sur iPad et
/// Mac. Le Mac n'a pas de geste « tirer pour actualiser » : un bouton de
/// barre d'outils (⌘R) le remplace, réservé au Mac (sur iPhone et iPad il
/// doublerait le geste). Titre en ligne sur iOS, comme
/// `TrivaHomeReferenceView` : un grand titre ajouterait une 6e taille de texte
/// à l'écran (DESIGN.md : 5 au plus).
///
/// ## Intégration (étape suivante, pas ici)
/// - `DiscoverView(model:onSearch:)`, avec UN `DiscoverViewModel` créé par le
///   shell de `TrivaRootView` (voir la documentation du modèle) ;
/// - `onSearch` reçoit l'article choisi pour « Chercher dans Triva » ;
/// - la vue contient son propre `NavigationStack` (titre, barre d'outils) :
///   ne pas l'envelopper dans un autre.
struct DiscoverView: View {
    let model: DiscoverViewModel
    let onSearch: ((DiscoverArticle) -> Void)?

    /// Largeur mesurée du fil (`onGeometryChange`), source du nombre de
    /// colonnes. 0 avant la première mesure, donc une colonne au tout
    /// premier rendu.
    @State private var availableWidth: CGFloat = 0
    /// Sujets dépliés dans « Tout ». État d'affichage local : il peut
    /// disparaître avec la vue sans conséquence.
    @State private var expandedTopics: Set<DiscoverTopic> = []
    /// Vrai seulement pendant un chargement lancé par « Réessayer » : le
    /// tirer-pour-actualiser affiche déjà son propre indicateur système, un
    /// second à la place du bouton ferait deux roues à l'écran (retour de Ben,
    /// 2026-10-04).
    @State private var isRetryingFromButton = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Ancre du haut du fil : changer de sujet ramène en haut du nouveau
    /// contenu. Posée sur le fil ENTIER, marges comprises, et pas sur les
    /// puces : `scrollTo(_:anchor: .top)` aligne le haut de la cible sur le
    /// haut de la zone visible, et des puces ancrées feraient remonter le fil
    /// de sa marge haute (8 pt) à chaque changement de sujet.
    private static let topAnchorID = "discover-top"

    init(model: DiscoverViewModel, onSearch: ((DiscoverArticle) -> Void)? = nil) {
        self.model = model
        self.onSearch = onSearch
    }

    /// Repli autonome (voir `DiscoverViewModel.standalone`) : garde l'appel
    /// actuel `DiscoverView()` de `TrivaRootView` compilable et fonctionnel
    /// avant l'intégration. Préférer `init(model:onSearch:)`.
    init(onSearch: ((DiscoverArticle) -> Void)? = nil) {
        self.init(model: .standalone, onSearch: onSearch)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    phaseContent
                }
                .refreshable {
                    await model.refresh()
                }
                .onChange(of: model.selectedTopic) {
                    proxy.scrollTo(Self.topAnchorID, anchor: .top)
                }
            }
            .navigationTitle("Découvrir")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #elseif os(macOS)
            .toolbar { refreshToolbarItem }
            #endif
            .task {
                await model.loadIfNeeded()
            }
            .onChange(of: model.phase) { oldPhase, newPhase in
                announce(DiscoverViewModel.announcement(from: oldPhase, to: newPhase))
            }
            .onChange(of: model.refreshDidFail) { _, didFail in
                if didFail {
                    announce("Actualisation impossible")
                }
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .idle, .loading:
            loadingView
        case .failed:
            failureView
        case .loaded(let content):
            if content.sections.isEmpty {
                emptyView
            } else {
                feed(content)
            }
        }
    }

    // MARK: Fil

    private func feed(_ content: DiscoverContent) -> some View {
        let columns = DiscoverLayout.columnCount(
            availableWidth: availableWidth,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
        return VStack(alignment: .leading, spacing: 24) {
            topicChips
            if model.refreshDidFail {
                refreshFailureNotice
            }
            if let topic = model.selectedTopic {
                topicArticles(topic, in: content, columns: columns)
            } else {
                overview(content, columns: columns)
            }
        }
        .frame(maxWidth: DiscoverLayout.maximumContentWidth, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            availableWidth = newWidth
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 40)
        .id(Self.topAnchorID)
    }

    /// Un seul `GlassEffectContainer` pour les puces, sœurs de verre, placé
    /// DANS le `ScrollView` horizontal comme les suggestions de
    /// `TrivaHomeReferenceView`. `scrollClipDisabled` : les puces défilent
    /// jusqu'au bord de l'écran au lieu d'être coupées net à la marge de 20.
    private var topicChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    DiscoverTopicChip(title: "Tout", isSelected: model.selectedTopic == nil) {
                        model.selectedTopic = nil
                    }
                    ForEach(DiscoverTopicCatalog.all) { definition in
                        DiscoverTopicChip(
                            title: definition.title,
                            isSelected: model.selectedTopic == definition.topic
                        ) {
                            model.selectedTopic = definition.topic
                        }
                    }
                }
            }
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sujets")
    }

    private var refreshFailureNotice: some View {
        Label("Actualisation impossible. Vérifie ta connexion.", systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// Vue « Tout » : un `ForEach` par sujet plutôt qu'une liste aplatie. La
    /// même URL peut remonter sous deux sujets (le service ne déduplique que
    /// DANS un sujet) : aplaties, deux lignes partageraient un `id`.
    private func overview(_ content: DiscoverContent, columns: Int) -> some View {
        LazyVStack(alignment: .leading, spacing: 32) {
            ForEach(content.sections) { section in
                overviewSection(section, columns: columns)
            }
        }
    }

    /// Une section de « Tout » : intitulé, deux rangées d'articles, puis
    /// « Afficher les N autres articles » qui déplie sur place. Même règle
    /// d'affichage que la liste de vidéos du chat
    /// (`MediaResultsPresentation.listLayout`) : le bouton n'apparaît que
    /// s'il cache au moins 2 articles.
    private func overviewSection(_ section: DiscoverTopicSection, columns: Int) -> some View {
        let limit = expandedTopics.contains(section.topic)
            ? section.articles.count
            : DiscoverLayout.overviewArticleLimit(columnCount: columns)
        let layout = MediaResultsPresentation.listLayout(totalCount: section.articles.count, limit: limit)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(for: section.topic)
            articleGrid(Array(section.articles.prefix(layout.visibleCount)), columns: columns)
            if layout.hiddenCount > 0 {
                Button {
                    withAnimation {
                        _ = expandedTopics.insert(section.topic)
                    }
                } label: {
                    Label(DiscoverLayout.showMoreLabel(hiddenCount: layout.hiddenCount), systemImage: "chevron.down")
                }
                .font(.subheadline)
                .buttonStyle(.glass)
            }
        }
    }

    /// Un sujet choisi : tous ses articles, sans intitulé (la puce
    /// sélectionnée le dit déjà). Sujet en échec : état « Aucun article »
    /// local, le reste de l'écran (puces) reste utilisable.
    @ViewBuilder
    private func topicArticles(_ topic: DiscoverTopic, in content: DiscoverContent, columns: Int) -> some View {
        if let section = content.sections.first(where: { $0.topic == topic }) {
            articleGrid(section.articles, columns: columns)
        } else {
            topicEmptyState(topic)
        }
    }

    private func articleGrid(_ articles: [DiscoverArticle], columns: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: DiscoverLayout.columnSpacing, alignment: .top),
                count: columns
            ),
            alignment: .leading,
            spacing: DiscoverLayout.rowSpacing
        ) {
            ForEach(articles) { article in
                DiscoverArticleRow(article: article, onSearch: onSearch)
            }
        }
    }

    /// Intitulé de section au style des labels de section de la DA
    /// (« ESSAIE » dans `TrivaHomeReferenceView`) : `.caption2` medium (11 pt
    /// par défaut, mais qui suit Dynamic Type), `tracking(1.5)`, majuscules,
    /// `.tertiary`. Trait `.isHeader` : le rotor « En-têtes » de VoiceOver
    /// saute directement d'un sujet à l'autre.
    private func sectionHeader(for topic: DiscoverTopic) -> some View {
        Text(title(for: topic))
            .font(.caption2.weight(.medium))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: États

    private var loadingView: some View {
        ProgressView("Chargement de l'actualité…")
            .containerRelativeFrame([.horizontal, .vertical])
    }

    /// « Réessayer » en `.glassProminent` : c'est la seule action de l'écran
    /// dans cet état, donc son action principale (DESIGN.md).
    private var failureView: some View {
        ContentUnavailableView {
            Label("Actualité indisponible", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Aucune source n'a répondu. Vérifie ta connexion, puis réessaie.")
        } actions: {
            Button("Réessayer") {
                Task { await model.refresh() }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.isLoading)
        }
        .containerRelativeFrame([.horizontal, .vertical])
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "Aucun article",
            systemImage: "newspaper",
            description: Text("Reviens un peu plus tard.")
        )
        .containerRelativeFrame([.horizontal, .vertical])
    }

    /// « Réessayer » relance TOUS les sujets : le service ne sait charger que
    /// l'ensemble. En `.glass` : action secondaire, sous les puces. Un
    /// indicateur prend sa place UNIQUEMENT quand c'est ce bouton qui a lancé
    /// le chargement (sur iPhone et iPad, il n'affiche pas le contrôle de
    /// « tirer pour actualiser ») ; pendant un tirer-pour-actualiser, le bouton
    /// est seulement grisé, pour ne jamais montrer deux indicateurs à la fois.
    private func topicEmptyState(_ topic: DiscoverTopic) -> some View {
        ContentUnavailableView {
            Label("Aucun article", systemImage: definition(for: topic)?.systemImage ?? "newspaper")
        } description: {
            Text("Rien n'a pu être chargé pour ce sujet.")
        } actions: {
            if isRetryingFromButton && model.isLoading {
                ProgressView()
                    .accessibilityLabel("Chargement en cours")
            } else {
                Button("Réessayer") {
                    Task {
                        isRetryingFromButton = true
                        await model.refresh()
                        isRetryingFromButton = false
                    }
                }
                .buttonStyle(.glass)
                .disabled(model.isLoading)
            }
        }
        .padding(.top, 24)
    }

    // MARK: Barre d'outils (Mac)

    #if os(macOS)
    /// Remplace le geste « tirer pour actualiser », absent sur Mac. Un
    /// indicateur de progression prend sa place pendant un chargement : le
    /// contenu restant affiché, c'est le seul signe qu'une actualisation
    /// tourne.
    private var refreshToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Actualisation en cours")
            } else {
                Button("Actualiser", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Actualiser (⌘R)")
            }
        }
    }
    #endif

    // MARK: Outils

    private func definition(for topic: DiscoverTopic) -> DiscoverTopicDefinition? {
        DiscoverTopicCatalog.all.first { $0.topic == topic }
    }

    /// Titre du catalogue (« Art & Culture »), ou l'identifiant brut si le
    /// catalogue venait à perdre une entrée : jamais d'intitulé vide.
    private func title(for topic: DiscoverTopic) -> String {
        definition(for: topic)?.title ?? topic.rawValue.capitalized
    }

    private func announce(_ message: String?) {
        guard let message else { return }
        AccessibilityNotification.Announcement(message).post()
    }
}

/// Puce de sujet. Sélectionnée : verre teinté à l'accent et texte à l'accent,
/// la teinte des chips de la DA (0,15) ; sinon verre neutre. Jamais de bordure
/// en plus (DESIGN.md : la teinte suffit à dire la sélection).
/// `.interactive()` : elle répond au toucher. Trait `.isSelected` : VoiceOver
/// annonce « sélectionné » sur la puce active.
private struct DiscoverTopicChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(
                    isSelected ? .regular.tint(.accentColor.opacity(0.15)).interactive() : .regular.interactive(),
                    in: .capsule
                )
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Previews

#Preview("Découvrir — tous les sujets") {
    DiscoverView(
        model: DiscoverViewModel(fetchContent: { DiscoverPreviewData.content }),
        onSearch: { _ in }
    )
}

#Preview("Découvrir — un sujet") {
    DiscoverView(
        model: DiscoverViewModel(selectedTopic: .tech, fetchContent: { DiscoverPreviewData.content }),
        onSearch: { _ in }
    )
}

#Preview("Découvrir — sujet sans article") {
    DiscoverView(
        model: DiscoverViewModel(selectedTopic: .sports, fetchContent: { DiscoverPreviewData.partialContent })
    )
}

#Preview("Découvrir — chargement") {
    DiscoverView(
        model: DiscoverViewModel(fetchContent: {
            try await Task.sleep(for: .seconds(3600))
            return DiscoverPreviewData.content
        })
    )
}

#Preview("Découvrir — erreur réseau") {
    DiscoverView(model: DiscoverViewModel(fetchContent: { DiscoverPreviewData.allFailedContent }))
}

#Preview("Découvrir — vide") {
    DiscoverView(model: DiscoverViewModel(fetchContent: { DiscoverContent.empty }))
}

#Preview("Découvrir — sombre") {
    DiscoverView(model: DiscoverViewModel(fetchContent: { DiscoverPreviewData.content }))
        .preferredColorScheme(.dark)
}

#Preview("Découvrir — très grand texte") {
    DiscoverView(model: DiscoverViewModel(fetchContent: { DiscoverPreviewData.content }))
        .dynamicTypeSize(.accessibility3)
}
