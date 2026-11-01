//
//  FavoriteModels.swift
//  Triva
//
//  Created by ben podrojsky on 30/09/2026.
//

import Foundation
import SwiftData

// MARK: - Isolation
//
// Même stratégie, et pour les mêmes raisons, que les modèles de l'historique :
// `nonisolated` explicite sur des classes `@Model` qui ne sont PAS `Sendable`
// (conformance déclarée `unavailable` par la macro), toutes manipulées depuis
// le seul `mainContext` de l'app, donc depuis le `@MainActor`. Justification
// complète, expansion de macro comprise, en tête de `ChatHistoryModels.swift` —
// on ne la duplique pas ici pour ne pas avoir deux versions qui divergent.

// MARK: - Favori

/// Une réponse de l'assistant mise en favori (1.10).
///
/// Portage de `FavoriteEntry` (`src/lib/types.ts`, web) :
/// `{ id, query, answer, sources: { title, url }[], savedAt }`, que le web
/// stocke en JSON dans `localStorage` sous la clé `perplexica_favorites`
/// (`src/lib/hooks/useFavorites.ts`).
///
/// ## Copie, et non relation — décision structurante
/// Un favori est un **instantané autonome** : il recopie la question, la
/// réponse, ses sources et la date du marquage. Il ne porte AUCUNE relation
/// SwiftData vers `StoredMessage` ou `StoredConversation`, seulement deux UUID
/// « faibles » (`messageID`, `conversationID`). Quatre raisons :
///
/// 1. **Survivre à la suppression de la conversation d'origine.** C'est
///    l'exigence du plan, et la raison d'être d'un favori : on marque une
///    réponse pour la garder même après avoir fait le ménage dans
///    l'historique. Avec une relation, la cascade conversation → messages
///    → sources emporterait le contenu, et un favori `nullify`-é resterait une
///    coquille vide impossible à afficher.
/// 2. **Figer ce qui a été marqué.** `ChatHistoryStore.updateText(of:to:)`
///    peut réécrire une réponse plus tard (régénération). Un favori relié
///    changerait de contenu sous les yeux de l'utilisateur ; une copie garde
///    exactement la réponse qu'il a jugée digne d'être conservée.
/// 3. **Fidélité au web**, qui fait déjà une copie complète (`answer:
///    copyMessage`, sources recopiées dans l'entrée).
/// 4. **Ne pas toucher au schéma de l'historique.** Une relation exigerait un
///    côté inverse déclaré dans `ChatHistoryModels.swift`, et couplerait les
///    règles de suppression des deux fonctionnalités.
///
/// Ce qu'on accepte : la donnée est dupliquée (quelques Ko par favori, sans
/// importance à l'échelle locale), et **effacer l'historique n'efface PAS les
/// favoris** — c'est voulu, mais un futur « tout effacer » des Réglages devra
/// proposer les deux explicitement pour tenir la promesse « réellement
/// effaçable ».
///
/// `conversationID` sert seulement à proposer « ouvrir la conversation » :
/// `ChatHistoryStore.conversation(with:)` renvoie `nil` si elle a été
/// supprimée, et l'UI masque alors l'action. Aucune référence pendante
/// possible, puisqu'il n'y a pas de référence.
///
/// ## Identifiant de dédoublonnage
/// `messageID` est l'`id` du `StoredMessage` marqué — la clé stable qui
/// survit à un relancement de l'app, contrairement à l'identifiant éphémère
/// d'une bulle de `ChatViewModel`. C'est lui que le store utilise pour
/// « est-ce déjà en favori ? » et pour empêcher les doublons.
///
/// Pas de `@Attribute(.unique)` sur `messageID`, pour la même raison que sur
/// `StoredConversation.id` : une contrainte d'unicité SwiftData transforme
/// l'insertion en *upsert* silencieux, qui écraserait la date et le contenu
/// d'un favori existant. L'unicité est garantie par `FavoritesStore.mark`,
/// qui vérifie avant d'insérer — et c'est testé.
///
/// ## Écart assumé avec le web : pas de plafond à 100
/// Le web tronque la liste à `MAX_FAVORITES = 100` (`.slice(0, 100)`), ce qui
/// supprime **en silence** le plus ancien favori au 101e marquage. Cette limite
/// n'existe là-bas que pour ménager le quota de `localStorage` (~5 Mo). SQLite
/// n'a pas cette contrainte, et perdre sans prévenir une réponse que
/// l'utilisateur a explicitement demandé à garder est la pire issue possible
/// pour une fonctionnalité de conservation : on ne porte donc pas le plafond.
@Model
nonisolated final class StoredFavorite {
    /// Identifiant propre du favori (clé des listes SwiftUI).
    var id: UUID

    /// `id` du `StoredMessage` d'assistant marqué. Clé de dédoublonnage et de
    /// recherche rapide — voir « Identifiant de dédoublonnage ».
    var messageID: UUID

    /// `id` de la conversation d'origine au moment du marquage, ou `nil` si le
    /// message n'était rattaché à aucune. Référence faible, jamais garantie
    /// valide : toujours la résoudre via `ChatHistoryStore.conversation(with:)`.
    var conversationID: UUID?

    /// Question de l'utilisateur à laquelle la réponse répondait (`query` côté
    /// web). Peut être vide si aucune question n'a été retrouvée.
    var question: String

    /// Réponse de l'assistant, Markdown brut avec ses marqueurs `[n]` —
    /// recopiée telle quelle pour que `CitationParser` la résolve contre
    /// `orderedSources` exactement comme dans le chat.
    var answer: String

    /// Date du marquage (`savedAt` côté web). Critère de tri de la liste.
    var savedAt: Date

    /// Sources recopiées, **non ordonnées** (tableau de relation SwiftData) :
    /// toujours passer par `orderedSources`.
    ///
    /// `.cascade` : retirer un favori retire ses sources — aucune ne doit rester
    /// orpheline dans le fichier SQLite. L'inverse n'est déclaré QUE de ce côté :
    /// le déclarer aussi sur `StoredFavoriteSource.favorite` provoque l'erreur de
    /// compilation « circular reference resolving attached macro
    /// 'Relationship' » documentée dans `ChatHistoryModels.swift`.
    @Relationship(deleteRule: .cascade, inverse: \StoredFavoriteSource.favorite)
    var sources: [StoredFavoriteSource]

    init(
        id: UUID = UUID(),
        messageID: UUID,
        conversationID: UUID?,
        question: String,
        answer: String,
        savedAt: Date
    ) {
        self.id = id
        self.messageID = messageID
        self.conversationID = conversationID
        self.question = question
        self.answer = answer
        self.savedAt = savedAt
        self.sources = []
    }

    /// Sources dans l'ordre de citation : `order == 0` ↔ marqueur `[1]`, puisque
    /// `CitationParser` résout `[n]` par `sources[n - 1]`. Désordonner cette
    /// liste ferait pointer chaque citation sur la mauvaise source.
    var orderedSources: [StoredFavoriteSource] {
        sources.sorted { $0.order < $1.order }
    }
}

