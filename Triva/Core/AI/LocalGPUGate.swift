//
//  LocalGPUGate.swift
//  Triva
//
//  Mission M (25/11) : quitter l'app pendant une réponse du modèle local la faisait planter sur iPhone.
//
//  Pourquoi : iOS et iPadOS refusent tout nouveau travail Metal d'une app en arrière-plan
//  (`MTLCommandBufferError.notPermitted`). MLX apprend ce refus dans le gestionnaire de fin du tampon et y lève une
//  exception C++ (`check_error`), hors de la pile Swift : aucun `catch` possible, l'app meurt.
//  Doc Apple « Preparing your Metal app to run in the background » : cesser d'envoyer du travail à la désactivation,
//  et s'assurer avant de rendre la main dans `didEnterBackground` que le travail déjà envoyé est pris en charge.
//
//  Ce que fait la barrière : chaque étape du modèle (un mot produit, un morceau de question lu) passe par `checkpoint`.
//  - app active : rien (un verrou et une comparaison) ;
//  - app inactive (Centre de contrôle, appel, sortie en cours) : le fil attend la fin des tampons déjà envoyés
//    (`drain`, permis : l'app est encore au premier plan), puis se GARE ; il repart tel quel au retour, rien n'est coupé ;
//  - app en arrière-plan : le fil se gare SANS rien envoyer, même pas `drain` (`Stream.synchronize()` envoie un tampon
//    vide, refusé lui aussi). Il n'est jamais relâché en arrière-plan.
//
//  Annuler une génération MLX envoie AUSSI un tampon (mlx-swift-lm synchronise en sortant : `generateLoopTask`,
//  `MLXLanguageModel.respond`). L'annulation qui arrive hors du premier plan (Stop automatique, Siri) est donc retenue
//  jusqu'au retour (`whenActive`) ; celui qui attendait la réponse, lui, reprend la main tout de suite.
//
//  Garer bloque un fil du pool coopératif : c'est voulu. La boucle de mlx-swift-lm est synchrone, il n'existe pas
//  d'autre endroit où la suspendre sans modifier la dépendance. Le fil est réveillé par le fil principal, jamais par
//  une autre tâche du pool : pas d'interblocage.
//

import Foundation

/// Ce que le système permet au GPU, pour l'app entière (toutes scènes confondues).
nonisolated enum LocalGPUPhase: Sendable, Equatable {
    case active
    /// Au premier plan mais ne reçoit plus les événements : le GPU est encore permis, l'arrière-plan peut suivre.
    case inactive
    /// Aucun travail Metal permis.
    case background
}

/// Erreur d'un travail du modèle local demandé alors que l'app reste en arrière-plan.
nonisolated enum LocalGPUGateError: Error, Sendable, Equatable {
    case unavailableInBackground
}

