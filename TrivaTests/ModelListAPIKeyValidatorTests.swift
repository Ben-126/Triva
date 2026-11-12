//
//  ModelListAPIKeyValidatorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Faux client HTTP : réponse ou erreur fixée, aucune requête réseau réelle.
private nonisolated final class StubRequester: HTTPDataRequesting, @unchecked Sendable {
    private let statusCode: Int
    private let body: String
    private let error: (any Error)?

    init(statusCode: Int = 200, body: String = "", error: (any Error)? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// Valideur de repli espion : dit s'il a été appelé et s'il accepte.
private nonisolated final class SpyFallback: APIKeyValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let shouldThrow: Bool

    init(shouldThrow: Bool = false) { self.shouldThrow = shouldThrow }

    var calls: Int { lock.withLock { _calls } }

    func validate(apiKey: String) async throws {
        lock.withLock { _calls += 1 }
        if shouldThrow { throw APIKeyValidationError.invalidKey(description: "repli") }
    }
}

private let source = CloudModelListSource.openAICompatible(baseURL: URL(string: "https://api.example.com/v1")!)
private let secret = "sk-test-SECRET-9876543210"

private func makeValidator(
    _ requester: StubRequester,
    source: CloudModelListSource = source,
    fallback: SpyFallback
) -> ModelListAPIKeyValidator {
    ModelListAPIKeyValidator(
        providerID: "test",
        source: source,
        fallback: fallback,
        service: CloudModelListService(requester: requester, cache: CloudModelListCache())
    )
}

@Suite("ModelListAPIKeyValidator — valider une clé par la liste des modèles")
struct ModelListAPIKeyValidatorTests {
    @Test("Liste reçue : la clé est valide, même si le modèle par défaut n'existe plus, sans repli")
    func listSucceedsWithoutFallback() async throws {
        let fallback = SpyFallback(shouldThrow: true)
        let requester = StubRequester(body: #"{"data":[{"id":"un-autre-modele"}]}"#)

        try await makeValidator(requester, fallback: fallback).validate(apiKey: secret)

        #expect(fallback.calls == 0)
    }

    @Test("401 : la clé est refusée, sans repli")
    func unauthorizedIsInvalid() async {
        let fallback = SpyFallback()
        let validator = makeValidator(StubRequester(statusCode: 401), fallback: fallback)

        await #expect(throws: APIKeyValidationError.self) {
            try await validator.validate(apiKey: secret)
        }
        #expect(fallback.calls == 0)
    }

    @Test("Liste absente (404) ou clé limitée (403) : repli sur la génération")
    func missingListFallsBack() async throws {
        for status in [404, 403] {
            let fallback = SpyFallback()
            try await makeValidator(StubRequester(statusCode: status), fallback: fallback).validate(apiKey: secret)
            #expect(fallback.calls == 1, "statut \(status)")
        }
    }

    @Test("Fournisseur à liste fixe (Perplexity) : repli direct, aucun appel de liste")
    func staticListUsesFallbackOnly() async throws {
        let fallback = SpyFallback()
        let requester = StubRequester(error: URLError(.notConnectedToInternet))

        try await makeValidator(requester, source: .staticList([]), fallback: fallback).validate(apiKey: secret)

        #expect(fallback.calls == 1)
    }

    @Test("Réseau coupé : « impossible de vérifier », pas « clé invalide », sans repli")
    func networkFailureIsUnverifiable() async {
        let fallback = SpyFallback()
        let validator = makeValidator(StubRequester(error: URLError(.notConnectedToInternet)), fallback: fallback)

        do {
            try await validator.validate(apiKey: secret)
            Issue.record("Une panne réseau ne doit pas valider la clé.")
        } catch let error as APIKeyValidationError {
            guard case .unverifiable = error else {
                Issue.record("Attendu .unverifiable, reçu \(error)")
                return
            }
        } catch {
            Issue.record("Erreur inattendue : \(error)")
        }
        #expect(fallback.calls == 0)
    }

    @Test("Le message d'une erreur ne contient jamais la clé")
    func errorNeverContainsTheKey() async {
        let validator = makeValidator(StubRequester(statusCode: 401, body: secret), fallback: SpyFallback())
        do {
            try await validator.validate(apiKey: secret)
            Issue.record("Une clé refusée doit lever une erreur.")
        } catch {
            #expect(!String(describing: error).contains(secret))
        }
    }

    @Test("Chaque fournisseur du catalogue a une source de liste : le validateur n'est jamais réduit au modèle fixe")
    @MainActor
    func everyCatalogProviderHasListSource() {
        for preset in CloudProviderCatalog.presets {
            #expect(
                CloudModelListService.source(forProviderID: preset.id, customPresets: []) != nil,
                "\(preset.id)"
            )
        }
    }
}
