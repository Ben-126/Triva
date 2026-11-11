//
//  SearXNGMaintenance.swift
//  Triva
//
//  Created by ben podrojsky on 01/11/2026.
//

import Foundation
import OSLog

/// Entretien de fond de la liste d'instances SearXNG (R3 « SearXNG fiabilisé », branché dans
/// l'app par la mission RI1a). À chaque passage de l'app au premier plan, lancement compris :
/// 1. rafraîchit l'annuaire searx.space s'il est dû (`SearXNGDirectoryRefreshing`) ;
/// 2. PUIS re-sonde les instances « médiocres » dont la mise de côté a expiré
///    (`FailoverManager.retestExpiredInstances`), sur un manager construit APRÈS le
///    rafraîchissement : c'est la liste que la prochaine recherche utilisera vraiment qu'il faut
///    juger, pas celle d'avant.
///
/// POURQUOI à chaque activation, et pas seulement au lancement : sur iPhone comme sur Mac, une
/// app reste en mémoire des jours entiers ; « au lancement » seulement ne rafraîchirait presque
/// jamais l'annuaire. Une activation sans rien à faire ne coûte rien : le rafraîchisseur
/// s'auto-limite (au plus une tentative par 24 h, 1 h après un échec hors ligne, date persistée)
/// et la re-sonde ne touche que les instances médiocres, au plus 3 (voir `FailoverManager`).
///
/// JAMAIS BLOQUANT : tout part dans une `Task` de priorité `.background`. Le rafraîchisseur réel
/// et la sonde sont `@concurrent` (hors du main actor), le `FailoverManager` est un acteur :
/// seul l'enchaînement des étapes passe par le main actor. Rien n'est attendu par l'interface :
/// une recherche lancée pendant un passage utilise la liste du moment, la suivante profite de ce
/// que le passage a appris.
///
/// UN SEUL PASSAGE À LA FOIS : une activation pendant un passage ne relance rien (plusieurs
/// fenêtres iPad, allers-retours rapides en arrière-plan). Sans ce verrou, deux passages
/// simultanés pourraient juger tous deux le rafraîchissement dû avant que l'un n'enregistre sa
/// date, et télécharger l'annuaire deux fois en sondant deux fois les mêmes instances.
///
/// Isolé au main actor (défaut du projet, rien à écrire) : il ne fait que lancer une tâche et
/// retenir son handle, sans aucun travail réseau ni calcul.
final class SearXNGMaintenance {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Triva",
        category: "SearXNGMaintenance"
    )

    private let refresher: any SearXNGDirectoryRefreshing
    private let prober: any InstanceProbing
    /// Construit un `FailoverManager` sur la liste d'instances COURANTE, branché sur la mémoire
    /// de fiabilité de l'app. Appelé après le rafraîchissement, jamais avant (voir l'en-tête).
    private let makeFailoverManager: @MainActor () -> FailoverManager
    /// Vrai quand le système dit qu'il n'y a pas de connexion (`ConnectivityMonitor.isOffline`) :
    /// un passage ne ferait que télécharger l'annuaire et sonder des instances dans le vide
    /// (tâche 1.16). Lue à CHAQUE activation, pas mémorisée.
    private let isOffline: @MainActor () -> Bool

    /// Passage en cours, `nil` au repos. Lecture exposée pour les tests.
    private(set) var inFlight: Task<Void, Never>?

    /// - Parameters:
    ///   - refresher: rafraîchissement de l'annuaire. L'app passe un `SearXNGDirectoryRefresher`
    ///     branché sur SES stores (voir `TrivaSharedStores.makeSearXNGMaintenance`).
    ///   - prober: sonde de la re-sonde (la vraie par défaut, une fausse dans les tests).
    ///   - makeFailoverManager: voir la propriété du même nom.
    ///   - isOffline: voir la propriété du même nom ; `{ false }` par défaut (comportement d'avant 1.16).
    init(
        refresher: any SearXNGDirectoryRefreshing,
        prober: any InstanceProbing = SearXNGInstanceHealthProbe(),
        isOffline: @escaping @MainActor () -> Bool = { false },
        makeFailoverManager: @escaping @MainActor () -> FailoverManager
    ) {
        self.refresher = refresher
        self.prober = prober
        self.isOffline = isOffline
        self.makeFailoverManager = makeFailoverManager
    }

    /// À appeler à chaque passage de l'app au premier plan (`scenePhase == .active`), lancement
    /// compris.
    ///
    /// Hors connexion (tâche 1.16) : AUCUN passage — ni téléchargement de l'annuaire, ni sonde. Le
    /// rafraîchisseur n'enregistrerait de toute façon qu'un échec « hors ligne » (nouvel essai dans 1 h)
    /// et la re-sonde mettrait à l'écart des instances qui n'ont rien fait de mal : il n'y a pas de
    /// réseau pour les juger. Le retour de la connexion rappelle cette fonction (`TrivaApp`).
    ///
    /// - Returns: la tâche du passage lancé (que les tests attendent), ou `nil` si un passage
    ///   était déjà en cours ou si l'appareil est hors connexion : rien n'est alors relancé.
    @discardableResult
    func sceneDidBecomeActive() -> Task<Void, Never>? {
        guard inFlight == nil, !isOffline() else { return nil }
        // Le corps de la tâche hérite du main actor : il ne peut donc démarrer qu'après la fin
        // de cette fonction, et `inFlight` est toujours affecté AVANT que `runPass` ne le remette
        // à `nil`.
        // Capture FORTE, volontaire : un passage est court et fini, il garde l'entretien en vie
        // jusqu'à son terme même si son propriétaire le relâche entre-temps. Avec `[weak self]`,
        // un appel « lancé puis oublié » ne ferait rien du tout, puisque la tâche ne démarre
        // qu'après le retour de cette fonction. Aucun cycle durable : `runPass` remet `inFlight`
        // à `nil` en sortant, et la tâche terminée libère sa closure.
        let pass = Task(priority: .background) {
            await self.runPass()
        }
        inFlight = pass
        return pass
    }

    /// Un passage : rafraîchissement, puis re-sonde sur la liste qui en résulte. Les issues sont
    /// journalisées, jamais affichées : un échec ici laisse simplement la liste précédente en
    /// service (voir `SearXNGDirectoryRefresher`). Aucune adresse n'est journalisée, seulement
    /// des issues et des comptes.
    private func runPass() async {
        defer { inFlight = nil }
        let outcome = await refresher.refreshIfNeeded(now: Date(), force: false)
        let recovered = await makeFailoverManager().retestExpiredInstances(using: prober)
        Self.logger.info(
            "Annuaire : \(String(describing: outcome), privacy: .public) ; instances revenues : \(recovered, privacy: .public)"
        )
    }
}
