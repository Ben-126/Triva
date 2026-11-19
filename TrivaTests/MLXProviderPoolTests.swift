//
//  MLXProviderPoolTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 19/11/2026.
//

import Foundation
import Testing
@testable import Triva

/// Pool MLX partagé entre fenêtres (chantier 2.2, mission M3), testé avec un double : MLX plante en
/// simulateur, et un vrai modèle pèserait plusieurs Go.
@Suite("MLXProviderPool")
@MainActor
struct MLXProviderPoolTests {
    private let windowA = UUID()
    private let windowB = UUID()

    // MARK: - Une instance par identifiant

    @Test("Même identifiant -> même instance, chargée une seule fois")
    func sameIDReturnsSameInstance() async throws {
        let pool = MLXProviderPool(selection: makePoolSelection(selected: "small"))
        let counter = MakeCounter()
        let fake = FakeLocalModel(name: "small")

        let first = try await pool.preparedModel(id: "small", requester: windowA) { counter.make(fake) }
        let second = try await pool.preparedModel(id: "small", requester: windowB) {
            counter.make(FakeLocalModel(name: "small"))
        }

        #expect(first === second)
        #expect(first === fake)
        #expect(counter.count == 1)
        #expect(fake.loadCount == 1)
        #expect(pool.isResident("small"))
    }

