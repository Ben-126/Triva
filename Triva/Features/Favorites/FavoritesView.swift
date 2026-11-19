//
//  FavoritesView.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation
import SwiftUI

// MARK: - État de l'écran

/// Résultat d'un chargement et instant de référence des dates relatives
/// (même rôle que `LibrarySnapshot`).
struct FavoritesSnapshot: Equatable {
    let favorites: [FavoriteSummary]
    let referenceDate: Date

    var isEmpty: Bool { favorites.isEmpty }

    /// Sans AUCUNE ligne de ce message : `unmark` retire tous ses doublons.
    func removing(messageID: UUID) -> FavoritesSnapshot {
        FavoritesSnapshot(favorites: favorites.filter { $0.messageID != messageID }, referenceDate: referenceDate)
    }
}

enum FavoritesPhase: Equatable {
    case loading
    case loaded(FavoritesSnapshot)
    /// `detail` : ligne sous le message (base inaccessible : dit que la recherche reste possible).
    case failed(message: String, detail: String? = nil)
}

/// Ce qui relance un chargement : requête, écriture réussie, « Réessayer ».
private struct FavoritesLoadKey: Equatable {
    let query: String
    let revision: Int
    let retry: Int
}

/// Type dédié plutôt qu'un `UUID` nu : une destination `for: UUID.self`
/// ajoutée un jour à la même pile ne pourrait pas l'intercepter.
struct FavoriteRoute: Hashable {
    let messageID: UUID
}

// MARK: - Écran

