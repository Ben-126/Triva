//
//  FavoritesView.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation
import SwiftUI

// MARK: - Valeurs affichées (logique pure)

/// Une ligne des Favoris : une COPIE en valeur, jamais un `StoredFavorite`.
/// Même parade que `LibraryConversationSummary` contre le piège documenté sur
/// `FavoritesStore` : une référence retirée reste lisible (`isDeleted` ne le
/// signale pas), une liste de valeurs n'affiche jamais de favori fantôme.
nonisolated struct FavoriteSummary: Identifiable, Hashable, Sendable {
    /// `StoredFavorite.id`, pas `messageID` : `unmark` admet qu'une autre
    /// version de l'app ait pu écrire deux favoris pour un même message, et
    /// deux lignes de même identité casseraient le `ForEach`.
    let id: UUID
    /// Clé du store pour retirer (`unmark(messageID:)`) et ouvrir le détail
    /// (`favorite(forMessageID:)`) : il n'existe aucune lecture par `id`.
    let messageID: UUID
    /// Prête pour une ligne (`FavoritePresentation.rowQuestion`), `nil` si
    /// aucune question n'a été retrouvée au marquage.
    let question: String?
    /// `AnswerExcerpt`, `nil` si la réponse n'a aucun texte affichable.
    let excerpt: String?
    /// Date du marquage : critère de tri du store, et date affichée.
    let savedAt: Date
}

/// Contenu complet d'un favori pour le détail, copié UNE fois du modèle :
/// aucune référence SwiftData ne vit dans l'état d'une vue.
nonisolated struct FavoriteDetailContent: Sendable, Equatable {
    let messageID: UUID
    /// Référence FAIBLE, jamais garantie valide (`StoredFavorite.conversationID`).
    let conversationID: UUID?
    /// Telle qu'enregistrée, éventuellement vide (repli à l'affichage).
    let question: String
    /// Markdown brut avec `<think>`, TL;DR et marqueurs `[n]`, tel que marqué.
    let answer: String
    /// Dans l'ORDRE DE CITATION : `sources[0]` est la source de `[1]`.
    let sources: [SearXNGSearchResult]
    let savedAt: Date
}

/// Conversions et textes fixes des Favoris. `nonisolated` : logique
/// déterministe, testable sans interface. Les fonctions qui lisent un modèle
/// sont synchrones, donc exécutées sur l'acteur de l'appelant — le main actor,
/// seul domaine où l'app touche ses modèles (`ChatHistoryModels.swift`).
nonisolated enum FavoritePresentation {
    /// Repli d'une question vide, cas prévu par `FavoritesStore` quand aucune
    /// question ne précède la réponse marquée.
    static let missingQuestionTitle = "Question non enregistrée"

    static let removalTitle = "Retirer ce favori ?"

    /// Vrai que la conversation d'origine existe encore ou non. Supprimée, le
    /// favori est la dernière trace de la réponse : d'où une confirmation que
    /// le web n'a pas.
    static let removalMessage =
        "La copie enregistrée sera effacée de cet appareil. La conversation d'origine n'est pas modifiée."

    /// Blancs normalisés, coupée sur un mot à la longueur d'un titre de la
    /// Bibliothèque : une question collée depuis un PDF ne doit ni s'étaler,
    /// ni être lue en entier par VoiceOver. `nil` sans caractère visible, testé
    /// avec le critère même de `ConversationTitleBuilder` : sinon des espaces
    /// insécables recevraient son repli, « Nouvelle conversation ».
    static func rowQuestion(from question: String) -> String? {
        guard question.contains(where: { !$0.isWhitespace }) else { return nil }
        return ConversationTitleBuilder.title(from: question)
    }

    /// Question complète du détail, rognée ; `nil` si elle est vide.
    static func detailQuestion(from question: String) -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Source au format de `CitationView` et `SourcesListView`. L'extrait
    /// redevient `content`, comme à l'aller (`StoredFavoriteSource(result:order:)`) ;
    /// les champs médias ne sont pas conservés par un favori.
    static func searchResult(title: String, url: String, snippet: String?) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: title, url: url, content: snippet,
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }

    /// Triées par `order` ICI plutôt que par l'appelant : `CitationParser`
    /// résout `[n]` par `sources[n - 1]` et un tableau de relation SwiftData
    /// n'a aucun ordre garanti. C'est l'invariant qui fait pointer chaque
    /// citation sur la bonne source.
    static func citationSources(from sources: [StoredFavoriteSource]) -> [SearXNGSearchResult] {
        sources
            .sorted { $0.order < $1.order }
            .map { searchResult(title: $0.title, url: $0.url, snippet: $0.snippet) }
    }

    static func detailContent(copying favorite: StoredFavorite) -> FavoriteDetailContent {
        FavoriteDetailContent(
            messageID: favorite.messageID,
            conversationID: favorite.conversationID,
            question: favorite.question,
            answer: favorite.answer,
            sources: citationSources(from: favorite.sources),
            savedAt: favorite.savedAt
        )
    }
}

