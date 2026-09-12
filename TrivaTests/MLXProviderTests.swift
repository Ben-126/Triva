//
//  MLXProviderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import MLXLMCommon
import Testing
@testable import Triva

@Suite("MLXProvider")
struct MLXProviderTests {
    @Test("wifiOnlySession() interdit systématiquement le cellulaire — garde-fou App Store")
    func wifiOnlySessionForbidsCellular() {
        let session = MLXProvider.wifiOnlySession()

        #expect(session.configuration.allowsCellularAccess == false)
    }

    @Test("modelStorageDirectory() range chaque modèle dans Application Support, pas Caches")
    func modelStorageDirectoryUsesApplicationSupport() {
        let directory = MLXProvider.modelStorageDirectory(for: "qwen3-0_6b-4bit")

        #expect(directory.path.contains("Application Support"))
        #expect(!directory.path.contains("/Caches/"))
        #expect(directory.lastPathComponent == "qwen3-0_6b-4bit")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "MLXModels")
    }

    @Test("modelStorageDirectory() isole chaque modèle dans son propre sous-dossier")
    func modelStorageDirectoryIsolatesModels() {
        let first = MLXProvider.modelStorageDirectory(for: "model-a")
        let second = MLXProvider.modelStorageDirectory(for: "model-b")

        #expect(first != second)
    }

    @Test("Utilise la config du LLMRegistry (EOS tokens inclus) quand registryKey existe")
    func resolvedConfigurationUsesRegistryWhenKeyExists() {
        let entry = Self.makeEntry(
            id: "qwen3-0_6b-4bit",
            huggingFaceRepo: "mlx-community/Qwen3-0.6B-4bit",
            registryKey: "qwen3_0_6b_4bit"
        )

        let configuration = MLXProvider.resolvedConfiguration(for: entry)

        #expect(configuration.name == entry.huggingFaceRepo)
        #expect(configuration.extraEOSTokens.contains("<|im_end|>"))
    }

    @Test("Retombe sur une config minimale pointant directement sur huggingFaceRepo quand registryKey est nil")
    func resolvedConfigurationFallsBackWithoutRegistryKey() {
        let entry = Self.makeEntry(
            id: "qwen3-32b-4bit",
            huggingFaceRepo: "mlx-community/Qwen3-32B-4bit",
            registryKey: nil
        )

        let configuration = MLXProvider.resolvedConfiguration(for: entry)

        #expect(configuration.name == entry.huggingFaceRepo)
        #expect(configuration.extraEOSTokens.isEmpty)
    }

    @Test("generate() échoue avec modelNotLoaded tant que prepare() n'a pas été appelé")
    func generateFailsBeforePrepare() async throws {
        let entry = Self.makeEntry(
            id: "qwen3-0_6b-4bit",
            huggingFaceRepo: "mlx-community/Qwen3-0.6B-4bit",
            registryKey: "qwen3_0_6b_4bit"
        )
        let provider = MLXProvider(entry: entry)

        await #expect(throws: MLXProviderError.modelNotLoaded) {
            try await provider.generate(prompt: "test")
        }
    }

    @Test("prepare() échoue immédiatement avec simulatorUnsupported sur le Simulateur — jamais de crash MLX (SIGABRT) faute de vrai GPU Metal (voir le rapport de crash de la revue 0.8)")
    func prepareFailsImmediatelyOnSimulator() async throws {
        let entry = Self.makeEntry(
            id: "qwen3-0_6b-4bit",
            huggingFaceRepo: "mlx-community/Qwen3-0.6B-4bit",
            registryKey: "qwen3_0_6b_4bit"
        )
        let provider = MLXProvider(entry: entry)

        await #expect(throws: MLXProviderError.simulatorUnsupported) {
            try await provider.prepare()
        }
    }

    @Test("streamGenerate() finish immédiatement avec modelNotLoaded tant que prepare() n'a pas été appelé, sans yield")
    func streamGenerateFinishesImmediatelyBeforePrepare() async throws {
        let entry = Self.makeEntry(
            id: "qwen3-0_6b-4bit",
            huggingFaceRepo: "mlx-community/Qwen3-0.6B-4bit",
            registryKey: "qwen3_0_6b_4bit"
        )
        let provider = MLXProvider(entry: entry)

        var received: [String] = []
        await #expect(throws: MLXProviderError.modelNotLoaded) {
            for try await chunk in provider.streamGenerate(prompt: "test") {
                received.append(chunk)
            }
        }
        #expect(received.isEmpty)
    }

    private static func makeEntry(
        id: String,
        huggingFaceRepo: String,
        registryKey: String?
    ) -> MLXModelCatalogEntry {
        MLXModelCatalogEntry(
            id: id,
            displayName: id,
            huggingFaceRepo: huggingFaceRepo,
            registryKey: registryKey,
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
}
