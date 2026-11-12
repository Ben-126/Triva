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
/// pas « si aucune autre source ne répond », ce qui serait faux : les sources ouvertes passent après.
///
/// FORMULATION (décision de Ben du 2026-11-11, retouchée d'un mot) : deux phrases courtes, sans la
/// liste des fournisseurs, le coût en « centime » et le reste de la phrase mot pour mot comme il l'a
/// demandé. Seule l'incise a changé, « si aucune autre source ne répond » devenant « si ni tes clés
/// de recherche ni les instances SearXNG ne répondent », pour la raison ci-dessus (À VALIDER PAR BEN).
nonisolated enum CloudWebSearchCostNotice {
    static let sentence =
        "Si ni tes clés de recherche ni les instances SearXNG ne répondent, Triva peut chercher sur le web "
        + "via ton fournisseur IA. C'est facturé sur ton compte (environ 1\u{00A0}centime par recherche "
        + "avec OpenAI)."
}