// MARK: - État de l'écran

/// Résultat d'un chargement et instant de référence des dates relatives
/// (même rôle que `LibrarySnapshot`).
private struct FavoritesSnapshot: Equatable {
    let favorites: [FavoriteSummary]
    let referenceDate: Date

    var isEmpty: Bool { favorites.isEmpty }

    /// Sans AUCUNE ligne de ce message : `unmark` retire tous ses doublons.
    func removing(messageID: UUID) -> FavoritesSnapshot {
        FavoritesSnapshot(favorites: favorites.filter { $0.messageID != messageID }, referenceDate: referenceDate)
    }
}

private enum FavoritesPhase: Equatable {
    case loading
    case loaded(FavoritesSnapshot)
    case failed(message: String)
}

/// Ce qui relance un chargement : requête, écriture réussie, « Réessayer ».
private struct FavoritesLoadKey: Equatable {
    let query: String
    let revision: Int
    let retry: Int
}

/// Type dédié plutôt qu'un `UUID` nu : une destination `for: UUID.self`
/// ajoutée un jour à la même pile ne pourrait pas l'intercepter.
private struct FavoriteRoute: Hashable {
    let messageID: UUID
}

// MARK: - Écran

/// Favoris : les réponses marquées d'une étoile (1.10).
///
/// Portage de `src/app/favorites/page.tsx` (web) : question, extrait, date,
/// retrait. Construit comme `LibraryView` (chargement, états, cache
/// d'extraits, copies en valeur) : qui connaît l'une connaît l'autre. Écarts
/// assumés avec le web : recherche (question, réponse, titre des sources) ;
/// toucher une ligne ouvre la réponse COMPLÈTE, citations et sources comprises,
/// quand le web n'en montre que l'aperçu tronqué ; retrait confirmé ; ni
/// compteur « (12) » ni pastilles de sources sur la ligne (DESIGN.md : rien
/// qui ne sert à rien) ; date relative sur la ligne, longue dans le détail.
///
/// ## Intégration (étape suivante)
/// - Passer les INSTANCES UNIQUES de `FavoritesStore` et `ChatHistoryStore` :
///   `revision` est propre à chaque instance (voir `LibraryView`), et l'étoile
///   du chat doit écrire dans celle que lit cet écran.
/// - `onOpenConversation` reçoit l'`id` de la conversation d'origine, comme
///   celui de la Bibliothèque. Le détail ne le propose que si elle existe
///   encore (`StoredFavorite.conversationID`), mais l'appelant doit supporter
///   un `nil` de `conversation(with:)` (suppression depuis une autre fenêtre).
struct FavoritesView: View {
    @State private var store: FavoritesStore
    @State private var historyStore: ChatHistoryStore
    private let isStorageVolatile: Bool
    private let onOpenConversation: (@MainActor (UUID) -> Void)?

