//
//  AIDisclaimerLine.swift
//  Triva
//
//  Mission C3 (audit légal, constat 9 ; AI Act art. 50, Apple Foundation Models).
//

import SwiftUI

/// Avertissement permanent sous chaque réponse terminée : « Réponse générée par IA… ».
///
/// EMPLACEMENT : sous le texte de la réponse, avant les sources, dans la bulle elle-même (et dans
/// le détail d'un favori, qui partage ce composant). Pourquoi là : il suit la réponse quand on la
/// copie en capture, la partage ou la retrouve dans les favoris ; il est lu par VoiceOver juste
/// après la réponse ; il ne coûte aucune place en haut de l'écran, ni un bandeau de plus à fermer.
/// Une ligne en pied du fil aurait disparu au défilement et n'aurait pas accompagné une réponse
/// retrouvée dans l'historique.
///
/// SOBRE (DESIGN.md) : `.caption`, encre des légendes de la bulle (`MessageBubbleView.legendStyle`,
/// contraste mesuré), ni icône ni verre ni couleur d'alerte. Version courte aux grandes tailles de
/// texte, où la phrase longue prendrait la moitié de l'écran.
struct AIDisclaimerLine: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // À VALIDER (texte légal)
        Text(dynamicTypeSize.isAccessibilitySize ? AIUseNoticeText.footerShort : AIUseNoticeText.footer)
            .font(.caption)
            .foregroundStyle(MessageBubbleView.legendStyle)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("chat.aiDisclaimer")
    }
}

/// Quand l'avertissement s'affiche : pur, donc testable.
nonisolated enum AIDisclaimerPolicy {
    /// Une réponse qui a du texte écrit par l'IA et qui n'est plus en cours d'écriture, même
    /// interrompue (le texte déjà écrit reste généré par une IA). Jamais pour un échec ni pour le
    /// message fixe « aucune source fiable » : ce n'est pas un texte généré.
    static func shows(state: MessageBubblePresentation.AnswerState, hasText: Bool) -> Bool {
        guard hasText else { return false }
        switch state {
        case .completed, .interrupted: return true
        case .streaming, .failed, .noReliableSources: return false
        }
    }
}
