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
/// Fonction STATIQUE à paramètres explicites, par choix : elle se teste sans construire d'orchestrateur,
/// et `nonisolated` la garde hors du main actor. (Plusieurs propriétés de l'orchestrateur sont
/// internes depuis le découpage E1 : ce n'est plus la visibilité qui l'impose.)
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

    /// Mission C1, R1-2 : le verdict de pertinence de la chaîne porte sur la réponse BRUTE du moteur
    /// (un seul résultat pertinent suffit à la retenir), mais ce que l'utilisateur voit et ce que le
    /// modèle cite, ce sont les sources CLASSÉES (plancher de score, top N, alternance des langues).
    /// Le classement peut écarter justement l'unique résultat pertinent : toutes les sources restantes
    /// sont hors sujet, et ni le refus du mode Fiable ni le rappel hors-sujet ne se déclenchaient.
    ///
    /// Rejuge donc les sources classées avec le MÊME test (`LexicalRelevance`, mêmes mots vides, même
    /// exigence de 2 mots). Ne fait que DÉGRADER un verdict favorable : un constat déjà négatif, une
    /// liste vide ou sans aucun extrait (rien à juger, comme dans `LexicalRelevance.assess`) sont rendus tels quels.
    /// Seulement avec une chaîne de repli, seule à juger : sans elle `matchesQuestion` reste vrai
    /// (« rien n'est jugé »), comme documenté dans `SearchArtifacts+ReliableMode`.
    nonisolated static func report(
        _ report: WebSearchChainReport,
        rejudgedOn rankedSources: [SearXNGSearchResult],
        query: String,
        hasChain: Bool
    ) -> WebSearchChainReport {
        guard hasChain, report.matchesQuestion, !rankedSources.isEmpty else { return report }
        guard case .offTopic = LexicalRelevance(query: query).assess(rankedSources) else { return report }
        var rejudged = report
        rejudged.matchesQuestion = false
        return rejudged
    }
}
