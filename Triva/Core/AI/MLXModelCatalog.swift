//
//  MLXModelCatalog.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

/// Une entrée du catalogue de modèles MLX proposés (voir `Resources/mlx-models.json`).
/// Une seule famille (Qwen3) sur toute l'échelle, `capabilityScore` croissant sert de
/// clé de tri pour la logique de recommandation par index (`MLXModelRecommender`).
struct MLXModelCatalogEntry: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let displayName: String
    let huggingFaceRepo: String
    /// Clé dans le `LLMRegistry` de `mlx-swift-lm`, `nil` si le modèle doit être
    /// chargé via une `ModelConfiguration` custom pointant vers `huggingFaceRepo`.
    let registryKey: String?
    let license: String
    let downloadSizeBytes: UInt64
    /// Seuil de `gpuWorkingSetBytes` (voir `MLXDeviceCapabilityProviding`) à partir
    /// duquel ce modèle est considéré comme tenant confortablement en mémoire.
    let recommendedGPUWorkingSetBytes: UInt64
    let capabilityScore: Int
    let supportsThinkingMode: Bool
    let isMixtureOfExperts: Bool
    /// `true` pour un modèle qui ne doit jamais être recommandé automatiquement
    /// (voir Qwen3-32B) — accessible uniquement via la liste complète.
    let isAdvancedOnly: Bool
    let summary: String
    let strengths: [String]
    let tradeoffs: [String]
}

enum MLXModelCatalogError: Error, Sendable, Equatable {
    case resourceMissing
    case invalidFormat
}

/// Charge le catalogue statique de modèles MLX depuis `Resources/mlx-models.json`,
/// trié par capacité croissante.
enum MLXModelCatalog {
    static func load(bundle: Bundle = .main, resourceName: String = "mlx-models") throws -> [MLXModelCatalogEntry] {
        guard let fileURL = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw MLXModelCatalogError.resourceMissing
        }

        return try parse(Data(contentsOf: fileURL))
    }

    /// Logique de décodage/tri pure, isolée du chargement depuis un bundle pour
    /// rester testable sans dépendre du système de fichiers.
    static func parse(_ data: Data) throws -> [MLXModelCatalogEntry] {
        let decoded = try JSONDecoder().decode(CatalogFile.self, from: data)

        guard !decoded.models.isEmpty else {
            throw MLXModelCatalogError.invalidFormat
        }

        return decoded.models.sorted { $0.capabilityScore < $1.capabilityScore }
    }

    private struct CatalogFile: Decodable {
        let models: [MLXModelCatalogEntry]
    }
}
