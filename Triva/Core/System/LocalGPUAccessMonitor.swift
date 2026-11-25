//
//  LocalGPUAccessMonitor.swift
//  Triva
//
//  Mission M (25/11) : dit à `LocalGPUGate` si le système permet le GPU, d'après l'état de l'app ENTIÈRE (toutes
//  scènes confondues : sur iPad, une fenêtre en arrière-plan ne coupe rien tant qu'une autre est devant), et arrête les
//  réponses du modèle local quand l'app passe en arrière-plan, dans cet ordre :
//    1. la barrière se ferme ; 2. le fil principal attend que chaque travail soit fini ou garé (borné) ;
//    3. les réponses sont arrêtées (début gardé, « Réponse interrompue »).
//  L'ordre compte : arrêter d'abord ferait synchroniser MLX, donc envoyer un tampon refusé (c'est le défaut de l'arrêt
//  à `.background` seul, mission X2).
//
//  Doc Apple vérifiée : `UIScene.willDeactivate` (pauses temporaires et avant l'arrière-plan), `didEnterBackground`
//  (~5 s accordées), `willEnterForeground` toujours suivi de `didActivate` ; une app à scènes démarre en arrière-plan.
//  Notifications plutôt que `scenePhase` : reçues synchroniquement, avant que SwiftUI ne réévalue quoi que ce soit, et
//  même quand aucune vue n'existe (Siri).
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// État de l'app d'après ses scènes. Logique pure.
nonisolated struct SceneActivityAggregate<SceneID: Hashable> {
    nonisolated enum Event {
        case willEnterForeground
        case didActivate
        case willDeactivate
        case didEnterBackground
        case didDisconnect
    }

    private var phases: [SceneID: LocalGPUPhase] = [:]

    /// La scène la plus active décide ; aucune scène : arrière-plan.
    var phase: LocalGPUPhase {
        if phases.values.contains(.active) { return .active }
        return phases.values.contains(.inactive) ? .inactive : .background
    }

    mutating func apply(_ event: Event, to scene: SceneID) {
        switch event {
        case .willEnterForeground:
            // Une scène déjà active ne redescend pas.
            if phases[scene] != .active { phases[scene] = .inactive }
        case .didActivate:
            phases[scene] = .active
        case .willDeactivate:
            phases[scene] = .inactive
        case .didEnterBackground:
            phases[scene] = .background
        case .didDisconnect:
            phases[scene] = nil
        }
    }
}

/// Qui fait répondre le modèle local et doit s'arrêter quand l'app passe en arrière-plan (fenêtres, Siri).
@MainActor
protocol LocalGenerationStopping: AnyObject {
    /// Demande l'arrêt dès l'appel (avant le premier `await`), puis attend que le début de la réponse soit écrit.
    func stopLocalGenerationInBackground() async
}

@MainActor
final class LocalGPUAccessMonitor {
    static let shared = LocalGPUAccessMonitor(gate: .shared)

    /// Attente maximale du fil principal dans `didEnterBackground` (le système accorde environ cinq secondes).
    static let quietTimeout: TimeInterval = 2.5

    private struct WeakOwner {
        weak var value: (any LocalGenerationStopping)?
    }

    private let gate: LocalGPUGate
    private let quietTimeout: TimeInterval
    private let keeper: any BackgroundRunKeeping
    private var scenes = SceneActivityAggregate<ObjectIdentifier>()
    private var owners: [WeakOwner] = []
    private var isStarted = false
    private var observers: [any NSObjectProtocol] = []

    init(
        gate: LocalGPUGate,
        quietTimeout: TimeInterval = LocalGPUAccessMonitor.quietTimeout,
        keeper: (any BackgroundRunKeeping)? = nil
    ) {
        self.gate = gate
        self.quietTimeout = quietTimeout
        #if os(iOS)
        self.keeper = keeper ?? UIKitBackgroundRunKeeper()
        #else
        self.keeper = keeper ?? NoBackgroundRunKeeper()
        #endif
    }

    /// Retenu faiblement : rien à faire à la fin de la session.
    func register(_ owner: any LocalGenerationStopping) {
        guard gate.isEnforced else { return }
        owners = owners.filter { $0.value != nil } + [WeakOwner(value: owner)]
    }

    /// L'état d'une scène a changé. Synchrone : dans `didEnterBackground`, rend la main une fois le GPU au repos.
    func sceneDidChange(_ event: SceneActivityAggregate<ObjectIdentifier>.Event, scene: ObjectIdentifier) {
        let previous = scenes.phase
        scenes.apply(event, to: scene)
        let phase = scenes.phase
        guard phase != previous else { return }
        gate.setPhase(phase)
        guard phase == .background else { return }
        stopLocalGenerations()
    }

    /// Le temps d'arrière-plan demandé au système couvre l'attente ET l'écriture du début de la réponse : sans lui, l'app
    /// pourrait être suspendue entre l'arrêt et l'écriture, puis fermée, et le début serait perdu.
    private func stopLocalGenerations() {
        let stopping = owners.compactMap(\.value)
        let token = stopping.isEmpty ? nil : keeper.begin(name: "Arrêt du modèle local", onExpire: {})
        gate.waitUntilQuiet(timeout: quietTimeout)
        Task.immediate {
            await withDiscardingTaskGroup { group in
                for owner in stopping {
                    group.addImmediateTask { @MainActor in await owner.stopLocalGenerationInBackground() }
                }
            }
            if let token { self.keeper.end(token) }
        }
    }

    /// Une fois, au lancement, avant la première scène. Sans effet sur Mac.
    func start() {
        #if os(iOS)
        guard gate.isEnforced, !isStarted else { return }
        isStarted = true
        observe(UIScene.willEnterForegroundNotification, as: .willEnterForeground)
        observe(UIScene.didActivateNotification, as: .didActivate)
        observe(UIScene.willDeactivateNotification, as: .willDeactivate)
        observe(UIScene.didEnterBackgroundNotification, as: .didEnterBackground)
        observe(UIScene.didDisconnectNotification, as: .didDisconnect)
        #endif
    }

    #if os(iOS)
    /// `queue: nil` : appelé sur le fil qui poste (le fil principal, UIKit), AVANT que le système ne reprenne la main.
    private func observe(_ name: Notification.Name, as event: SceneActivityAggregate<ObjectIdentifier>.Event) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
            guard let scene = note.object as? UIScene else { return }
            let id = ObjectIdentifier(scene)
            MainActor.assumeIsolated { self?.sceneDidChange(event, scene: id) }
        }
        observers.append(observer)
    }
    #endif
}
