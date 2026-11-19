//
//  MLXProviderPool.swift
//  Triva
//
//  Created by ben podrojsky on 19/11/2026.
//

import Foundation
import Observation

/// Modèle local que le pool sait charger et décharger (couture de test : les tests passent un
/// double, l'app passe `MLXProvider`). `AnyObject` : le pool compare les instances (`===`).
nonisolated protocol PoolableLocalModel: AIGenerating, AnyObject {
    /// Charge le modèle en mémoire (télécharge d'abord s'il le faut).
    func loadIntoMemory() async throws
    /// Libère la mémoire du modèle. Ensuite, toute génération sur cette instance échoue.
    func unloadFromMemory() async
}

/// Modèle que l'écran de choix d'un modèle fait ESSAYER avant de le valider (chantier 2.2, mission G1) :
/// en plus du pool, il sait télécharger avec une progression.
nonisolated protocol TrialLocalModel: PoolableLocalModel {
    func loadIntoMemory(onProgress: @escaping @Sendable (MLXDownloadProgress) -> Void) async throws
}

extension MLXProvider: TrialLocalModel {
    func loadIntoMemory(onProgress: @escaping @Sendable (MLXDownloadProgress) -> Void) async throws {
        try await prepare(onProgress: onProgress)
    }
}

extension MLXProvider: PoolableLocalModel {
    func loadIntoMemory() async throws {
        try await prepare()
    }

    /// `cancel()` retire le modèle du cache de `mlx-swift-lm` (ses poids sont libérés dès que la
    /// dernière génération en cours les rend) et oublie la session : c'est bien un déchargement.
    func unloadFromMemory() async {
        await cancel()
    }
}

/// Le modèle MLX de l'app, partagé par toutes les fenêtres (chantier 2.2, mission M3).
///
/// ## Ce qui existait, ce qui change
/// `mlx-swift-lm` garde déjà les poids dans un cache global par identifiant : deux fenêtres sur le
/// même modèle ne le chargeaient PAS deux fois. Mais rien ne le libérait jamais : changer de modèle
/// laissait l'ancien en mémoire (plusieurs Go) jusqu'à la fermeture de l'app, comme quitter MLX pour
/// un autre moteur. Et deux fenêtres qui posaient une question en même temps se bloquaient l'une
/// l'autre sans le dire. Le pool :
/// - garde UN modèle résident, une seule instance par identifiant, chargée une seule fois même si
///   plusieurs fenêtres la demandent en même temps ;
/// - décharge l'ancien modèle dès que la sélection change (Réglages, autre fenêtre, suppression du
///   modèle) et quand plus aucune fenêtre MLX n'existe ;
/// - fait passer générations, chargements et déchargements par UNE file (`turns`) : jamais deux
///   modèles en mémoire, et la fenêtre qui attend affiche pourquoi.
///
/// Une génération sur un modèle remplacé entre-temps échoue (`MLXProviderError.modelNotLoaded`)
/// plutôt que de recharger l'ancien en douce : la question suivante part sur le nouveau.
@MainActor
@Observable
final class MLXProviderPool {
    private struct Resident {
        let modelID: String
        let model: any PoolableLocalModel
    }

    private struct PendingLoad {
        let token: UUID
        let modelID: String
        let task: Task<any PoolableLocalModel, any Error>
    }

    /// File unique du modèle local, lue par l'interface (attente d'une autre fenêtre).
    let turns = LocalModelTurnQueue()
    private let selection: MLXModelSelectionStore
    /// Demandeur des travaux d'entretien (déchargements) : jamais une fenêtre.
    private let maintenanceRequester = UUID()

    @ObservationIgnored private var resident: Resident?
    @ObservationIgnored private var pendingLoad: PendingLoad?
    @ObservationIgnored private var requesters: Set<UUID> = []
    @ObservationIgnored private var evictionTask: Task<Void, Never>?

    /// `selection` : LE store partagé de l'app. Le pool le suit lui-même pour décharger l'ancien
    /// modèle à chaque changement, d'où qu'il vienne.
    init(selection: MLXModelSelectionStore) {
        self.selection = selection
        observeSelection()
    }

    /// Modèle demandé par la sélection courante : le seul qui a le droit de rester en mémoire.
    private var targetModelID: String? { selection.selectedModelID }

    /// Le modèle `modelID` est-il chargé en mémoire (par n'importe quelle fenêtre) ?
    func isResident(_ modelID: String) -> Bool {
        resident?.modelID == modelID
    }

