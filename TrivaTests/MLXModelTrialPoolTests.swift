//
//  MLXModelTrialPoolTests.swift
//  TrivaTests
//
//  Chantier 2.2, mission G1 : l'essai d'un modèle MLX (écran de choix) passe par le pool partagé.
//  Doubles (`FakeLocalModel`) : MLX plante en simulateur et un vrai modèle pèserait plusieurs Go.
//

import Foundation
import Testing
@testable import Triva

extension FakeLocalModel: TrialLocalModel {
    func loadIntoMemory(onProgress: @escaping @Sendable (MLXDownloadProgress) -> Void) async throws {
        try await loadIntoMemory()
    }
}

/// Fabrique de modèles d'essai : rend, pour chaque modèle du catalogue, le double préparé par le test.
@MainActor
private final class TrialFactory {
    private(set) var made: [String: FakeLocalModel] = [:]
    private let log: PoolEventLog

    init(log: PoolEventLog) { self.log = log }

    func make(_ entry: MLXModelCatalogEntry) -> any TrialLocalModel {
        let model = FakeLocalModel(name: "trial-\(entry.id)", log: log)
        made[entry.id] = model
        return model
    }
}

private func trialEntry(_ id: String) -> MLXModelCatalogEntry {
    MLXModelCatalogEntry(
        id: id, displayName: id, huggingFaceRepo: "mlx-community/\(id)", registryKey: nil, license: "Apache 2.0",
        downloadSizeBytes: 1, recommendedGPUWorkingSetBytes: 1, capabilityScore: 1, supportsThinkingMode: false,
        isMixtureOfExperts: false, isAdvancedOnly: false, summary: "", strengths: [], tradeoffs: []
    )
}

/// Un pool avec `resident` déjà chargé pour la fenêtre `window`, et un coordinateur d'essai branché dessus.
@MainActor
private struct TrialRig {
    let selection: MLXModelSelectionStore
    let pool: MLXProviderPool
    let factory: TrialFactory
    let log = PoolEventLog()
    let window = UUID()

    init(selected: String?) {
        let log = log
        selection = makePoolSelection(selected: selected)
        pool = MLXProviderPool(selection: selection)
        factory = TrialFactory(log: log)
    }

    func makeCoordinator(onValidated: @escaping (MLXModelCatalogEntry) -> Void = { _ in }) -> MLXModelSelectionCoordinator {
        let factory = factory
        return MLXModelSelectionCoordinator(pool: pool, makeModel: { factory.make($0) }, onValidated: onValidated)
    }

    /// Charge `model` comme modèle résident du pool pour `window`.
    func makeResident(_ model: FakeLocalModel, id: String) async throws {
        _ = try await pool.preparedModel(id: id, requester: window) { model }
    }

    /// Choisit un modèle dans le coordinateur et attend la phase d'essai.
    func startTrial(_ coordinator: MLXModelSelectionCoordinator, id: String) async -> Bool {
        coordinator.select(trialEntry(id))
        return await waitForPool { coordinator.phase == .trial }
    }

    /// Barrière : un déchargement « sentinelle » demandé APRÈS les autres n'a lieu qu'une fois leurs tours rendus.
    func settleMaintenance() async -> Bool {
        let sentinel = FakeLocalModel(name: "sentinel", log: log)
        pool.discardTrialModel(sentinel, id: "sentinel")
        return await waitForPool { sentinel.unloadCount == 1 }
    }
}

@Suite("Essai d'un modèle MLX par le pool")
@MainActor
struct MLXModelTrialPoolTests {
    // MARK: - Même file que les fenêtres

