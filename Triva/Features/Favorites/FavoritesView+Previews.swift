//
//  FavoritesView+Previews.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI

// Sorti tel quel de `FavoritesView.swift` (mission E1a), qui dépassait 800 lignes.


/// Données factices. Seuls les aperçus qui passent par un store utilisent les
/// stores en mémoire ; les autres alimentent les vues de présentation.
enum FavoritesPreviewData {
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

struct FavoritesContentPreview: View {
    let phase: FavoritesPhase
    var query = ""

    var body: some View {
        NavigationStack {
            FavoritesContentView(
                phase: phase, query: query,
                onRequestRemoval: { _ in }, onRetry: {}
            )
            .navigationTitle("Favoris")
        }
    }
}

#Preview("Écran complet — stores en mémoire") {
    let stores = FavoritesPreviewData.seededStores()
    FavoritesView(store: stores.favorites, historyStore: stores.history, onOpenConversation: { _ in })
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

#Preview("Base inaccessible — sombre") {
    FavoritesContentPreview(phase: .failed(
        message: TrivaStorage.unavailableTitle,
        detail: TrivaStorage.unavailableDetail
    ))
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
