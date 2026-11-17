//
//  SafeSearchPolicy.swift
//  Triva
//

import Foundation

/// Niveau de filtrage de contenu pour adultes envoyé à CHAQUE moteur de recherche.
///
/// Décision de Ben (Q5, révisée le 2026-11-14) : niveau MODÉRÉ PAR DÉFAUT, désactivable dans
/// Réglages > Avancé (« Filtrer les contenus pour adultes »). Source unique : toute valeur envoyée à un moteur vient d'ici,
/// pour qu'un changement de niveau se fasse à un seul endroit.
///
/// Valeurs documentées par fournisseur (consultées le 2026-11-14) :
/// - SearXNG : `safesearch` = 0 (aucun), 1 (modéré), 2 (strict) — recherches web ET images ;
/// - Brave : `safesearch` = `off` | `moderate` | `strict` (défaut `moderate`)
///   https://api-dashboard.search.brave.com/api-reference/web/search/get ;
/// - Tavily : `safe_search` booléen (pas de niveau) — « non pris en charge pour les profondeurs
///   `fast` et `ultra-fast` » ; Triva n'utilise que `basic` et `advanced`
///   https://docs.tavily.com/documentation/api-reference/endpoint/search ;
/// - Marginalia : `nsfw` = 0 (aucun filtre) ou 1 (« réduction expérimentale des résultats
///   extrêmes ») — 1 est le niveau le plus élevé offert
///   https://about.marginalia-search.com/article/api/ .
nonisolated enum SafeSearchPolicy {
    /// Clé `UserDefaults` / `@AppStorage` de l'interrupteur de Réglages > Avancé.
    static let defaultsKey = "search.safeSearch.enabled"
    /// Valeur quand la clé n'a jamais été écrite : filtre ACTIVÉ. Unique source du défaut
    /// (l'interrupteur `@AppStorage` doit l'utiliser aussi).
    static let enabledByDefault = true

    /// Lit le réglage. Évalué à chaque requête, donc pris en compte sans relancer l'app.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? enabledByDefault
    }

    /// SearXNG : 1 = modéré, 0 = aucun filtre.
    static func searXNGLevel(enabled: Bool) -> String { enabled ? "1" : "0" }
    /// Brave : `moderate` ou `off`.
    static func braveLevel(enabled: Bool) -> String { enabled ? "moderate" : "off" }
    /// Tavily : `true` si actif, `nil` (paramètre omis) sinon.
    static func tavilyFlag(enabled: Bool) -> Bool? { enabled ? true : nil }
    /// Marginalia : 1 = réduction des résultats extrêmes (maximum offert), 0 = aucun filtre.
    static func marginaliaLevel(enabled: Bool) -> String { enabled ? "1" : "0" }
}
