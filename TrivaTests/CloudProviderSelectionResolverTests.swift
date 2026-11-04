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

@MainActor
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

    @Test("Id Claude inconnu : provider construit avec les capacités par défaut")
    func buildsUnknownClaudeModelWithDefaultCapabilities() throws {
        let selection = CloudProviderSelection(providerID: CloudProviderSelectionResolver.claudeProviderID, model: "claude-modele-inconnu")

        let resolved = CloudProviderSelectionResolver.makeProvider(
            for: selection,
            customPresets: [],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )

        let provider = try #require(resolved as? CloudBYOKProvider)
        #expect(provider.model.id == "claude-modele-inconnu")
        #expect(provider.model.capabilities == CloudProviderSelectionResolver.unknownClaudeModelCapabilities)
        #expect(!provider.model.capabilities.samplingParams)
        #expect(!provider.model.capabilities.adaptiveThinking)
        #expect(provider.model.capabilities.effortLevels.isEmpty)
    }

    @Test("Id Claude connu : capacités précises du package conservées")
    func knownClaudeModelKeepsPackageCapabilities() throws {
        let selection = CloudProviderSelection(providerID: CloudProviderSelectionResolver.claudeProviderID, model: "claude-haiku-4-5")

        let resolved = CloudProviderSelectionResolver.makeProvider(
            for: selection,
            customPresets: [],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        )

        let provider = try #require(resolved as? CloudBYOKProvider)
        #expect(provider.model == ClaudeModel.haiku4_5)
    }

    @Test("Id Claude daté : rapproché de l'alias connu et de ses capacités")
    func datedClaudeIDMapsToKnownAlias() {
        #expect(CloudProviderSelectionResolver.claudeModel(forID: "claude-haiku-4-5-20251001") == ClaudeModel.haiku4_5)
        #expect(CloudProviderSelectionResolver.claudeModel(forID: "claude-haiku-4-5-beta") == nil)
        #expect(CloudProviderSelectionResolver.resolvedClaudeModel(forID: "claude-opus-5") == ClaudeModel.opus5)
    }

    @Test("Modèle Claude vide : nil")
    func returnsNilForEmptyClaudeModel() {
        let selection = CloudProviderSelection(providerID: CloudProviderSelectionResolver.claudeProviderID, model: "")

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

    /// Le nom porté par le provider est celui des messages d'erreur typés
    /// (bug 6) : « Clé API refusée par Mon LLM… ». Il doit suivre le preset
    /// RÉSOLU, personnalisé compris, puisque `makeProvider` n'utilise pas
    /// `init(preset:)`.
    @Test("Le provider compatible OpenAI porte le nom affiché du preset, personnalisé compris (bug 6)")
    func openAICompatibleProviderCarriesPresetDisplayName() throws {
        let groq = try #require(CloudProviderCatalog.presets.first { $0.id == "groq" })
        let custom = CloudProviderPreset(
            id: "custom:abc",
            displayName: "Mon LLM",
            baseURL: URL(string: "https://llm.example.com/v1")!,
            defaultModel: "mon-modele-defaut"
        )

        let catalogProvider = CloudProviderSelectionResolver.makeProvider(
            for: CloudProviderSelection(providerID: groq.id, model: groq.defaultModel),
            customPresets: [],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        ) as? OpenAICompatibleProvider
        let customProvider = CloudProviderSelectionResolver.makeProvider(
            for: CloudProviderSelection(providerID: custom.id, model: "mon-modele-choisi"),
            customPresets: [custom],
            keyStore: MockAPIKeyStore(storedKey: "sk-test")
        ) as? OpenAICompatibleProvider

        #expect(catalogProvider?.providerName == "Groq")
        #expect(customProvider?.providerName == "Mon LLM")
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
