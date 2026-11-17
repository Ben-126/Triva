//
//  ChatViewModel+CloudConsent.swift
//  Triva
//
//  Created by ben podrojsky on 14/11/2026.
//

import Foundation

// Consentement avant le premier envoi à une IA cloud (mission C2). La vue appelle
// `consentRequestBeforeSending()` AVANT de vider le brouillon : si une demande revient, elle montre
// la feuille, et la saisie reste intacte tant que l'utilisateur n'a pas autorisé.
extension ChatViewModel {
    /// `nil` : on peut envoyer. Sinon la demande à montrer ; rien n'est parti.
    func consentRequestBeforeSending() -> CloudAIConsentRequest? {
        resolveConsentRequest()
    }

    /// « Autoriser » : l'accord est mémorisé pour ce fournisseur.
    func allowCloudConsent(_ request: CloudAIConsentRequest) {
        grantConsent(request)
        if errorDescription == CloudAIConsentText.cancelled { setErrorDescription(nil) }
    }

    /// « Annuler » : rien n'est envoyé, message clair (la saisie, elle, n'a pas été touchée).
    func declineCloudConsent() {
        setErrorDescription(CloudAIConsentText.cancelled)
    }
}