    @Test("Deux fenêtres qui demandent le même modèle en même temps -> un seul chargement")
    func concurrentRequestsShareOneLoad() async throws {
        let pool = MLXProviderPool(selection: makePoolSelection(selected: "small"))
        let gate = TestGate()
        let fake = FakeLocalModel(name: "small", loadGate: gate)
        let counter = MakeCounter()
        let windowA = windowA
        let windowB = windowB

        let first = Task { try await pool.preparedModel(id: "small", requester: windowA) { counter.make(fake) } }
        #expect(await waitForPool { counter.count == 1 })
        let second = Task {
            try await pool.preparedModel(id: "small", requester: windowB) {
                counter.make(FakeLocalModel(name: "other"))
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()

        let modelA = try await first.value
        let modelB = try await second.value
        #expect(modelA === modelB)
        #expect(counter.count == 1)
        #expect(fake.loadCount == 1)
    }

    // MARK: - File d'attente

    @Test("Deux questions simultanées -> sérialisées, la deuxième fenêtre sait qu'elle attend")
    func simultaneousGenerationsAreSerialized() async throws {
        let pool = MLXProviderPool(selection: makePoolSelection(selected: "small"))
        let gate = TestGate()
        let fake = FakeLocalModel(name: "small", generationGate: gate)
        let model = try await pool.preparedModel(id: "small", requester: windowA) { fake }
        _ = try await pool.preparedModel(id: "small", requester: windowB) { fake }
        let generatorA = pool.generator(for: model, requester: windowA)
        let generatorB = pool.generator(for: model, requester: windowB)

        let answerA = Task { try await generatorA.generate(prompt: "a") }
        #expect(await waitForPool { fake.startedGenerations == 1 })
        let answerB = Task { try await generatorB.generate(prompt: "b") }
        #expect(await waitForPool { pool.isWaitingForAnotherWindow(windowB) })
        #expect(!pool.isWaitingForAnotherWindow(windowA))
        #expect(fake.startedGenerations == 1)

        await gate.open()
        #expect(try await answerA.value == "small:a")
        #expect(try await answerB.value == "small:b")
        #expect(fake.maxConcurrentGenerations == 1)
        #expect(!pool.isWaitingForAnotherWindow(windowB))
    }

    @Test("Le flux aussi attend son tour et le rend à la fin")
    func streamingTakesAndReleasesTurn() async throws {
        let pool = MLXProviderPool(selection: makePoolSelection(selected: "small"))
        let gate = TestGate()
        let fake = FakeLocalModel(name: "small", generationGate: gate)
        let model = try await pool.preparedModel(id: "small", requester: windowA) { fake }
        let generatorA = pool.generator(for: model, requester: windowA)
        let generatorB = pool.generator(for: model, requester: windowB)

        let streamA = Task { () -> [String] in
            var chunks: [String] = []
            for try await chunk in generatorA.streamGenerate(prompt: "a") { chunks.append(chunk) }
            return chunks
        }
        #expect(await waitForPool { fake.startedGenerations == 1 })
        let answerB = Task { try await generatorB.generate(prompt: "b") }
        #expect(await waitForPool { pool.isWaitingForAnotherWindow(windowB) })

        await gate.open()
        #expect(try await streamA.value == ["small:a"])
        #expect(try await answerB.value == "small:b")
        #expect(fake.maxConcurrentGenerations == 1)
    }

    @Test("Stop pendant l'attente -> la place est rendue, la file continue")
    func cancelledWaiterFreesItsPlace() async throws {
        let pool = MLXProviderPool(selection: makePoolSelection(selected: "small"))
        let gate = TestGate()
        let fake = FakeLocalModel(name: "small", generationGate: gate)
        let model = try await pool.preparedModel(id: "small", requester: windowA) { fake }
        let generatorA = pool.generator(for: model, requester: windowA)
        let generatorB = pool.generator(for: model, requester: windowB)
        let windowC = UUID()
        let generatorC = pool.generator(for: model, requester: windowC)

        let answerA = Task { try await generatorA.generate(prompt: "a") }
        #expect(await waitForPool { fake.startedGenerations == 1 })
        let answerB = Task { try await generatorB.generate(prompt: "b") }
        #expect(await waitForPool { pool.isWaitingForAnotherWindow(windowB) })
        let answerC = Task { try await generatorC.generate(prompt: "c") }
        #expect(await waitForPool { pool.isWaitingForAnotherWindow(windowC) })

        answerB.cancel()
        #expect(await waitForPool { !pool.isWaitingForAnotherWindow(windowB) })
        await #expect(throws: CancellationError.self) { try await answerB.value }

        await gate.open()
        #expect(try await answerA.value == "small:a")
        #expect(try await answerC.value == "small:c")
        #expect(fake.startedGenerations == 2)
    }

    @Test("Une erreur de génération rend aussi le tour")
    func failedGenerationReleasesTurn() async throws {
        let pool = MLXProviderPool(selection: makePoolSelection(selected: "small"))
        let broken = FakeLocalModel(name: "small")
        let model = try await pool.preparedModel(id: "small", requester: windowA) { broken }
        await broken.unloadFromMemory() // le double lève `modelNotLoaded` à la génération
        let generator = pool.generator(for: model, requester: windowA)

        await #expect(throws: MLXProviderError.self) { try await generator.generate(prompt: "a") }
        #expect(pool.turns.holder == nil)
    }

    // MARK: - Mémoire

    @Test("Changement de modèle -> l'ancien est déchargé aussitôt")
    func selectionChangeUnloadsOldModel() async throws {
        let selection = makePoolSelection(selected: "small")
        let pool = MLXProviderPool(selection: selection)
        let small = FakeLocalModel(name: "small")
        _ = try await pool.preparedModel(id: "small", requester: windowA) { small }

        selection.selectedModelID = "large"

        #expect(await waitForPool { small.unloadCount == 1 })
        #expect(!pool.isResident("small"))
    }

    @Test("Changement de modèle pendant une réponse -> déchargé APRÈS la fin de la réponse")
    func unloadWaitsForRunningGeneration() async throws {
        let selection = makePoolSelection(selected: "small")
        let pool = MLXProviderPool(selection: selection)
        let log = PoolEventLog()
        let gate = TestGate()
        let small = FakeLocalModel(name: "small", log: log, generationGate: gate)
        let model = try await pool.preparedModel(id: "small", requester: windowA) { small }
        let generator = pool.generator(for: model, requester: windowA)

        let answer = Task { try await generator.generate(prompt: "a") }
        #expect(await waitForPool { small.startedGenerations == 1 })
        selection.selectedModelID = "large"
        try await Task.sleep(for: .milliseconds(100))
        #expect(small.unloadCount == 0)

        await gate.open()
        #expect(try await answer.value == "small:a")
        #expect(await waitForPool { small.unloadCount == 1 })
        let events = await log.events
        #expect(events.firstIndex(of: "generate small a end")! < events.firstIndex(of: "unload small")!)
    }

    @Test("Nouveau modèle demandé -> l'ancien est déchargé AVANT le chargement du nouveau")
    func neverTwoModelsInMemory() async throws {
        let selection = makePoolSelection(selected: "small")
        let pool = MLXProviderPool(selection: selection)
        let log = PoolEventLog()
        let small = FakeLocalModel(name: "small", log: log)
        let large = FakeLocalModel(name: "large", log: log)
        _ = try await pool.preparedModel(id: "small", requester: windowA) { small }

        selection.selectedModelID = "large"
        let loaded = try await pool.preparedModel(id: "large", requester: windowB) { large }

        #expect(loaded === large)
        #expect(pool.isResident("large"))
        #expect(small.unloadCount == 1)
        let events = await log.events
        #expect(events.firstIndex(of: "unload small")! < events.firstIndex(of: "load large start")!)
    }

    @Test("Question posée sur un modèle remplacé entre-temps -> modelNotLoaded, rien de rechargé")
    func generationOnReplacedModelFails() async throws {
        let selection = makePoolSelection(selected: "small")
        let pool = MLXProviderPool(selection: selection)
        let small = FakeLocalModel(name: "small")
        let model = try await pool.preparedModel(id: "small", requester: windowA) { small }
        let generator = pool.generator(for: model, requester: windowA)

        selection.selectedModelID = "large"
        #expect(await waitForPool { small.unloadCount == 1 })

        await #expect(throws: MLXProviderError.self) { try await generator.generate(prompt: "a") }
        #expect(small.loadCount == 1)
        #expect(pool.turns.holder == nil)
    }

    @Test("Sélection changée pendant le chargement -> chargement abandonné et libéré")
    func selectionChangedDuringLoadIsDiscarded() async throws {
        let selection = makePoolSelection(selected: "small")
        let pool = MLXProviderPool(selection: selection)
        let gate = TestGate()
        let small = FakeLocalModel(name: "small", loadGate: gate)

        let load = Task { try await pool.preparedModel(id: "small", requester: windowA) { small } }
        #expect(await waitForPool { pool.turns.holder != nil })
        selection.selectedModelID = "large"
        await gate.open()

        await #expect(throws: MLXProviderError.self) { _ = try await load.value }
        #expect(small.unloadCount == 1)
        #expect(!pool.isResident("small"))
    }

    @Test("Dernière fenêtre fermée -> modèle déchargé ; une fenêtre restante le garde")
    func lastRequesterUnregisteredUnloads() async throws {
        let pool = MLXProviderPool(selection: makePoolSelection(selected: "small"))
        let small = FakeLocalModel(name: "small")
        _ = try await pool.preparedModel(id: "small", requester: windowA) { small }
        _ = try await pool.preparedModel(id: "small", requester: windowB) { small }

        pool.unregister(windowA)
        try await Task.sleep(for: .milliseconds(100))
        #expect(pool.isResident("small"))
        #expect(small.unloadCount == 0)

        pool.unregister(windowB)
        #expect(await waitForPool { small.unloadCount == 1 })
        #expect(!pool.isResident("small"))
    }

    @Test("Fenêtre ouverte sans avoir encore rien demandé -> le modèle reste en mémoire")
    func registeredWindowKeepsModelResident() async throws {
        let pool = MLXProviderPool(selection: makePoolSelection(selected: "small"))
        let small = FakeLocalModel(name: "small")
        _ = try await pool.preparedModel(id: "small", requester: windowA) { small }
        pool.register(windowB)

        pool.unregister(windowA)
        try await Task.sleep(for: .milliseconds(100))
        #expect(pool.isResident("small"))
        #expect(small.unloadCount == 0)

        pool.unregister(windowB)
        #expect(await waitForPool { small.unloadCount == 1 })
    }

    @Test("Chargement en échec -> rien de résident, la demande suivante recharge")
    func failedLoadLeavesNothingResident() async throws {
        let pool = MLXProviderPool(selection: makePoolSelection(selected: "small"))
        let failing = FakeLocalModel(name: "small", loadError: MLXProviderError.simulatorUnsupported)

        await #expect(throws: MLXProviderError.self) {
            _ = try await pool.preparedModel(id: "small", requester: windowA) { failing }
        }
        #expect(!pool.isResident("small"))

        let working = FakeLocalModel(name: "small")
        let model = try await pool.preparedModel(id: "small", requester: windowA) { working }
        #expect(model === working)
    }
}