    /// `requester` attend-il qu'une autre fenêtre ait fini avec le modèle local ?
    func isWaitingForAnotherWindow(_ requester: UUID) -> Bool {
        turns.isWaitingBehindAnother(requester)
    }

    /// Le modèle `modelID`, chargé, partagé. `make` n'est appelé que s'il faut une instance neuve.
    /// Plusieurs demandes simultanées du même modèle attendent le MÊME chargement.
    ///
    /// `modelID` doit être celui de la sélection courante (lu juste avant, sans suspension) ; une
    /// sélection changée pendant le chargement le fait échouer (`modelNotLoaded`) et le décharge.
    func preparedModel(
        id modelID: String,
        requester: UUID,
        make: () -> any PoolableLocalModel
    ) async throws -> any PoolableLocalModel {
        requesters.insert(requester)
        if let resident, resident.modelID == modelID {
            return resident.model
        }
        if let pendingLoad, pendingLoad.modelID == modelID {
            return try await pendingLoad.task.value
        }
        let token = UUID()
        let model = make()
        let task = Task { @MainActor in
            try await self.load(model, id: modelID, requester: requester, token: token)
        }
        pendingLoad = PendingLoad(token: token, modelID: modelID, task: task)
        return try await task.value
    }

    /// Générateur à rendre au chat : chaque appel attend son tour dans la file, et vérifie que le
    /// modèle est toujours celui du pool.
    func generator(for model: any PoolableLocalModel, requester: UUID) -> any AIGenerating {
        PooledLocalGenerator(model: model, pool: self, requester: requester)
    }

    /// Une fenêtre MLX s'ouvre (session de recherche créée) : tant qu'au moins une fenêtre MLX existe,
    /// le modèle reste en mémoire, même si elle n'a encore rien demandé. Sans cela, fermer une fenêtre
    /// avant que l'autre ait posé sa première question déchargeait le modèle, puis le rechargeait
    /// (plusieurs Go relus) dès cette question.
    func register(_ requester: UUID) {
        requesters.insert(requester)
    }

    /// Fin d'une fenêtre (session de recherche libérée) : quand plus aucune n'utilise MLX, le
    /// modèle est déchargé. Sans effet pour une fenêtre qui n'a jamais rien demandé.
    func unregister(_ requester: UUID) {
        guard requesters.remove(requester) != nil else { return }
        scheduleEvictionIfUnwanted()
    }

    // MARK: - Tours de génération (`PooledLocalGenerator`)

    /// Attend son tour puis vérifie que `model` est toujours le modèle résident. Le tour est rendu
    /// (et l'erreur levée) sinon.
    func beginGeneration(with model: any PoolableLocalModel, requester: UUID) async throws -> LocalModelTurn {
        let turn = try await turns.acquire(for: requester)
        guard let resident, resident.model === model else {
            endGeneration(turn)
            throw MLXProviderError.modelNotLoaded
        }
        return turn
    }

    func endGeneration(_ turn: LocalModelTurn) {
        turns.release(turn)
        scheduleEvictionIfUnwanted()
    }

    // MARK: - Essai d'un modèle (écran de choix, mission G1)

    /// Générateur de l'ESSAI d'un modèle : la génération passe par la même file que celles des fenêtres
    /// (une seule génération MLX à la fois), mais le modèle essayé n'a pas à être le modèle résident
    /// (c'est justement un modèle qu'on n'a pas encore choisi). L'essai n'entre PAS dans les demandeurs :
    /// il ne retient pas le modèle résident en mémoire.
    func trialGenerator(for model: any PoolableLocalModel, requester: UUID) -> any AIGenerating {
        PooledLocalGenerator(model: model, pool: self, requester: requester, requiresResidentModel: false)
    }

    /// Tour d'une génération d'essai : attend son rang, sans exiger que `model` soit le résident.
    func beginTrialGeneration(requester: UUID) async throws -> LocalModelTurn {
        try await turns.acquire(for: requester)
    }

    /// L'essai est abandonné (autre modèle, annulation, fenêtre fermée). Le modèle d'essai n'est
    /// déchargé QUE si le pool ne s'en sert pas : `unloadFromMemory()` retire le modèle du cache GLOBAL
    /// de `mlx-swift-lm`, pour cet identifiant, donc sous les pieds d'un modèle résident (ou en cours de
    /// chargement) de même identifiant. La vérification se fait à SON tour dans la file : un chargement du
    /// pool qui démarrerait entre-temps passe soit avant (il est alors résident), soit après (il recharge).
    func discardTrialModel(_ model: any PoolableLocalModel, id modelID: String) {
        Task { @MainActor [weak self] in
            guard let self else {
                await model.unloadFromMemory()
                return
            }
            await self.withMaintenanceTurn {
                await self.unloadTrialModelIfUnused(model, id: modelID)
            }
        }
    }

