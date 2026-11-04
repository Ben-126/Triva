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

@MainActor
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

// MARK: - Erreurs typées (bug 6)

/// Statut renvoyé par le client HTTP → cause attendue : un échantillon par
/// famille. Le classement complet des statuts est testé dans
/// `CloudProviderFailureTests`. Constante de fichier non isolée : le target de
/// tests n'a pas l'isolation `MainActor` par défaut, et `CloudProviderFailure`
/// est `nonisolated`.
private let sampleStatusMappings: [(Int, CloudProviderFailure)] = [
    (401, .apiKeyRejected(statusCode: 401)),
    (413, .contextWindowExceeded),
    (429, .rateLimited),
    (503, .serverUnavailable(statusCode: 503)),
    (400, .requestRejected(statusCode: 400)),
]

/// Erreur dont la description reprend le texte d'un serveur, à la manière d'un
/// fournisseur « Personnalisé » qui renverrait l'en-tête d'authentification.
private struct ServerEchoError: Error, CustomStringConvertible {
    var description: String { "Invalid header: Bearer sk-SECRET-42" }
}

@MainActor
@Suite("OpenAICompatibleProvider.mapClientError (bug 6)")
struct OpenAICompatibleProviderErrorMappingTests {
    @Test("Un statut HTTP d'échec devient sa cause typée, au nom du fournisseur", arguments: sampleStatusMappings)
    func failureStatusBecomesTypedFailure(statusCode: Int, expected: CloudProviderFailure) {
        let mapped = OpenAICompatibleProvider.mapClientError(
            OpenAICompatibleClientError.requestFailed(statusCode: statusCode),
            provider: "Groq"
        )
        #expect(mapped as? OpenAICompatibleProviderError == .providerFailure(provider: "Groq", reason: expected))
    }

    @Test("Erreur de transport (délai dépassé, réseau) : fournisseur injoignable")
    func transportErrorBecomesUnreachable() {
        let mapped = OpenAICompatibleProvider.mapClientError(OpenAICompatibleClientError.transportError, provider: "Groq")
        #expect(mapped as? OpenAICompatibleProviderError == .providerFailure(provider: "Groq", reason: .unreachable))
    }

    @Test("apiError : generationFailed SANS le message du serveur, qui peut contenir la clé")
    func apiErrorNeverKeepsServerMessage() {
        let mapped = OpenAICompatibleProvider.mapClientError(
            OpenAICompatibleClientError.apiError(message: "Invalid header: Bearer sk-SECRET-42"),
            provider: "Mon LLM"
        )
        #expect(mapped as? OpenAICompatibleProviderError == .generationFailed(description: "apiError"))
    }

    @Test("Réponse illisible : generationFailed neutre")
    func decodingFailureStaysUnclassified() {
        let mapped = OpenAICompatibleProvider.mapClientError(OpenAICompatibleClientError.decodingFailed, provider: "Groq")
        #expect(mapped as? OpenAICompatibleProviderError == .generationFailed(description: "decodingFailed"))
    }

    @Test("L'annulation ressort intacte : tâche Swift ou requête URLSession")
    func cancellationPassesThroughUntouched() {
        #expect(OpenAICompatibleProvider.mapClientError(CancellationError(), provider: "Groq") is CancellationError)
        let urlCancellation = OpenAICompatibleProvider.mapClientError(URLError(.cancelled), provider: "Groq")
        #expect((urlCancellation as? URLError)?.code == .cancelled)
    }

    @Test("Une OpenAICompatibleProviderError déjà formée passe telle quelle")
    func providerErrorPassesThrough() {
        let mapped = OpenAICompatibleProvider.mapClientError(OpenAICompatibleProviderError.missingAPIKey, provider: "Groq")
        #expect(mapped as? OpenAICompatibleProviderError == .missingAPIKey)
    }

    @Test("Autre erreur : generationFailed avec le seul nom du type, jamais sa description")
    func unknownErrorKeepsOnlyTheTypeName() throws {
        let mapped = OpenAICompatibleProvider.mapClientError(ServerEchoError(), provider: "Groq")
        let providerError = try #require(mapped as? OpenAICompatibleProviderError)
        guard case .generationFailed(let description) = providerError else {
            Issue.record("Attendu generationFailed, obtenu \(providerError)")
            return
        }
        #expect(description == String(reflecting: ServerEchoError.self))
        #expect(!description.contains("SECRET"))
    }

    @Test("generate() : un 429 du client remonte typé, au nom affiché du preset")
    func generateSurfacesTypedFailureWithPresetName() async throws {
        let groq = try #require(CloudProviderCatalog.presets.first { $0.id == "groq" })
        let provider = OpenAICompatibleProvider(
            preset: groq,
            keyStore: MockAPIKeyStore(storedKey: "sk-test"),
            client: MockOpenAICompatibleClient(errorToThrow: OpenAICompatibleClientError.requestFailed(statusCode: 429))
        )

        await #expect(throws: OpenAICompatibleProviderError.providerFailure(provider: "Groq", reason: .rateLimited)) {
            _ = try await provider.generate(prompt: "Bonjour")
        }
    }

    @Test("generate() : l'annulation du client n'est jamais emballée en échec")
    func generateKeepsCancellation() async {
        let provider = OpenAICompatibleProvider(
            account: "groq",
            baseURL: URL(string: "https://api.groq.com/openai/v1")!,
            model: "llama-3.3-70b-versatile",
            keyStore: MockAPIKeyStore(storedKey: "sk-test"),
            client: MockOpenAICompatibleClient(errorToThrow: CancellationError())
        )

        await #expect(throws: CancellationError.self) {
            _ = try await provider.generate(prompt: "Bonjour")
        }
    }

    @Test("Nom du fournisseur : celui passé, sinon celui du catalogue, sinon l'hôte de l'URL")
    func providerNameFallbacks() {
        let customURL = URL(string: "https://llm.example.com/v1")!

        let named = OpenAICompatibleProvider(account: "custom:abc", providerName: " Mon LLM ", baseURL: customURL, model: "m")
        let catalog = OpenAICompatibleProvider(account: "groq", baseURL: customURL, model: "m")
        let blankName = OpenAICompatibleProvider(account: "custom:abc", providerName: "   ", baseURL: customURL, model: "m")
        let unnamed = OpenAICompatibleProvider(account: "custom:abc", baseURL: customURL, model: "m")

        #expect(named.providerName == "Mon LLM")
        #expect(catalog.providerName == "Groq")
        #expect(blankName.providerName == "llm.example.com")
        #expect(unnamed.providerName == "llm.example.com")
    }
}