    @State private var query = ""
    @State private var phase: FavoritesPhase = .loading
    @State private var retryCount = 0
    @State private var excerptCache = AnswerExcerptCache()
    @State private var path: [FavoriteRoute] = []
    @State private var pendingRemoval: FavoriteSummary?
    @State private var removalErrorMessage: String?

    /// Même délai, même raison que la Bibliothèque : `favorites(matching:)`
    /// normalise toutes les réponses sur le main actor.
    private static let searchDebounce: Duration = .milliseconds(250)

    /// Défauts pour que `TrivaRootView` compile avant l'intégration
    /// (`FavoritesView()`), avec les réserves de ceux de `LibraryView` :
    /// instances distinctes de celles du chat, base sur disque. Un aperçu
    /// passe toujours des stores en mémoire.
    init(
        store: FavoritesStore = FavoritesStore(container: TrivaModelContainer.shared),
        historyStore: ChatHistoryStore = ChatHistoryStore(container: TrivaModelContainer.shared),
        isStorageVolatile: Bool = TrivaModelContainer.isUsingVolatileFallback,
        onOpenConversation: (@MainActor (UUID) -> Void)? = nil
    ) {
        _store = State(initialValue: store)
        _historyStore = State(initialValue: historyStore)
        self.isStorageVolatile = isStorageVolatile
        self.onOpenConversation = onOpenConversation
    }

    var body: some View {
        NavigationStack(path: $path) {
            FavoritesContentView(
                phase: phase, query: query, isStorageVolatile: isStorageVolatile,
                onRequestRemoval: { pendingRemoval = $0 }, onRetry: { retryCount += 1 }
            )
            .navigationTitle("Favoris")
            .searchable(text: $query, prompt: Text("Rechercher dans les favoris"))
            .task(id: FavoritesLoadKey(query: query, revision: store.revision, retry: retryCount)) {
                await reload()
            }
            .navigationDestination(for: FavoriteRoute.self) { route in
                FavoriteDetailScreen(
                    messageID: route.messageID, store: store, historyStore: historyStore,
                    onOpenConversation: onOpenConversation, onRemove: { removeFavorite(messageID: $0) }
                )
            }
            .confirmationDialog(
                FavoritePresentation.removalTitle, isPresented: isConfirmingRemoval,
                titleVisibility: .visible, presenting: pendingRemoval
            ) { favorite in
                Button("Retirer", role: .destructive) { removeFavorite(messageID: favorite.messageID) }
                // Explicite : celui du système sortirait en anglais (aucune
                // localisation fr dans le projet).
                Button("Annuler", role: .cancel) {}
            } message: { _ in
                Text(FavoritePresentation.removalMessage)
            }
        }
        // Sur la pile entière, pas sur la liste : un retrait demandé depuis le
        // détail doit pouvoir afficher son échec quand la liste est recouverte.
        .alert(removalErrorMessage ?? "", isPresented: isShowingRemovalError) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Chargement

    /// Même déroulé que `LibraryView.reload()` : délai de frappe annulable,
    /// puis lecture synchrone (aucune suspension entre la lecture du store et
    /// l'affectation de `phase`). Message d'échec : le `userFacingMessage` du
    /// store, texte fixe — jamais `diagnosticDescription`.
    private func reload() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            do {
                try await Task.sleep(for: Self.searchDebounce)
            } catch {
                // Annulée par `.task(id:)` : une frappe plus récente a pris le
                // relais, ne surtout pas lire pour une requête périmée.
                return
            }
        }

