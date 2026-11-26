//
//  LocalGPUAccessMonitorTests.swift
//  TrivaTests
//
//  Mission M (25/11) : arrêt des réponses du modèle local au passage de l'APP en arrière-plan, après le GPU au repos.
//

import Foundation
import Testing
@testable import Triva

@MainActor
private final class StopRecorder: LocalGenerationStopping {
    private(set) var stops = 0
    /// Travaux encore actifs au moment de l'arrêt (attendu : aucun).
    private(set) var activeWorkAtStop: Int?
    private let gate: LocalGPUGate
    /// Durée de l'arrêt (écriture du début de la réponse) : `.zero` par défaut.
    private let stopDuration: Duration
    private(set) var isStopFinished = false
    /// F3 : reprises demandées, et si l'arrêt était fini à ce moment-là (attendu : oui) et la barrière rouverte.
    private(set) var resumes = 0
    private(set) var stopWasFinishedAtResume: Bool?
    private(set) var gatePhaseAtResume: LocalGPUPhase?

    init(gate: LocalGPUGate, stopDuration: Duration = .zero) {
        self.gate = gate
        self.stopDuration = stopDuration
    }

    func stopLocalGenerationInBackground() async {
        stops += 1
        activeWorkAtStop = gate.counts.running - gate.counts.parked
        if stopDuration > .zero { try? await Task.sleep(for: stopDuration) }
        isStopFinished = true
    }

    func resumeLocalGenerationAfterBackground() {
        resumes += 1
        stopWasFinishedAtResume = isStopFinished
        gatePhaseAtResume = gate.phase
    }
}

@MainActor
private final class KeeperRecorder: BackgroundRunKeeping {
    private(set) var begun = 0
    private(set) var ended = 0

    func begin(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) -> BackgroundRunToken? {
        begun += 1
        return BackgroundRunToken(rawValue: begun)
    }

    func end(_ token: BackgroundRunToken) { ended += 1 }
}

@MainActor
@Suite("Mission M — l'app passe en arrière-plan")
struct LocalGPUAccessMonitorTests {
    private final class Scene {}
    private let gate = LocalGPUGate(isEnforced: true, initialPhase: .background)
    private let keeper = KeeperRecorder()
    private let sceneA = Scene()
    private let sceneB = Scene()

    private func monitor(timeout: TimeInterval = 0.2) -> LocalGPUAccessMonitor {
        LocalGPUAccessMonitor(gate: gate, quietTimeout: timeout, keeper: keeper)
    }

    @Test("Inactif : rien n'est arrêté, la barrière se ferme ; au retour elle se rouvre")
    func inactiveStopsNothing() {
        let monitor = monitor()
        let owner = StopRecorder(gate: gate)
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        #expect(gate.phase == .active)
        monitor.sceneDidChange(.willDeactivate, scene: ObjectIdentifier(sceneA))
        #expect(gate.phase == .inactive)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        #expect(gate.phase == .active)
        #expect(owner.stops == 0)
    }

