//
//  SearchDropTarget.swift
//  Triva
//
//  Chantier 2.2 (M5) : la fenêtre de recherche reçoit les glisser-déposer (Finder, Fichiers, Safari, Notes).
//  Un seul `dropDestination` pour toute la fenêtre ; étiquette en verre pendant le survol.
//

import SwiftUI

extension View {
    func acceptsSearchDrops(on coordinator: TrivaRootCoordinator) -> some View {
        modifier(SearchDropTarget(coordinator: coordinator))
    }
}

nonisolated enum SearchDropPresentation {
    /// Texte du survol (à valider par Ben).
    static let hint = "Dépose pour ajouter à ta question"

    /// Phases où un élément survole la fenêtre.
    static func isTargeted(_ phase: DropSession.Phase) -> Bool {
        switch phase {
        case .entering, .active: true
        default: false
        }
    }
}

private struct SearchDropTarget: ViewModifier {
    let coordinator: TrivaRootCoordinator
    @State private var isTargeted = false
    /// Un dépôt peut rappeler l'action pour la même session : chaque dépôt n'est appliqué qu'une fois.
    @State private var lastHandledSession: DropSession.ID?

    func body(content: Content) -> some View {
        content
            .dropDestination(for: DroppedItem.self) { items, session in
                isTargeted = false
                guard lastHandledSession != session.id else { return }
                lastHandledSession = session.id
                coordinator.receiveDrop(items)
            }
            .onDropSessionUpdated { session in
                let targeted = SearchDropPresentation.isTargeted(session.phase)
                if targeted != isTargeted { isTargeted = targeted }
            }
            .overlay {
                if isTargeted {
                    highlight
                }
            }
    }

    /// Seule une étiquette en verre, au centre : ni teinte en transparence sur la fenêtre, ni bordure ajoutée
    /// (DESIGN.md bannit tout calque semi-transparent).
    private var highlight: some View {
        Text(SearchDropPresentation.hint)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
