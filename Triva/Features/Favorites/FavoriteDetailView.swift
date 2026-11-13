//
//  FavoriteDetailView.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI

// Sorti tel quel de `FavoritesView.swift` (mission E1a), qui dépassait 800 lignes.


enum FavoriteDetailPhase: Equatable {
    case loading
    case loaded(FavoriteDetailContent, canOpenConversation: Bool)
    case missing
    case failed(message: String)
}

/// Relecture à chaque écriture de L'UN OU L'AUTRE store : le favori peut être
/// retiré par l'étoile du chat, sa conversation supprimée depuis la
/// Bibliothèque (dans une autre fenêtre, sur Mac).
struct FavoriteDetailLoadKey: Equatable {
    let revision: Int
    let historyRevision: Int
    let retry: Int
}

/// La réponse complète d'un favori, relue par son `messageID` puis copiée en
/// valeur (`FavoriteDetailContent`).
struct FavoriteDetailScreen: View {
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
        .accessibilityIdentifier("favorites.detail.remove")
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
struct FavoriteDetailContentView: View {
    let content: FavoriteDetailContent
    let onOpenConversation: (@MainActor () -> Void)?

    @Environment(\.calendar) private var calendar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Colonne de lecture de 640 pt hors `compact`, comme la réponse dans la Recherche
    /// (`ChatView.contentMaxWidth`) : sans elle, le texte s'étirait sur toute la largeur d'un iPad ou
    /// d'un Mac, collé à gauche (finding Q3 n°47).
    private var readingColumnMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    var body: some View {
        let segments = ReasoningSegmenter.segment(content.answer, isStreaming: false)
        let answer = FavoritePresentation.answerSnapshot(of: content)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    ThinkBoxView(segments: segments)
                    if let tldr = segments.tldr {
                        CitationView(
                            text: tldr, sources: content.sources, isStreaming: false,
                            unreadSourceNumbers: content.uncitableSourceNumbers
                        )
                        .font(.headline)
                    }
                    CitationView(
                        text: segments.body, sources: content.sources, isStreaming: false,
                        unreadSourceNumbers: content.uncitableSourceNumbers
                    )
                    // Mêmes mentions, même composant que sous la réponse du chat (mission E2b).
                    AnswerNoteLine(answer: answer)
                }
                if !content.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HistorySectionHeader(title: "Sources")
                        SourcesListView(sources: content.sources, unreadNumbers: content.uncitableSourceNumbers)
                        OffTopicSourcesNote(answer: answer)
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
            .frame(maxWidth: readingColumnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
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
