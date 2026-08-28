//
//  MLXModelRecommenderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import Testing
@testable import Triva

private struct MockMLXDeviceCapabilities: MLXDeviceCapabilityProviding {
    let gpuWorkingSetBytes: UInt64
    let chipSpeedTier: ChipSpeedTier
}

@Suite("MLXModelRecommender")
struct MLXModelRecommenderTests {
    // Catalogue de test à 4 paliers : 1 Go / 4 Go / 8 Go / 16 Go (le dernier "advancedOnly").
    private static let catalog: [MLXModelCatalogEntry] = [
        makeEntry(id: "tiny", score: 1, requiredBytes: 1_000_000_000),
        makeEntry(id: "small", score: 2, requiredBytes: 4_000_000_000),
        makeEntry(id: "medium", score: 3, requiredBytes: 8_000_000_000),
        makeEntry(id: "advanced", score: 4, requiredBytes: 16_000_000_000, advancedOnly: true),
    ]

    @Test("Recommande le plus petit modèle quand l'appareil est très limité")
    func recommendsSmallestOnConstrainedDevice() throws {
        let capabilities = MockMLXDeviceCapabilities(gpuWorkingSetBytes: 500_000_000, chipSpeedTier: .base)

        let recommendation = try #require(MLXModelRecommender.recommend(from: Self.catalog, for: capabilities))

        #expect(recommendation.recommended.id == "tiny")
        #expect(recommendation.fasterLessPerformant == nil)
        #expect(recommendation.morePerformantSlower?.id == "small")
    }

    @Test("Redescend d'un cran sur une puce base par rapport à la capacité maximale")
    func stepsDownOneNotchOnBaseChip() throws {
        let capabilities = MockMLXDeviceCapabilities(gpuWorkingSetBytes: 8_000_000_000, chipSpeedTier: .base)

        let recommendation = try #require(MLXModelRecommender.recommend(from: Self.catalog, for: capabilities))

        #expect(recommendation.recommended.id == "small")
        #expect(recommendation.morePerformantSlower?.id == "medium")
        #expect(recommendation.fasterLessPerformant?.id == "tiny")
    }

    @Test("Va jusqu'à la capacité maximale sur une puce Pro/Max/Ultra, sans redescendre d'un cran", arguments: [
        ChipSpeedTier.pro, ChipSpeedTier.max, ChipSpeedTier.ultra,
    ])
    func doesNotStepDownOnFasterChips(tier: ChipSpeedTier) throws {
        let capabilities = MockMLXDeviceCapabilities(gpuWorkingSetBytes: 8_000_000_000, chipSpeedTier: tier)

        let recommendation = try #require(MLXModelRecommender.recommend(from: Self.catalog, for: capabilities))

        #expect(recommendation.recommended.id == "medium")
    }

    @Test("Ne recommande jamais un modèle isAdvancedOnly, même avec largement assez de capacité")
    func neverRecommendsAdvancedOnlyModel() throws {
        let capabilities = MockMLXDeviceCapabilities(gpuWorkingSetBytes: 200_000_000_000, chipSpeedTier: .ultra)

        let recommendation = try #require(MLXModelRecommender.recommend(from: Self.catalog, for: capabilities))

        #expect(recommendation.recommended.id == "medium")
        #expect(recommendation.morePerformantSlower == nil)
    }

    @Test("Retourne nil quand le catalogue ne contient que des modèles avancés")
    func returnsNilWhenCatalogHasOnlyAdvancedModels() {
        let capabilities = MockMLXDeviceCapabilities(gpuWorkingSetBytes: 200_000_000_000, chipSpeedTier: .ultra)
        let advancedOnlyCatalog = [Self.makeEntry(id: "advanced", score: 1, requiredBytes: 1, advancedOnly: true)]

        let recommendation = MLXModelRecommender.recommend(from: advancedOnlyCatalog, for: capabilities)

        #expect(recommendation == nil)
    }

    private static func makeEntry(
        id: String,
        score: Int,
        requiredBytes: UInt64,
        advancedOnly: Bool = false
    ) -> MLXModelCatalogEntry {
        MLXModelCatalogEntry(
            id: id,
            displayName: id,
            huggingFaceRepo: "mlx-community/\(id)",
            registryKey: nil,
            license: "Apache 2.0",
            downloadSizeBytes: 1,
            recommendedGPUWorkingSetBytes: requiredBytes,
            capabilityScore: score,
            supportsThinkingMode: true,
            isMixtureOfExperts: false,
            isAdvancedOnly: advancedOnly,
            summary: "",
            strengths: [],
            tradeoffs: []
        )
    }
}
