//
//  HangingLabel.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import SwiftUI

/// Icône + texte avec RETRAIT SUSPENDU : la deuxième ligne repart sous le texte, jamais sous
/// l'icône (QA Q3, finding 36). À AX3, « Démarre quasi / instantanément » ou « Obtenir une clé /
/// Brave Search » repartaient sous l'icône dans une liste, et la lecture en souffrait.
///
/// Icône calée sur la première ligne de base, masquée pour VoiceOver : le texte suffit, et
/// l'élément se lit d'un seul tenant. Mêmes police et couleur que l'environnement, comme `Label`.
struct HangingLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(title)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("AX3") {
    VStack(alignment: .leading, spacing: 8) {
        HangingLabel("Démarre quasi instantanément", systemImage: "checkmark.circle")
        HangingLabel("Obtenir une clé Brave Search", systemImage: "arrow.up.forward.square")
    }
    .padding(20)
    .dynamicTypeSize(.accessibility3)
}
