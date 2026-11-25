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
///
/// ## Un seul modèle en mémoire, essai compris (décision de Ben, 2026-11-24)
/// Tant que le réglage `MLXModelSelectionStore.allowsMultipleModels` est éteint (par défaut), le modèle
/// qu'on ESSAIE ne s'ajoute jamais au résident : essayer un autre modèle décharge le résident (à son tour dans
/// la file : une réponse en cours se termine d'abord). Ce modèle « évincé » n'est pas perdu : la fenêtre qui le
/// tient le fait recharger, dans son tour, à sa question suivante (`beginGeneration`), et ce rechargement libère
/// à son tour le modèle d'essai (rechargé depuis le disque à la prochaine question d'essai). Allumé : l'essai
/// et le résident coexistent, comme avant.
@MainActor
@Observable
final class MLXProviderPool {
    private struct Resident {
        let modelID: String
        let model: any PoolableLocalModel
    }

    /// Modèle d'essai suivi par le pool (écran de choix d'un modèle). Classe : l'état change pendant que
    /// plusieurs tâches l'attendent.
    private final class TrialSlot {
        let modelID: String
        let model: any PoolableLocalModel
        /// Poids en mémoire.
        var isLoaded = false
        /// Téléchargement/chargement en cours, hors de la file (plusieurs minutes).
        var isLoading = true
        /// Essai abandonné : s'il finit de charger, il est aussitôt déchargé.
        var isDiscarded = false

        init(modelID: String, model: any PoolableLocalModel) {
            self.modelID = modelID
            self.model = model
        }

        var holdsMemory: Bool { isLoaded || isLoading }
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
    @ObservationIgnored private var trials: [TrialSlot] = []
    /// Résident libéré pour faire place à un essai (réglage éteint) : sa fenêtre le fait recharger à sa
    /// question suivante. `nil` dès qu'un modèle redevient résident.
    @ObservationIgnored private var displaced: Resident?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?

    /// `selection` : LE store partagé de l'app. Le pool le suit lui-même pour décharger l'ancien
    /// modèle à chaque changement, d'où qu'il vienne.
    init(selection: MLXModelSelectionStore) {
        self.selection = selection
        observeSelection()
    }

    /// Modèle demandé par la sélection courante : le seul qui a le droit de rester en mémoire.
    private var targetModelID: String? { selection.selectedModelID }

    /// Réglage « Autoriser plusieurs modèles en mémoire ».
    private var allowsMultipleModels: Bool { selection.allowsMultipleModels }

    /// Le modèle `modelID` est-il chargé en mémoire (par n'importe quelle fenêtre) ?
    func isResident(_ modelID: String) -> Bool {
        resident?.modelID == modelID
    }

    /// `requester` attend-il qu'une autre fenêtre ait fini avec le modèle local ?
    func isWaitingForAnotherWindow(_ requester: UUID) -> Bool {
        turns.isWaitingBehindAnother(requester)
    }

