//
//  SearchOrchestrator+WebSearchChain.swift
//  Triva
//
//  Created by ben podrojsky on 03/11/2026.
//

import Foundation

/// Tour seedé de la recherche web, avec la chaîne de repli (RI1b). Logique sortie de
/// `SearchOrchestrator.swift`, qui dépasse déjà largement 800 lignes : n'y restent que la
/// plomberie (propriété, paramètre d'init, champ `webSourceKind` des artefacts) et l'appel.
/// Fonction STATIQUE à paramètres explicites : les propriétés de l'orchestrateur sont `private`,
/// donc invisibles depuis ce fichier.
extension SearchOrchestrator {
    /// Sortie du tour seedé, source web qui l'a fournie (`SearchArtifacts.webSourceKind`) et constat
    /// de la chaîne (`SearchArtifacts.webSearchReport`, mission A2).
    nonisolated struct SeededWebSearch: Sendable {
        let output: SearchActionOutput
        let sourceKind: WebSearchSourceKind
        let report: WebSearchChainReport
    }

    /// Tour seedé : l'action de la famille (`WebSearchFlavor.action(webSearchChain:)`), qui passe
    /// par la chaîne de repli quand l'envoi en fournit une, par SearXNG seul sinon.
    ///
    /// Repli du bug 5, SANS chaîne seulement (`WebSearchFlavor.emptyResultFallback(webSearchChain:)`) :
    /// une recherche à moteurs FORCÉS restée vide est relancée une fois en recherche web, même
    /// requête (la reformulation). Un moteur forcé bloqué ou suspendu par l'instance fait répondre
    /// SearXNG en HTTP 200 `{"results": [], "unresponsive_engines": […]}` : un succès pour
    /// `FailoverManager` — à raison, l'instance fonctionne —, et la réponse partait sans aucune
    /// source, là où 0.7 interrogeait toujours les moteurs par défaut. Une erreur, elle, remonte
    /// comme avant. Avec la chaîne, ce repli vit dans son étape SearXNG (`WebSearchChain`), et
    /// toutes les sources en échec lèvent `WebSearchChainError.allSourcesFailed`.
    ///
    /// `trustedDomainsOnly` (mode Fiable) : la chaîne continue tant qu'aucun résultat ne passe le
    /// filtre de domaines (`WebSearchChain.requiringTrustedDomains`). Sans chaîne, sans effet.
    ///
    /// `nonisolated` : tourne sur l'exécuteur de l'orchestrateur (`@concurrent`) ; seuls la
    /// construction de l'action et son aiguillage sautent sur le main actor (types non annotés).
    nonisolated static func seededWebSearch(
        flavor: WebSearchFlavor,
        query: String,
        webSearchChain: WebSearchChain?,
        trustedDomainsOnly: Bool,
        failoverManager: FailoverManager
    ) async throws -> SeededWebSearch {
        let webSearchChain = webSearchChain?.requiringTrustedDomains(trustedDomainsOnly)
        let action = await flavor.action(webSearchChain: webSearchChain)
        let first = try await action.searchWeb(query: query, failoverManager: failoverManager)
        guard first.response.results.isEmpty,
              let fallback = await flavor.emptyResultFallback(webSearchChain: webSearchChain) else {
            return SeededWebSearch(output: .searchResults(first.response.results), sourceKind: first.source, report: first.report)
        }
        let second = try await fallback.searchWeb(query: query, failoverManager: failoverManager)
        return SeededWebSearch(output: .searchResults(second.response.results), sourceKind: second.source, report: second.report)
    }
}