    /// L'essai est validé : si c'est désormais le modèle voulu par la sélection et qu'une fenêtre l'utilise,
    /// il DEVIENT le modèle résident (déjà chargé, aucun rechargement à la première question) ; l'ancien est
    /// déchargé. Sinon (aucune fenêtre, sélection autre, même modèle déjà résident ou en chargement) il est
    /// traité comme un essai abandonné. À appeler APRÈS avoir écrit la sélection.
    func adoptTrialModel(_ model: any PoolableLocalModel, id modelID: String) {
        Task { @MainActor [weak self] in
            guard let self else {
                await model.unloadFromMemory()
                return
            }
            await self.withMaintenanceTurn {
                let isFree = self.resident?.modelID != modelID && self.pendingLoad?.modelID != modelID
                if isFree, self.targetModelID == modelID, !self.requesters.isEmpty {
                    await self.unloadResident()
                    self.resident = Resident(modelID: modelID, model: model)
                } else {
                    await self.unloadTrialModelIfUnused(model, id: modelID)
                }
            }
        }
    }

    private func unloadTrialModelIfUnused(_ model: any PoolableLocalModel, id modelID: String) async {
        let isUsedByPool = resident?.modelID == modelID || pendingLoad?.modelID == modelID
        guard !isUsedByPool else { return }
        await model.unloadFromMemory()
    }

    /// Travail d'entretien rendu à son tour dans la file, comme les déchargements.
    private func withMaintenanceTurn(_ work: () async -> Void) async {
        guard let turn = try? await turns.acquire(for: maintenanceRequester) else { return }
        await work()
        endGeneration(turn)
    }

    // MARK: - Chargement et déchargement

    /// Charge `model` pendant SON tour : aucune génération ne tourne, et l'ancien modèle est
    /// déchargé AVANT de charger le nouveau.
    private func load(
        _ model: any PoolableLocalModel,
        id modelID: String,
        requester: UUID,
        token: UUID
    ) async throws -> any PoolableLocalModel {
        defer {
            if pendingLoad?.token == token { pendingLoad = nil }
        }
        let turn = try await turns.acquire(for: requester)
        defer { endGeneration(turn) }
        // La sélection a changé pendant l'attente : ce modèle n'est plus voulu, ne rien toucher.
        guard targetModelID == modelID else { throw MLXProviderError.modelNotLoaded }
        if let resident, resident.modelID == modelID { return resident.model }
        await unloadResident()
        try await model.loadIntoMemory()
        // Sélection changée PENDANT le chargement, ou plus aucune fenêtre : on ne l'installe pas.
        guard targetModelID == modelID, !requesters.isEmpty else {
            await model.unloadFromMemory()
            throw MLXProviderError.modelNotLoaded
        }
        resident = Resident(modelID: modelID, model: model)
        return model
    }

    /// Le modèle résident n'a plus de raison d'être en mémoire.
    private var residentIsUnwanted: Bool {
        guard let resident else { return false }
        return requesters.isEmpty || resident.modelID != targetModelID
    }

    /// Décharge le modèle résident s'il n'est plus voulu, à son tour dans la file (jamais au milieu
    /// d'une génération). Un seul déchargement programmé à la fois.
    private func scheduleEvictionIfUnwanted() {
        guard residentIsUnwanted, evictionTask == nil else { return }
        evictionTask = Task { @MainActor [weak self] in
            await self?.evictIfUnwanted()
        }
    }

    private func evictIfUnwanted() async {
        defer { evictionTask = nil }
        guard let turn = try? await turns.acquire(for: maintenanceRequester) else { return }
        defer { turns.release(turn) }
        // Revérifié à son tour : la sélection a pu revenir sur ce modèle entre-temps.
        guard residentIsUnwanted else { return }
        await unloadResident()
    }

    private func unloadResident() async {
        guard let old = resident else { return }
        resident = nil
        await old.model.unloadFromMemory()
    }

    /// Suit la sélection partagée : chaque changement peut rendre le modèle résident inutile.
    private func observeSelection() {
        withObservationTracking {
            _ = selection.selectedModelID
        } onChange: { [weak self] in
            // Appelé AVANT l'écriture (`willSet`) : on relit la valeur au tour suivant du main actor.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSelection()
                self.scheduleEvictionIfUnwanted()
            }
        }
    }
}