/// `@unchecked Sendable` : tout l'état est lu et écrit sous `condition`.
nonisolated final class LocalGPUGate: @unchecked Sendable {
    /// iOS et iPadOS coupent le GPU des apps en arrière-plan ; le Mac, non.
    static var platformRestrictsGPU: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// La barrière de l'app. Au lancement sur iOS : « arrière-plan » tant qu'aucune scène n'est active (une app à scènes
    /// démarre dans cet état, et Siri peut la lancer sans jamais la montrer).
    static let shared = LocalGPUGate(
        isEnforced: platformRestrictsGPU,
        initialPhase: platformRestrictsGPU ? .background : .active
    )

    /// Pas entre deux regards d'une attente `async` (l'attente n'a lieu que hors de l'état actif).
    private static let pollInterval = Duration.milliseconds(50)
    /// Temps laissé à l'app pour revenir au premier plan quand un travail DÉMARRE en arrière-plan (passage au premier
    /// plan demandé par Siri). Compté en battements : une app suspendue ne « vieillit » pas.
    static let defaultBackgroundPatience = 200
    /// Temps laissé aux tampons DÉJÀ envoyés d'un fil garé sans les avoir attendus (au plus un morceau de question).
    static let defaultSettleTime: TimeInterval = 0.5

    /// Faux (Mac) : la barrière est toujours ouverte et le modèle n'est même pas enveloppé.
    let isEnforced: Bool
    private let condition = NSCondition()
    private var currentPhase: LocalGPUPhase
    private var runningCount = 0
    private var parkedCount = 0
    /// Fils garés sans avoir pu attendre leurs tampons (arrivés à la barrière l'app déjà en arrière-plan).
    private var undrainedCount = 0
    private var deferredActions: [@Sendable () -> Void] = []

    init(isEnforced: Bool, initialPhase: LocalGPUPhase) {
        self.isEnforced = isEnforced
        self.currentPhase = isEnforced ? initialPhase : .active
    }

    // MARK: - État

    var phase: LocalGPUPhase {
        condition.withLock { currentPhase }
    }

    /// Travaux en cours (générations, chargements) et fils garés : pour les tests et les journaux.
    var counts: (running: Int, parked: Int) {
        condition.withLock { (runningCount, parkedCount) }
    }

    /// Sans effet quand la barrière n'est pas imposée.
    func setPhase(_ newPhase: LocalGPUPhase) {
        guard isEnforced else { return }
        let actions = condition.withLock {
            currentPhase = newPhase
            condition.broadcast()
            guard newPhase == .active else { return [@Sendable () -> Void]() }
            defer { deferredActions = [] }
            return deferredActions
        }
        for action in actions { action() }
    }

    /// Exécute `action` maintenant si le GPU est permis, sinon au retour au premier plan. Pour les annulations : voir
    /// la note de tête.
    func whenActive(_ action: @escaping @Sendable () -> Void) {
        let isActive = condition.withLock {
            if currentPhase != .active { deferredActions.append(action) }
            return currentPhase == .active
        }
        if isActive { action() }
    }

    // MARK: - Fil du modèle

    /// À appeler AVANT chaque travail envoyé au GPU. Rend la main aussitôt si l'app est active ; sinon gare le fil
    /// jusqu'au retour au premier plan. `drain` : attend la fin des travaux déjà envoyés (jamais appelé en arrière-plan).
    func checkpoint(drain: () -> Void) {
        guard isEnforced else { return }
        condition.lock()
        defer { condition.unlock() }
        var didDrain = false
        while currentPhase != .active {
            if currentPhase == .inactive, !didDrain {
                didDrain = true
                condition.unlock()
                drain()
                condition.lock()
                continue
            }
            let isUndrained = !didDrain
            parkedCount += 1
            if isUndrained { undrainedCount += 1 }
            condition.broadcast()
            while currentPhase != .active { condition.wait() }
            parkedCount -= 1
            if isUndrained { undrainedCount -= 1 }
        }
    }

    // MARK: - Début et fin d'un travail

    /// Attend que le GPU soit permis, puis compte le travail. Inactif : attend le retour, aussi longtemps qu'il faut.
    /// Arrière-plan : attend `backgroundPatience` battements puis lève (`nil` : attend toujours). Annulable.
    func begin(backgroundPatience: Int? = defaultBackgroundPatience) async throws -> LocalGPUWork {
        var backgroundBeats = 0
        while true {
            try Task.checkCancellation()
            if let work = beginIfActive() { return work }
            if phase == .background {
                backgroundBeats += 1
                if let backgroundPatience, backgroundBeats > backgroundPatience {
                    throw LocalGPUGateError.unavailableInBackground
                }
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Vérification et comptage sous le même verrou : l'app ne peut pas s'éclipser entre les deux.
    private func beginIfActive() -> LocalGPUWork? {
        condition.withLock {
            guard currentPhase == .active else { return nil }
            runningCount += 1
            return LocalGPUWork(gate: self)
        }
    }

    fileprivate func finishOne() {
        condition.withLock {
            runningCount -= 1
            condition.broadcast()
        }
    }

    // MARK: - Passage en arrière-plan

    /// Bloque l'appelant (le fil principal, dans `didEnterBackground`) jusqu'à ce que chaque travail en cours soit fini
    /// ou garé, au plus `timeout` secondes (le système en accorde environ cinq). `true` : plus rien ne part au GPU.
    /// Un fil garé sans avoir attendu ses tampons (écran verrouillé d'un coup) : on leur laisse `settleTime`, car Apple
    /// demande qu'ils soient pris en charge avant de rendre la main et les attendre par MLX en enverrait un de plus.
    @discardableResult
    func waitUntilQuiet(timeout: TimeInterval, settleTime: TimeInterval = defaultSettleTime) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while runningCount > parkedCount {
            guard condition.wait(until: deadline) else { return runningCount <= parkedCount }
        }
        let settleDeadline = min(deadline, Date(timeIntervalSinceNow: settleTime))
        while undrainedCount > 0 {
            guard condition.wait(until: settleDeadline) else { break }
        }
        return true
    }
}

/// Un travail compté par la barrière. `finish` est sans effet la deuxième fois.
nonisolated final class LocalGPUWork: @unchecked Sendable {
    /// Après une annulation ou une erreur, mlx-swift-lm peut encore finir l'étape en cours puis synchroniser, alors que
    /// l'appelant a déjà repris la main : le travail reste compté ce temps-là.
    static let cancellationGrace = Duration.milliseconds(1_500)
    /// Fin normale : MLX synchronise le GPU en sortant, au moment même où l'appelant reçoit la fin de la réponse.
    static let completionGrace = Duration.milliseconds(300)

    private let gate: LocalGPUGate
    private let lock = NSLock()
    private var isFinished = false

    fileprivate init(gate: LocalGPUGate) {
        self.gate = gate
    }

    func finish() {
        let isFirst = lock.withLock {
            defer { isFinished = true }
            return !isFinished
        }
        if isFirst { gate.finishOne() }
    }

    /// Fin après une annulation ou une erreur : voir `cancellationGrace`.
    func finishAfterGrace(_ grace: Duration = cancellationGrace) {
        Task.detached {
            try? await Task.sleep(for: grace)
            self.finish()
        }
    }

    /// Un travail oublié ne doit pas faire attendre chaque passage en arrière-plan.
    deinit {
        if !isFinished { gate.finishOne() }
    }
}
