//
//  HandoffRoute.swift
//  Triva
//
//  Chantier 2.3 (missions H1 et H2) : lire l'en-tête d'une activité Handoff reçue. ENTRÉE EXTERNE : un autre appareil (ou
//  un autre programme qui se ferait passer pour lui) peut envoyer n'importe quoi. Ce qui sort d'ici est un en-tête vérifié ;
//  ce qu'on en fait (`HandoffReceiver`) ne sait que NAVIGUER ou remplir la barre de saisie, jamais envoyer.
//

import Foundation

nonisolated enum HandoffRoute {
    /// L'en-tête vérifié, ou `nil` si l'activité est refusée (autre type, version inconnue, texte vide ou illisible).
    static func payload(forActivityType activityType: String, userInfo: [AnyHashable: Any]?) -> HandoffPayload? {
        guard activityType == HandoffPayload.activityType else { return nil }
        return HandoffPayload(userInfo: userInfo)
    }
}
