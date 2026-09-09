//
//  MLXProvider.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

enum MLXProviderError: Error, Sendable, Equatable {
    case downloadFailed(description: String)
    case modelNotLoaded
    case generationFailed(description: String)
    /// `MLXLanguageModel` (mlx-swift-lm) exige iOS/macOS 27, alors que la
    /// cible de déploiement du projet reste 26.5 — un appareil resté sur un
    /// OS plus ancien ne peut donc pas utiliser MLX local du tout. À
    /// arbitrer avec Ben (monter la cible à 27, ou accepter la limitation
    /// tant qu'iOS 27 n'est pas généralisé) plutôt qu'à masquer.
    case unsupportedOS
}

/// Progression de téléchargement d'un modèle MLX (0.5), exposée à l'UI.
///
/// À ne pas confondre avec `MLXFoundationModels.MLXDownloadProgress` (le
/// singleton `@Observable` interne du module, alimenté automatiquement en
/// parallèle par `MLXLanguageModel` — voir `load` dans `makeLanguageModel`) :
/// ce type-ci est le nôtre, et reste le seul contrat que connaît
/// `MLXModelSelectionCoordinator`.
struct MLXDownloadProgress: Sendable, Equatable {
    let fractionCompleted: Double
}

/// Génération de texte via un modèle MLX téléchargé et chargé en mémoire
/// (0.5), 100% sur l'appareil — porté sur `MLXLanguageModel` de
/// `mlx-swift-lm`, qui conforme MLX au protocole officiel
/// `FoundationModels.LanguageModel`. Le téléchargement, le cache Hugging Face
/// et la reprise restent gérés par `mlx-swift-lm` + `swift-huggingface` ; on
/// impose seulement l'emplacement de stockage et le Wi-Fi obligatoire via les
/// points d'extension `weightsLocation`/`load` de `MLXLanguageModel` :
///
/// - Stockage dans **Application Support** (pas Caches) : l'utilisateur a
///   choisi explicitement de garder ce modèle, le système ne doit jamais le
///   purger silencieusement sous pression disque comme il le ferait avec
///   Caches. Un sous-dossier par identifiant de modèle évite un
///   re-téléchargement au prochain lancement et prépare la gestion multi-
///   modèles prévue en 1.15 (voir espace utilisé, supprimer).
/// - Wi-Fi obligatoire pour tout le catalogue, sans seuil (respecte la limite
///   App Store de 200 Mo en cellulaire — le plus petit modèle la dépasse déjà).
///
/// `MLXLanguageModel` exige iOS/macOS 27 (voir `MLXProviderError.unsupportedOS`) ;
/// ce type reste volontairement sans annotation `@available` pour ne pas faire
/// remonter cette contrainte jusqu'à `MLXModelSelectionCoordinator` ou
/// `AIProviderSelector` — la disponibilité est vérifiée à l'exécution dans
/// `prepare()`.
actor MLXProvider: AIGenerating {
    /// Boîte type-effacée autour d'un `MLXLanguageModel` chargé, pour obtenir
    /// une session fraîche à chaque appel (voir `generate()` — aucune mémoire
    /// de conversation entre deux appels, comme l'ancien code et comme
    /// `AppleIntelligenceProvider.generate()`, puisque `LanguageModelSession`
    /// accumule son propre transcript si on la réutilise). Cette indirection
    /// permet à `MLXProvider` de ne jamais porter l'annotation
    /// `@available(iOS 27, ...)` qu'exige `MLXLanguageModel`, pour ne pas la
    /// faire remonter jusqu'à `MLXModelSelectionCoordinator`/`AIProviderSelector`.
    private struct LoadedModel {
        let makeSession: @Sendable () -> LanguageModelSession
    }

    /// Non-`private` uniquement pour permettre à `MLXModelSelectionResolverTests`
    /// de vérifier que le provider résolu correspond bien à l'entrée attendue —
    /// même pattern que `CloudBYOKProvider.model`/`OpenAICompatibleProvider.model`.
    let entry: MLXModelCatalogEntry
    private var loaded: LoadedModel?
    /// Levier d'éviction du modèle *en cours de construction*, posé dès que
    /// `MLXLanguageModel` existe — donc AVANT `preload()`, pas après. Voir
    /// `cancel()` : c'est justement pendant le téléchargement que ce levier
    /// doit déjà être disponible pour avoir un effet.
    private var evictCurrent: (@Sendable () async -> Void)?

    init(entry: MLXModelCatalogEntry) {
        self.entry = entry
    }

    /// Télécharge (si besoin, sinon réutilise le cache local) et charge le
    /// modèle en mémoire. À appeler avant `generate(prompt:)`.
    func prepare(onProgress: @Sendable @escaping (MLXDownloadProgress) -> Void = { _ in }) async throws {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let model = Self.makeLanguageModel(for: entry, onProgress: onProgress)
            // Posé avant `preload()`, pas après : `cancel()` doit pouvoir
            // évincer ce modèle pendant que le téléchargement est en cours,
            // c'est le seul moment où ça a un effet (voir `cancel()`).
            evictCurrent = { await model.evict() }

            do {
                try await model.preload()
            } catch {
                evictCurrent = nil
                throw MLXProviderError.downloadFailed(description: String(describing: error))
            }

            loaded = LoadedModel(makeSession: { LanguageModelSession(model: model) })
        } else {
            throw MLXProviderError.unsupportedOS
        }
    }

    func generate(prompt: String) async throws -> String {
        guard let loaded else {
            throw MLXProviderError.modelNotLoaded
        }

        do {
            let response = try await loaded.makeSession().respond(to: prompt)
            return response.content
        } catch {
            throw MLXProviderError.generationFailed(description: String(describing: error))
        }
    }

    /// Vrai streaming token-par-token, même principe qu'
    /// `AppleIntelligenceProvider.streamGenerate(prompt:)`. `nonisolated` est
    /// nécessaire ici : `AIGenerating.streamGenerate` n'est pas `async`, donc
    /// un appelant hors de l'acteur doit pouvoir l'appeler sans `await` — la
    /// lecture de `loaded` (état isolé à l'acteur) se fait alors via un
    /// `await self.loaded` explicite à l'intérieur de la tâche, avant tout
    /// streaming réel, exactement comme le `guard let loaded` de `generate()`.
    nonisolated func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let loaded = await self.loaded else {
                    continuation.finish(throwing: MLXProviderError.modelNotLoaded)
                    return
                }

                do {
                    for try await snapshot in loaded.makeSession().streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: MLXProviderError.generationFailed(description: String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// À appeler quand l'utilisateur annule un téléchargement ou abandonne ce
    /// provider (voir `MLXModelSelectionCoordinator.cancelDownload()` /
    /// `.chooseAnotherModel()`).
    ///
    /// Évince le modèle du registre des chargements en cours de
    /// `MLXLanguageModel` — `ModelCache.load` protège son cache par
    /// `guard loadingTasks[modelID] === loadTask else { return loaded }` avant
    /// d'écrire `containers[modelID]`, et c'est justement `evict()` qui
    /// retire l'entrée de `loadingTasks`. Appelé pendant le téléchargement
    /// (le seul moment où `evictCurrent` est déjà posé, voir `prepare()`),
    /// ça garantit qu'un résultat obtenu après annulation ne sera jamais mis
    /// en cache ni réutilisé par un prochain `prepare()`.
    ///
    /// LIMITE CONNUE du module `mlx-swift-lm` (voir le commentaire de
    /// `ModelCache.remove` dans `MLXLanguageModel.swift` : "the load path is
    /// not cancellation-aware today") : ceci n'interrompt PAS le transfert
    /// réseau lui-même. Le téléchargement continue en tâche de fond jusqu'à
    /// sa fin naturelle (succès ou échec) même après annulation — seul son
    /// résultat est écarté. L'ancienne implémentation (actor-only,
    /// `HubClient`/`Downloader` directement awaited depuis la Task annulée
    /// par l'appelant) arrêtait réellement le transfert à la prochaine
    /// vérification de cancellation coopérative. C'est une régression de
    /// comportement inhérente à cette version du module, pas contournable
    /// depuis l'app — à arbitrer avec Ben.
    func cancel() async {
        await evictCurrent?()
        evictCurrent = nil
        loaded = nil
    }

    /// Construit le `MLXLanguageModel` pour une entrée du catalogue, en
    /// réinjectant dans `weightsLocation`/`load` exactement la même politique
    /// de stockage et de réseau que l'ancienne implémentation actor-only
    /// (voir le commentaire de tête). `load` reçoit un `progressHandler`
    /// déjà branché par `MLXLanguageModel` sur son propre
    /// `MLXDownloadProgress.shared` interne : on le relaie tel quel en plus
    /// d'alimenter notre `onProgress` à nous, pour ne rien perdre côté
    /// framework tout en gardant le contrat existant avec l'UI.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private static func makeLanguageModel(
        for entry: MLXModelCatalogEntry,
        onProgress: @Sendable @escaping (MLXDownloadProgress) -> Void
    ) -> MLXLanguageModel {
        let storageDirectory = modelStorageDirectory(for: entry.id)
        let configuration = resolvedConfiguration(for: entry)

        return MLXLanguageModel(
            configuration: configuration,
            weightsLocation: { id in
                let cache = HubCache(location: .fixed(directory: storageDirectory))
                guard let repo = Repo.ID(rawValue: id) else { return cache.cacheDirectory }
                if let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
                    let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
                {
                    return snapshot
                }
                return cache.repoDirectory(repo: repo, kind: .model)
            },
            load: { configuration, progressHandler in
                let hubClient = HubClient(
                    session: wifiOnlySession(),
                    cache: HubCache(location: .fixed(directory: storageDirectory))
                )
                return try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(hubClient),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: configuration
                ) { progress in
                    onProgress(MLXDownloadProgress(fractionCompleted: progress.fractionCompleted))
                    progressHandler(progress)
                }
            }
        )
    }

    /// Résout la config MLX pour une entrée du catalogue : passe par le
    /// `LLMRegistry` (EOS tokens, prompt par défaut déjà connus pour ce
    /// modèle) quand `registryKey` existe, sinon une config minimale pointant
    /// directement sur `huggingFaceRepo`, comme le faisait l'ancien code.
    /// Logique pure, isolée de `makeLanguageModel` pour rester testable sans
    /// dépendre d'iOS/macOS 27 (`ModelConfiguration`/`LLMRegistry` n'ont pas
    /// cette contrainte).
    static func resolvedConfiguration(for entry: MLXModelCatalogEntry) -> ModelConfiguration {
        entry.registryKey != nil
            ? LLMRegistry.shared.configuration(id: entry.huggingFaceRepo)
            : ModelConfiguration(id: entry.huggingFaceRepo)
    }

    static func modelStorageDirectory(for modelId: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("MLXModels", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
    }

    static func wifiOnlySession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = false
        return URLSession(configuration: configuration)
    }
}