    /// `requester` attend-il derrière son propre travail (voir `LocalModelTurnQueue.isWaitingBehindOwnWork`) ?
    func isWaitingBehindOwnWork(_ requester: UUID) -> Bool {
        turns.isWaitingBehindOwnWork(requester)
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
        // Le modèle libéré pour un essai revient sur la MÊME instance : une autre fenêtre la tient peut-être.
        let model: any PoolableLocalModel
        if let displaced, displaced.modelID == modelID {
            model = displaced.model
        } else {
            model = make()
        }
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
    ///
    /// Exception : `model` est le résident libéré pour un essai (réglage éteint) et la sélection n'a pas changé :
    /// il est rechargé ICI, dans le tour, et le modèle d'essai est libéré à son tour.
    func beginGeneration(with model: any PoolableLocalModel, requester: UUID) async throws -> LocalModelTurn {
        let turn = try await turns.acquire(for: requester)
        if let resident, resident.model === model {
            return turn
        }
        if resident == nil, let displaced, displaced.model === model {
            do {
                try await restore(displaced)
                return turn
            } catch {
                endGeneration(turn)
                throw error
            }
        }
        endGeneration(turn)
        throw MLXProviderError.modelNotLoaded
    }

    /// Recharge le résident libéré pour un essai. Appelé pendant un tour.
    private func restore(_ evicted: Resident) async throws {
        guard targetModelID == evicted.modelID, !requesters.isEmpty else { throw MLXProviderError.modelNotLoaded }
        await unloadTrials(otherThan: evicted.modelID)
        try await evicted.model.loadIntoMemory()
        guard targetModelID == evicted.modelID, !requesters.isEmpty else {
            await evicted.model.unloadFromMemory()
            throw MLXProviderError.modelNotLoaded
        }
        resident = evicted
        displaced = nil
    }

    func endGeneration(_ turn: LocalModelTurn) {
        turns.release(turn)
        scheduleEvictionIfUnwanted()
    }

    // MARK: - Essai d'un modèle (écran de choix, missions G1 et K1)

    /// Générateur de l'ESSAI d'un modèle : la génération passe par la même file que celles des fenêtres
    /// (une seule génération MLX à la fois), mais le modèle essayé n'a pas à être le modèle résident du pool
    /// (c'est justement un modèle qu'on n'a pas encore choisi). L'essai n'entre PAS dans les demandeurs :
    /// il ne retient pas le modèle résident en mémoire.
    func trialGenerator(for model: any PoolableLocalModel, requester: UUID) -> any AIGenerating {
        PooledLocalGenerator(model: model, pool: self, requester: requester, requiresResidentModel: false)
    }

    /// Télécharge et charge le modèle d'ESSAI `model` (poids annonçant leur progression).
    ///
    /// Réglage éteint : avant de commencer, le résident (et tout autre essai chargé) est déchargé, à son tour
    /// dans la file : une réponse en cours se termine d'abord. Le téléchargement lui-même reste HORS de la file
    /// (plusieurs minutes : il ferait attendre toutes les fenêtres). Une fenêtre qui pose une question pendant
    /// ce temps recharge son modèle ; à la fin du téléchargement, l'essai reprend la place (`settle`).
    func loadTrialModel(
        _ model: any TrialLocalModel,
        id modelID: String,
        onProgress: @escaping @Sendable (MLXDownloadProgress) -> Void
    ) async throws {
        let slot = TrialSlot(modelID: modelID, model: model)
        trials.append(slot)
        do {
            if !allowsMultipleModels {
                try await withTurn {
                    // Abandonné pendant l'attente du tour : ne rien libérer pour un essai qui n'aura pas lieu.
                    if !slot.isDiscarded { await self.evictOthers(forTrial: slot) }
                }
            }
            guard !slot.isDiscarded else { throw CancellationError() }
            try await model.loadIntoMemory(onProgress: onProgress)
        } catch {
            slot.isLoading = false
            forget(slot)
            throw error
        }
        slot.isLoading = false
        if !slot.isDiscarded { slot.isLoaded = true }
        // Le chargement est fini : l'écran passe à l'essai sans attendre le tour de la file (une fenêtre peut
        // être en train de charger son modèle, des minutes). La remise en ordre de la mémoire se fait à son tour.
        if slot.isDiscarded || !allowsMultipleModels {
            Task { @MainActor [weak self] in await self?.settle(slot) }
        }
    }

    /// Fin du chargement d'un essai, à son tour dans la file : abandonné entre-temps, il est déchargé ; sinon,
    /// réglage éteint, il prend la place des autres modèles (qu'une fenêtre aurait rechargés pendant le
    /// téléchargement).
    private func settle(_ slot: TrialSlot) async {
        await withMaintenanceTurn {
            if slot.isDiscarded {
                await self.unloadTrialModelIfUnused(slot.model, id: slot.modelID)
            } else if !self.allowsMultipleModels, slot.isLoaded {
                await self.evictOthers(forTrial: slot)
            }
        }
    }

    /// Tour d'une génération d'essai : attend son rang. Réglage éteint, l'essai prend alors la place du résident ;
    /// un essai libéré entre-temps (par la question d'une fenêtre) est rechargé depuis le disque.
    func beginTrialGeneration(with model: any PoolableLocalModel, requester: UUID) async throws -> LocalModelTurn {
        let turn = try await turns.acquire(for: requester)
        guard let slot = trials.first(where: { $0.model === model }), !slot.isDiscarded else { return turn }
        do {
            if !allowsMultipleModels { await evictOthers(forTrial: slot) }
            if !slot.isLoaded && !slot.isLoading {
                try await model.loadIntoMemory()
                slot.isLoaded = true
            }
        } catch {
            endGeneration(turn)
            throw error
        }
        return turn
    }

    /// L'essai est abandonné (autre modèle, annulation, fenêtre fermée). Le modèle d'essai n'est
    /// déchargé QUE si le pool ne s'en sert pas : `unloadFromMemory()` retire le modèle du cache GLOBAL
    /// de `mlx-swift-lm`, pour cet identifiant, donc sous les pieds d'un modèle résident (ou en cours de
    /// chargement) de même identifiant. La vérification se fait à SON tour dans la file : un chargement du
    /// pool qui démarrerait entre-temps passe soit avant (il est alors résident), soit après (il recharge).
    /// Le résident libéré pour cet essai n'est PAS rechargé d'office : sa fenêtre le fait à sa question suivante.
    func discardTrialModel(_ model: any PoolableLocalModel, id modelID: String) {
        let slot = trials.first { $0.model === model }
        slot?.isDiscarded = true
        if let slot { forget(slot) }
        Task { @MainActor [weak self] in
            guard let self else {
                await model.unloadFromMemory()
                return
            }
            await self.withMaintenanceTurn {
                await self.unloadTrialModelIfUnused(model, id: modelID, slot: slot)
            }
        }
    }

    /// L'essai est validé : si c'est désormais le modèle voulu par la sélection et qu'une fenêtre l'utilise,
    /// il DEVIENT le modèle résident (déjà chargé, aucun rechargement à la première question) ; l'ancien est
    /// déchargé. Sinon (aucune fenêtre, sélection autre, même modèle déjà résident ou en chargement, essai
    /// libéré entre-temps) il est traité comme un essai abandonné. À appeler APRÈS avoir écrit la sélection.
    func adoptTrialModel(_ model: any PoolableLocalModel, id modelID: String) {
        let slot = trials.first { $0.model === model }
        Task { @MainActor [weak self] in
            guard let self else {
                await model.unloadFromMemory()
                return
            }
            await self.withMaintenanceTurn {
                if let slot { self.forget(slot) }
                let isFree = self.resident?.modelID != modelID && self.pendingLoad?.modelID != modelID
                let isLoaded = slot?.isLoaded ?? true
                if isLoaded, isFree, self.targetModelID == modelID, !self.requesters.isEmpty {
                    await self.unloadResident()
                    self.resident = Resident(modelID: modelID, model: model)
                    self.displaced = nil
                    if !self.allowsMultipleModels { await self.unloadTrials(otherThan: modelID) }
                } else {
                    await self.unloadTrialModelIfUnused(model, id: modelID, slot: slot)
                }
            }
        }
    }

    private func forget(_ slot: TrialSlot) {
        trials.removeAll { $0 === slot }
    }

    /// Décharge `model` s'il ne sert à personne : ni résident ni chargement du pool de même identifiant, et
    /// pas déjà libéré (`slot` : l'essai suivi, s'il l'est encore).
    private func unloadTrialModelIfUnused(_ model: any PoolableLocalModel, id modelID: String, slot: TrialSlot? = nil) async {
        let isUsedByPool = resident?.modelID == modelID || pendingLoad?.modelID == modelID
        guard !isUsedByPool else { return }
        if let slot, !slot.holdsMemory { return }
        slot?.isLoaded = false
        await model.unloadFromMemory()
    }

    // MARK: - Un seul modèle en mémoire (réglage éteint)

    /// Libère tout ce qui occupe la mémoire sauf le modèle d'essai `slot` (même identifiant = mêmes poids,
    /// partagés dans le cache global : rien à libérer). Le résident libéré est mémorisé pour être rechargé.
    private func evictOthers(forTrial slot: TrialSlot) async {
        if let old = resident, old.modelID != slot.modelID {
            displaced = old
            resident = nil
            await old.model.unloadFromMemory()
        }
        await unloadTrials(otherThan: slot.modelID, besides: slot)
    }

    /// Décharge les essais CHARGÉS d'un autre identifiant que `modelID`. Un essai encore en train de télécharger
    /// n'est pas touché (`settle` s'en occupe à la fin).
    private func unloadTrials(otherThan modelID: String, besides keep: TrialSlot? = nil) async {
        for slot in trials where slot !== keep && slot.isLoaded && slot.modelID != modelID {
            slot.isLoaded = false
            await slot.model.unloadFromMemory()
        }
    }

    /// Réglage éteint alors que plusieurs modèles sont en mémoire : les essais chargés sont libérés (le
    /// résident reste, c'est lui que les fenêtres utilisent).
    private func scheduleReconcileIfSingleModel() {
        guard !allowsMultipleModels, reconcileTask == nil,
              trials.contains(where: \.isLoaded) else { return }
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reconcileTask = nil }
            await self.withMaintenanceTurn {
                guard !self.allowsMultipleModels, let keptID = self.resident?.modelID else { return }
                await self.unloadTrials(otherThan: keptID)
            }
        }
    }

    /// Travail d'entretien rendu à son tour dans la file, comme les déchargements. Lève si l'attente du tour est
    /// annulée (le travail n'a alors pas eu lieu).
    private func withTurn<T>(_ work: () async -> T) async throws -> T {
        let turn = try await turns.acquire(for: maintenanceRequester)
        defer { endGeneration(turn) }
        return await work()
    }

    private func withMaintenanceTurn(_ work: () async -> Void) async {
        _ = try? await withTurn(work)
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
        if !allowsMultipleModels { await unloadTrials(otherThan: modelID) }
        try await model.loadIntoMemory()
        // Sélection changée PENDANT le chargement, ou plus aucune fenêtre : on ne l'installe pas.
        guard targetModelID == modelID, !requesters.isEmpty else {
            await model.unloadFromMemory()
            throw MLXProviderError.modelNotLoaded
        }
        resident = Resident(modelID: modelID, model: model)
        displaced = nil
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
            _ = selection.allowsMultipleModels
        } onChange: { [weak self] in
            // Appelé AVANT l'écriture (`willSet`) : on relit la valeur au tour suivant du main actor.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSelection()
                self.scheduleEvictionIfUnwanted()
                self.scheduleReconcileIfSingleModel()
            }
        }
    }
}
