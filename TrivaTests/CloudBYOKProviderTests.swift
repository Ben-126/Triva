//
//  CloudBYOKProviderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 31/08/2026.
//

import Testing
import Foundation
import FoundationModels
import ClaudeForFoundationModels
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

@MainActor
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

    @Test("streamGenerate() finish immédiatement avec missingAPIKey quand aucune clé n'est stockée, sans yield")
    func streamGenerateFinishesImmediatelyWhenNoKeyStored() async throws {
        let provider = CloudBYOKProvider(keyStore: MockAPIKeyStore(storedKey: nil))

        var received: [String] = []
        await #expect(throws: CloudBYOKError.missingAPIKey) {
            for try await chunk in provider.streamGenerate(prompt: "Bonjour") {
                received.append(chunk)
            }
        }
        #expect(received.isEmpty)
    }

    @Test("streamGenerate() finish immédiatement avec missingAPIKey quand la clé stockée est vide, sans yield")
    func streamGenerateFinishesImmediatelyWhenKeyIsEmpty() async throws {
        let provider = CloudBYOKProvider(keyStore: MockAPIKeyStore(storedKey: ""))

        var received: [String] = []
        await #expect(throws: CloudBYOKError.missingAPIKey) {
            for try await chunk in provider.streamGenerate(prompt: "Bonjour") {
                received.append(chunk)
            }
        }
        #expect(received.isEmpty)
    }

    @Test("streamGenerate() finish avec generationFailed quand le Keychain renvoie une erreur")
    func streamGenerateFinishesWithGenerationFailedWhenKeyStoreThrows() async throws {
        let provider = CloudBYOKProvider(keyStore: MockAPIKeyStore(readError: StubError()))

        var received: [String] = []
        await #expect(throws: CloudBYOKError.self) {
            for try await chunk in provider.streamGenerate(prompt: "Bonjour") {
                received.append(chunk)
            }
        }
        #expect(received.isEmpty)
    }
}

// MARK: - Erreurs typées (bug 6)

/// Erreurs telles que les lève `ClaudeForFoundationModels` (voir son
/// `ErrorMapper`), construites sans réseau ni session.
private let typedClaudeErrors: [(any Error, CloudProviderFailure)] = [
    (LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "429")), .rateLimited),
    (LanguageModelError.contextSizeExceeded(.init(contextSize: 0, tokenCount: 0, debugDescription: "413")), .contextWindowExceeded),
    (LanguageModelError.timeout(.init(debugDescription: "timedOut")), .unreachable),
    (ClaudeError.missingCredential, .apiKeyRejected(statusCode: nil)),
    (URLError(.notConnectedToInternet), .unreachable),
    (URLError(.networkConnectionLost), .unreachable),
]

/// Erreur dont la description reprend le texte d'un serveur, comme l'`APIError`
/// (visibilité `package`) du package pour un 403 ou un 5xx.
private struct ServerEchoError: Error, CustomStringConvertible {
    var description: String { "permission_error: Bearer sk-SECRET-42" }
}

@MainActor
@Suite("CloudBYOKProvider.mapGenerationError (bug 6)")
struct CloudBYOKErrorMappingTests {
    @Test("Chaque erreur typée du package Claude devient sa cause, au nom de Claude", arguments: typedClaudeErrors)
    func typedErrorBecomesProviderFailure(error: any Error, expected: CloudProviderFailure) {
        let mapped = CloudBYOKProvider.mapGenerationError(error)
        #expect(mapped as? CloudBYOKError == .providerFailure(provider: "Claude", reason: expected))
    }

    @Test("L'annulation ressort intacte : tâche Swift ou requête URLSession")
    func cancellationPassesThroughUntouched() {
        #expect(CloudBYOKProvider.mapGenerationError(CancellationError()) is CancellationError)
        #expect((CloudBYOKProvider.mapGenerationError(URLError(.cancelled)) as? URLError)?.code == .cancelled)
    }

    @Test("Une CloudBYOKError déjà formée passe telle quelle")
    func providerErrorPassesThrough() {
        #expect(CloudBYOKProvider.mapGenerationError(CloudBYOKError.missingAPIKey) as? CloudBYOKError == .missingAPIKey)
    }

    @Test("Erreur non classée (403, 5xx, garde-fou…) : generationFailed qui ne garde que le nom du type, jamais le texte du serveur")
    func unclassifiedErrorKeepsOnlyTheTypeName() {
        let guardrail = LanguageModelError.guardrailViolation(.init(debugDescription: "Bearer sk-SECRET-42"))
        for error: any Error in [ServerEchoError(), guardrail, ClaudeError.attestationFailed] {
            #expect(CloudBYOKProvider.failureReason(for: error) == nil)
            guard case .generationFailed(let description)? = CloudBYOKProvider.mapGenerationError(error) as? CloudBYOKError else {
                Issue.record("\(type(of: error)) aurait dû devenir generationFailed")
                continue
            }
            #expect(!description.contains("SECRET"))
            #expect(description == String(reflecting: type(of: error)))
        }
    }
}
