//
//  MLXProvider.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

enum MLXProviderError: Error, Sendable, Equatable {
    case downloadFailed(description: String)
    case modelNotLoaded
    case generationFailed(description: String)
}

/// Progression de téléchargement d'un modèle MLX (0.5), exposée à l'UI.
struct MLXDownloadProgress: Sendable, Equatable {
    let fractionCompleted: Double
}

/// Génération de texte via un modèle MLX téléchargé et chargé en mémoire (0.5),
/// 100% sur l'appareil. Le téléchargement, le cache Hugging Face et la reprise
/// sont gérés par `mlx-swift-lm` + `swift-huggingface` — on impose seulement
/// l'emplacement de stockage et le Wi-Fi obligatoire :
///
/// - Stockage dans **Application Support** (pas Caches) : l'utilisateur a
///   choisi explicitement de garder ce modèle, le système ne doit jamais le
///   purger silencieusement sous pression disque comme il le ferait avec
///   Caches. Un sous-dossier par identifiant de modèle évite un
///   re-téléchargement au prochain lancement et prépare la gestion multi-
///   modèles prévue en 1.15 (voir espace utilisé, supprimer).
/// - Wi-Fi obligatoire pour tout le catalogue, sans seuil (respecte la limite
///   App Store de 200 Mo en cellulaire — le plus petit modèle la dépasse déjà).
actor MLXProvider: AIGenerating {
    private let entry: MLXModelCatalogEntry
    private var container: ModelContainer?

    init(entry: MLXModelCatalogEntry) {
        self.entry = entry
    }

    /// Télécharge (si besoin, sinon réutilise le cache local) et charge le
    /// modèle en mémoire. À appeler avant `generate(prompt:)`.
    func prepare(onProgress: @Sendable @escaping (MLXDownloadProgress) -> Void = { _ in }) async throws {
        let hubClient = HubClient(
            session: Self.wifiOnlySession(),
            cache: HubCache(location: .fixed(directory: Self.modelStorageDirectory(for: entry.id)))
        )
        let configuration = ModelConfiguration(id: entry.huggingFaceRepo)

        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(hubClient),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration
            ) { progress in
                onProgress(MLXDownloadProgress(fractionCompleted: progress.fractionCompleted))
            }
        } catch {
            throw MLXProviderError.downloadFailed(description: String(describing: error))
        }
    }

    func generate(prompt: String) async throws -> String {
        guard let container else {
            throw MLXProviderError.modelNotLoaded
        }

        do {
            let input = try await container.prepare(input: UserInput(prompt: prompt))
            let stream = try await container.generate(input: input, parameters: GenerateParameters())

            var output = ""
            for await event in stream {
                if let chunk = event.chunk {
                    output += chunk
                }
            }
            return output
        } catch {
            throw MLXProviderError.generationFailed(description: String(describing: error))
        }
    }

    private static func modelStorageDirectory(for modelId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("MLXModels", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
    }

    private static func wifiOnlySession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = false
        return URLSession(configuration: configuration)
    }
}
