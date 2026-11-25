//
//  BackgroundRunKeeper.swift
//  Triva
//
//  Chantier 2.1 (mission D) : demande au système quelques secondes de plus quand l'app passe en arrière-plan au
//  milieu d'une recherche, pour que l'activité en direct continue d'avancer (environ 30 s ; au-delà, l'activité devient
//  périmée et affiche « Recherche interrompue »). Une seule tâche d'arrière-plan par échange, TOUJOURS terminée.
//
//  Mission X1 : `BackgroundExpiryMonitor` prévient quelques secondes avant la fin (le gestionnaire d'expiration est
//  synchrone : le système suspend l'app dès qu'il rend la main, trop tard pour envoyer « interrompue »).
//
//  Doc Apple vérifiée : `UIApplication.beginBackgroundTask(withName:expirationHandler:)` rend un identifiant à
//  passer à `endBackgroundTask(_:)` ; le gestionnaire d'expiration est appelé juste avant la fin du temps accordé
//  (il faut alors terminer la tâche, sinon le système tue l'app) ; l'identifiant vaut `.invalid` si l'arrière-plan
//  n'est pas possible.
//

import Foundation
#if os(iOS)
import UIKit
#endif

nonisolated struct BackgroundRunToken: Hashable, Sendable {
    let rawValue: Int
}

@MainActor
protocol BackgroundRunKeeping: AnyObject {
    /// `nil` si le système refuse. `onExpire` : le temps accordé est presque écoulé (la tâche est alors terminée
    /// par le gardien lui-même, `end` reste sans danger).
    func begin(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) -> BackgroundRunToken?
    func end(_ token: BackgroundRunToken)
}

/// Mac (pas d'activité en direct) et tests : rien à garder.
@MainActor
final class NoBackgroundRunKeeper: BackgroundRunKeeping {
    func begin(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) -> BackgroundRunToken? { nil }
    func end(_ token: BackgroundRunToken) {}
}

#if os(iOS)
@MainActor
final class UIKitBackgroundRunKeeper: BackgroundRunKeeping {
    /// Tâches ouvertes : `endBackgroundTask` n'est appelé qu'UNE fois par identifiant (le système proteste sinon).
    private var open: Set<Int> = []

    /// Surveillances du temps restant, par tâche ouverte.
    private var monitors: [Int: BackgroundExpiryMonitor] = [:]

    func begin(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) -> BackgroundRunToken? {
        let box = TokenBox()
        // `onExpire` ne part qu'UNE fois : d'abord par la surveillance (quelques secondes AVANT la fin, le temps
        // d'envoyer l'état « interrompue »), sinon par le gestionnaire d'expiration d'UIKit.
        let notify: @MainActor () -> Void = {
            guard !box.hasWarned else { return }
            box.hasWarned = true
            onExpire()
        }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Appelé sur le fil principal, juste avant la fin du temps accordé : prévenir si ce n'est pas déjà fait,
            // puis terminer la tâche (sans quoi le système arrête l'app).
            notify()
            if let raw = box.raw { self?.end(BackgroundRunToken(rawValue: raw)) }
        }
        guard identifier != .invalid else { return nil }
        box.raw = identifier.rawValue
        open.insert(identifier.rawValue)
        monitors[identifier.rawValue] = BackgroundExpiryMonitor(
            remainingTime: { UIApplication.shared.backgroundTimeRemaining },
            warn: notify
        )
        return BackgroundRunToken(rawValue: identifier.rawValue)
    }

    func end(_ token: BackgroundRunToken) {
        monitors.removeValue(forKey: token.rawValue)?.cancel()
        guard open.remove(token.rawValue) != nil else { return }
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.rawValue))
    }
}

/// Partage l'identifiant avec le gestionnaire d'expiration, créé avant que l'identifiant existe.
@MainActor
private final class TokenBox {
    var raw: Int?
    var hasWarned = false
}
#endif
