//
//  MLXSingleModelPoolTests.swift
//  TrivaTests
//
//  Mission K1 (2026-11-24, décision de Ben) : UN SEUL modèle MLX en mémoire à la fois, essai compris, tant que
//  le réglage « Autoriser plusieurs modèles en mémoire » est éteint (par défaut). Doubles (`FakeLocalModel`) :
//  MLX plante en simulateur. « Jamais deux en mémoire » est prouvé par l'ORDRE du journal (un déchargement
//  précède toujours le chargement suivant) et par `FakeLocalModelCounters.isLoaded`.
//

import Foundation
import Testing
@testable import Triva

/// Nombre de doubles actuellement chargés en mémoire.
private func loadedCount(_ models: FakeLocalModel...) -> Int {
    models.filter { $0.counters.isLoaded }.count
}

/// Pool en mode « un seul modèle », `small` résident pour la fenêtre `rig.window`.
@MainActor
private struct SingleRig {
    let rig = TrialRig(selected: "small", allowsMultipleModels: false)
    let resident: FakeLocalModel
    let model: any PoolableLocalModel

    init() async throws {
        let resident = FakeLocalModel(name: "small", log: rig.log)
        self.resident = resident
        model = try await rig.pool.preparedModel(id: "small", requester: rig.window) { resident }
    }

    var pool: MLXProviderPool { rig.pool }
    var log: PoolEventLog { rig.log }

    /// La question d'une fenêtre sur le modèle `small` qu'elle tient depuis `preparedModel`.
    func windowAnswer(_ prompt: String = "q") async throws -> String {
        try await pool.generator(for: model, requester: rig.window).generate(prompt: prompt)
    }
}

@Suite("Un seul modèle MLX en mémoire (réglage éteint)")
@MainActor
struct MLXSingleModelPoolTests {
    // MARK: - L'essai libère le modèle résident

