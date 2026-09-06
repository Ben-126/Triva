//
//  MLXModelSelectionResolverTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 06/09/2026.
//

import Testing
import Foundation
@testable import Triva

@Suite("MLXModelSelectionResolver")
struct MLXModelSelectionResolverTests {
    private static func makeEntry(id: String) -> MLXModelCatalogEntry {
        MLXModelCatalogEntry(
            id: id,
            displayName: id,
            huggingFaceRepo: "mlx-community/\(id)",
            registryKey: nil,
            license: "Apache 2.0",
            downloadSizeBytes: 1,
            recommendedGPUWorkingSetBytes: 1,
            capabilityScore: 1,
            supportsThinkingMode: true,
            isMixtureOfExperts: false,
            isAdvancedOnly: false,
            summary: "",
            strengths: [],
            tradeoffs: []
        )
    }

    @Test("Résout un MLXProvider pour l'entrée du catalogue correspondant à l'id")
    func resolvesProviderForKnownModelID() async {
        let entry = Self.makeEntry(id: "qwen3-1_7b-4bit")
        let catalog = [Self.makeEntry(id: "qwen3-0_6b-4bit"), entry]

        let resolved = MLXModelSelectionResolver.makeProvider(modelID: "qwen3-1_7b-4bit", catalog: catalog)

        let provider = try? #require(resolved)
        let resolvedEntry = await provider?.entry
        #expect(resolvedEntry == entry)
    }

    @Test("Renvoie nil si l'id ne correspond à aucune entrée du catalogue")
    func returnsNilForUnknownModelID() {
        let catalog = [Self.makeEntry(id: "qwen3-0_6b-4bit")]

        let resolved = MLXModelSelectionResolver.makeProvider(modelID: "modele-inconnu", catalog: catalog)

        #expect(resolved == nil)
    }

    @Test("Renvoie nil pour un catalogue vide")
    func returnsNilForEmptyCatalog() {
        let resolved = MLXModelSelectionResolver.makeProvider(modelID: "qwen3-0_6b-4bit", catalog: [])

        #expect(resolved == nil)
    }
}
