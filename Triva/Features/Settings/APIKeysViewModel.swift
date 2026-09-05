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

    init(
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        validator: any APIKeyValidating = ClaudeAPIKeyValidator(),
        account: String = CloudBYOKProviderKind.claude.rawValue
    ) {
        self.keyStore = keyStore
        self.validator = validator
        self.account = account
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

    func deleteStoredKey() {
        try? keyStore.deleteAPIKey(account: account)
        hasStoredKey = false
        state = .idle
    }
}