    @Test("Une question d'essai attend le tour d'une fenêtre qui répond, puis passe")
    func trialQuestionWaitsBehindAWindow() async throws {
        let rig = TrialRig(selected: "small")
        let gate = TestGate()
        let resident = FakeLocalModel(name: "small", log: rig.log, generationGate: gate)
        let model = try await rig.pool.preparedModel(id: "small", requester: rig.window) { resident }
        let generator = rig.pool.generator(for: model, requester: rig.window)
        let coordinator = rig.makeCoordinator()
        #expect(await rig.startTrial(coordinator, id: "other"))
        let trial = try #require(rig.factory.made["other"])

        let windowAnswer = Task { try await generator.generate(prompt: "fenêtre") }
        #expect(await waitForPool { resident.startedGenerations == 1 })
        let question = Task { await coordinator.askNextTrialQuestion() }
        #expect(await waitForPool { rig.pool.turns.waitingRequesters.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(trial.startedGenerations == 0)
        #expect(coordinator.isGeneratingTrialAnswer)

        await gate.open()
        _ = try await windowAnswer.value
        await question.value
        #expect(trial.startedGenerations == 1)
        #expect(coordinator.trialAnswers.count == 1)
        #expect(!coordinator.isGeneratingTrialAnswer)
        #expect(rig.pool.turns.holder == nil)
    }

    @Test("Le modèle d'essai n'est jamais un « demandeur » : fermer la dernière fenêtre décharge quand même le résident")
    func trialDoesNotKeepTheResidentAlive() async throws {
        let rig = TrialRig(selected: "small")
        let resident = FakeLocalModel(name: "small", log: rig.log)
        try await rig.makeResident(resident, id: "small")
        let coordinator = rig.makeCoordinator()
        #expect(await rig.startTrial(coordinator, id: "other"))
        await coordinator.askNextTrialQuestion()
        #expect(coordinator.trialAnswers.count == 1)

        rig.pool.unregister(rig.window)

        #expect(await waitForPool { resident.unloadCount == 1 })
        #expect(!rig.pool.isResident("small"))
    }

    @Test("Une génération d'essai qui échoue rend quand même son tour")
    func failedTrialGenerationReleasesTheTurn() async throws {
        let rig = TrialRig(selected: "small")
        let coordinator = rig.makeCoordinator()
        #expect(await rig.startTrial(coordinator, id: "other"))
        let trial = try #require(rig.factory.made["other"])
        await trial.unloadFromMemory()   // la génération suivante échoue (`modelNotLoaded`)

        await coordinator.askNextTrialQuestion()

        #expect(coordinator.trialAnswers.count == 1)
        #expect(rig.pool.turns.holder == nil)
        #expect(rig.pool.turns.waitingRequesters.isEmpty)
    }

    // MARK: - Abandonner l'essai sans évincer un modèle utilisé

    @Test("Annuler l'essai du modèle qui est DÉJÀ résident ne le décharge pas")
    func abandoningTrialOfTheResidentModelKeepsIt() async throws {
        let rig = TrialRig(selected: "small")
        let resident = FakeLocalModel(name: "small", log: rig.log)
        try await rig.makeResident(resident, id: "small")
        let coordinator = rig.makeCoordinator()
        #expect(await rig.startTrial(coordinator, id: "small"))
        let trial = try #require(rig.factory.made["small"])

        coordinator.chooseAnotherModel()

        #expect(await rig.settleMaintenance())
        #expect(trial.unloadCount == 0)
        #expect(resident.unloadCount == 0)
        #expect(rig.pool.isResident("small"))
    }

    @Test("Annuler pendant que le pool CHARGE ce même modèle ne le décharge pas non plus")
    func abandoningTrialDuringPoolLoadKeepsIt() async throws {
        let rig = TrialRig(selected: "small")
        let gate = TestGate()
        let loading = FakeLocalModel(name: "small", log: rig.log, loadGate: gate)
        let pool = rig.pool
        let window = rig.window
        let load = Task { try await pool.preparedModel(id: "small", requester: window) { loading } }
        #expect(await waitForPool { await rig.log.events.contains("load small start") })
        let coordinator = rig.makeCoordinator()
        #expect(await rig.startTrial(coordinator, id: "small"))
        let trial = try #require(rig.factory.made["small"])

        coordinator.cancelDownload()
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        _ = try await load.value

        #expect(await rig.settleMaintenance())
        #expect(trial.unloadCount == 0)
        #expect(loading.unloadCount == 0)
        #expect(rig.pool.isResident("small"))
    }

