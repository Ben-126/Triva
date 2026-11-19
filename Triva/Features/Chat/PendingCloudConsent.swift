//
//  PendingCloudConsent.swift
//  Triva
//
//  Mission I1 (2.0, iPhone Duo).
//

import Foundation

/// L'envoi interrompu par la demande de consentement cloud, sous forme de DONNÉES. Avant, `ChatView` en
/// gardait une closure (`afterConsent`) dans un `@State` : plier ou déplier l'iPhone Duo remplace la vue,
/// la feuille de consentement disparaissait avec elle et l'envoi était perdu sans un mot. Ici, la demande
/// et l'envoi vivent dans le `ChatViewModel`, qui survit au remontage.
nonisolated enum PendingSendAction: Equatable, Sendable {
    /// Question tapée dans la barre de saisie (le texte tel qu'il était au moment de l'envoi).
    case send(query: String)
    /// Suggestion touchée.
    case suggestion(String)
    /// « Réessayer en mode Rapide » sur une réponse sans source fiable.
    case retryInQuickMode(messageID: UUID)
    /// « Lire cette page » : la réponse est refaite avec la page lue.
    case regenerateWithReadPages
    /// « Relancer » après un envoi bloqué hors connexion.
    case retryAfterOffline(quickMode: Bool)
}

/// Demande de consentement affichée, et ce qu'il faut envoyer une fois « Autoriser » touché.
nonisolated struct PendingCloudConsent: Equatable, Identifiable, Sendable {
    let request: CloudAIConsentRequest
    let action: PendingSendAction

    var id: String { request.id }
}
