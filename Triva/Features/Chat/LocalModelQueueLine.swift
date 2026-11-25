//
//  LocalModelQueueLine.swift
//  Triva
//
//  Created by ben podrojsky on 19/11/2026.
//

import SwiftUI

/// Ligne d'état de l'écran de recherche quand le modèle local MLX est déjà utilisé (une autre fenêtre, Siri ou Raccourcis)
/// (chantier 2.2, mission M3) : la question de cette fenêtre est en file, elle part juste après.
/// Sans elle, la fenêtre semblait figée. Même forme que `OfflineStatusLine` (DESIGN.md : SF Symbol,
/// couleur sémantique, texte en `.primary` car c'est l'information principale de la ligne).
struct LocalModelQueueLine: View {
    /// Texte neutre (X2, à valider par Ben) : le modèle peut aussi être occupé par Siri ou Raccourcis, sans aucune
    /// autre fenêtre.
    static let text = "Le modèle local est déjà utilisé. Ta question part juste après."

    var body: some View {
        Label(Self.text, systemImage: "hourglass")
            .font(.footnote)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("search.localModelQueue")
    }
}

#Preview {
    LocalModelQueueLine()
        .padding()
}
