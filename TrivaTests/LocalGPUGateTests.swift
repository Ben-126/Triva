//
//  LocalGPUGateTests.swift
//  TrivaTests
//
//  Mission M (25/11) : barrière du GPU du modèle local. Rien ici ne touche au GPU : `drain` est un compteur.
//  Suites NON isolées au main actor : `checkpoint` et `waitUntilQuiet` bloquent leur fil, exprès.
//

import Foundation
import os
import Testing
@testable import Triva

nonisolated final class GateCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { state.withLock { $0 } }
    func increment() { state.withLock { $0 += 1 } }
}

/// Attend une condition sans jamais bloquer le pool coopératif (`Task.sleep`, jamais `Task.yield` seul).
nonisolated func gateWait(_ condition: @Sendable () -> Bool, seconds: Double = 5) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

nonisolated private func gate(_ phase: LocalGPUPhase, enforced: Bool = true) -> LocalGPUGate {
    LocalGPUGate(isEnforced: enforced, initialPhase: phase)
}

/// Passe la barrière sur un vrai fil (comme la boucle de MLX) ; `passed` compte les passages.
nonisolated private func passOnThread(_ gate: LocalGPUGate, drains: GateCounter, passed: GateCounter) {
    Thread.detachNewThread {
        gate.checkpoint { drains.increment() }
        passed.increment()
    }
}

// MARK: - État de l'app

@Suite("Mission M — état de l'app d'après ses scènes")
struct SceneActivityAggregateTests {
    typealias Aggregate = SceneActivityAggregate<String>

    private func phase(_ events: [(Aggregate.Event, String)]) -> LocalGPUPhase {
        var aggregate = Aggregate()
        for (event, scene) in events { aggregate.apply(event, to: scene) }
        return aggregate.phase
    }

    @Test("Aucune scène (lancement par Siri) : arrière-plan")
    func noScene() {
        #expect(phase([]) == .background)
    }

    @Test("Cycle d'une scène : inactif, actif, inactif, arrière-plan, retour")
    func singleSceneCycle() {
        #expect(phase([(.willEnterForeground, "a")]) == .inactive)
        #expect(phase([(.willEnterForeground, "a"), (.didActivate, "a")]) == .active)
        #expect(phase([(.didActivate, "a"), (.willDeactivate, "a")]) == .inactive)
        #expect(phase([(.didActivate, "a"), (.willDeactivate, "a"), (.didEnterBackground, "a")]) == .background)
        #expect(phase([(.didEnterBackground, "a"), (.willEnterForeground, "a"), (.didActivate, "a")]) == .active)
    }

    @Test("iPad, deux fenêtres : l'une en arrière-plan ne coupe rien tant que l'autre est active")
    func secondSceneKeepsTheAppActive() {
        #expect(phase([(.didActivate, "a"), (.didActivate, "b"), (.didEnterBackground, "a")]) == .active)
        #expect(phase([(.didActivate, "a"), (.didActivate, "b"), (.willDeactivate, "a"), (.didEnterBackground, "b")]) == .inactive)
        #expect(phase([(.didActivate, "a"), (.didActivate, "b"), (.didEnterBackground, "a"), (.didEnterBackground, "b")]) == .background)
    }

    @Test("Fenêtre fermée : oubliée, dans tous les états")
    func disconnectedSceneIsForgotten() {
        #expect(phase([(.didActivate, "a"), (.didDisconnect, "a")]) == .background)
        #expect(phase([(.didActivate, "a"), (.didActivate, "b"), (.didDisconnect, "a")]) == .active)
    }

    @Test("« Va entrer au premier plan » ne rétrograde pas une scène déjà active")
    func willEnterForegroundNeverDemotes() {
        #expect(phase([(.didActivate, "a"), (.willEnterForeground, "a")]) == .active)
    }
}

// MARK: - Passage de la barrière

@Suite("Mission M — passage de la barrière par le fil du modèle")
struct LocalGPUGateCheckpointTests {
    @Test("Plateforme : iOS impose la barrière, le Mac non")
    func platformFlag() {
        #if os(iOS)
        #expect(LocalGPUGate.platformRestrictsGPU)
        #else
        #expect(!LocalGPUGate.platformRestrictsGPU)
        #expect(!LocalGPUGate.shared.isEnforced)
        #expect(LocalGPUGate.shared.phase == .active)
        #endif
    }

    @Test("Mac (barrière non imposée) : toujours ouverte, les changements d'état sont ignorés")
    func notEnforcedIsTransparent() {
        let gate = gate(.background, enforced: false)
        gate.setPhase(.background)
        let drains = GateCounter()
        gate.checkpoint { drains.increment() }
        #expect(gate.phase == .active)
        #expect(drains.value == 0)
    }

    @Test("App active : passe sans attendre ni vider")
    func activePasses() {
        let drains = GateCounter()
        gate(.active).checkpoint { drains.increment() }
        #expect(drains.value == 0)
    }

