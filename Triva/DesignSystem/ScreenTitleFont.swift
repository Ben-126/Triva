//
//  ScreenTitleFont.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI

/// Police du titre d'accroche d'un écran : 28 pt `.semibold` à la taille de texte par défaut
/// (valeur fixée par `DESIGN.md`), mais qui GRANDIT avec Dynamic Type.
///
/// POURQUOI : avec `.font(.system(size: 28, weight: .semibold))`, le titre restait à 28 pt pendant
/// que son sous-titre (`.subheadline`) grossissait avec le réglage système. À AX3, le titre devenait
/// plus petit que son sous-titre et la hiérarchie s'inversait (finding Q3 n°14, HIG typography.md :
/// « Maintain a consistent information hierarchy regardless of the current font size »).
/// `@ScaledMetric(relativeTo: .title)` garde les 28 pt exacts à la taille par défaut et applique la
/// même courbe d'agrandissement que `.title`, donc le titre reste toujours devant son sous-titre.
private struct ScreenTitleFontModifier: ViewModifier {
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 28

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .semibold))
    }
}

extension View {
    /// Applique la police du titre d'accroche (voir `ScreenTitleFontModifier`).
    func screenTitleFont() -> some View {
        modifier(ScreenTitleFontModifier())
    }
}
