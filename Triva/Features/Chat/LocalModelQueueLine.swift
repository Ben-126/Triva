//
//  LocalModelQueueLine.swift
//  Triva
//
//  Created by ben podrojsky on 19/11/2026.
//

import SwiftUI

/// Ligne d'état de l'écran de recherche quand une autre fenêtre utilise le modèle local MLX
/// (chantier 2.2, mission M3) : la question de cette fenêtre est en file, elle part juste après.
/// Sans elle, la fenêtre semblait figée. Même forme que `OfflineStatusLine` (DESIGN.md : SF Symbol,
/// couleur sémantique, texte en `.primary` car c'est l'information principale de la ligne).
struct LocalModelQueueLine: View {
    static let text = "Une autre fenêtre utilise le modèle local. Ta question part juste après."

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