/// Favoris : les réponses marquées d'une étoile (1.10).
///
/// Portage de la page Favoris de la version web d'origine : question, extrait, date,
/// retrait. Construit comme `LibraryView` (chargement, états, cache
/// d'extraits, copies en valeur) : qui connaît l'une connaît l'autre. Écarts
/// assumés avec la version web d'origine : recherche (question, réponse, titre des sources) ;
/// toucher une ligne ouvre la réponse COMPLÈTE, citations et sources comprises,
/// quand la version web d'origine n'en montre que l'aperçu tronqué ; retrait confirmé ; ni
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
    private let onOpenConversation: (@MainActor (UUID) -> Void)?

    @State private var query = ""
    @State private var phase: FavoritesPhase = .loading
    @State private var retryCount = 0
    @State private var excerptCache = AnswerExcerptCache()
    /// Pile injectée (`TrivaRootCoordinator.favoritesPath`), `nil` : `localPath` (aperçus). Voir `SettingsView`.
    private let injectedPath: Binding<NavigationPath>?
    @State private var localPath = NavigationPath()
    /// Favori ouvert dans le volet de droite (Duo déplié), injecté (`TrivaRootCoordinator.favoritesSelection`)
    /// ou local pour les aperçus. Même sélection que la route poussée de `path`, vue de deux manières.
    private let injectedSelection: Binding<UUID?>?
    @State private var localSelection: UUID?
    @State private var pendingRemoval: FavoriteSummary?
    @State private var removalErrorMessage: String?

    /// Même délai, même raison que la Bibliothèque : `favorites(matching:)`
    /// normalise toutes les réponses sur le main actor.
    private static let searchDebounce: Duration = .milliseconds(250)

    /// Stores obligatoires, comme ceux de `LibraryView` : un défaut créerait des
    /// instances distinctes de celles du chat et ouvrirait la vraie base. Un
    /// aperçu passe toujours des stores en mémoire.
    init(
        store: FavoritesStore,
        historyStore: ChatHistoryStore,
        onOpenConversation: (@MainActor (UUID) -> Void)? = nil,
        navigationPath: Binding<NavigationPath>? = nil,
        selection: Binding<UUID?>? = nil
    ) {
        _store = State(initialValue: store)
        _historyStore = State(initialValue: historyStore)
        self.onOpenConversation = onOpenConversation
        injectedPath = navigationPath
        injectedSelection = selection
    }

    private var path: Binding<NavigationPath> { injectedPath ?? $localPath }
    private var openedFavorite: Binding<UUID?> { injectedSelection ?? $localSelection }

    var body: some View {
        // Duo déplié en paysage : liste | détail côte à côte (mission I2). Ailleurs, la pile d'avant.
        DuoPaneContainer { columnCount in
            if columnCount == 2 {
                twoPanes
            } else {
                singlePane
            }
        }
        // Sur la pile entière, pas sur la liste : un retrait demandé depuis le
        // détail doit pouvoir afficher son échec quand la liste est recouverte.
        .alert(removalErrorMessage ?? "", isPresented: isShowingRemovalError) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Présentations

    /// Une colonne : la liste, et le détail poussé sur la pile (iPhone, iPad, Mac, Duo plié ou en portrait).
    private var singlePane: some View {
        NavigationStack(path: path) {
            listScreen(selection: nil)
                .navigationDestination(for: FavoriteRoute.self) { route in
                    detailScreen(messageID: route.messageID)
                        // La route poussée est AUSSI la sélection du volet de droite : déplier garde le favori ouvert.
                        .onAppear { openedFavorite.wrappedValue = route.messageID }
                }
                // Retour à la liste : plus de favori ouvert.
                .onChange(of: path.wrappedValue.count) { _, count in
                    if count == 0 { openedFavorite.wrappedValue = nil }
                }
        }
    }

    /// Deux colonnes : la liste à gauche, le favori sélectionné à droite. UNE SEULE pile de navigation, posée
    /// AUTOUR des deux volets (HIG « Designing for iPhone Duo » : la navigation reste en dehors de
    /// l'`ArrangementView`, revue R1 C2) : titre « Favoris » et recherche viennent de cette pile ; le détail n'a
    /// pas de pile ni de titre à lui (`showsNavigationTitle: false`), son bouton « Retirer » monte dans la même
    /// barre. La sélection est recopiée dans `path` : replier l'appareil retrouve le favori ouvert, poussé sur
    /// la pile.
    private var twoPanes: some View {
        NavigationStack {
            listChrome(
                DuoTwoPanes {
                    FavoritesContentView(
                        phase: phase, query: query,
                        onRequestRemoval: { pendingRemoval = $0 },
                        onRetry: retry,
                        selection: selectionBinding
                    )
                } secondary: {
                    detailPane
                }
            )
        }
    }

    /// Volet de droite : le favori ouvert, ou une invite. Séparateur sur son bord gauche.
    @ViewBuilder
    private var detailPane: some View {
        Group {
            if let messageID = openedFavorite.wrappedValue {
                detailScreen(messageID: messageID, showsNavigationTitle: false)
                    .id(messageID)
            } else {
                Text("Choisis un favori dans la liste.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("favorites.detailPlaceholder")
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 1)
        }
    }

    /// Sélection du volet de droite, et route correspondante sur la pile (pour le repli).
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { openedFavorite.wrappedValue },
            set: { newValue in
                openedFavorite.wrappedValue = newValue
                path.wrappedValue = newValue.map { NavigationPath([FavoriteRoute(messageID: $0)]) } ?? NavigationPath()
            }
        )
    }

    private func detailScreen(messageID: UUID, showsNavigationTitle: Bool = true) -> some View {
        FavoriteDetailScreen(
            messageID: messageID, store: store, historyStore: historyStore,
            onOpenConversation: onOpenConversation, onRemove: { removeFavorite(messageID: $0) },
            showsNavigationTitle: showsNavigationTitle
        )
    }

    /// Retente d'abord l'ouverture de la base (sans effet quand elle est ouverte), puis relit la liste.
    private func retry() {
        store.retryOpeningStorage()
        retryCount += 1
    }

    /// La liste d'une colonne (pile d'avant).
    private func listScreen(selection: Binding<UUID?>?) -> some View {
        listChrome(
            FavoritesContentView(
                phase: phase, query: query,
                onRequestRemoval: { pendingRemoval = $0 },
                onRetry: retry,
                selection: selection
            )
        )
    }

    /// Titre, recherche, chargement et confirmation de retrait : identiques dans les deux présentations (posés sur
    /// la liste seule, ou autour des deux volets).
    private func listChrome<Content: View>(_ content: Content) -> some View {
        content
            .navigationTitle("Favoris")
            // Titre en ligne, comme Bibliothèque et Découvrir (finding Q3 n°30).
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: Text("Rechercher dans les favoris"))
            .task(id: FavoritesLoadKey(query: query, revision: store.revision, retry: retryCount)) {
                await reload()
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
        } catch FavoritesStoreError.storageUnavailable {
            phase = .failed(message: TrivaStorage.unavailableTitle, detail: TrivaStorage.unavailableDetail)
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
        // Referme le détail SEULEMENT si c'est celui du favori retiré : avec deux volets, la liste reste visible
        // et on peut retirer un autre favori que celui qui est ouvert (revue R1, C1).
        guard FavoriteDetailClosing.closesDetail(
            removing: messageID,
            opened: openedFavorite.wrappedValue,
            hasPushedRoute: !path.wrappedValue.isEmpty
        ) else { return }
        path.wrappedValue = NavigationPath()
        openedFavorite.wrappedValue = nil
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var isShowingRemovalError: Binding<Bool> {
        Binding(get: { removalErrorMessage != nil }, set: { if !$0 { removalErrorMessage = nil } })
    }
}
