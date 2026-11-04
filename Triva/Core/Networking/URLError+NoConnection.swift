//
//  URLError+NoConnection.swift
//  Triva
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation

extension URLError {
    /// L'APPAREIL n'a pas de connexion utilisable (décision de Ben : on déduit ce cas des erreurs
    /// reçues, sans surveillance réseau en continu).
    ///
    /// Volontairement restreint à ce que le système affirme sur l'appareil. Restent dehors, car un
    /// seul serveur en panne les produit aussi, connexion en parfait état : `cannotFindHost` et
    /// `dnsLookupFailed` (instance disparue), `cannotConnectToHost` (serveur éteint),
    /// `networkConnectionLost` (connexion réutilisée fermée par le serveur).
    nonisolated var indicatesNoConnection: Bool {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: true
        default: false
        }
    }
}
