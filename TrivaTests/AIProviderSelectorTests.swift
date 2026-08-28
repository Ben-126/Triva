//
//  AIProviderSelectorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import Testing
@testable import Triva

private struct MockDeviceCapabilities: DeviceCapabilityProviding {
    let isAppleIntelligenceAvailable: Bool
    let physicalMemoryBytes: UInt64
}

@Suite("AIProviderSelector")
struct AIProviderSelectorTests {
    @Test("Recommande Apple Intelligence quand l'appareil le supporte, peu importe la RAM")
    func recommendsAppleIntelligenceWhenAvailable() {
        let capabilities = MockDeviceCapabilities(isAppleIntelligenceAvailable: true, physicalMemoryBytes: 2_000_000_000)

        let recommendation = AIProviderSelector.recommend(for: capabilities)

        #expect(recommendation == AIEngineRecommendation(option: .appleIntelligence))
    }

    @Test("Recommande MLX local quand Apple Intelligence est indisponible")
    func recommendsMLXWhenAppleIntelligenceUnavailable() {
        let capabilities = MockDeviceCapabilities(isAppleIntelligenceAvailable: false, physicalMemoryBytes: 4_000_000_000)

        let recommendation = AIProviderSelector.recommend(for: capabilities)

        #expect(recommendation == AIEngineRecommendation(option: .mlxLocal))
    }
}

@Suite("AIEngineSettingsStore")
struct AIEngineSettingsStoreTests {
    @Test("Persiste et recharge le moteur choisi")
    func persistsSelectedOption() {
        let suiteName = "AIEngineSettingsStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = AIEngineSettingsStore(userDefaults: userDefaults)
        #expect(store.selectedOption == nil)

        store.selectedOption = .cloudBYOK

        let reloaded = AIEngineSettingsStore(userDefaults: userDefaults)
        #expect(reloaded.selectedOption == .cloudBYOK)
    }
}
