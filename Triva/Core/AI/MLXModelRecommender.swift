//
//  MLXModelRecommender.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

/// Résultat de la recommandation : le modèle conseillé pour l'appareil détecté,
/// entouré de ses 2 voisins dans le catalogue (± 1 en capacité) pour l'écran de
/// choix initial (voir 0.5 du plan). `nil` pour un voisin en bout de catalogue.
struct MLXModelRecommendation: Sendable, Equatable {
    let recommended: MLXModelCatalogEntry
    let morePerformantSlower: MLXModelCatalogEntry?
    let fasterLessPerformant: MLXModelCatalogEntry?
}

/// Logique pure et déterministe de recommandation d'un modèle MLX précis,
/// isolée du matériel réel via `MLXDeviceCapabilityProviding` pour rester
/// testable. Le catalogue est un tableau trié par capacité croissante ; on
/// calcule un index recommandé et on expose ses voisins immédiats plutôt que
/// des tiers rigides.
enum MLXModelRecommender {
    static func recommend(
        from catalog: [MLXModelCatalogEntry],
        for capabilities: any MLXDeviceCapabilityProviding
    ) -> MLXModelRecommendation? {
        // Qwen3-32B (isAdvancedOnly) n'est jamais recommandé automatiquement,
        // même sur un Mac Ultra qui aurait largement la RAM : il reste
        // accessible uniquement via la liste complète.
        let recommendable = catalog.filter { !$0.isAdvancedOnly }
        guard !recommendable.isEmpty else { return nil }

        // Index le plus haut dont le besoin GPU tient dans la capacité détectée.
        var capacityIndex = 0
        for (index, entry) in recommendable.enumerated()
        where entry.recommendedGPUWorkingSetBytes <= capabilities.gpuWorkingSetBytes {
            capacityIndex = index
        }

        // Sur une puce "base" (pas de suffixe Pro/Max/Ultra), on redescend d'un
        // cran par rapport à la capacité max pour privilégier la fluidité.
        let speedAdjustedIndex = capabilities.chipSpeedTier == .base
            ? max(0, capacityIndex - 1)
            : capacityIndex

        let recommendedIndex = min(speedAdjustedIndex, recommendable.count - 1)

        return MLXModelRecommendation(
            recommended: recommendable[recommendedIndex],
            morePerformantSlower: recommendable[safe: recommendedIndex + 1],
            fasterLessPerformant: recommendable[safe: recommendedIndex - 1]
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
