//
//  GatedLanguageModel.swift
//  Triva
//
//  Mission M (25/11) : branche `LocalGPUGate` dans mlx-swift-lm SANS modifier la dépendance. Le modèle chargé est
//  enveloppé (`ModelContainer.update`) : chaque appel du modèle, donc chaque mot produit et chaque morceau de question
//  lu, passe d'abord par la barrière. Seulement là où le système coupe le GPU en arrière-plan (iOS, iPadOS).
//

import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Enveloppe transparente : même cache, mêmes sorties, mêmes conventions de dialogue (raisonnement, outils).
nonisolated final class GatedLanguageModel: Module, LanguageModel {
    /// Longueur maximale d'un morceau de question envoyé d'un coup (512 par défaut dans mlx-swift-lm). Plus court :
    /// l'attente des tampons en cours, quand l'app s'éclipse, reste bien en dessous de la seconde.
    static let prefillStepLimit = 256

    let base: any LanguageModel
    private let gate: LocalGPUGate
    private let drain: @Sendable () -> Void

    /// `drain` : attend la fin des tampons déjà envoyés (couture de test).
    init(
        _ base: any LanguageModel,
        gate: LocalGPUGate,
        drain: @escaping @Sendable () -> Void = { Stream.gpu.synchronize() }
    ) {
        self.base = base
        self.gate = gate
        self.drain = drain
        super.init()
        // Comme `ModelContext.init` : un modèle d'inférence n'est jamais en mode entraînement.
        train(false)
    }

    // MARK: Étapes du modèle

    func prepare() throws {
        gate.checkpoint(drain: drain)
        try base.prepare()
    }

    func prepare(
        _ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters
    ) throws -> PrepareResult {
        gate.checkpoint(drain: drain)
        return try base.prepare(input, cache: cache, state: state, prefill: Self.gated(prefill, gate: gate, drain: drain))
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        gate.checkpoint(drain: drain)
        return base(input, cache: cache, state: state)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        gate.checkpoint(drain: drain)
        return base(inputs, cache: cache)
    }

    /// Lecture de la question : la barrière est passée après chaque morceau (le rappel `progress` suit l'envoi du
    /// morceau), et les morceaux sont plus courts.
    static func gated(
        _ prefill: PrefillParameters, gate: LocalGPUGate, drain: @escaping @Sendable () -> Void
    ) -> PrefillParameters {
        var gated = prefill
        gated.stepSize = min(prefill.stepSize ?? prefillStepLimit, prefillStepLimit)
        let report = prefill.progress
        gated.progress = { processed, total in
            report?(processed, total)
            gate.checkpoint(drain: drain)
        }
        return gated
    }

    // MARK: Transmis tel quel

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        try base.newCache(parameters: parameters)
    }

    func cacheStatus(parameters: GenerateParameters?) throws -> KVCacheStatus {
        try base.cacheStatus(parameters: parameters)
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        base.sanitize(weights: weights)
    }

    func sanitize(weights: [String: MLXArray], metadata: [String: String]) -> [String: MLXArray] {
        base.sanitize(weights: weights, metadata: metadata)
    }

    var toolCallFormat: ToolCallFormat? { base.toolCallFormat }
    var reasoningConfig: ReasoningConfig? { base.reasoningConfig }
}

/// Enveloppe le téléchargement : le CHARGEMENT en mémoire qui suit n'a lieu que l'app au premier plan (les poids se
/// lisent sur le processeur, mais la fin du chargement peut toucher au GPU). Un téléchargement fini en arrière-plan
/// attend donc le retour, sans jamais échouer. Le travail est compté jusqu'à `load.finish()`.
nonisolated struct GatedDownloader: Downloader {
    let base: any Downloader
    let gate: LocalGPUGate
    let load: GatedLoad

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let url = try await base.download(
            id: id, revision: revision, matching: patterns, useLatest: useLatest, progressHandler: progressHandler
        )
        load.replace(with: try await gate.begin(backgroundPatience: nil))
        return url
    }
}

/// Le travail de chargement en cours (un par chargement, partagé entre `GatedDownloader` et l'appelant).
nonisolated final class GatedLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var work: LocalGPUWork?

    func replace(with newWork: LocalGPUWork) {
        let old = lock.withLock {
            defer { work = newWork }
            return work
        }
        old?.finish()
    }

    func finish() {
        let old = lock.withLock {
            defer { work = nil }
            return work
        }
        old?.finish()
    }
}
