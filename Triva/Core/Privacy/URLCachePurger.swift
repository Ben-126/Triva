//
//  URLCachePurger.swift
//  Triva
//
//  Created by ben podrojsky on 10/11/2026.
//

import Foundation

/// Purge UNIQUE du cache HTTP partagé (`URLCache.shared`), au premier lancement
/// qui suit l'arrivée de ce correctif.
///
/// POURQUOI : avant la session sans cache de `SearXNGClient` et
/// `URLSessionFetcher`, `URLSession.shared` écrivait chaque GET dans
/// `Library/Caches/<bundle>/Cache.db`, URL comprise. Les questions de
/// l'utilisateur (`q=…`) y sont restées en clair, et la mission Q2 y a même
/// retrouvé une copie de clé API (un GET `/v1/models` fait avant que la liste
/// des modèles passe par `URLSessionDataRequester.uncachedSession`). Empêcher
/// les nouvelles écritures ne suffit pas : ce qui est déjà sur le disque y reste.
///
/// UNE SEULE FOIS par installation (drapeau dans les préférences) : après la
/// purge, plus rien de sensible n'entre dans ce cache, le vider à chaque
/// lancement n'apporterait que du travail disque inutile. Ne touche à rien
/// d'autre que `URLCache` : ni Trousseau, ni historique, ni préférences.
///
/// Le drapeau n'est posé qu'APRÈS la purge : une app tuée en plein milieu la
/// refait au lancement suivant. `@concurrent` : vider une base SQLite peut
/// prendre un moment, le fil principal ne doit pas l'attendre.
nonisolated struct URLCachePurger: Sendable {
    /// Suffixe de version : une future purge (autre fuite découverte) n'aurait
    /// qu'à changer ce nombre pour se rejouer une fois.
    static let completedFlagKey = "privacy.urlCachePurged.v1"

    /// `UserDefaults` est documenté thread-safe mais n'est pas annoté `Sendable`
    /// par le SDK : `nonisolated(unsafe)` plutôt qu'un `@unchecked Sendable` sur
    /// tout le type, pour que le compilateur continue de vérifier le reste.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let cache: URLCache

    init(defaults: UserDefaults = .standard, cache: URLCache = .shared) {
        self.defaults = defaults
        self.cache = cache
    }

    /// Vrai si la purge a eu lieu pendant cet appel, faux si elle avait déjà été faite.
    @discardableResult
    @concurrent
    func purgeIfNeeded() async -> Bool {
        guard !defaults.bool(forKey: Self.completedFlagKey) else { return false }
        cache.removeAllCachedResponses()
        defaults.set(true, forKey: Self.completedFlagKey)
        return true
    }
}
