//
//  TrivaRootCoordinator+Windows.swift
//  Triva
//
//  Chantier 2.2 (M2) : « une recherche = une fenêtre » (Mac, iPad).
//

import Foundation

extension TrivaRootCoordinator {
    /// Titre d'une fenêtre qui n'affiche aucune conversation enregistrée.
    static let newSearchTitle = "Nouvelle recherche"

    /// Aligne la cible de la fenêtre (`windowTarget`), son titre et le registre sur le fil réellement affiché.
    ///
    /// La valeur suit la session dans LES DEUX SENS : une conversation enregistrée ou rouverte donne
    /// `.conversation(id)` ; un fil vidé (nouvelle conversation, suppression) redonne une recherche neuve
    /// avec un identifiant NEUF. Sans cela, deux fenêtres ouvertes sur la même conversation (« Ouvrir dans une
    /// nouvelle fenêtre ») écriraient toutes deux dans `ChatHistoryStore`.
    ///
    /// Une recherche neuve DÉJÀ neuve garde son identifiant : changer la valeur d'une fenêtre sans raison
    /// serait du bruit pour la restauration.
    ///
    /// - Parameter refreshTitle: relit le titre de la conversation même si elle n'a pas changé (historique modifié).
    func syncWindowTarget(refreshTitle: Bool = false) {
        let displayed = session.chatViewModel?.currentConversationID
        let newTarget: TrivaWindowTarget
        switch (displayed, windowTarget) {
        case (let id?, _):
            newTarget = .conversation(id)
        case (nil, .conversation):
            newTarget = .freshSearch()
        case (nil, .newSearch):
            newTarget = windowTarget
        }
        let changed = newTarget != windowTarget
        if changed { windowTarget = newTarget }
        if changed || refreshTitle { updateSearchTitle(for: displayed) }
        windowRegistry.setDisplayed(displayed, in: windowID)
    }

    /// Première apparition de la fenêtre avec la cible mémorisée par SwiftUI (relancement, ou ouverture
    /// par `openWindow(value:)`). Une conversation supprimée entre-temps redevient une recherche neuve
    /// (`TrivaWindowTarget.restored`), de même qu'une conversation qu'une AUTRE fenêtre tient déjà
    /// (`WindowConversationRegistry`) : c'est la garde qui empêche deux fenêtres d'écrire la même.
    ///
    /// Base illisible : on tente quand même d'ouvrir la conversation, le chat affiche alors l'erreur de
    /// persistance plutôt que d'oublier silencieusement la fenêtre.
    ///
    /// - Parameter externalInbox: boîte des demandes extérieures. Une conversation que le widget, Spotlight ou un raccourci
    ///   vient de demander et qui n'existe plus est ANNONCÉE (« Cette conversation n'existe plus. »), comme sur iPhone ; à la
    ///   restauration d'un relancement, la fenêtre redevient une recherche neuve sans rien dire (R2-19).
    func restoreWindowTarget(_ target: TrivaWindowTarget, externalInbox: ExternalQueryInbox? = nil) {
        switch target {
        case .newSearch:
            windowTarget = target
        case .conversation(let id):
            let requestedFromOutside = externalInbox?.takeConversationRequest(id) ?? false
            // Une autre fenêtre tient déjà cette conversation (elle ou une de ses réponses en cours) : deux
            // fenêtres écriraient dedans. Cette fenêtre devient une recherche neuve, sans rien charger.
            let isHeldElsewhere = windowRegistry.isHeld(id, excluding: windowID)
            let exists = conversationExists(id)
            let existing: Set<UUID> = exists && !isHeldElsewhere ? [id] : []
            let resolved = TrivaWindowTarget.restored(target, existingIDs: existing)
            if case .conversation = resolved {
                openConversation(id: id)
            } else {
                windowTarget = resolved
                // Fenêtre créée sur une conversation qu'une autre tient : plutôt que de laisser la seule recherche
                // vide, la fenêtre qui tient la conversation passe devant (rapport W2-G1, point 4).
                if isHeldElsewhere {
                    windowRegistry.focusHolder(of: id, excluding: windowID)
                } else if requestedFromOutside && !exists {
                    session.ensureChatViewModel()
                    session.chatViewModel?.reportMissingConversation()
                }
            }
        }
        syncWindowTarget(refreshTitle: true)
    }

    /// La valeur de scène a CHANGÉ après le premier affichage : si c'est la conversation restaurée du relancement
    /// (arrivée après le premier rendu), la fenêtre vierge la rouvre. Mêmes règles que `restoreWindowTarget` :
    /// supprimée ou tenue par une autre fenêtre, elle donne une recherche neuve. Ce que la fenêtre a elle-même
    /// publié (écho) n'est jamais rouvert : voir `WindowRestoration`.
    ///
    /// - Returns: `true` si la valeur a été prise pour une restauration (la cible de la fenêtre a pu changer).
    @discardableResult
    func receiveLateWindowValue(_ value: TrivaWindowTarget, restoration: WindowRestoration) -> Bool {
        let isPristine = windowTarget.conversationID == nil && session.chatViewModel?.currentConversationID == nil
        guard let target = restoration.lateTarget(for: value, isPristine: isPristine) else { return false }
        restoreWindowTarget(target)
        restoration.noteHeld(windowTarget)
        return true
    }

    /// Bibliothèque ou favori > une conversation, DEPUIS cette fenêtre.
    ///
    /// Déjà tenue par une autre fenêtre : cette fenêtre-là passe au premier plan (`focusHolder`, fenêtre AppKit ou
    /// scène iPad) au lieu de charger la conversation une seconde fois ici ou d'ouvrir une fenêtre vide. Si elle
    /// ne sait pas se mettre devant, repli sur `openInWindow` (`openWindow(value: .conversation(id))`, qui ramène
    /// la fenêtre dont la valeur est cette conversation). Sinon, comportement d'avant : elle s'ouvre ici.
    ///
    /// - Parameters:
    ///   - canUseOtherWindows: l'appareil ouvre plusieurs fenêtres (`supportsMultipleWindows`).
    ///   - openInWindow: ouvre ou ramène la fenêtre de cette conversation.
    func openConversationFromHistory(id: UUID, canUseOtherWindows: Bool, openInWindow: (UUID) -> Void) {
        if canUseOtherWindows, windowRegistry.isHeld(id, excluding: windowID) {
            if !windowRegistry.focusHolder(of: id, excluding: windowID) { openInWindow(id) }
        } else {
            openConversation(id: id)
        }
    }

    // MARK: - Privé

    /// Faux si la conversation est absente. Une erreur de lecture compte comme « existe » : la
    /// restauration ne doit pas jeter une fenêtre sur une panne passagère de la base.
    private func conversationExists(_ id: UUID) -> Bool {
        do {
            return try session.stores.chatHistory.conversation(with: id) != nil
        } catch {
            return true
        }
    }

    private func updateSearchTitle(for conversationID: UUID?) {
        guard let conversationID,
              let stored = try? session.stores.chatHistory.conversation(with: conversationID),
              !stored.title.isEmpty else {
            searchTitle = Self.newSearchTitle
            return
        }
        searchTitle = stored.title
    }
}
