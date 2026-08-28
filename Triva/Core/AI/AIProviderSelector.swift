//
//  AIProviderSelector.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import FoundationModels

/// Les 3 familles de moteur IA proposées à l'utilisateur (voir 0.3 du plan).
enum AIEngineOption: String, Sendable, CaseIterable, Codable {
    case appleIntelligence
    case mlxLocal
    case cloudBYOK
}

struct AIEngineRecommendation: Sendable, Equatable {
    let option: AIEngineOption
}

/// Abstraction des capacités de l'appareil, pour pouvoir tester
/// `AIProviderSelector` sans dépendre du matériel réel.
protocol DeviceCapabilityProviding: Sendable {
    var isAppleIntelligenceAvailable: Bool { get }
    var physicalMemoryBytes: UInt64 { get }
}

/// Détecte les capacités réelles de l'appareil : disponibilité d'Apple
/// Intelligence (Foundation Models) et RAM physique.
struct SystemDeviceCapabilityProvider: DeviceCapabilityProviding {
    var isAppleIntelligenceAvailable: Bool {
        AppleIntelligenceProvider.mapAvailability(SystemLanguageModel.default.availability) == nil
    }

    var physicalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }
}

/// Logique pure et déterministe de recommandation du moteur IA par défaut,
/// isolée du matériel réel via `DeviceCapabilityProviding` pour rester testable.
///
/// Ne recommande que la famille de moteur (Apple Intelligence / MLX local) —
/// une fois "MLX local" choisi, `MLXModelRecommender` (0.5) détermine le
/// modèle précis à proposer parmi le catalogue, à partir d'une détection de
/// capacité/vitesse plus fine (RAM GPU + génération de puce).
enum AIProviderSelector {
    static func recommend(for capabilities: any DeviceCapabilityProviding) -> AIEngineRecommendation {
        guard !capabilities.isAppleIntelligenceAvailable else {
            return AIEngineRecommendation(option: .appleIntelligence)
        }

        return AIEngineRecommendation(option: .mlxLocal)
    }
}

/// Stocke le choix de moteur IA de l'utilisateur, pour un accès ultérieur
/// depuis les Réglages (1.15) — persistance simple, aucune donnée sensible.
@Observable
final class AIEngineSettingsStore {
    private static let storageKey = "ai.engine.selectedOption"
    private let userDefaults: UserDefaults

    var selectedOption: AIEngineOption? {
        didSet {
            userDefaults.set(selectedOption?.rawValue, forKey: Self.storageKey)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let rawValue = userDefaults.string(forKey: Self.storageKey) {
            selectedOption = AIEngineOption(rawValue: rawValue)
        } else {
            selectedOption = nil
        }
    }
}