    @Test("Annuler l'essai d'un AUTRE modèle le décharge, sans toucher au résident")
    func abandoningTrialOfAnotherModelUnloadsOnlyIt() async throws {
        let rig = TrialRig(selected: "small")
        let resident = FakeLocalModel(name: "small", log: rig.log)
        try await rig.makeResident(resident, id: "small")
        let coordinator = rig.makeCoordinator()
        #expect(await rig.startTrial(coordinator, id: "other"))
        let trial = try #require(rig.factory.made["other"])

        coordinator.chooseAnotherModel()

        #expect(await waitForPool { trial.unloadCount == 1 })
        #expect(resident.unloadCount == 0)
        #expect(rig.pool.isResident("small"))
        #expect(coordinator.phase == .idle)
    }

    @Test("Fermer l'écran sans choisir décharge le modèle d'essai (le coordinateur disparaît)")
    func closingTheSheetUnloadsTheTrialModel() async throws {
        let rig = TrialRig(selected: "small")
        var coordinator: MLXModelSelectionCoordinator? = rig.makeCoordinator()
        let started = await rig.startTrial(try #require(coordinator), id: "other")
        #expect(started)
        let trial = try #require(rig.factory.made["other"])

        coordinator = nil

        #expect(await waitForPool { trial.unloadCount == 1 })
    }

    // MARK: - Valider

    @Test("Valider : le modèle d'essai devient le résident, sans rechargement, et l'ancien est déchargé")
    func validatingAdoptsTheTrialModel() async throws {
        let rig = TrialRig(selected: "small")
        let old = FakeLocalModel(name: "small", log: rig.log)
        try await rig.makeResident(old, id: "small")
        let selection = rig.selection
        let coordinator = rig.makeCoordinator { selection.selectedModelID = $0.id }
        #expect(await rig.startTrial(coordinator, id: "big"))
        let trial = try #require(rig.factory.made["big"])

        coordinator.validateAsDefault()

        #expect(await waitForPool { rig.pool.isResident("big") })
        #expect(await rig.settleMaintenance())
        #expect(trial.unloadCount == 0)
        #expect(old.unloadCount == 1)
        #expect(!rig.pool.isResident("small"))
        // La première question de la fenêtre reprend le modèle déjà chargé : aucune fabrication, aucun chargement.
        let counter = MakeCounter()
        let reused = try await rig.pool.preparedModel(id: "big", requester: rig.window) {
            counter.make(FakeLocalModel(name: "autre"))
        }
        #expect(reused === trial)
        #expect(counter.count == 0)
        #expect(trial.loadCount == 1)
    }

    @Test("Valider sans aucune fenêtre qui utilise MLX : le modèle d'essai est libéré, pas gardé en mémoire")
    func validatingWithoutWindowReleasesTheTrialModel() async throws {
        let rig = TrialRig(selected: nil)
        let selection = rig.selection
        let coordinator = rig.makeCoordinator { selection.selectedModelID = $0.id }
        #expect(await rig.startTrial(coordinator, id: "big"))
        let trial = try #require(rig.factory.made["big"])

        coordinator.validateAsDefault()

        #expect(await waitForPool { trial.unloadCount == 1 })
        #expect(!rig.pool.isResident("big"))
    }

    @Test("Valider le modèle qui est déjà résident : l'instance du pool reste, le doublon d'essai n'évince rien")
    func validatingTheResidentModelKeepsThePoolInstance() async throws {
        let rig = TrialRig(selected: "small")
        let resident = FakeLocalModel(name: "small", log: rig.log)
        try await rig.makeResident(resident, id: "small")
        let selection = rig.selection
        let coordinator = rig.makeCoordinator { selection.selectedModelID = $0.id }
        #expect(await rig.startTrial(coordinator, id: "small"))
        let trial = try #require(rig.factory.made["small"])

        coordinator.validateAsDefault()

        #expect(await rig.settleMaintenance())
        #expect(trial.unloadCount == 0)
        #expect(resident.unloadCount == 0)
        #expect(rig.pool.isResident("small"))
    }
}
