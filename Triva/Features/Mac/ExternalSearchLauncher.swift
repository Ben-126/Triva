//
//  ExternalSearchLauncher.swift
//  Triva
//
//  Chantier 2.2 (M7) : tout ce qui vient « de l'extérieur » et doit ouvrir une fenêtre de recherche
//  (Service « Rechercher avec Triva », barre des menus, menu du Dock) passe par ce point unique.
//

import Foundation
import Observation
import SwiftUI

/// File des fenêtres à ouvrir à la demande de l'extérieur du fil de l'app.
///
/// Pourquoi une file et pas un appel direct à `openWindow` : le Service du Mac, le menu du Dock et le panneau de
/// la barre des menus n'ont pas d'environnement SwiftUI. Ils déposent ici une cible (`TrivaWindowTarget`), et un
/// observateur (la scène de l'app, ou une fenêtre déjà ouverte) l'ouvre. Trois sources, un seul chemin.
///
/// La question reçue n'est JAMAIS écrite dans la cible (qui est enregistrée sur disque par SwiftUI pour la
/// restauration) : elle reste en mémoire dans la boîte d'entrée (`ExternalQueryInbox`) et la fenêtre neuve la
/// reprend par l'identifiant de sa cible.
@Observable
final class ExternalSearchLauncher {
    /// Exemplaire de l'app. Les tests construisent le leur.
    static let shared = ExternalSearchLauncher()

    /// Message du Service quand la sélection est vide ou illisible (affiché par le système).
    static let noTextMessage = "Aucun texte sélectionné."

    /// Cibles en attente au plus : si personne ne les ouvre, la file ne grossit pas.
    static let maxPending = 8

    let inbox: ExternalQueryInbox

    /// Augmente à chaque demande : déclencheur des `onChange` qui ouvrent les fenêtres.
    private(set) var revision = 0

    /// Fenêtres de recherche actuellement affichées, PAR IDENTIFIANT : SwiftUI peut rappeler `onAppear` sans
    /// `onDisappear` (réactivation de scène, restauration), ce qui faisait dériver un simple compteur au-dessus de
    /// zéro après la fermeture de toutes les fenêtres (la scène de l'app n'ouvrait alors plus rien). Avec des
    /// identifiants, une apparition répétée est sans effet.
    @ObservationIgnored private var visibleWindowIDs: Set<UUID> = []
    /// Nombre de fenêtres affichées. Sert à départager les observateurs : tant qu'une fenêtre existe, c'est elle
    /// qui ouvre ; la scène de l'app n'ouvre que quand il n'y en a plus aucune.
    private(set) var visibleWindowCount = 0

    @ObservationIgnored private var pending: [TrivaWindowTarget] = []

    init(inbox: ExternalQueryInbox = ExternalQueryInbox()) {
        self.inbox = inbox
    }

    // MARK: Demandes

    /// Une recherche avec cette question. La question est assainie (`ExternalQuerySanitizer`) ; vide ou illisible,
    /// rien n'est ouvert.
    /// - Parameter origin: `.draft` (Service, partage, dépôts : la question reste dans la barre de saisie, jamais
    ///   envoyée) ou `.typedInMenuBar` (le panneau de la barre des menus : envoyée par la fenêtre).
    /// - Returns: `true` si une fenêtre va s'ouvrir.
    @discardableResult
    func requestSearch(question: String?, origin: ExternalQueryOrigin = .draft) -> Bool {
        guard let clean = ExternalQuerySanitizer.sanitizeReportingTruncation(question) else { return false }
        let id = inbox.deposit(clean.text, origin: origin, wasTruncated: clean.wasTruncated)
        enqueue(.newSearch(id))
        return true
    }

    /// Une fenêtre de recherche vide (menu du Dock, barre des menus).
    func requestNewSearch() {
        enqueue(TrivaWindowTarget.freshSearch())
    }

    /// Une conversation de l'historique ; si une fenêtre l'affiche déjà, SwiftUI la ramène au premier plan.
    func requestConversation(_ id: UUID) {
        enqueue(.conversation(id))
    }

    /// Rend les cibles à ouvrir et vide la file : deux observateurs qui réagissent à la même demande n'ouvrent
    /// donc jamais deux fenêtres.
    func drain() -> [TrivaWindowTarget] {
        let targets = pending
        pending.removeAll()
        return targets
    }

    // MARK: Fenêtres affichées

    func windowDidAppear(id: UUID) {
        visibleWindowIDs.insert(id)
        visibleWindowCount = visibleWindowIDs.count
    }

    func windowDidDisappear(id: UUID) {
        visibleWindowIDs.remove(id)
        visibleWindowCount = visibleWindowIDs.count
    }

    // MARK: Privé

    private func enqueue(_ target: TrivaWindowTarget) {
        pending.append(target)
        if pending.count > Self.maxPending {
            pending.removeFirst(pending.count - Self.maxPending)
        }
        revision += 1
    }
}

extension EnvironmentValues {
    /// Boîte d'entrée des questions venues de l'extérieur. `nil` : aperçus et tests, la coquille n'y lit rien.
    @Entry var externalQueryInbox: ExternalQueryInbox? = nil
}
