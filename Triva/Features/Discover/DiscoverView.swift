//
//  DiscoverView.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation
import SwiftUI

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
/// ## Premier chargement sans cache : des places réservées
/// Chaque sujet a sa place dans l'ordre du catalogue dès le départ, occupée par
/// des lignes neutres de même gabarit que les vraies (`DiscoverPendingSection`).
/// Un sujet prêt remplit SA place, sans déplacer ceux qui sont déjà visibles.
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
/// ## Intégration
/// - UN `DiscoverViewModel` par `TrivaRootCoordinator` (voir sa documentation) ;
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
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    phaseContent
                        // Le contenu affiché ne change qu'à la fin d'une actualisation, en une fois
                        // (voir `DiscoverViewModel`) : un fondu plutôt qu'un saut sec (Q1).
                        .animation(reduceMotion ? nil : .smooth, value: model.phase)
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
            .toolbar { backgroundUpdateToolbarItem }
            #elseif os(macOS)
            .toolbar { refreshToolbarItem }
            #endif
            .task {
                await model.loadIfNeeded()
            }
            // Tâche 1.16 : la connexion revient, le cache affiché hors connexion se met à jour.
            .onChange(of: model.isDeviceOffline) { _, isOffline in
                guard !isOffline else { return }
                Task { await model.connectionDidReturn() }
            }
            // À la fin du chargement seulement : pas une annonce par sujet reçu.
            .onChange(of: model.isLoading) { wasLoading, isLoading in
                if wasLoading && !isLoading {
                    announce(model.completionAnnouncement)
                }
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .idle:
            // Le temps de lire le cache (quelques millisecondes) : un indicateur
            // ne ferait que clignoter avant les articles.
            Color.clear
                .containerRelativeFrame([.horizontal, .vertical])
        case .loading:
            feed(.empty)
        case .failed:
            failureView
        case .loaded(let content):
            if content.sections.isEmpty && model.pendingTopics.isEmpty {
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
            if let notice = model.staleNotice(calendar: calendar) {
                staleNoticeLabel(notice)
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
    /// `TrivaHomeReferenceView`. Le défilement est coupé à la marge (voir plus bas).
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
        // Pas de `scrollClipDisabled` : il laissait les puces défiler sous l'indicateur d'état et
        // l'anneau de batterie de l'iPhone Duo plié (finding Q3 n°26, HIG designing-for-iphone-duo.md :
        // « Use safe areas to make sure controls don't cover your content »). Les puces sont coupées
        // à la marge, avec le fondu de bord de défilement du système.
        .scrollEdgeEffectStyle(.soft, for: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sujets")
    }

    private func staleNoticeLabel(_ notice: String) -> some View {
        Label(notice, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// Vue « Tout » : un `ForEach` par sujet plutôt qu'une liste aplatie. La
    /// même URL peut remonter sous deux sujets (le service ne déduplique que
    /// DANS un sujet) : aplaties, deux lignes partageraient un `id`.
    private func overview(_ content: DiscoverContent, columns: Int) -> some View {
        LazyVStack(alignment: .leading, spacing: 32) {
            ForEach(DiscoverViewModel.overviewSlots(content: content, pending: model.pendingTopics)) { slot in
                switch slot {
                case .ready(let section):
                    overviewSection(section, columns: columns)
                case .pending(let topicID):
                    if let topic = DiscoverTopic(rawValue: topicID) {
                        DiscoverPendingSection(title: title(for: topic), showsHeader: true, columns: columns)
                    }
                }
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
            languageNote(for: section.topic)
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
            VStack(alignment: .leading, spacing: 12) {
                languageNote(for: topic)
                articleGrid(section.articles, columns: columns)
            }
        } else if model.pendingTopics.contains(topic) {
            DiscoverPendingSection(title: title(for: topic), showsHeader: false, columns: columns)
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
        // Le tout premier rendu se fait à une colonne (`availableWidth` vaut 0, voir plus haut). En
        // passant à deux, la grille gardait des hauteurs de rangée périmées : le bouton « Afficher
        // les N autres articles » recouvrait le texte du 2e rang pendant 5 à 8 s, jusqu'à la première
        // mise à jour du modèle (filmé sur iPad Pro, vu aussi sur Mac, mission Q2). Une nouvelle
        // identité par nombre de colonnes force une vraie mesure.
        .id(columns)
    }

    /// Intitulé de section au style des labels de section de la DA
    /// (« ESSAIE » dans `TrivaHomeReferenceView`) : `.caption2` medium (11 pt
    /// par défaut, mais qui suit Dynamic Type), `tracking(1.5)`, majuscules,
    /// `.tertiary`. Trait `.isHeader` : le rotor « En-têtes » de VoiceOver
    /// saute directement d'un sujet à l'autre.
    private func sectionHeader(for topic: DiscoverTopic) -> some View {
        DiscoverSectionHeader(title: title(for: topic))
    }

    /// Dit que les articles d'un sujet ne sont pas dans la langue de l'appareil, faute de flux
    /// utilisable dans celle-ci (Sport en français, voir `DiscoverFeedCatalog`).
    @ViewBuilder
    private func languageNote(for topic: DiscoverTopic) -> some View {
        let language = DiscoverLanguage.device()
        if definition(for: topic)?.usesOtherLanguage(than: language) == true {
            Text(language == .french ? "Articles en anglais pour ce sujet." : "Articles en français pour ce sujet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: États

    /// « Réessayer » en `.glassProminent` : c'est la seule action de l'écran
    /// dans cet état, donc son action principale (DESIGN.md).
    private var failureView: some View {
        ContentUnavailableView {
            Label(
                model.isShowingOfflineState ? "Hors connexion" : "Actualité indisponible",
                systemImage: model.isShowingOfflineState ? "wifi.slash" : "wifi.exclamationmark"
            )
        } description: {
            Text(model.isShowingOfflineState
                ? "L'actualité a besoin d'Internet. Elle s'affichera au retour de la connexion."
                : "Aucune source n'a répondu. Vérifie ta connexion, puis réessaie.")
        } actions: {
            Button("Réessayer") {
                Task { await model.refresh() }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.isLoading)
        }
        .containerRelativeFrame([.horizontal, .vertical])
        .accessibilityIdentifier("discover.failure")
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "Aucun article",
            systemImage: "newspaper",
            description: Text("Reviens un peu plus tard.")
        )
        .containerRelativeFrame([.horizontal, .vertical])
        .accessibilityIdentifier("discover.empty")
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
            Text("Aucun article récent, ou la source ne répond pas pour le moment.")
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

    // MARK: Barre d'outils

    #if os(iOS)
    /// Mise à jour des articles restaurés au lancement, que rien d'autre ne
    /// signale : le contrôle de « tirer pour actualiser » n'apparaît pas sans geste.
    /// Jamais pendant un geste, pour ne pas montrer deux indicateurs à la fois.
    @ToolbarContentBuilder
    private var backgroundUpdateToolbarItem: some ToolbarContent {
        if model.isUpdatingRestoredContent {
            ToolbarItem(placement: .topBarTrailing) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Actualisation en cours")
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
    #endif

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

/// Intitulé de section au style des labels de section de la DA (voir
/// `sectionHeader(for:)`).
private struct DiscoverSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Place réservée à un sujet encore en route : son intitulé et le même nombre de
/// lignes que l'aperçu de « Tout », pour que le remplissage ne déplace pas les
/// sujets suivants. Pour VoiceOver, un seul élément qui dit ce qui se passe.
private struct DiscoverPendingSection: View {
    let title: String
    let showsHeader: Bool
    let columns: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                DiscoverSectionHeader(title: title)
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: DiscoverLayout.columnSpacing, alignment: .top),
                    count: columns
                ),
                alignment: .leading,
                spacing: DiscoverLayout.rowSpacing
            ) {
                ForEach(0..<DiscoverLayout.overviewArticleLimit(columnCount: columns), id: \.self) { _ in
                    DiscoverPlaceholderRow()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), chargement en cours")
        .accessibilityIdentifier("discover.pending")
    }
}

/// Ligne neutre aux mêmes polices qu'une vraie (`DiscoverArticleRow`). SANS vignette : la
/// plupart des flux n'en fournissent pas (Numerama, ESPN, The Conversation…), et une vignette
/// qui disparaît à l'arrivée des articles changerait la largeur du texte sous les yeux
/// (finding Q3 51). Rédaction système et couleur sémantique : ni animation ni dégradé
/// décoratif (DESIGN.md).
private struct DiscoverPlaceholderRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Éditeur · il y a 3 heures")
                    .font(.caption)
                Text(verbatim: "Un titre d'article sur deux lignes, comme la plupart de ceux du fil")
                    .font(.headline)
                Text(verbatim: "Un extrait court qui occupe la place habituelle sous le titre de l'article.")
                    .font(.subheadline)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .redacted(reason: .placeholder)
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
        .accessibilityIdentifier("discover.chip")
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

#Preview("Découvrir — premier chargement, un sujet prêt") {
    DiscoverView(
        model: DiscoverViewModel(loadContent: { onTopicFinished in
            onTopicFinished(.finance, DiscoverPreviewData.content.sections[1].articles)
            try await Task.sleep(for: .seconds(3600))
            return DiscoverPreviewData.content
        })
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
