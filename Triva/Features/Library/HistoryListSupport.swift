//
//  HistoryListSupport.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import Foundation
import SwiftUI

// MARK: - Mémoïsation des aperçus (partagée avec FavoritesView)

/// Aperçus déjà calculés, par identifiant et par « version ».
///
/// Pourquoi : une liste est reconstruite à chaque changement de `revision` de
/// son store — donc à chaque message ajouté par le chat quand la Bibliothèque
/// est visible en même temps (iPad, Mac) — et à chaque recherche. Sans cache,
/// chaque reconstruction recalculerait les 500 aperçus et, surtout,
/// rechargerait les messages de chaque conversation (une requête SQLite par
/// conversation dont la relation n'est pas déjà en mémoire).
///
/// La version d'une conversation est son `updatedAt` : `ChatHistoryStore` la
/// met à jour à CHAQUE écriture qui touche un message (ajout, `updateText`),
/// donc une version inchangée garantit une dernière réponse inchangée. Celle
/// d'un favori, copie figée par construction, est son `savedAt`.
///
/// Isolation par défaut (`@MainActor`) : seules les vues s'en servent. Pas
/// `@Observable` : remplir le cache ne doit jamais redessiner une vue.
final class AnswerExcerptCache {
    private struct Entry {
        let version: Date
        let excerpt: String?
    }

    private var entries: [UUID: Entry] = [:]

    func excerpt(for id: UUID, version: Date, compute: () -> String?) -> String? {
        if let entry = entries[id], entry.version == version {
            return entry.excerpt
        }
        let excerpt = compute()
        entries[id] = Entry(version: version, excerpt: excerpt)
        return excerpt
    }

    /// Oublie les identifiants disparus. À n'appeler qu'avec une liste
    /// COMPLÈTE : sur un résultat de recherche, cela viderait le cache de tout
    /// ce qui ne correspond pas à la requête.
    func retainOnly(_ ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}

// MARK: - Mise en page commune (partagée avec FavoritesView)

/// Marges des lignes de liste : 20 de chaque côté (padding horizontal de
/// DESIGN.md) et 12 verticalement, valeurs de la grille.
enum HistoryListLayout {
    static let rowInsets = EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
}

/// Bandeau en tête de liste quand la base locale est inutilisable et que l'app
/// s'est rabattue sur un conteneur en mémoire
/// (`TrivaModelContainer.isUsingVolatileFallback`). C'est une exigence écrite
/// sur ce conteneur : « ton historique est vide » et « ton historique ne peut
/// pas être enregistré » ne veulent pas dire la même chose.
///
/// Texte statique : ni verre ni carte (DESIGN.md), une ligne de liste sobre.
struct StorageVolatilityNotice: View {
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .listRowInsets(HistoryListLayout.rowInsets)
        .listRowSeparator(.hidden)
    }
}

/// Label de section de DESIGN.md (« ESSAIE ») : sections de la Bibliothèque,
/// « Sources » du détail d'un favori. En `.caption2` (11 pt à la taille par
/// défaut) plutôt qu'en taille fixe : il suit le Dynamic Type, comme le
/// libellé de `CitationSourceCard`.
struct HistorySectionHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(.caption2.weight(.medium))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .accessibilityAddTraits(.isHeader)
    }
}
