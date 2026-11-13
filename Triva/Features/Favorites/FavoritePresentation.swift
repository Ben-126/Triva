//
//  FavoritePresentation.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

// Sorti tel quel de `FavoritesView.swift` (mission E1a), qui dépassait 800 lignes.


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
    /// Les mentions de la bulle d'où vient le favori (missions E1a et E2b) : sources non lues
    /// (citation en texte simple, « non lue » dans la liste), « Réponse sans recherche » et ses
    /// pendants, « Sources probablement hors sujet ».
    var notes = StoredAnswerNotes()

    var uncitableSourceNumbers: Set<Int> { notes.uncitableSourceNumbers }
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
    /// la version web d'origine n'a pas.
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
            savedAt: favorite.savedAt,
            notes: favorite.answerNotes
        )
    }

    /// Le résumé que la bulle du chat lit pour poser ses mentions (`MessageBubblePresentation`),
    /// reconstruit pour le détail : mêmes règles d'affichage, donc mêmes mentions, aux mêmes
    /// conditions. Un favori est toujours une réponse terminée et non vide.
    ///
    /// `webSourceCount` : les premières sources d'un message peuvent être des fichiers joints (URL
    /// synthétique, sans lien) ; la bulle les retire pour juger « hors sujet » d'une recherche WEB,
    /// et le favori, qui recopie les sources dans l'ordre, les retire de la même façon.
    static func answerSnapshot(of content: FavoriteDetailContent) -> MessageBubblePresentation.AnswerSnapshot {
        let segments = ReasoningSegmenter.segment(content.answer, isStreaming: false)
        let attachmentCount = content.sources.prefix { UploadsSearchResultBuilder.attachmentID(fromSourceURL: $0.url) != nil }.count
        return MessageBubblePresentation.AnswerSnapshot(
            state: .completed,
            reasoningPhase: segments.reasoningPhase,
            hasTLDR: segments.tldr != nil,
            hasBody: !segments.body.isEmpty,
            sourceCount: content.sources.count,
            webSourceCount: max(0, content.sources.count - attachmentCount),
            answeredWithoutSearch: content.notes.answeredWithoutSearch,
            answeredOffline: content.notes.answeredOffline,
            answeredWithoutReadableSource: content.notes.answeredWithoutReadableSource,
            sourcesMayBeOffTopic: content.notes.sourcesMayBeOffTopic
        )
    }
}
