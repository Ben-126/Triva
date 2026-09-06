//
//  CloudProviderSelectionResolverTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/09/2026.
//

import Testing
import Foundation
import ClaudeForFoundationModels
@testable import Triva

/// Faux magasin de clés API, même pattern que `CloudBYOKProviderTests` /
/// `OpenAICompatibleProviderTests` — un exemplaire `private` par fichier de test.
private struct MockAPIKeyStore: APIKeyStoring {
    var storedKey: String?

    func apiKey(account: String) throws -> String? { storedKey }
    func save(apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

@Suite("CloudProviderSelectionResolver")
struct CloudProviderSelectionResolverTests {
    @Test("Résout vers CloudBYOKProvider pour Claude avec un modèle valide")
    func resolvesClaudeProviderWithValidModel() {
        let selection = CloudProviderSelection(providerID: CloudProviderSelectionResolver.claudeProviderID, model: "claude-sonnet-5")

        let resolved = CloudProviderSelectionResolver.makeProvider(
            for: selection,
            customPresets: [],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )

        let provider = try? #require(resolved as? CloudBYOKProvider)
        #expect(provider?.model.id == "claude-sonnet-5")
    }

    @Test("Renvoie nil pour un id de modèle Claude inconnu")
    func returnsNilForUnknownClaudeModel() {
        let selection = CloudProviderSelection(providerID: CloudProviderSelectionResolver.claudeProviderID, model: "claude-modele-inconnu")

        let resolved = CloudProviderSelectionResolver.makeProvider(
            for: selection,
            customPresets: [],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )

        #expect(resolved == nil)
    }

    @Test("Résout vers OpenAICompatibleProvider pour un preset connu du catalogue, avec le modèle de la sélection")
    func resolvesCatalogPresetWithSelectionModel() {
        let preset = CloudProviderCatalog.presets.first { $0.id == "groq" }!
        // Modèle volontairement différent de `preset.defaultModel`, pour vérifier
        // que le modèle choisi par l'utilisateur prime bien sur celui du preset.
        let chosenModel = "llama-3.1-8b-instant"
        #expect(chosenModel != preset.defaultModel)

        let selection = CloudProviderSelection(providerID: preset.id, model: chosenModel)

        let resolved = CloudProviderSelectionResolver.makeProvider(
            for: selection,
            customPresets: [],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )

        let provider = try? #require(resolved as? OpenAICompatibleProvider)
        #expect(provider?.account == "groq")
        #expect(provider?.model == chosenModel)
    }

    @Test("Résout vers OpenAICompatibleProvider pour un preset personnalisé passé dans customPresets")
    func resolvesCustomPreset() {
        let custom = CloudProviderPreset(
            id: "custom:abc",
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            defaultModel: "mon-modele-defaut"
        )
        let selection = CloudProviderSelection(providerID: custom.id, model: "mon-modele-choisi")

        let resolved = CloudProviderSelectionResolver.makeProvider(
            for: selection,
            customPresets: [custom],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )

        let provider = try? #require(resolved as? OpenAICompatibleProvider)
        #expect(provider?.account == "custom:abc")
        #expect(provider?.model == "mon-modele-choisi")
    }

    @Test("Renvoie nil si le providerID ne correspond à rien")
    func returnsNilForUnknownProviderID() {
        let selection = CloudProviderSelection(providerID: "inconnu", model: "peu importe")

        let resolved = CloudProviderSelectionResolver.makeProvider(
            for: selection,
            customPresets: [],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )

        #expect(resolved == nil)
    }

    @Test("knownClaudeModels contient bien les 7 modèles connus")
    func knownClaudeModelsHasSevenEntries() {
        let ids = Set(CloudProviderSelectionResolver.knownClaudeModels.map(\.id))
        #expect(ids == [
            "claude-opus-5",
            "claude-sonnet-5",
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-opus-4-6",
            "claude-sonnet-4-6",
            "claude-haiku-4-5"
        ])
    }
}
