//
//  SourceRankerTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 18/09/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Formule de scoring

@MainActor
@Suite("SourceRanker — formule de scoring")
struct SourceRankerFormulaTests {
    @Test("Formule exacte : (similarity * 0,7 + positionScore * 0,3) * multiplicateur")
    func relevanceScoreMatchesWebFormula() {
        // Cas connu 1 : 1er résultat (positionScore 1), domaine neutre.
        #expect(
            SourceRanker.relevanceScore(similarity: 0.8, positionScore: 1.0, domainMultiplier: 1.0)
                == 0.8 * 0.7 + 1.0 * 0.3
        )
        // Cas connu 2 : domaine boosté. L'expression est répliquée dans le
        // MÊME ordre d'opérations que l'implémentation — c'est la seule
        // façon de comparer sans tolérance arbitraire (mesuré :
        // `(0,5*0,7 + 1*0,3) * 1,25` vaut 0,8124999999999999 et non 0,8125).
        #expect(
            SourceRanker.relevanceScore(similarity: 0.5, positionScore: 1.0, domainMultiplier: 1.25)
                == (0.5 * 0.7 + 1.0 * 0.3) * 1.25
        )
        // Cas connu 3 : domaine pénalisé.
        #expect(
            SourceRanker.relevanceScore(similarity: 1.0, positionScore: 0.5, domainMultiplier: 0.4)
                == (1.0 * 0.7 + 0.5 * 0.3) * 0.4
        )
    }

    @Test("Les poids sont ceux du web et somment à 1")
    func weightsMatchWeb() {
        #expect(SourceRanker.similarityWeight == 0.7)
        #expect(SourceRanker.positionWeight == 0.3)
        #expect(SourceRanker.similarityWeight + SourceRanker.positionWeight == 1.0)
    }

    @Test("positionScore = max(0, 1 - position * 0,1)")
    func positionScoreDecaysThenFloorsAtZero() {
        #expect(SourceRanker.positionScore(forPosition: 0) == 1.0)
        #expect(SourceRanker.positionScore(forPosition: 1) == 1 - 0.1)
        #expect(SourceRanker.positionScore(forPosition: 5) == 1 - 5 * 0.1)
        // À partir du 11e résultat, la position n'apporte plus rien.
        #expect(SourceRanker.positionScore(forPosition: 10) == 0.0)
        #expect(SourceRanker.positionScore(forPosition: 50) == 0.0)
    }

    @Test("positionScore ne dépasse jamais 1, même sur une position négative")
    func positionScoreIsCappedAtOne() {
        #expect(SourceRanker.positionScore(forPosition: -5) == 1.0)
    }

    @Test("Les multiplicateurs et le plancher de similarité sont ceux du web")
    func portedConstantsMatchWeb() {
        #expect(SourceRanker.boostedMultiplier == 1.25)
        #expect(SourceRanker.penalizedMultiplier == 0.4)
        #expect(SourceRanker.neutralMultiplier == 1.0)
        #expect(SourceRanker.minimumSimilarity == 0.2)
        #expect(SourceRanker.defaultNearDuplicateThreshold == 0.75)
    }
}

// MARK: - Multiplicateur de domaine

@MainActor
@Suite("SourceRanker — multiplicateur de domaine")
struct SourceRankerDomainTests {
    /// Test paramétré plutôt qu'une boucle : chaque domaine devient un cas
    /// nommé dans le rapport, donc un échec dit TOUT DE SUITE lequel des
    /// douze motifs s'est cassé, sans relire le message d'assertion.
    @Test("Domaines boostés : multiplicateur 1,25 et considérés fiables", arguments: [
        "https://www.nasa.gov/mission",
        "https://mit.edu/admissions",
        "https://fr.wikipedia.org/wiki/TypeScript",
        "https://arxiv.org/abs/2401.00001",
        "https://www.nature.com/articles/x",
        "https://github.com/apple/swift",
        "https://stackoverflow.com/questions/1",
        "https://developer.mozilla.org/fr/docs/Web/JavaScript",
        "https://docs.python.org/3/library/json.html",
        "https://w3.org/TR/html52/",
        "https://pubmed.ncbi.nlm.nih.gov/123456/",
        "https://scholar.google.com/citations",
    ])
    func boostedDomainsAreBoosted(url: String) {
        #expect(SourceRanker.domainMultiplier(for: url) == SourceRanker.boostedMultiplier)
        #expect(SourceRanker.isTrustedDomain(url))
    }

