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
            try keyStore.save(apiKey: trimmed, account: account)
            hasStoredKey = true
            state = .saved
        } catch {
            state = .failed("Clé invalide ou refusée par le fournisseur.")
        }
    }

    /// Supprime la clé Keychain de ce fournisseur. Si ce fournisseur était le
    /// fournisseur BYOK actuellement sélectionné (`CloudProviderSelectionStore`),
    /// la sélection est aussi effacée — sinon elle resterait orpheline
    /// indéfiniment, sans clé pour la résoudre.
    func deleteStoredKey() {
        try? keyStore.deleteAPIKey(account: account)
        hasStoredKey = false
        state = .idle

        if selectionStore.selection?.providerID == account {
            selectionStore.selection = nil
        }
    }
}
