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
    private let isStorageVolatile: Bool
    private let onOpenConversation: (@MainActor (UUID) -> Void)?

    @State private var query = ""
    @State private var phase: FavoritesPhase = .loading
    @State private var retryCount = 0
    @State private var excerptCache = AnswerExcerptCache()
    @State private var path = NavigationPath()
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
            // Titre en ligne, comme Bibliothèque et Découvrir (finding Q3 n°30).
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
        // Referme le détail : seul celui du favori retiré peut être ouvert (la pile le cache sinon).
        path = NavigationPath()
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var isShowingRemovalError: Binding<Bool> {
        Binding(get: { removalErrorMessage != nil }, set: { if !$0 { removalErrorMessage = nil } })
    }
}
