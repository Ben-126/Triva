//
//  CardTitleRow.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI

/// Première ligne d'une carte de choix : titre, capsule facultative (« Recommandé », « Plus rapide »)
/// et élément de fin (coche, taille de téléchargement).
///
/// POURQUOI un composant : à Dynamic Type AX3, titre et capsule restaient sur une même ligne. La
/// capsule était écrasée (« Recom/mandé » coupé sans tiret, « Re-/com-/mandé » qui débordait) et le
/// titre se coupait en deux (« Apple Intelli-gence »). Finding Q3 n°13, HIG typography.md :
/// « consider using a stacked layout where text appears above secondary items ». Aux tailles
/// d'accessibilité la ligne devient donc une pile : capsule, titre, puis élément de fin, chacun sur
/// toute la largeur. Aux tailles normales la mise en page est celle d'avant.
struct CardTitleRow<Trailing: View>: View {
    let title: String
    var badge: String?
    @ViewBuilder let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            if isStacked, let badge {
                badgeView(badge)
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.leading)
            if !isStacked, let badge {
                badgeView(badge)
            }
            if !isStacked {
                Spacer(minLength: 8)
            }
            trailing
        }
    }

    private func badgeView(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // Fond plein teinté, PAS de verre : la carte qui porte cette ligne est déjà en verre, et du
            // verre sur du verre dégrade rendu et lisibilité (DESIGN.md ; revue R3-8). 0,15 est
            // l'opacité de fond de badge prévue par la DA.
            .background(Color.accentColor.opacity(0.15), in: .capsule)
    }
}

#Preview("Normal") {
    CardTitleRow(title: "Apple Intelligence", badge: "Recommandé") {
        Image(systemName: "checkmark.circle.fill")
    }
    .padding(20)
}

#Preview("AX3") {
    CardTitleRow(title: "Apple Intelligence", badge: "Recommandé") {
        Image(systemName: "checkmark.circle.fill")
    }
    .padding(20)
    .dynamicTypeSize(.accessibility3)
}
