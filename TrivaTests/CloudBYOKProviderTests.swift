//
//  CloudBYOKProviderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 31/08/2026.
//

import Testing
@testable import Triva

/// Faux magasin de clés API, pour tester `CloudBYOKProvider` sans toucher au
/// vrai Keychain ni faire de vrai appel réseau vers Claude.
private struct MockAPIKeyStore: APIKeyStoring {
    var storedKey: String?
    var readError: (any Error)?

    func apiKey(account: String) throws -> String? {
        if let readError { throw readError }
        return storedKey
    }

    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

private struct StubError: Error, Equatable {}

@Suite("CloudBYOKProvider")
struct CloudBYOKProviderTests {
    @Test("Échoue avec missingAPIKey quand aucune clé n'est stockée")
    func missingAPIKeyWhenNoKeyStored() async throws {
        let provider = CloudBYOKProvider(keyStore: MockAPIKeyStore(storedKey: nil))

        await #expect(throws: CloudBYOKError.missingAPIKey) {
            _ = try await provider.generate(prompt: "Bonjour")
        }
    }

    @Test("Échoue avec missingAPIKey quand la clé stockée est vide")
    func missingAPIKeyWhenKeyIsEmpty() async throws {
        let provider = CloudBYOKProvider(keyStore: MockAPIKeyStore(storedKey: ""))

        await #expect(throws: CloudBYOKError.missingAPIKey) {
            _ = try await provider.generate(prompt: "Bonjour")
        }
    }

    @Test("Échoue avec generationFailed quand le Keychain renvoie une erreur")
    func generationFailedWhenKeyStoreThrows() async throws {
        let provider = CloudBYOKProvider(keyStore: MockAPIKeyStore(readError: StubError()))

        await #expect(throws: CloudBYOKError.self) {
            _ = try await provider.generate(prompt: "Bonjour")
        }
    }

    @Test("Utilise le compte du fournisseur Claude par défaut")
    func defaultAccountMatchesClaudeProviderKind() {
        #expect(CloudBYOKProviderKind.claude.rawValue == "claude")
        #expect(CloudBYOKProviderKind.allCases == [.claude])
    }
}