        let now = Date.now
        do {
            let summaries = try store.favorites(matching: trimmedQuery).map(summary(of:))
            // Liste COMPLÈTE seulement : un résultat de recherche viderait le
            // cache de tout ce qui ne correspond pas à la requête.
            if trimmedQuery.isEmpty {
                excerptCache.retainOnly(Set(summaries.map(\.id)))
            }
            phase = .loaded(FavoritesSnapshot(favorites: summaries, referenceDate: now))
        } catch {
            phase = .failed(message: (error as? FavoritesStoreError)?.userFacingMessage ?? "Impossible de lire les favoris.")
        }
    }

    /// Version d'un extrait : `savedAt`. Un favori est une copie figée, son
    /// texte ne change jamais pour un même `id` (voir `AnswerExcerptCache`).
    private func summary(of favorite: StoredFavorite) -> FavoriteSummary {
        let excerpt = excerptCache.excerpt(for: favorite.id, version: favorite.savedAt) {
            AnswerExcerpt.make(from: favorite.answer)
        }
        return FavoriteSummary(
            id: favorite.id,
            messageID: favorite.messageID,
            question: FavoritePresentation.rowQuestion(from: favorite.question),
            excerpt: excerpt,
            savedAt: favorite.savedAt
        )
    }

    // MARK: Retrait

    /// Par `messageID`, jamais par référence de modèle : `unmark` relit lui-même
    /// ce qu'il retire. `false` (déjà retiré ailleurs entre-temps) n'est pas
    /// une erreur, le résultat voulu est atteint.
    private func removeFavorite(messageID: UUID) {
        do {
            try store.unmark(messageID: messageID)
        } catch {
            removalErrorMessage = (error as? FavoritesStoreError)?.userFacingMessage
                ?? "Impossible de modifier les favoris."
            return
        }
        // Retrait immédiat, sans attendre le rechargement déclenché par
        // `revision` : la ligne balayée ne doit pas réapparaître un instant.
        if case .loaded(let snapshot) = phase {
            withAnimation { phase = .loaded(snapshot.removing(messageID: messageID)) }
        }
        // Referme le détail s'il était ouvert sur ce favori.
        path.removeAll { $0.messageID == messageID }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var isShowingRemovalError: Binding<Bool> {
        Binding(get: { removalErrorMessage != nil }, set: { if !$0 { removalErrorMessage = nil } })
    }
}

// MARK: - Liste (présentation pure)

/// La liste et ses états, sans accès aux données (les aperçus l'alimentent
/// avec 0, 1 et 500 lignes, une erreur, un stockage volatil). Même structure
/// que `LibraryContentView` : `List` paresseuse qui porte le balayage, aucun
/// verre sur les lignes (texte statique, et 500 calques coûteraient cher),
/// états en `overlay` pour garder le titre et la recherche en place.
private struct FavoritesContentView: View {
    let phase: FavoritesPhase
    let query: String
    let isStorageVolatile: Bool
    let onRequestRemoval: @MainActor (FavoriteSummary) -> Void
    let onRetry: @MainActor () -> Void

    private static let volatileNotice =
        "Les favoris ne peuvent pas être enregistrés sur cet appareil. Ils seront perdus à la fermeture de Triva."

    var body: some View {
        List {
            if let snapshot {
                if isStorageVolatile, !snapshot.isEmpty {
                    StorageVolatilityNotice(text: Self.volatileNotice)
                }
                ForEach(snapshot.favorites) { favorite in
                    row(for: favorite, referenceDate: snapshot.referenceDate)
                }
            }
        }
        .listStyle(.plain)
        .overlay { overlay }
    }

    private var snapshot: FavoritesSnapshot? {
        if case .loaded(let snapshot) = phase { snapshot } else { nil }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `NavigationLink` et non un `Button` à closure comme dans la
    /// Bibliothèque : le détail vit dans cette pile, et le chevron annonce sur
    /// iOS qu'un écran va s'ouvrir. Balayage ET menu contextuel sur les deux
    /// plateformes, pour les raisons données sur `LibraryContentView`.
    private func row(for favorite: FavoriteSummary, referenceDate: Date) -> some View {
        NavigationLink(value: FavoriteRoute(messageID: favorite.messageID)) {
            FavoriteRowLabel(favorite: favorite, referenceDate: referenceDate)
        }
        .accessibilityHint("Ouvre la réponse complète")
        .listRowInsets(HistoryListLayout.rowInsets)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            removeButton(for: favorite, title: "Retirer")
        }
        .contextMenu {
            removeButton(for: favorite, title: "Retirer des favoris")
        }
    }