    @Test("Essayer un autre modèle décharge le résident AVANT le téléchargement : jamais deux en mémoire")
    func trialEvictsTheResidentBeforeLoading() async throws {
        let single = try await SingleRig()
        let coordinator = single.rig.makeCoordinator()

        #expect(await single.rig.startTrial(coordinator, id: "other"))

        let trial = try #require(single.rig.factory.made["other"])
        #expect(await single.log.events == [
            "load small start", "load small end", "unload small", "load trial-other start", "load trial-other end",
        ])
        #expect(single.resident.unloadCount == 1)
        #expect(!single.pool.isResident("small"))
        #expect(loadedCount(single.resident, trial) == 1)
    }

    @Test("Une réponse en cours se termine d'abord : l'éviction attend son tour dans la file")
    func evictionWaitsForARunningAnswer() async throws {
        let rig = TrialRig(selected: "small", allowsMultipleModels: false)
        let gate = TestGate()
        let resident = FakeLocalModel(name: "small", log: rig.log, generationGate: gate)
        let model = try await rig.pool.preparedModel(id: "small", requester: rig.window) { resident }
        let generator = rig.pool.generator(for: model, requester: rig.window)
        let coordinator = rig.makeCoordinator()
        let answer = Task { try await generator.generate(prompt: "en cours") }
        #expect(await waitForPool { resident.startedGenerations == 1 })

        coordinator.select(trialEntry("other"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(resident.unloadCount == 0)
        #expect(coordinator.phase == .downloading(fractionCompleted: 0))

        await gate.open()
        #expect(try await answer.value == "small:en cours")
        #expect(await waitForPool { coordinator.phase == .trial })
        #expect(resident.unloadCount == 1)
    }

    @Test("Essayer le modèle qui est DÉJÀ résident ne décharge rien")
    func trialOfTheResidentModelEvictsNothing() async throws {
        let single = try await SingleRig()
        let coordinator = single.rig.makeCoordinator()

        #expect(await single.rig.startTrial(coordinator, id: "small"))

        #expect(single.resident.unloadCount == 0)
        #expect(single.pool.isResident("small"))
    }

    // MARK: - Le résident revient à la question suivante

    @Test("La question suivante d'une fenêtre recharge le résident (dans son tour) et libère l'essai")
    func windowQuestionReloadsTheResidentAndEvictsTheTrial() async throws {
        let single = try await SingleRig()
        let coordinator = single.rig.makeCoordinator()
        #expect(await single.rig.startTrial(coordinator, id: "other"))
        let trial = try #require(single.rig.factory.made["other"])

        let answer = try await single.windowAnswer()

        #expect(answer == "small:q")
        #expect(single.resident.loadCount == 2)
        #expect(trial.unloadCount == 1)
        #expect(single.pool.isResident("small"))
        #expect(loadedCount(single.resident, trial) == 1)
        let events = await single.log.events
        let afterTrialLoaded = Array(events.drop { $0 != "load trial-other end" }.dropFirst())
        #expect(afterTrialLoaded.prefix(3) == ["unload trial-other", "load small start", "load small end"])
        #expect(single.pool.turns.holder == nil)
    }

    @Test("La question d'essai suivante recharge l'essai et libère le résident")
    func trialQuestionReloadsTheTrialAndEvictsTheResident() async throws {
        let single = try await SingleRig()
        let coordinator = single.rig.makeCoordinator()
        #expect(await single.rig.startTrial(coordinator, id: "other"))
        let trial = try #require(single.rig.factory.made["other"])
        _ = try await single.windowAnswer()
        #expect(trial.unloadCount == 1)

        await coordinator.askNextTrialQuestion()

        #expect(coordinator.trialAnswers == ["trial-other:\(MLXModelSelectionCoordinator.trialQuestions[0])"])
        #expect(trial.loadCount == 2)
        #expect(single.resident.unloadCount == 2)
        #expect(loadedCount(single.resident, trial) == 1)
        #expect(single.pool.turns.holder == nil)
    }

    @Test("Une nouvelle fenêtre qui demande le modèle évincé reprend la MÊME instance (celle que tient l'autre fenêtre)")
    func newWindowReusesTheEvictedInstance() async throws {
        let single = try await SingleRig()
        let coordinator = single.rig.makeCoordinator()
        #expect(await single.rig.startTrial(coordinator, id: "other"))
        let counter = MakeCounter()

        let reused = try await single.pool.preparedModel(id: "small", requester: UUID()) {
            counter.make(FakeLocalModel(name: "autre instance"))
        }

        #expect(reused === single.model)
        #expect(counter.count == 0)
        #expect(single.resident.loadCount == 2)
        // L'autre fenêtre, qui tenait cette instance, n'est pas laissée en erreur.
        #expect(try await single.windowAnswer() == "small:q")
    }

    @Test("Sélection changée entre-temps : le modèle évincé ne revient PAS en douce")
    func changedSelectionDoesNotBringTheEvictedModelBack() async throws {
        let single = try await SingleRig()
        let coordinator = single.rig.makeCoordinator()
        #expect(await single.rig.startTrial(coordinator, id: "other"))
        single.rig.selection.selectedModelID = "ailleurs"

        await #expect(throws: MLXProviderError.modelNotLoaded) { try await single.windowAnswer() }

        #expect(single.resident.loadCount == 1)
        #expect(single.pool.turns.holder == nil)
    }

    // MARK: - Pendant le téléchargement de l'essai

    @Test("Une question de fenêtre PENDANT le téléchargement recharge le résident ; la fin du téléchargement le libère")
    func windowQuestionDuringTrialDownload() async throws {
        let single = try await SingleRig()
        let gate = TestGate()
        single.rig.factory.loadGates["other"] = gate
        let coordinator = single.rig.makeCoordinator()
        coordinator.select(trialEntry("other"))
        #expect(await waitForPool { await single.log.events.contains("load trial-other start") })
        #expect(single.resident.unloadCount == 1)

        #expect(try await single.windowAnswer() == "small:q")
        #expect(single.resident.loadCount == 2)

        await gate.open()
        #expect(await waitForPool { coordinator.phase == .trial })
        let trial = try #require(single.rig.factory.made["other"])
        #expect(await waitForPool { single.resident.unloadCount == 2 })
        #expect(loadedCount(single.resident, trial) == 1)
        #expect(trial.counters.isLoaded)
    }

    @Test("Essai abandonné PENDANT son téléchargement : le modèle ne reste pas en mémoire quand il finit de charger")
    func abandonedDuringDownloadIsUnloadedWhenItFinishes() async throws {
        let single = try await SingleRig()
        let gate = TestGate()
        single.rig.factory.loadGates["other"] = gate
        let coordinator = single.rig.makeCoordinator()
        coordinator.select(trialEntry("other"))
        #expect(await waitForPool { await single.log.events.contains("load trial-other start") })
        let trial = try #require(single.rig.factory.made["other"])

        coordinator.chooseAnotherModel()
        await gate.open()

        #expect(await waitForPool { trial.loadCount == 1 && !trial.counters.isLoaded && trial.unloadCount >= 2 })
        #expect(coordinator.phase == .idle)
    }

    @Test("Téléchargement d'essai en échec : l'essai est oublié, le résident revient à la question suivante")
    func failedTrialDownloadForgetsTheTrial() async throws {
        let single = try await SingleRig()
        single.rig.factory.loadErrors["other"] = .modelNotLoaded
        let coordinator = single.rig.makeCoordinator()

        coordinator.select(trialEntry("other"))
        #expect(await waitForPool { if case .failed = coordinator.phase { true } else { false } })

        #expect(try await single.windowAnswer() == "small:q")
        #expect(single.resident.loadCount == 2)
        let trial = try #require(single.rig.factory.made["other"])
        #expect(trial.unloadCount == 0)
    }

    // MARK: - Abandonner, valider

    @Test("Abandonner l'essai : l'essai est libéré, le résident revient à la prochaine question d'une fenêtre")
    func abandoningTheTrialLeavesTheResidentForTheNextQuestion() async throws {
        let single = try await SingleRig()
        let coordinator = single.rig.makeCoordinator()
        #expect(await single.rig.startTrial(coordinator, id: "other"))
        let trial = try #require(single.rig.factory.made["other"])

        coordinator.chooseAnotherModel()
        #expect(await single.rig.settleMaintenance())

        #expect(trial.unloadCount == 1)
        #expect(single.resident.unloadCount == 1)
        #expect(try await single.windowAnswer() == "small:q")
        #expect(single.resident.loadCount == 2)
        #expect(trial.unloadCount == 1)
    }

    @Test("Valider : l'essai (seul en mémoire) devient le résident, sans rechargement ni déchargement en plus")
    func validatingAdoptsTheOnlyLoadedTrial() async throws {
        let single = try await SingleRig()
        let selection = single.rig.selection
        let coordinator = single.rig.makeCoordinator { selection.selectedModelID = $0.id }
        #expect(await single.rig.startTrial(coordinator, id: "big"))
        let trial = try #require(single.rig.factory.made["big"])

        coordinator.validateAsDefault()

        #expect(await waitForPool { single.pool.isResident("big") })
        #expect(await single.rig.settleMaintenance())
        #expect(trial.loadCount == 1)
        #expect(trial.unloadCount == 0)
        #expect(single.resident.unloadCount == 1)
        #expect(loadedCount(single.resident, trial) == 1)
    }

    @Test("Valider après que la fenêtre a rechargé l'ancien modèle : l'essai déjà libéré n'est ni adopté ni rechargé")
    func validatingAnEvictedTrialDoesNotAdoptIt() async throws {
        let single = try await SingleRig()
        let selection = single.rig.selection
        let coordinator = single.rig.makeCoordinator { selection.selectedModelID = $0.id }
        #expect(await single.rig.startTrial(coordinator, id: "big"))
        let trial = try #require(single.rig.factory.made["big"])
        _ = try await single.windowAnswer()
        #expect(trial.unloadCount == 1)

        coordinator.validateAsDefault()

        // L'ancien modèle n'est plus voulu : libéré. Rien n'est en mémoire tant que la fenêtre ne repose pas de question.
        #expect(await waitForPool { single.resident.unloadCount == 2 })
        #expect(await single.rig.settleMaintenance())
        #expect(!single.pool.isResident("big"))
        #expect(trial.loadCount == 1)
        #expect(trial.unloadCount == 1)
        #expect(loadedCount(single.resident, trial) == 0)
    }

    // MARK: - Le réglage

    @Test("Éteindre le réglage alors qu'un essai et le résident sont en mémoire : l'essai est libéré, le résident reste")
    func turningTheSettingOffUnloadsTheTrial() async throws {
        let rig = TrialRig(selected: "small", allowsMultipleModels: true)
        let resident = FakeLocalModel(name: "small", log: rig.log)
        try await rig.makeResident(resident, id: "small")
        let coordinator = rig.makeCoordinator()
        #expect(await rig.startTrial(coordinator, id: "other"))
        let trial = try #require(rig.factory.made["other"])
        #expect(loadedCount(resident, trial) == 2)

        rig.selection.allowsMultipleModels = false

        #expect(await waitForPool { trial.unloadCount == 1 })
        #expect(resident.unloadCount == 0)
        #expect(rig.pool.isResident("small"))
        #expect(loadedCount(resident, trial) == 1)
    }

    @Test("Réglage allumé : essayer un autre modèle ne décharge pas le résident")
    func multipleModelsAllowedKeepsTheResident() async throws {
        let rig = TrialRig(selected: "small", allowsMultipleModels: true)
        let resident = FakeLocalModel(name: "small", log: rig.log)
        try await rig.makeResident(resident, id: "small")
        let coordinator = rig.makeCoordinator()

        #expect(await rig.startTrial(coordinator, id: "other"))

        let trial = try #require(rig.factory.made["other"])
        #expect(resident.unloadCount == 0)
        #expect(rig.pool.isResident("small"))
        #expect(loadedCount(resident, trial) == 2)
    }
}