// MARK: - Source d'un favori

/// Copie d'une source citée par une réponse mise en favori.
///
/// Modèle dédié plutôt que réutilisation de `StoredSource` : celle-ci
/// appartient à un `StoredMessage` et disparaît en cascade avec la
/// conversation — exactement ce qu'un favori doit éviter. Et plutôt qu'un
/// tableau `Codable` stocké en attribut : c'est la forme déjà éprouvée (et
/// testée) par l'historique, qui garde `order` explicite et reste interrogeable.
///
/// Le web ne garde que `{ title, url }` ; on conserve aussi l'extrait, gratuit à
/// ce stade et utile à la recherche plein texte ou à un aperçu hors ligne.
@Model
nonisolated final class StoredFavoriteSource {
    var id: UUID

    var title: String

    /// `String` et non `URL`, comme `StoredSource.url` et
    /// `SearXNGSearchResult.url` : une adresse qu'`URL` refuserait ne doit pas
    /// faire perdre la source. Conversion au moment d'ouvrir le lien.
    var url: String

    var snippet: String?

    /// Rang de citation : `order == 0` correspond au marqueur `[1]`.
    var order: Int

    @Relationship(deleteRule: .nullify)
    var favorite: StoredFavorite?

    init(
        id: UUID = UUID(),
        title: String,
        url: String,
        snippet: String?,
        order: Int
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
        self.order = order
    }

    /// Copie d'une source de l'historique (marquage depuis un `StoredMessage`).
    convenience init(copying source: StoredSource, order: Int) {
        self.init(title: source.title, url: source.url, snippet: source.snippet, order: order)
    }

    /// Copie d'un résultat de recherche (marquage direct depuis le chat).
    convenience init(result: SearXNGSearchResult, order: Int) {
        self.init(title: result.title, url: result.url, snippet: result.content, order: order)
    }
}