    /// Rôle destructif : rouge système et annonce VoiceOver adaptée, sans
    /// couleur en dur. Libellé court au balayage, explicite dans le menu.
    private func removeButton(for favorite: FavoriteSummary, title: String) -> some View {
        Button(role: .destructive) {
            onRequestRemoval(favorite)
        } label: {
            Label(title, systemImage: "star.slash")
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch phase {
        case .loading:
            // Lecture locale quasi instantanée : un indicateur ne ferait que
            // clignoter pendant une image.
            EmptyView()
        case .failed(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } actions: {
                // Seule action de l'écran dans cet état : action principale
                // (DESIGN.md), comme dans Découvrir.
                Button("Réessayer", action: onRetry)
                    .buttonStyle(.glassProminent)
            }
        case .loaded(let snapshot) where snapshot.isEmpty:
            if trimmedQuery.isEmpty {
                ContentUnavailableView("Aucun favori", systemImage: "star", description: Text(verbatim: isStorageVolatile
                    ? Self.volatileNotice
                    : "Les réponses que tu marques d'une étoile apparaîtront ici."))
            } else {
                // Pas `ContentUnavailableView.search` : son texte vient du
                // système et sortirait en anglais.
                ContentUnavailableView("Aucun résultat", systemImage: "magnifyingglass", description: Text(
                    verbatim: "Aucun favori ne correspond à «\u{00A0}\(trimmedQuery)\u{00A0}»."
                ))
            }
        case .loaded:
            EmptyView()
        }
    }
}

/// Question, extrait, date, empilés comme une ligne de la Bibliothèque.
/// Extrait sur trois lignes et non deux : c'est le contenu même du favori (le
/// web en montre aussi trois, `line-clamp-3`). Sans texte affichable, il est
/// omis : question et date suffisent à reconnaître la ligne.
private struct FavoriteRowLabel: View {
    let favorite: FavoriteSummary
    let referenceDate: Date

    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Repli en `.tertiary`, comme « Aucune réponse enregistrée » dans
            // la Bibliothèque : un libellé de remplacement, pas un contenu.
            Text(verbatim: favorite.question ?? FavoritePresentation.missingQuestionTitle)
                .font(.headline)
                .foregroundStyle(favorite.question == nil ? HierarchicalShapeStyle.tertiary : .primary)
                .lineLimit(2)
            if let excerpt = favorite.excerpt {
                Text(verbatim: excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text(verbatim: RelativeDateLabel.text(for: favorite.savedAt, relativeTo: referenceDate, calendar: calendar))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Détail

private enum FavoriteDetailPhase: Equatable {
    case loading
    case loaded(FavoriteDetailContent, canOpenConversation: Bool)
    case missing
    case failed(message: String)
}

/// Relecture à chaque écriture de L'UN OU L'AUTRE store : le favori peut être
/// retiré par l'étoile du chat, sa conversation supprimée depuis la
/// Bibliothèque (dans une autre fenêtre, sur Mac).
private struct FavoriteDetailLoadKey: Equatable {
    let revision: Int
    let historyRevision: Int
    let retry: Int
}

/// La réponse complète d'un favori, relue par son `messageID` puis copiée en
/// valeur (`FavoriteDetailContent`).
private struct FavoriteDetailScreen: View {
    let messageID: UUID
    let store: FavoritesStore
    let historyStore: ChatHistoryStore
    let onOpenConversation: (@MainActor (UUID) -> Void)?
    let onRemove: @MainActor (UUID) -> Void

    @State private var phase: FavoriteDetailPhase = .loading
    @State private var retryCount = 0
    @State private var isConfirmingRemoval = false

    var body: some View {
        content
            .navigationTitle("Favori")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let loaded = loadedContent {
                    ToolbarItem(placement: .primaryAction) {
                        removeButton(messageID: loaded.messageID)
                    }
                }
            }
            .task(id: FavoriteDetailLoadKey(revision: store.revision, historyRevision: historyStore.revision, retry: retryCount)) {
                load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            // `Color.clear` et non `EmptyView` : une vue vide n'apparaît
            // jamais, et la `.task` qui charge le favori ne partirait pas.
            Color.clear
        case .loaded(let detail, let canOpenConversation):
            FavoriteDetailContentView(
                content: detail,
                onOpenConversation: canOpenConversation ? openConversationAction(for: detail) : nil
            )
        case .missing:
            ContentUnavailableView("Favori introuvable", systemImage: "star.slash", description: Text("Il a été retiré des favoris."))
        case .failed(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Réessayer") { retryCount += 1 }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private var loadedContent: FavoriteDetailContent? {
        if case .loaded(let detail, _) = phase { detail } else { nil }
    }

    /// Synchrone : aucune suspension entre la lecture et l'affectation.
    private func load() {
        do {
            guard let favorite = try store.favorite(forMessageID: messageID) else {
                // Retiré pendant l'affichage : on garde la copie. Retiré d'ici,
                // la pile se referme déjà, et un état vide apparaîtrait en
                // pleine animation ; retiré d'ailleurs, la copie reste lisible
                // jusqu'au retour (une valeur, rien de fantôme).
                if case .loaded = phase { return }
                phase = .missing
                return
            }
            let detail = FavoritePresentation.detailContent(copying: favorite)
            phase = .loaded(detail, canOpenConversation: conversationStillExists(detail.conversationID))
        } catch {
            phase = .failed(message: (error as? FavoritesStoreError)?.userFacingMessage ?? "Impossible de lire les favoris.")
        }
    }

    /// Action proposée seulement si la conversation existe ENCORE
    /// (`StoredFavorite.conversationID`). Un échec de lecture de l'historique
    /// la masque sans message, délibérément : le favori reste entièrement
    /// lisible, un bouton voué à l'échec serait pire que son absence, et
    /// l'erreur s'affiche dans la Bibliothèque, qui lit le même historique.
    private func conversationStillExists(_ conversationID: UUID?) -> Bool {
        guard onOpenConversation != nil, let conversationID else { return false }
        do {
            return try historyStore.conversation(with: conversationID) != nil
        } catch {
            return false
        }
    }

    private func openConversationAction(for detail: FavoriteDetailContent) -> (@MainActor () -> Void)? {
        guard let onOpenConversation, let conversationID = detail.conversationID else { return nil }
        return { onOpenConversation(conversationID) }
    }

    /// `.primaryAction` et non `.topBarTrailing` (propre à iOS). Confirmation
    /// attachée au bouton : sur iPad et Mac, elle s'ouvre depuis lui.
    private func removeButton(messageID: UUID) -> some View {
        Button("Retirer des favoris", systemImage: "star.slash") {
            isConfirmingRemoval = true
        }
        .confirmationDialog(FavoritePresentation.removalTitle, isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Retirer", role: .destructive) { onRemove(messageID) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(FavoritePresentation.removalMessage)
        }
    }
}

/// Mise en page du détail, sans accès aux données.
///
/// Composition prévue pour la bulle de chat (doc de `CitationView`) : texte
/// segmenté UNE fois par rendu ; raisonnement à `ThinkBoxView` (rien en phase
/// `.absent`) ; TL;DR, qu'aucune des deux vues ne rend, au-dessus du corps ;
/// corps par `CitationView`, pour que chaque `[n]` reste touchable. Ni verre
/// ni carte : du texte statique (DESIGN.md). Cinq tailles au plus : `.title3`,
/// corps et `.headline` (même taille), `.footnote`, `.caption`, `.caption2`.
private struct FavoriteDetailContentView: View {
    let content: FavoriteDetailContent
    let onOpenConversation: (@MainActor () -> Void)?

    @Environment(\.calendar) private var calendar

    var body: some View {
        let segments = ReasoningSegmenter.segment(content.answer, isStreaming: false)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    ThinkBoxView(segments: segments)
                    if let tldr = segments.tldr {
                        CitationView(text: tldr, sources: content.sources, isStreaming: false)
                            .font(.headline)
                    }
                    CitationView(text: segments.body, sources: content.sources, isStreaming: false)
                }
                if !content.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HistorySectionHeader(title: "Sources")
                        SourcesListView(sources: content.sources)
                    }
                }
                // Seul élément de verre de l'écran, donc sans conteneur ;
                // `.glass` : action secondaire, la lecture reste l'essentiel.
                if let onOpenConversation {
                    Button("Ouvrir la conversation", systemImage: "bubble.left.and.bubble.right", action: onOpenConversation)
                        .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Question complète et date du marquage, lues comme un seul titre. Repli
    /// en `.tertiary`, comme sur la ligne.
    private var header: some View {
        let question = FavoritePresentation.detailQuestion(from: content.question)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: question ?? FavoritePresentation.missingQuestionTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(question == nil ? HierarchicalShapeStyle.tertiary : .primary)
            Text(verbatim: "Enregistrée le \(RelativeDateLabel.longDate(content.savedAt, calendar: calendar))")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Aperçus

/// Données factices. Seuls les aperçus qui passent par un store utilisent les
/// stores en mémoire ; les autres alimentent les vues de présentation.
private enum FavoritesPreviewData {
    static let referenceDate = Date.now

    private static let questions = [
        "Comment fonctionne la photosynthèse ?",
        "",
        "Quelle est la différence entre une marée de vives-eaux et une marée de mortes-eaux, et pourquoi la Lune compte-t-elle plus que le Soleil ?",
        "Recette de la pâte à crêpes",
    ]

    private static let excerpts: [String?] = [
        "La photosynthèse convertit l'énergie lumineuse en énergie chimique, dans les chloroplastes des cellules végétales.",
        "330 mètres avec ses antennes.",
        "Aux vives-eaux, le Soleil et la Lune sont alignés et leurs attractions s'additionnent. Aux mortes-eaux, elles se contrarient.",
        nil,
    ]

    /// Un favori toutes les 30 heures en remontant le temps.
    static func snapshot(count: Int) -> FavoritesSnapshot {
        let favorites = (0..<count).map { index in
            FavoriteSummary(
                id: UUID(), messageID: UUID(),
                question: FavoritePresentation.rowQuestion(from: questions[index % questions.count]),
                excerpt: excerpts[index % excerpts.count],
                savedAt: referenceDate.addingTimeInterval(-Double(index) * 30 * 3_600)
            )
        }
        return FavoritesSnapshot(favorites: favorites, referenceDate: referenceDate)
    }

    static let sources = [
        FavoritePresentation.searchResult(title: "Photosynthèse — Wikipédia", url: "https://fr.wikipedia.org/wiki/Photosynth%C3%A8se", snippet: nil),
        FavoritePresentation.searchResult(title: "Chloroplast — Britannica", url: "https://www.britannica.com/science/chloroplast", snippet: nil),
    ]

    /// Raisonnement, TL;DR, Markdown et citations : tout ce que le détail rend.
    static let detail = FavoriteDetailContent(
        messageID: UUID(), conversationID: UUID(),
        question: "Comment fonctionne la photosynthèse ?",
        answer: "<think>Expliquer la phase lumineuse, puis le cycle de Calvin.</think>"
            + "<tldr>La plante transforme la lumière en sucres[1].</tldr>"
            + "La **photosynthèse** convertit l'énergie lumineuse en énergie chimique[1]. "
            + "Elle a lieu dans les chloroplastes[2], en deux étapes : la phase lumineuse, puis le cycle de Calvin.",
        sources: sources, savedAt: referenceDate.addingTimeInterval(-3 * 86_400)
    )

    /// Sans question (repli), sans source ni raisonnement.
    static let bareDetail = FavoriteDetailContent(
        messageID: UUID(), conversationID: nil, question: "",
        answer: "Réponse enregistrée sans source ni raisonnement.", sources: [], savedAt: referenceDate
    )

    /// Les deux stores sur le MÊME conteneur en mémoire, comme dans l'app : un
    /// favori relié à une vraie conversation (le détail propose alors « Ouvrir
    /// la conversation »), un autre sans conversation.
    static func seededStores() -> (favorites: FavoritesStore, history: ChatHistoryStore) {
        do {
            let container = try TrivaModelContainer.makeInMemory()
            let history = ChatHistoryStore(container: container)
            let favorites = FavoritesStore(container: container)
            let date = referenceDate.addingTimeInterval(-2 * 3_600)
            let conversation = try history.createConversation(firstQuestion: detail.question, now: date)
            try history.appendUserMessage(to: conversation, text: detail.question, now: date)
            let answer = try history.appendAssistantMessage(to: conversation, text: detail.answer, sources: sources, now: date)
            try favorites.mark(answer, now: date)
            let earlier = referenceDate.addingTimeInterval(-50 * 3_600)
            try favorites.mark(messageID: UUID(), conversationID: nil, question: questions[2], answer: excerpts[2] ?? "", now: earlier)
            return (favorites, history)
        } catch {
            // Comme `LibraryPreviewData` : en mémoire, seul un schéma invalide
            // (bug de développement) peut échouer.
            preconditionFailure("Aperçu des Favoris impossible : \(error)")
        }
    }
}

private struct FavoritesContentPreview: View {
    let phase: FavoritesPhase
    var query = ""
    var isStorageVolatile = false

    var body: some View {
        NavigationStack {
            FavoritesContentView(
                phase: phase, query: query, isStorageVolatile: isStorageVolatile,
                onRequestRemoval: { _ in }, onRetry: {}
            )
            .navigationTitle("Favoris")
        }
    }
}

#Preview("Écran complet — stores en mémoire") {
    let stores = FavoritesPreviewData.seededStores()
    FavoritesView(store: stores.favorites, historyStore: stores.history, isStorageVolatile: false, onOpenConversation: { _ in })
}

#Preview("500 favoris") {
    FavoritesContentPreview(phase: .loaded(FavoritesPreviewData.snapshot(count: 500)))
}

#Preview("Un favori") {
    FavoritesContentPreview(phase: .loaded(FavoritesPreviewData.snapshot(count: 1)))
}

#Preview("Vide") {
    FavoritesContentPreview(phase: .loaded(FavoritesPreviewData.snapshot(count: 0)))
}

#Preview("Aucun résultat") {
    FavoritesContentPreview(phase: .loaded(FavoritesPreviewData.snapshot(count: 0)), query: "fusion froide")
}

#Preview("Erreur de lecture") {
    FavoritesContentPreview(phase: .failed(message: "Impossible de lire les favoris."))
}

#Preview("Stockage volatil — sombre") {
    FavoritesContentPreview(phase: .loaded(FavoritesPreviewData.snapshot(count: 3)), isStorageVolatile: true)
        .preferredColorScheme(.dark)
}

#Preview("Très grand texte") {
    FavoritesContentPreview(phase: .loaded(FavoritesPreviewData.snapshot(count: 4)))
        .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Détail") {
    NavigationStack {
        FavoriteDetailContentView(content: FavoritesPreviewData.detail, onOpenConversation: {})
    }
}

#Preview("Détail — sans question ni source, sombre") {
    NavigationStack {
        FavoriteDetailContentView(content: FavoritesPreviewData.bareDetail, onOpenConversation: nil)
    }
    .preferredColorScheme(.dark)
}

#Preview("Détail — favori retiré") {
    let stores = FavoritesPreviewData.seededStores()
    NavigationStack {
        FavoriteDetailScreen(messageID: UUID(), store: stores.favorites, historyStore: stores.history, onOpenConversation: nil, onRemove: { _ in })
    }
}
