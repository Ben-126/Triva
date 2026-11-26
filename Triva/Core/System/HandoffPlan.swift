//
//  HandoffPlan.swift
//  Triva
//
//  Chantier 2.3 (missions H1 et H2) : quand et quoi diffuser par Handoff. Pur et testé ; la vue (`HandoffAdvertiser`) ne fait
//  que le brancher sur SwiftUI (`userActivity(_:isActive:_:)`).
//

import Foundation

nonisolated enum HandoffPlan {
    /// Décision de Ben (2026-11-26, mission H2) : l'identifiant de la conversation part toujours avec le texte ; il annonce
    /// que la discussion ENTIÈRE (questions, réponses, sources) peut être demandée par les flux de continuation. Interrupteur
    /// de code : `false` rend exactement le comportement de la mission H1 (le texte seul, jamais l'identifiant, aucun flux
    /// proposé ni servi). Une seule ligne à changer pour revenir en arrière.
    static let offersConversation = true

    /// Le contenu à diffuser, ou `nil` : réglage éteint, ou rien à dire. `nil` éteint l'activité (`isActive == false`).
    ///
    /// Le texte de la barre de saisie d'abord ; à défaut, la dernière question de la conversation affichée (marquée comme
    /// telle : elle est déjà dans la discussion et ne doit pas être remise dans la barre de l'autre appareil).
    static func payload(
        isEnabled: Bool,
        draft: String?,
        lastQuestion: String?,
        conversationID: UUID?,
        offersConversation: Bool = HandoffPlan.offersConversation
    ) -> HandoffPayload? {
        guard isEnabled else { return nil }
        let sharedID = offersConversation ? conversationID : nil
        return HandoffPayload(draft: draft, conversationID: sharedID, draftIsTyped: true)
            ?? HandoffPayload(draft: lastQuestion, conversationID: sharedID, draftIsTyped: false)
    }

    /// Vrai si une activité doit être annoncée au système.
    static func isActive(isEnabled: Bool, draft: String?, lastQuestion: String?) -> Bool {
        payload(isEnabled: isEnabled, draft: draft, lastQuestion: lastQuestion, conversationID: nil) != nil
    }
}
