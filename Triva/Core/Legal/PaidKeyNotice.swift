//
//  PaidKeyNotice.swift
//  Triva
//
//  Mention « clé API payante chez le fournisseur » (mission C5, audit légal). Texte EXACT, VALIDÉ par
//  Ben (2026-11-17, quota gratuit ajouté le 2026-11-18, Q-V2b) : ne pas le reformuler. Une seule constante, affichée au choix du moteur (accueil
//  et Réglages) et dans les écrans de clés et de fournisseur cloud.
//

import SwiftUI

nonisolated enum PaidKeyNotice {
    static let text =
        "Avec ta propre clé, chaque question est payée chez le fournisseur (OpenAI, Anthropic…), "
        + "ou décomptée de ton quota gratuit s'il en offre un, sur ton compte chez lui. Triva est gratuite et ne reçoit jamais d'argent. "
        + "Apple Intelligence et les modèles sur l'appareil sont gratuits."
}

/// La mention en texte secondaire : lisible, sans icône ni couleur d'alerte (DESIGN.md). Suit
/// Dynamic Type ; lue telle quelle par VoiceOver.
struct PaidKeyNoticeText: View {
    var body: some View {
        Text(PaidKeyNotice.text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("legal.paidKeyNotice")
    }
}
