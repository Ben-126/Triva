//
//  MLXDeviceCapability.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import Metal

/// Tier de vitesse relative d'une puce Apple Silicon/A-series, déduit du nom du
/// GPU (`MTLDevice.name`) plutôt que d'une table `hw.model -> puce` figée qui
/// casserait à chaque nouvelle génération Apple. MLX tourne sur le GPU (Metal),
/// pas sur le Neural Engine — celui-ci n'entre donc pas dans ce calcul (il sert
/// à Core ML / Apple Intelligence, déjà géré séparément en 0.4).
enum ChipSpeedTier: Int, Sendable, Codable, Comparable, CaseIterable {
    case base
    case pro
    case max
    case ultra

    static func < (lhs: ChipSpeedTier, rhs: ChipSpeedTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// `deviceName` typique : "Apple M4 Pro", "Apple M3 Ultra", "Apple M1",
    /// "Apple A17 Pro GPU" (iPhone), "Apple M4 GPU" (iPad).
    static func parse(deviceName: String) -> ChipSpeedTier {
        let name = deviceName.lowercased()
        if name.contains("ultra") {
            return .ultra
        } else if name.contains("max") {
            return .max
        } else if name.contains("pro") {
            return .pro
        } else {
            return .base
        }
    }
}

/// Abstraction des capacités matérielles pertinentes pour choisir un modèle MLX,
/// isolée du matériel réel pour rester testable (voir `DeviceCapabilityProviding`
/// en 0.3 pour le choix de famille de moteur IA — abstraction séparée et plus
/// large, celle-ci est spécifique au dimensionnement précis d'un modèle MLX).
protocol MLXDeviceCapabilityProviding: Sendable {
    /// Budget mémoire utilisable par le GPU (`MTLDevice.recommendedMaxWorkingSetSize`),
    /// plus fiable que la RAM totale brute pour savoir si un modèle tient sans ramer.
    var gpuWorkingSetBytes: UInt64 { get }
    var chipSpeedTier: ChipSpeedTier { get }
}

/// Détecte les capacités réelles de l'appareil via Metal.
struct SystemMLXDeviceCapabilityProvider: MLXDeviceCapabilityProviding {
    var gpuWorkingSetBytes: UInt64 {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return ProcessInfo.processInfo.physicalMemory
        }
        return UInt64(device.recommendedMaxWorkingSetSize)
    }

    var chipSpeedTier: ChipSpeedTier {
        ChipSpeedTier.parse(deviceName: MTLCreateSystemDefaultDevice()?.name ?? "")
    }
}