    @Test("Inactif (Centre de contrôle, appel) : vide une fois, se gare, et repart au retour")
    func inactiveDrainsThenParksThenResumes() async {
        let gate = gate(.inactive)
        let (drains, passed) = (GateCounter(), GateCounter())
        passOnThread(gate, drains: drains, passed: passed)
        #expect(await gateWait { gate.counts.parked == 1 })
        #expect(drains.value == 1)
        #expect(passed.value == 0)

        gate.setPhase(.active)
        #expect(await gateWait { passed.value == 1 })
        #expect(drains.value == 1)
        #expect(gate.counts.parked == 0)
    }

    @Test("Arrière-plan : se gare SANS vider (vider enverrait un tampon refusé)")
    func backgroundParksWithoutDraining() async {
        let gate = gate(.background)
        let (drains, passed) = (GateCounter(), GateCounter())
        passOnThread(gate, drains: drains, passed: passed)
        #expect(await gateWait { gate.counts.parked == 1 })
        #expect(drains.value == 0)

        gate.setPhase(.active)
        #expect(await gateWait { passed.value == 1 })
        #expect(drains.value == 0)
    }

    @Test("Garé puis arrière-plan puis « va revenir » : reste garé jusqu'à l'état actif, ne vide plus")
    func staysParkedUntilActive() async {
        let gate = gate(.inactive)
        let (drains, passed) = (GateCounter(), GateCounter())
        passOnThread(gate, drains: drains, passed: passed)
        #expect(await gateWait { gate.counts.parked == 1 })

        gate.setPhase(.background)
        gate.setPhase(.inactive)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(passed.value == 0)
        #expect(gate.counts.parked == 1)
        #expect(drains.value == 1)

        gate.setPhase(.active)
        #expect(await gateWait { passed.value == 1 })
    }

    @Test("Deux fils garés (ancienne génération et autre modèle) : tous deux comptés, tous deux relâchés")
    func twoParkedThreads() async {
        let gate = gate(.background)
        let (drains, passed) = (GateCounter(), GateCounter())
        passOnThread(gate, drains: drains, passed: passed)
        passOnThread(gate, drains: drains, passed: passed)
        #expect(await gateWait { gate.counts.parked == 2 })
        gate.setPhase(.active)
        #expect(await gateWait { passed.value == 2 })
        #expect(gate.counts.parked == 0)
    }
}

// MARK: - Travaux comptés