    @Test("Domaines pénalisés : multiplicateur 0,4 et jamais fiables", arguments: [
        "https://www.pinterest.com/pin/1",
        "https://quora.com/What-is-TypeScript",
        "https://answers.yahoo.com/question/1",
        "https://ehow.com/how_1",
        "https://fr.wikihow.com/article",
        "https://thoughtcatalog.com/post",
    ])
    func penalizedDomainsArePenalized(url: String) {
        #expect(SourceRanker.domainMultiplier(for: url) == SourceRanker.penalizedMultiplier)
        #expect(!SourceRanker.isTrustedDomain(url))
    }

    @Test("Domaine inconnu : multiplicateur neutre 1,0")
    func unknownDomainIsNeutral() {
        #expect(SourceRanker.domainMultiplier(for: "https://exemple.fr/blog") == 1.0)
        #expect(!SourceRanker.isTrustedDomain("https://exemple.fr/blog"))
    }

    @Test("Un domaine boosté l'emporte sur un pénalisé, comme la boucle du web")
    func boostWinsOverPenalty() {
        // `docs.` est testé avant `quora.com` parce que le web retourne dès
        // le premier motif boosté trouvé. Comportement porté tel quel.
        #expect(SourceRanker.domainMultiplier(for: "https://docs.quora.com/guide") == SourceRanker.boostedMultiplier)
    }

    @Test("Divergence documentée : on compare l'HÔTE, pas l'URL entière")
    func matchingIsHostBasedNotSubstringBased() {
        // Le `url.includes('.edu')` du web matcherait `education.fr`.
        #expect(SourceRanker.domainMultiplier(for: "https://monsite.education.fr/cours") == 1.0)
        // Il matcherait aussi un domaine de hameçonnage entièrement contrôlé
        // par son propriétaire : c'est le faux positif le plus grave.
        #expect(SourceRanker.domainMultiplier(for: "https://github.com.phishing.example/x") == 1.0)
        // Et une simple mention dans la requête ou le chemin.
        #expect(SourceRanker.domainMultiplier(for: "https://spam.example/?q=wikipedia.org") == 1.0)
        #expect(SourceRanker.domainMultiplier(for: "https://spam.example/wikipedia.org/page") == 1.0)
        // En revanche un sous-domaine légitime reste bien reconnu.
        #expect(SourceRanker.domainMultiplier(for: "https://en.m.wikipedia.org/wiki/X") == SourceRanker.boostedMultiplier)
        // …et un domaine qui se contente de contenir le motif, non.
        #expect(SourceRanker.domainMultiplier(for: "https://notwikipedia.org/x") == 1.0)
    }

    @Test("Règle ccTLD : data.gov.uk est boosté, evil.gov.com ne l'est pas")
    func countryCodeRuleClosesTheGovDotComHole() {
        // Vrai portail public : le `includes('.gov')` du web l'attrapait
        // aussi, on ne régresse donc pas.
        #expect(SourceRanker.domainMultiplier(for: "https://data.gov.uk/dataset/x") == SourceRanker.boostedMultiplier)
        #expect(SourceRanker.domainMultiplier(for: "https://www.education.gov.au/page") == SourceRanker.boostedMultiplier)
        // `gov.com` est librement enregistrable : un simple `contains(".gov.")`
        // en ferait une source boostée. C'est le trou que la règle ferme.
        #expect(SourceRanker.domainMultiplier(for: "https://evil.gov.com/x") == 1.0)
        #expect(SourceRanker.domainMultiplier(for: "https://faux.edu.net/x") == 1.0)
    }

    @Test("Préfixe de sous-domaine `docs.` : ancré sur un label entier")
    func subdomainPrefixMatchesWholeLabelOnly() {
        #expect(SourceRanker.matches(host: "docs.python.org", pattern: "docs."))
        #expect(SourceRanker.matches(host: "fr.docs.example.com", pattern: "docs."))
        // `mydocs` n'est pas `docs` : le motif doit commencer un label.
        #expect(!SourceRanker.matches(host: "mydocs.example.com", pattern: "docs."))
    }

    @Test("`www.` est ignoré à l'extraction de l'hôte")
    func wwwPrefixIsStripped() {
        #expect(SourceRanker.normalizedHost(of: "https://www.exemple.fr/a") == "exemple.fr")
        #expect(SourceRanker.normalizedHost(of: "https://EXEMPLE.FR/a") == "exemple.fr")
    }

