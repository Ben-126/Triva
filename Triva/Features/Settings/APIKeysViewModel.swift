//
//  APIKeysViewModel.swift
//  Triva
//
//  Created by ben podrojsky on 03/09/2026.
//

import Foundation

enum APIKeySaveState: Equatable {
    case idle
    case validating
    case saved
    case failed(String)
}

/// Logique de saisie/validation/stockage de la clé API BYOK (0.6), isolée de
/// `KeychainAPIKeyStore` et `ClaudeAPIKeyValidator` via des protocoles pour
/// rester testable sans vrai Keychain ni vrai appel réseau.
@Observable
final class APIKeysViewModel {
    private(set) var state: APIKeySaveState = .idle
    private(set) var hasStoredKey: Bool

    private let keyStore: any APIKeyStoring
    private let validator: any APIKeyValidating
    private let account: String
    private let selectionStore: CloudProviderSelectionStore

    init(
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        validator: any APIKeyValidating = ClaudeAPIKeyValidator(),
        account: String = CloudBYOKProviderKind.claude.rawValue,
        selectionStore: CloudProviderSelectionStore = CloudProviderSelectionStore()
    ) {
        self.keyStore = keyStore
        self.validator = validator
        self.account = account
        self.selectionStore = selectionStore
        hasStoredKey = ((try? keyStore.apiKey(account: account)) ?? nil)?.isEmpty == false
    }

    /// Valide `rawKey` auprès du fournisseur avant de l'enregistrer — une clé
    /// refusée n'est jamais stockée en Keychain.
    func save(rawKey: String) async {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed("Entre une clé API avant d'enregistrer.")
            return
        }

        state = .validating
        do {
            try await validator.validate(apiKey: trimmed)
        } catch APIKeyValidationError.unverifiable(let message) {
            // Pas un refus : on ne dit pas « clé invalide » à quelqu'un dont le réseau est coupé.
            state = .failed("Impossible de vérifier la clé pour l'instant. \(message)")
            return
        } catch {
            state = .failed("Clé invalide ou refusée par le fournisseur.")
            return
        }

        do {
            try keyStore.save(apiKey: trimmed, account: account)
        } catch {
            // Une clé VALIDE que le Trousseau refuse n'est pas une « clé invalide ». **À VALIDER PAR BEN.**
            state = .failed(Self.keychainSaveFailureMessage)
            return
        }
        hasStoredKey = true
        state = .saved
    }

    /// Textes **À VALIDER PAR BEN**.
    static let keychainSaveFailureMessage = "La clé est valide, mais le Trousseau n'a pas pu l'enregistrer. Réessaie."
    static let keychainDeleteFailureMessage = "La clé n'a pas pu être supprimée du Trousseau : elle y est toujours. Réessaie."

    /// Supprime la clé Keychain de ce fournisseur. Si ce fournisseur était le
    /// fournisseur BYOK actuellement sélectionné (`CloudProviderSelectionStore`),
    /// la sélection est aussi effacée — sinon elle resterait orpheline
    /// indéfiniment, sans clé pour la résoudre.
    ///
    /// Si le Trousseau refuse, la clé est toujours là : `hasStoredKey`, la
    /// sélection et l'écran ne bougent pas, et l'échec est dit (`state`).
    func deleteStoredKey() {
        do {
            try keyStore.deleteAPIKey(account: account)
        } catch {
            state = .failed(Self.keychainDeleteFailureMessage)
            return
        }
        hasStoredKey = false
        state = .idle

        if selectionStore.selection?.providerID == account {
            selectionStore.selection = nil
        }
    }
}