    @Test("Arrière-plan : arrêt demandé une fois, dans l'appel même, sous temps d'arrière-plan rendu ensuite")
    func backgroundStopsOnce() async throws {
        let monitor = monitor()
        let owner = StopRecorder(gate: gate)
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.willDeactivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneA))
        #expect(gate.phase == .background)
        #expect(owner.stops == 1)
        #expect(keeper.begun == 1)
        let keeper = keeper
        for _ in 0..<200 where keeper.ended == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(keeper.ended == 1)
    }

    @Test("L'arrêt vient APRÈS le GPU au repos : un travail finissant pendant l'attente n'est plus actif")
    func stopsAfterQuiet() async throws {
        let monitor = monitor(timeout: 5)
        let owner = StopRecorder(gate: gate)
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        let work = try await gate.begin()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.1)
            work.finish()
        }
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneA))
        #expect(owner.activeWorkAtStop == 0)
    }

    @Test("iPad : une fenêtre en arrière-plan n'arrête rien tant que l'autre est devant ; la dernière arrête tout")
    func lastSceneStopsEverything() {
        let monitor = monitor()
        let owner = StopRecorder(gate: gate)
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneB))
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneA))
        #expect(owner.stops == 0)
        #expect(gate.phase == .active)
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneB))
        #expect(owner.stops == 1)
    }

    @Test("Session finie : retenue faiblement, jamais gardée en vie, aucun temps d'arrière-plan demandé")
    func ownersAreWeak() {
        let monitor = monitor()
        weak var released: StopRecorder?
        do {
            let owner = StopRecorder(gate: gate)
            released = owner
            monitor.register(owner)
        }
        #expect(released == nil)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneA))
        #expect(keeper.begun == 0)
    }

    @Test("Mac : rien n'est jamais arrêté")
    func macNeverStops() {
        let open = LocalGPUGate(isEnforced: false, initialPhase: .active)
        let monitor = LocalGPUAccessMonitor(gate: open, quietTimeout: 0.1, keeper: keeper)
        let owner = StopRecorder(gate: open)
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneA))
        #expect(owner.stops == 0)
        #expect(open.phase == .active)
    }

    // MARK: - F3 : reprise au retour au premier plan

    private func waitForResumes(_ owner: StopRecorder, _ expected: Int) async throws {
        for _ in 0..<300 where owner.resumes < expected { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("F3 : retour au premier plan après l'arrière-plan : UNE reprise demandée, barrière rouverte, arrêt fini")
    func returnAfterBackgroundResumesOnce() async throws {
        let monitor = monitor()
        let owner = StopRecorder(gate: gate)
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.willDeactivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneA))
        #expect(owner.resumes == 0, "rien ne reprend pendant l'arrière-plan")

        monitor.sceneDidChange(.willEnterForeground, scene: ObjectIdentifier(sceneA))
        #expect(owner.resumes == 0, "pas encore active")
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        try await waitForResumes(owner, 1)

        #expect(owner.resumes == 1)
        #expect(owner.stopWasFinishedAtResume == true)
        #expect(owner.gatePhaseAtResume == .active)

        monitor.sceneDidChange(.willDeactivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        try await Task.sleep(for: .milliseconds(50))
        #expect(owner.resumes == 1, "un simple passage inactif -> actif ne redemande rien")
    }

    @Test("F3 : Centre de contrôle (inactif puis actif), sans arrière-plan : aucune reprise, puisque rien n'a été arrêté")
    func inactiveOnlyNeverResumes() async throws {
        let monitor = monitor()
        let owner = StopRecorder(gate: gate)
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.willDeactivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        try await Task.sleep(for: .milliseconds(50))
        #expect(owner.resumes == 0)
    }

    @Test("F3 : retour AVANT la fin de l'arrêt : la reprise attend que le début soit écrit")
    func resumeWaitsForTheStopToFinish() async throws {
        let monitor = monitor()
        let owner = StopRecorder(gate: gate, stopDuration: .milliseconds(200))
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        #expect(!owner.isStopFinished)

        try await waitForResumes(owner, 1)

        #expect(owner.resumes == 1)
        #expect(owner.stopWasFinishedAtResume == true)
    }

    @Test("F3 iPad : une scène revient pendant que l'autre reste en arrière-plan : reprise une fois, à la première scène active")
    func iPadResumesWhenTheFirstSceneReturns() async throws {
        let monitor = monitor()
        let owner = StopRecorder(gate: gate)
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneB))
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneB))
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneB))
        try await waitForResumes(owner, 1)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        try await Task.sleep(for: .milliseconds(50))
        #expect(owner.resumes == 1)
    }

    @Test("F3 Mac : jamais de reprise (jamais d'arrêt)")
    func macNeverResumes() async throws {
        let open = LocalGPUGate(isEnforced: false, initialPhase: .active)
        let monitor = LocalGPUAccessMonitor(gate: open, quietTimeout: 0.1, keeper: keeper)
        let owner = StopRecorder(gate: open)
        monitor.register(owner)
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didEnterBackground, scene: ObjectIdentifier(sceneA))
        monitor.sceneDidChange(.didActivate, scene: ObjectIdentifier(sceneA))
        try await Task.sleep(for: .milliseconds(50))
        #expect(owner.resumes == 0)
    }
}
