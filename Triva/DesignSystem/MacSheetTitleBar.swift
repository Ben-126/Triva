//
//  MacSheetTitleBar.swift
//  Triva
//
//  Created by ben podrojsky on 13/11/2026.
//

import SwiftUI

/// Titre d'une feuille Mac aligné sur son contenu (F46, mission E2c).
///
/// Dans la `NavigationStack` d'une feuille Mac, le titre de barre se place en haut à gauche avec
/// ≈ 28 pt de plus que les marges du contenu (mesuré : titre à 48 pt, formulaire à 20 pt ; ni
/// `toolbarRole(.editor)` ni `ToolbarItem(.principal)` n'y changent rien, `toolbarTitleAlignment`
/// et `ToolbarItemPlacement.title` n'existent pas sur macOS). On retire donc le titre de la barre
/// et on pose le même texte en tête du contenu, sur la marge de 20 pt. Le `navigationTitle` reste
/// posé sur l'écran : VoiceOver et le menu Fenêtre le lisent toujours.
///
/// Sans effet sur iPhone et iPad, où la barre de navigation centre son titre.
private struct MacSheetTitleBarModifier: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .toolbar(removing: .title)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    Divider()
                }
                // Opaque : le contenu défile derrière, comme la barre « Fermer » du bas.
                .background(.background)
            }
        #else
        content
        #endif
    }
}

extension View {
    /// Voir `MacSheetTitleBarModifier`. À poser sur le contenu d'une `NavigationStack` de feuille,
    /// à côté de son `navigationTitle` (qui reste, pour l'accessibilité).
    func macSheetTitleBar(_ title: String) -> some View {
        modifier(MacSheetTitleBarModifier(title: title))
    }
}
