//
//  AppleIntelligenceModelChoice.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import SwiftUI

/// Textes du choix « cloud privé d'Apple / sur l'appareil » (mission A4), partagés par l'écran de
/// choix du moteur et les Réglages : une seule rédaction, testée, que Ben valide une fois.
///
/// Ce qu'ils affirment est vérifié dans la documentation d'Apple (2026-11-11) : le cloud privé a
/// un contexte quatre à huit fois plus grand (« plus puissant »), Apple n'y conserve jamais les
/// demandes (WWDC26 session 319) ; le modèle sur l'appareil marche hors connexion et rien ne
/// sort. Aucun de ces textes n'apparaît tant que le cloud n'est pas proposé
/// (`PrivateCloudStatus.isOffered`).
nonisolated enum AppleIntelligenceModelCopy {
    /// Libellé complet (Réglages).
    static func title(for kind: AppleIntelligenceModelKind) -> String {
        switch kind {
        case .privateCloud: "Cloud privé d'Apple"
        case .onDevice: "Sur l'appareil"
        }
    }

    /// Libellé court (sélecteur segmenté de l'écran de choix).
    static func shortTitle(for kind: AppleIntelligenceModelKind) -> String {
        switch kind {
        case .privateCloud: "Cloud privé"
        case .onDevice: "Sur l'appareil"
        }
    }

    /// Une phrase par option.
    static func detail(for kind: AppleIntelligenceModelKind) -> String {
        switch kind {
        case .privateCloud: "Plus puissant. Protégé par Apple : rien n'est conservé."
        case .onDevice: "Marche sans Internet. Rien ne quitte ton appareil."
        }
    }

    /// Les deux options en deux phrases, sous le sélecteur de l'écran de choix.
    static let comparison = "Cloud privé : plus puissant, protégé par Apple, rien n'est conservé. Sur l'appareil : marche sans Internet, rien ne quitte ton appareil."

    /// Pied de section des Réglages : le repli automatique, dit une fois.
    static let fallbackNote = "Sans connexion, ou une fois la limite du jour atteinte, Triva répond sur l'appareil."

    /// Sous-titre de la carte Apple Intelligence quand le cloud est proposé : « sur l'appareil »
    /// n'y serait plus vrai pour tout le monde.
    static let engineCardSubtitle = "Gratuit. Nécessite un appareil compatible avec Apple Intelligence activé."
}

/// Sélecteur segmenté de l'écran de choix du moteur, sous la carte Apple Intelligence. Contrôle
/// système, sans verre : DESIGN.md réserve le verre aux barres, badges et cartes.
struct AppleIntelligenceModelSegmentedChoice: View {
    @Binding var selection: AppleIntelligenceModelKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Modèle d'Apple Intelligence", selection: $selection) {
                ForEach(AppleIntelligenceModelKind.allCases, id: \.self) { kind in
                    Text(AppleIntelligenceModelCopy.shortTitle(for: kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("engine.appleModelPicker")

            Text(AppleIntelligenceModelCopy.comparison)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }
}

#Preview("Choix du modèle Apple") {
    @Previewable @State var selection = AppleIntelligenceModelKind.privateCloud
    AppleIntelligenceModelSegmentedChoice(selection: $selection)
        .padding(.vertical, 20)
}
