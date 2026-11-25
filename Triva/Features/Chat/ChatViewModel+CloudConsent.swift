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

    // MARK: - Envoi en attente (mission I1)

    /// Demande le consentement avant `action`. `true` : une feuille est à montrer (`pendingConsent`), l'envoi
    /// attend « Autoriser » ; `false` : rien à demander, l'appelant envoie tout de suite. Rien n'est parti,
    /// et la saisie reste intacte, tant que l'utilisateur n'a pas autorisé.
    func requestConsent(resuming action: PendingSendAction) -> Bool {
        guard let request = consentRequestBeforeSending() else { return false }
        setPendingConsent(PendingCloudConsent(request: request, action: action))
        return true
    }

    /// « Autoriser » : l'accord est mémorisé, puis l'envoi interrompu repart. Renvoie cet envoi (`nil` s'il
    /// n'y avait rien en attente) : pour `.send`, l'appelant vide en plus le brouillon, qui n'appartient pas
    /// au modèle.
    @discardableResult
    func allowPendingConsent() -> PendingSendAction? {
        guard let pending = pendingConsent else { return nil }
        allowCloudConsent(pending.request)
        setPendingConsent(nil)
        start(pending.action)
        return pending.action
    }

    /// « Annuler » : rien n'est envoyé, message clair ; la saisie n'a pas été touchée.
    func declinePendingConsent() {
        guard pendingConsent != nil else { return }
        setPendingConsent(nil)
        declineCloudConsent()
    }

    /// Lance l'envoi décrit par `action` (la vue, elle, vide d'abord le brouillon pour `.send`).
    func start(_ action: PendingSendAction) {
        switch action {
        case .send(let query): startSend(query: query)
        case .suggestion(let suggestion): startSuggestion(suggestion)
        case .retryInQuickMode(let messageID): startRetryInQuickMode(messageID: messageID)
        case .retryInterrupted(let messageID): startRetryInterrupted(messageID: messageID)
        case .regenerateWithReadPages: startRegenerationWithReadPages()
        case .retryAfterOffline(let quickMode): startRetryAfterOffline(quickMode: quickMode)
        }
    }
}
