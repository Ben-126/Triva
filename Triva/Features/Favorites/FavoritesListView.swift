//
//  FavoritesListView.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI

// Sorti tel quel de `FavoritesView.swift` (mission E1a), qui dépassait 800 lignes.


/// La liste et ses états, sans accès aux données (les aperçus l'alimentent
/// avec 0, 1 et 500 lignes, une erreur, une base inaccessible). Même structure
/// que `LibraryContentView` : `List` paresseuse qui porte le balayage, aucun
/// verre sur les lignes (texte statique, et 500 calques coûteraient cher),
/// états en `overlay` pour garder le titre et la recherche en place.
struct FavoritesContentView: View {
    let phase: FavoritesPhase
    let query: String
    let onRequestRemoval: @MainActor (FavoriteSummary) -> Void
    let onRetry: @MainActor () -> Void

    var body: some View {
        List {
            if let snapshot {
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
        .accessibilityIdentifier("favorites.row")
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
        case .failed(let message, let detail):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } description: {
                if let detail { Text(verbatim: detail) }
            } actions: {
                // Seule action de l'écran dans cet état : action principale
                // (DESIGN.md), comme dans Découvrir.
                Button("Réessayer", action: onRetry)
                    .buttonStyle(.glassProminent)
            }
        case .loaded(let snapshot) where snapshot.isEmpty:
            if trimmedQuery.isEmpty {
                ContentUnavailableView("Aucun favori", systemImage: "star", description: Text(
                    "Les réponses que tu marques d'une étoile apparaîtront ici."
                ))
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
/// Extrait sur trois lignes et non deux : c'est le contenu même du favori (la
/// version web d'origine en montre aussi trois, `line-clamp-3`). Sans texte affichable, il est
/// omis : question et date suffisent à reconnaître la ligne.
struct FavoriteRowLabel: View {
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
