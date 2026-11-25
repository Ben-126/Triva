//
//  SharedInboxConsumer.swift
//  Triva
//
//  Chantier 2.1 (mission E) : à chaque passage de l'app au premier plan, reprend ce que l'extension de partage a
//  déposé dans l'App Group. Une extension de partage ne peut pas ouvrir l'app (limite Apple) : c'est l'app qui vient
//  chercher. Le texte devient un BROUILLON (`SystemRoute.draft`), le fichier une pièce jointe (`SystemRoute.attachment`) :
//  JAMAIS envoyés, l'utilisateur relit puis valide lui-même.
//

import Foundation

@MainActor
final class SharedInboxConsumer {
    static let shared = SharedInboxConsumer(inbox: SharedInbox.live())

    private let inbox: SharedInbox?
    private let center: SystemRouteCenter
    private let depositRoot: URL
    /// Deux scènes (iPad) peuvent devenir actives presque ensemble : une seule reprise à la fois.
    private var isTakingOver = false

    /// - Parameters:
    ///   - inbox: la boîte de l'App Group, `nil` quand le groupe n'est pas disponible (rien à reprendre).
    ///   - depositRoot: racine du coffre de pièces jointes (celle du contrôleur de pièces jointes de la fenêtre).
    init(
        inbox: SharedInbox?,
        center: SystemRouteCenter = .shared,
        depositRoot: URL = AttachmentFileVault.defaultRootDirectory
    ) {
        self.inbox = inbox
        self.center = center
        self.depositRoot = depositRoot
    }

    /// Reprend le partage le plus récent, s'il y en a un. Sans effet si une reprise est déjà en cours.
    func takeOver() async {
        guard let inbox, !isTakingOver else { return }
        isTakingOver = true
        defer { isTakingOver = false }
        guard let handoff = await SharedInboxHandoff.takeLatest(from: inbox, depositRoot: depositRoot) else { return }
        // Le fichier d'abord : le brouillon qui l'accompagne arrive dans la même fenêtre.
        if let deposit = handoff.depositURL { center.submit(.attachment(deposit)) }
        if let text = handoff.text { center.submit(.draft(text)) }
    }

    /// « Tout effacer » : vide la boîte (entrées, fichiers, copies en cours d'écriture). Appelé par l'étape
    /// « intégrations système » de l'effacement.
    func eraseAll() {
        inbox?.removeAll()
    }
}