@Suite("Mission M — travaux comptés et attente avant l'arrière-plan")
struct LocalGPUGateWorkTests {
    @Test("Aucun travail : l'attente rend la main tout de suite")
    func nothingToWaitFor() {
        let start = ContinuousClock.now
        #expect(gate(.background).waitUntilQuiet(timeout: 5))
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("Travail en cours, ni fini ni garé : l'attente est bornée et le dit")
    func boundedWait() async throws {
        let gate = gate(.active)
        let work = try await gate.begin()
        gate.setPhase(.background)
        #expect(!gate.waitUntilQuiet(timeout: 0.1))
        work.finish()
        #expect(gate.waitUntilQuiet(timeout: 0.1))
    }

    @Test("Travail garé : l'attente est satisfaite, le travail reste compté")
    func parkedWorkIsQuiet() async throws {
        let gate = gate(.active)
        let work = try await gate.begin()
        let (drains, passed) = (GateCounter(), GateCounter())
        gate.setPhase(.inactive)
        passOnThread(gate, drains: drains, passed: passed)
        #expect(await gateWait { gate.counts.parked == 1 })
        gate.setPhase(.background)

        #expect(gate.waitUntilQuiet(timeout: 0.1))
        #expect(gate.counts.running == 1)

        gate.setPhase(.active)
        #expect(await gateWait { passed.value == 1 })
        #expect(!gate.waitUntilQuiet(timeout: 0.05))
        work.finish()
    }

    @Test("Le fil se gare PENDANT l'attente : elle se termine alors, sans épuiser son délai")
    func parkingEndsTheWait() async throws {
        let gate = gate(.active)
        let work = try await gate.begin()
        gate.setPhase(.background)
        let (drains, passed) = (GateCounter(), GateCounter())
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.1)
            gate.checkpoint { drains.increment() }
            passed.increment()
        }
        let start = ContinuousClock.now
        #expect(gate.waitUntilQuiet(timeout: 10))
        #expect(ContinuousClock.now - start < .seconds(8))
        gate.setPhase(.active)
        #expect(await gateWait { passed.value == 1 })
        work.finish()
    }

    @Test("Garé sans avoir attendu ses tampons (écran verrouillé d'un coup) : ils ont encore un temps, borné")
    func undrainedParkingSettles() async throws {
        let gate = gate(.active)
        let work = try await gate.begin()
        gate.setPhase(.background)
        let (drains, passed) = (GateCounter(), GateCounter())
        passOnThread(gate, drains: drains, passed: passed)
        #expect(await gateWait { gate.counts.parked == 1 })

        let start = ContinuousClock.now
        #expect(gate.waitUntilQuiet(timeout: 10, settleTime: 0.3))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(250))
        #expect(elapsed < .seconds(8))
        #expect(drains.value == 0)

        gate.setPhase(.active)
        #expect(await gateWait { passed.value == 1 })
        work.finish()
        // Plus personne de garé : plus aucun temps à laisser.
        #expect(await gateWait { gate.counts.parked == 0 })
        let after = ContinuousClock.now
        #expect(gate.waitUntilQuiet(timeout: 10, settleTime: 5))
        #expect(ContinuousClock.now - after < .seconds(4))
    }

    @Test("Garé après avoir attendu ses tampons (passage par inactif) : aucun temps en plus")
    func drainedParkingDoesNotSettle() async throws {
        let gate = gate(.active)
        let work = try await gate.begin()
        gate.setPhase(.inactive)
        let (drains, passed) = (GateCounter(), GateCounter())
        passOnThread(gate, drains: drains, passed: passed)
        #expect(await gateWait { gate.counts.parked == 1 })
        gate.setPhase(.background)

        let start = ContinuousClock.now
        #expect(gate.waitUntilQuiet(timeout: 10, settleTime: 5))
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(drains.value == 1)

        gate.setPhase(.active)
        #expect(await gateWait { passed.value == 1 })
        work.finish()
    }

    @Test("Fin comptée une seule fois ; un travail oublié est rendu à sa libération")
    func finishIsIdempotentAndDeinitReleases() async throws {
        let gate = gate(.active)
        let first = try await gate.begin()
        var second: LocalGPUWork? = try await gate.begin()
        #expect(gate.counts.running == 2)
        first.finish()
        first.finish()
        #expect(gate.counts.running == 1)
        second = nil
        #expect(second == nil)
        #expect(gate.counts.running == 0)
    }

    @Test("Fin après annulation : encore comptée le temps que MLX finisse son étape")
    func graceKeepsCounting() async throws {
        let gate = gate(.active)
        let work = try await gate.begin()
        work.finishAfterGrace(.milliseconds(150))
        #expect(gate.counts.running == 1)
        #expect(await gateWait { gate.counts.running == 0 })
    }

    @Test("Démarrer inactif : attend le retour, sans être compté entre-temps")
    func beginWaitsWhileInactive() async throws {
        let gate = gate(.inactive)
        let started = GateCounter()
        let task = Task.detached {
            let work = try await gate.begin(backgroundPatience: 1)
            started.increment()
            work.finish()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(started.value == 0)
        #expect(gate.counts.running == 0)
        gate.setPhase(.active)
        try await task.value
        #expect(started.value == 1)
    }

    @Test("Démarrer en arrière-plan : erreur claire au bout de la patience, rien compté")
    func beginGivesUpInBackground() async {
        let gate = gate(.background)
        await #expect(throws: LocalGPUGateError.unavailableInBackground) {
            _ = try await gate.begin(backgroundPatience: 2)
        }
        #expect(gate.counts.running == 0)
    }

    @Test("Démarrer en arrière-plan sans limite (chargement après téléchargement) : attend le premier plan")
    func beginWithoutPatienceWaits() async throws {
        let gate = gate(.background)
        let task = Task.detached { try await gate.begin(backgroundPatience: nil).finish() }
        try await Task.sleep(for: .milliseconds(200))
        gate.setPhase(.active)
        try await task.value
    }

    @Test("Attente annulée (Stop) : CancellationError")
    func cancelledWait() async {
        let gate = gate(.inactive)
        let task = Task.detached { _ = try await gate.begin() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

// MARK: - Annulations différées

@Suite("Mission M — annulation retenue hors du premier plan")
struct LocalGPUGateDeferredTests {
    @Test("App active (et Mac) : tout de suite", arguments: [true, false])
    func runsImmediatelyWhenActive(enforced: Bool) {
        let ran = GateCounter()
        gate(.active, enforced: enforced).whenActive { ran.increment() }
        #expect(ran.value == 1)
    }

    @Test("Inactif ou arrière-plan : au retour, une seule fois", arguments: [LocalGPUPhase.inactive, .background])
    func deferredUntilActive(phase: LocalGPUPhase) {
        let gate = gate(phase)
        let ran = GateCounter()
        gate.whenActive { ran.increment() }
        #expect(ran.value == 0)
        gate.setPhase(.background)
        gate.setPhase(.inactive)
        #expect(ran.value == 0)
        gate.setPhase(.active)
        #expect(ran.value == 1)
        gate.setPhase(.inactive)
        gate.setPhase(.active)
        #expect(ran.value == 1)
    }
}