    @Test("URL non analysable : ni récompensée ni punie")
    func unparseableURLIsNeutral() {
        #expect(SourceRanker.normalizedHost(of: "pas une url") == nil)
        #expect(SourceRanker.domainMultiplier(for: "pas une url") == 1.0)
        #expect(!SourceRanker.isTrustedDomain("pas une url"))
        #expect(SourceRanker.domainMultiplier(for: "") == 1.0)
    }
}

// MARK: - Contenu utilisé pour la similarité

@MainActor
@Suite("SourceRanker — contenu scoré")
struct SourceRankerContentTests {
    @Test("Port de `r.content || r.title` : le titre prend le relais")
    func contentFallsBackToTitle() {
        #expect(SourceRanker.rankedContent(of: makeSourceResult(url: "https://a.fr", title: "T", content: "Extrait")) == "Extrait")
        #expect(SourceRanker.rankedContent(of: makeSourceResult(url: "https://a.fr", title: "T", content: nil)) == "T")
        #expect(SourceRanker.rankedContent(of: makeSourceResult(url: "https://a.fr", title: "T", content: "")) == "T")
        // Divergence assumée avec JavaScript : " " est truthy en JS mais ne
        // vaut rien comme texte, on bascule donc aussi sur le titre.
        #expect(SourceRanker.rankedContent(of: makeSourceResult(url: "https://a.fr", title: "T", content: "   \n")) == "T")
    }
}

// MARK: - Clé de déduplication d'URL

@MainActor
@Suite("SourceRanker — normalisation d'URL")
struct SourceRankerURLKeyTests {
    @Test("Même page : `www.`, slash final, fragment et `utm_*` sont ignorés")
    func trackingAndCosmeticDifferencesCollapse() {
        let reference = SourceRanker.normalizedURLKey(for: "https://exemple.fr/article?b=2")
        #expect(SourceRanker.normalizedURLKey(for: "https://www.exemple.fr/article?b=2") == reference)
        #expect(SourceRanker.normalizedURLKey(for: "https://exemple.fr/article/?b=2") == reference)
        #expect(SourceRanker.normalizedURLKey(for: "https://exemple.fr/article?b=2#section-3") == reference)
        #expect(SourceRanker.normalizedURLKey(for: "https://exemple.fr/article?utm_source=x&b=2") == reference)
        #expect(SourceRanker.normalizedURLKey(for: "https://exemple.fr/article?b=2&fbclid=abc") == reference)
        #expect(SourceRanker.normalizedURLKey(for: "  https://exemple.fr/article?b=2  ") == reference)
    }

    @Test("L'ordre des paramètres conservés ne change pas la clé")
    func queryItemOrderDoesNotMatter() {
        #expect(
            SourceRanker.normalizedURLKey(for: "https://exemple.fr/a?a=1&b=2")
                == SourceRanker.normalizedURLKey(for: "https://exemple.fr/a?b=2&a=1")
        )
    }

    @Test("Un paramètre inconnu porte peut-être le contenu : il distingue")
    func unknownQueryParametersStillSeparatePages() {
        #expect(
            SourceRanker.normalizedURLKey(for: "https://exemple.fr/a?id=1")
                != SourceRanker.normalizedURLKey(for: "https://exemple.fr/a?id=2")
        )
    }

    @Test("Le chemin garde sa casse : /Article et /article peuvent différer")
    func pathCaseIsPreserved() {
        #expect(
            SourceRanker.normalizedURLKey(for: "https://exemple.fr/Article")
                != SourceRanker.normalizedURLKey(for: "https://exemple.fr/article")
        )
    }

    @Test("Limite assumée : http et https donnent deux clés distinctes")
    func schemeIsPartOfTheKey() {
        #expect(
            SourceRanker.normalizedURLKey(for: "http://exemple.fr/a")
                != SourceRanker.normalizedURLKey(for: "https://exemple.fr/a")
        )
    }

    @Test("URL illisible : la chaîne brute nettoyée sert de clé")
    func unparseableURLsKeepTheirOwnIdentity() {
        #expect(SourceRanker.normalizedURLKey(for: "  Pas Une URL  ") == "pas une url")
        #expect(SourceRanker.normalizedURLKey(for: "pas une url") != SourceRanker.normalizedURLKey(for: "autre chose"))
    }
}

