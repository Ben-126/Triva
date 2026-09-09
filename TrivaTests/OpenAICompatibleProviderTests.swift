//
//  OpenAICompatibleProviderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Faux magasin de clés API, même pattern que `CloudBYOKProviderTests`.
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

/// Faux client HTTP, pour tester `OpenAICompatibleProvider` sans vrai appel réseau.
private struct MockOpenAICompatibleClient: OpenAICompatibleRequesting {
    var response: String = ""
    var errorToThrow: (any Error)?

    func generate(baseURL: URL, apiKey: String, model: String, prompt: String) async throws -> String {
        if let errorToThrow { throw errorToThrow }
        return response
    }
}

private struct StubError: Error, Equatable {}

@Suite("OpenAICompatibleProvider")
struct OpenAICompatibleProviderTests {
    private let preset = CloudProviderCatalog.presets.first { $0.id == "groq" }!

    @Test("Échoue avec missingAPIKey quand aucune clé n'est stockée")
    func missingAPIKeyWhenNoKeyStored() async throws {
        let provider = OpenAICompatibleProvider(
            preset: preset,
            keyStore: MockAPIKeyStore(storedKey: nil),
            client: MockOpenAICompatibleClient()
        )

        await #expect(throws: OpenAICompatibleProviderError.missingAPIKey) {
            _ = try await provider.generate(prompt: "Bonjour")
        }
    }

    @Test("Échoue avec missingAPIKey quand la clé stockée est vide")
    func missingAPIKeyWhenKeyIsEmpty() async throws {
        let provider = OpenAICompatibleProvider(
            preset: preset,
            keyStore: MockAPIKeyStore(storedKey: ""),
            client: MockOpenAICompatibleClient()
        )

        await #expect(throws: OpenAICompatibleProviderError.missingAPIKey) {
            _ = try await provider.generate(prompt: "Bonjour")
        }
    }

    @Test("Renvoie le texte généré par le client quand tout va bien")
    func returnsGeneratedTextOnSuccess() async throws {
        let provider = OpenAICompatibleProvider(
            preset: preset,
            keyStore: MockAPIKeyStore(storedKey: "sk-test"),
            client: MockOpenAICompatibleClient(response: "Réponse")
        )

        let text = try await provider.generate(prompt: "Bonjour")
        #expect(text == "Réponse")
    }

    @Test("Échoue avec generationFailed quand le client HTTP échoue")
    func generationFailedWhenClientThrows() async throws {
        let provider = OpenAICompatibleProvider(
            preset: preset,
            keyStore: MockAPIKeyStore(storedKey: "sk-test"),
            client: MockOpenAICompatibleClient(errorToThrow: StubError())
        )

        await #expect(throws: OpenAICompatibleProviderError.self) {
            _ = try await provider.generate(prompt: "Bonjour")
        }
    }

    @Test("Échoue avec generationFailed quand le Keychain renvoie une erreur")
    func generationFailedWhenKeyStoreThrows() async throws {
        let provider = OpenAICompatibleProvider(
            preset: preset,
            keyStore: MockAPIKeyStore(readError: StubError()),
            client: MockOpenAICompatibleClient()
        )

        await #expect(throws: OpenAICompatibleProviderError.self) {
            _ = try await provider.generate(prompt: "Bonjour")
        }
    }

    @Test("Utilise l'id du preset comme compte Keychain")
    func usesPresetIDAsAccount() {
        let provider = OpenAICompatibleProvider(preset: preset)
        #expect(provider.account == "groq")
    }

    /// `OpenAICompatibleProvider` n'implémente pas `streamGenerate(prompt:)` —
    /// il hérite tel quel de l'implémentation par défaut du protocole
    /// `AIGenerating` (0.8) : un seul yield contenant le texte complet de
    /// `generate(prompt:)`, puis fin normale du flux.
    @Test("streamGenerate() par défaut produit un seul yield avec le texte complet")
    func streamGenerateDefaultProducesSingleYieldWithFullText() async throws {
        let provider = OpenAICompatibleProvider(
            preset: preset,
            keyStore: MockAPIKeyStore(storedKey: "sk-test"),
            client: MockOpenAICompatibleClient(response: "Réponse complète")
        )

        var received: [String] = []
        for try await chunk in provider.streamGenerate(prompt: "Bonjour") {
            received.append(chunk)
        }

        #expect(received == ["Réponse complète"])
    }

    @Test("streamGenerate() par défaut propage l'erreur de generate() sans yield")
    func streamGenerateDefaultPropagatesGenerateError() async throws {
        let provider = OpenAICompatibleProvider(
            preset: preset,
            keyStore: MockAPIKeyStore(storedKey: nil),
            client: MockOpenAICompatibleClient()
        )

        var received: [String] = []
        await #expect(throws: OpenAICompatibleProviderError.missingAPIKey) {
            for try await chunk in provider.streamGenerate(prompt: "Bonjour") {
                received.append(chunk)
            }
        }
        #expect(received.isEmpty)
    }
}
