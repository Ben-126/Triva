//
//  CloudWebSearchCostNotice.swift
//  Triva
//
//  Created by ben podrojsky on 10/11/2026.
//

import Foundation

/// Phrase unique qui prévient l'utilisateur que la recherche web « prêtée » par son fournisseur IA
/// (`CloudWebSearchProvider`) est payante, affichée dans les Réglages concernés (« Clés de
/// recherche », « Fournisseur et modèle »). Une seule source de vérité : les deux écrans disent
/// exactement la même chose.
///
/// POURQUOI cette phrase existe : la requête part de l'appareil vers le fournisseur, sans serveur
/// de Triva entre les deux. Chaque recherche est donc facturée à l'utilisateur, et pas seulement
/// pour la réponse : l'outil de recherche injecte le contenu des pages dans l'entrée. Mesure du
/// 2026-11-10 avec `gpt-6-luna` (modèle de recherche OpenAI par défaut) : 8 692 jetons d'entrée
/// pour 62 de sortie (8 550 jetons d'entrée mesurés auparavant avec `gpt-4o-mini`), plus 10 $ pour
/// 1 000 appels d'outil, soit environ 1 cent par recherche. Seul OpenAI a été mesuré : la phrase ne
/// chiffre donc que lui, et dit seulement « facturée » pour les autres.
///
/// QUAND cela s'applique, pour que la phrase reste vraie : uniquement avec le moteur « Clé API
/// personnelle » (`WebSearchChain.assemble`), et APRÈS les clés de recherche et les instances
/// SearXNG mais AVANT les sources ouvertes (Wikipédia…) : l'ordre est
/// `keyed + searxng + cloud + openSources` (`WebSearchChain.providers(for:)`). La phrase ne dit donc
/// pas « quand aucune autre source ne répond », ce qui serait faux : les sources ouvertes passent après.
nonisolated enum CloudWebSearchCostNotice {
    static let sentence =
        "Avec le moteur «\u{00A0}Clé API personnelle\u{00A0}», quand ni tes clés de recherche ni les "
        + "instances SearXNG ne répondent, Triva peut lancer une recherche web chez ton fournisseur "
        + "(OpenAI, Anthropic, Gemini ou Perplexity) : elle est facturée sur ton compte, environ 1 cent "
        + "par recherche avec OpenAI, où l'outil ajoute environ 8\u{00A0}700 jetons d'entrée."
}
