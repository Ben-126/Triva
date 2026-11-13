//
//  SourceRanker+PureFunctions.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

// Sorti de `SourceRanker.swift` (mission E1c) : déplacement pur, aucun
// changement de code ni de comportement. Les fonctions pures et statiques
// (contenu classé, scores, domaines de confiance, normalisation d'URL),
// testables seules. `nonisolated extension` : `SourceRanker` est `nonisolated`,
// mais une extension dans un autre fichier n'en hérite pas.
nonisolated extension SourceRanker {
    // MARK: - Fonctions pures (testables seules)

    /// Texte représentant un résultat pour le calcul de similarité. Port de
    /// `r.content || r.title` (version web d'origine) : en JavaScript une chaîne vide est
    /// falsy, donc un extrait vide bascule automatiquement sur le titre.
    /// Swift n'ayant pas cette notion, on teste explicitement le contenu non
    /// vide APRÈS nettoyage des blancs — sinon un `content: " "` renvoyé par
    /// une instance SearXNG donnerait une similarité nulle alors que le titre
    /// était parfaitement exploitable.
    static func rankedContent(of result: SearXNGSearchResult) -> String {
        guard let content = result.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return result.title }
        return content
    }

    /// `max(0, 1 - position * 0,1)`, port littéral.
    ///
    /// Le plafond à 1 est un ajout : une position négative est impossible via
    /// `rank` (les index d'un tableau Swift ne le sont jamais), mais la
    /// fonction est exposée pour les tests et rien ne doit pouvoir produire
    /// un score de position supérieur à celui du tout premier résultat.
    static func positionScore(forPosition position: Int) -> Double {
        min(1, max(0, 1 - Double(position) * positionScoreDecay))
    }

    /// `(similarity * 0,7 + positionScore * 0,3) * domainMultiplier`, dans
    /// cet ordre exact d'opérations — les tests répliquent la même expression
    /// pour pouvoir comparer au bit près, sans tolérance arbitraire.
    static func relevanceScore(similarity: Double, positionScore: Double, domainMultiplier: Double) -> Double {
        (similarity * similarityWeight + positionScore * positionWeight) * domainMultiplier
    }

    /// Multiplicateur de domaine.
    ///
    /// LES DOMAINES BOOSTÉS SONT TESTÉS EN PREMIER ET L'EMPORTENT :
    /// `docs.quora.com` vaut 1,25 et non 0,4. C'est le comportement de la version web d'origine,
    /// dont la boucle `for` retourne dès le premier motif boosté trouvé ;
    /// conservé tel quel pour ne pas modifier silencieusement un classement
    /// au passage d'un portage.
    static func domainMultiplier(for url: String) -> Double {
        guard let host = normalizedHost(of: url) else { return neutralMultiplier }
        if boostedDomains.contains(where: { matches(host: host, pattern: $0) }) {
            return boostedMultiplier
        }
        if penalizedDomains.contains(where: { matches(host: host, pattern: $0) }) {
            return penalizedMultiplier
        }
        return neutralMultiplier
    }

    /// Un domaine est "fiable" (mode `reliable`, 1.13) s'il est boosté.
    /// Défini EN FONCTION de `boostedDomains` plutôt que par une liste
    /// parallèle : deux listes censées dire la même chose finissent toujours
    /// par diverger.
    static func isTrustedDomain(_ url: String) -> Bool {
        guard let host = normalizedHost(of: url) else { return false }
        return boostedDomains.contains { matches(host: host, pattern: $0) }
    }

    /// Hôte de l'URL, en minuscules et sans `www.`.
    ///
    /// DIVERGENCE VOLONTAIRE vis-à-vis de la version web d'origine, qui fait un simple
    /// `url.toLowerCase().includes(motif)` sur l'URL ENTIÈRE. Ce test produit
    /// trois faux positifs bien réels :
    /// - `.edu` matche `monsite.education.fr`, et `.gov` matche
    ///   `un-blog.gov-conspiracy.net` ;
    /// - `github.com` matche `github.com.phishing.example` — un domaine que
    ///   son propriétaire contrôle entièrement, donc une faille de classement
    ///   exploitable par n'importe qui ;
    /// - `wikipedia.org` matche `spam.example/?q=wikipedia.org`, c'est-à-dire
    ///   une simple mention dans le chemin ou la requête.
    ///
    /// On raisonne donc sur l'hôte réel, extrait via `URLComponents`. C'est
    /// strictement plus juste, et la seule chose qu'on "perd" par rapport à la
    /// version web d'origine est la correspondance sur des mentions hors-hôte, qui n'avait
    /// aucun sens.
    ///
    /// URL non analysable ou sans hôte -> `nil` -> multiplicateur neutre : une
    /// URL qu'on ne comprend pas ne doit être ni récompensée ni punie.
    static func normalizedHost(of url: String) -> String? {
        guard
            let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
            let host = components.host?.lowercased(),
            !host.isEmpty
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst("www.".count)) : host
    }

    /// Nombre de caractères d'un domaine national de premier niveau (`.uk`,
    /// `.fr`, `.au`…). Sert à reconnaître les `gov.uk` / `edu.au` sans
    /// embarquer de liste de suffixes publics — voir `matches(host:pattern:)`.
    private static let countryCodeTopLevelDomainLength = 2

    /// Décide si `host` correspond à `pattern`. Trois formes, déduites de la
    /// forme du motif lui-même pour que les listes restent des copies
    /// littérales de celles de la version web d'origine :
    ///
    /// - `".gov"` (commence par un point) — domaine de premier niveau. Matche
    ///   `nasa.gov`, et `data.gov.uk` via la règle ccTLD ci-dessous.
    /// - `"docs."` (finit par un point) — préfixe de sous-domaine. Matche
    ///   `docs.python.org` et `fr.docs.example.com`, mais pas
    ///   `mydocs.example.com` ni `example.com/docs.html` (on ne regarde que
    ///   l'hôte).
    /// - tout le reste — domaine complet. Matche le domaine exact et ses
    ///   sous-domaines (`fr.wikipedia.org`), jamais un domaine qui se contente
    ///   de le contenir (`notwikipedia.org`, `github.com.phishing.example`).
    ///
    /// RÈGLE ccTLD, la seule subtilité : `.gov` doit matcher `data.gov.uk`
    /// (vrai portail public britannique, que le `includes('.gov')` de la version web d'origine
    /// attrapait aussi) sans matcher `evil.gov.com`. Un simple
    /// `host.contains(".gov.")` attraperait les deux — or `gov.com` est un
    /// domaine librement enregistrable, donc ce serait un trou de classement
    /// exploitable, pas une hypothèse d'école. On exige donc que le motif
    /// soit l'AVANT-DERNIER label et que le dernier fasse exactement
    /// 2 caractères, longueur d'un domaine national.
    ///
    /// Approximation assumée : pas de liste de suffixes publics (ce serait
    /// une dépendance et des centaines de lignes à maintenir pour un gain
    /// marginal). Elle laisse donc passer `x.gov.co` — `.co` étant un vrai
    /// ccTLD, c'est le prix de l'heuristique, et le risque résiduel est très
    /// inférieur à celui qu'elle supprime.
    static func matches(host: String, pattern: String) -> Bool {
        if pattern.hasPrefix(".") {
            if host.hasSuffix(pattern) { return true }

            let labels = host.split(separator: ".")
            guard labels.count >= 2, let lastLabel = labels.last else { return false }
            return labels[labels.count - 2] == pattern.dropFirst()
                && lastLabel.count == countryCodeTopLevelDomainLength
        }

        if pattern.hasSuffix(".") {
            return host.hasPrefix(pattern) || host.contains("." + pattern)
        }

        return host == pattern || host.hasSuffix("." + pattern)
    }

    /// Préfixes de paramètres de requête purement analytiques, retirés de la
    /// clé de déduplication.
    static let trackingQueryParameterPrefixes = ["utm_"]

    /// Noms exacts de paramètres de suivi, retirés eux aussi : deux liens
    /// vers la même page qui ne diffèrent que par leur provenance sont un
    /// seul et même document.
    ///
    /// Liste NOMMÉE et volontairement courte — un paramètre inconnu est
    /// CONSERVÉ, car beaucoup de sites font transiter le contenu réel par la
    /// requête (`?id=`, `?page=`, `?v=` sur YouTube) et les fusionner
    /// perdrait de vraies sources distinctes. L'erreur "deux entrées pour la
    /// même page" est bien moins grave que l'erreur "une seule entrée pour
    /// deux pages différentes".
    static let trackingQueryParameterNames: Set<String> = [
        "fbclid",
        "gclid",
        "gbraid",
        "wbraid",
        "msclkid",
        "yclid",
        "igshid",
        "mc_cid",
        "mc_eid",
        "ref_src",
    ]

    /// Clé de déduplication d'une URL : schéma + hôte (sans `www.`) + chemin
    /// (sans slash final) + paramètres non analytiques triés.
    ///
    /// Le fragment (`#section`) est retiré : il désigne un endroit DANS un
    /// document, pas un autre document. Le tri des paramètres restants rend
    /// la clé indépendante de l'ordre dans lequel l'instance les a renvoyés —
    /// deux moteurs agrégés peuvent remonter `?a=1&b=2` et `?b=2&a=1` pour la
    /// même page.
    ///
    /// Le chemin n'est PAS mis en minuscules : sur la plupart des serveurs il
    /// est sensible à la casse, `/Article` et `/article` peuvent être deux
    /// pages distinctes. L'hôte, lui, ne l'est jamais.
    ///
    /// LIMITE ASSUMÉE : `http://` et `https://` produisent deux clés
    /// différentes, le schéma faisant partie de la clé. Ce cas est rattrapé
    /// par le second niveau de déduplication — deux variantes de protocole de
    /// la même page portent le même extrait, donc un score lexical proche
    /// de 1 (mesuré 1,0000 pour un texte comparé à lui-même).
    ///
    /// URL non analysable -> la chaîne brute nettoyée et mise en minuscules
    /// sert de clé : deux URLs illisibles identiques restent des doublons,
    /// deux URLs illisibles différentes ne sont jamais fusionnées par
    /// accident.
    static func normalizedURLKey(for url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmed),
            let host = normalizedHost(of: trimmed)
        else { return trimmed.lowercased() }

        let scheme = components.scheme?.lowercased() ?? ""

        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty { path = "/" }

        let keptItems = (components.queryItems ?? [])
            .filter { !isTrackingQueryParameter(named: $0.name) }
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
        let query = keptItems.isEmpty ? "" : "?" + keptItems.joined(separator: "&")

        // Clé reconstruite à la main plutôt que via `components.url` : ça la
        // rend lisible dans un message d'échec de test, et ça garantit que le
        // fragment est absent puisqu'on ne le lit jamais.
        return "\(scheme)://\(host)\(path)\(query)"
    }

    private static func isTrackingQueryParameter(named name: String) -> Bool {
        let lowercased = name.lowercased()
        if trackingQueryParameterNames.contains(lowercased) { return true }
        return trackingQueryParameterPrefixes.contains { lowercased.hasPrefix($0) }
    }
}
