//
//  SourceRankerTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 18/09/2026.
//

import Testing
import Foundation
@testable import Triva

// MARK: - Fabriques et scorers factices

/// Fabrique un résultat SearXNG minimal : seuls `url`, `title` et `content`
/// comptent pour le ranking, tous les autres champs (images, iframe, auteur)
/// ne sont jamais lus par `SourceRanker`.
private func makeResult(
    url: String,
    title: String = "Titre",
    content: String? = "Contenu"
) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: title,
        url: url,
        content: content,
        imgSrc: nil,
        thumbnailSrc: nil,
        thumbnail: nil,
        author: nil,
        iframeSrc: nil
    )
}

/// Scorer de pertinence factice : renvoie un score fixé PAR TEXTE, avec une
/// valeur par défaut pour les textes non listés. C'est ce qui rend tout le
/// classement entièrement prévisible — le plan exige que `SourceRanker` soit
/// couvrable exhaustivement, ce qui suppose de ne jamais dépendre d'un vrai
/// modèle de langue dans ces tests.
private struct FixedSimilarityScorer: TextSimilarityScoring {
    let scoresByText: [String: Double]
    let defaultScore: Double

    init(_ scoresByText: [String: Double] = [:], defaultScore: Double = 0.5) {
        self.scoresByText = scoresByText
        self.defaultScore = defaultScore
    }

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        candidates.map { scoresByText[$0] ?? defaultScore }
    }
}

/// Scorer de doublons neutralisé : rien n'est jamais un quasi-doublon.
/// Utilisé partout où le test porte sur le SCORING, pour que la
/// déduplication de contenu ne vienne pas brouiller l'observation.
private struct NeverDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

/// Scorer de doublons saturé : tout est quasi-doublon de tout.
private struct AlwaysDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 1, count: candidates.count)
    }
}

/// Renvoie EXACTEMENT le seuil de quasi-doublon : sert à prouver que la
/// comparaison est stricte (`> seuil`), comme le `similarity > 0.75` du web.
private struct AtThresholdDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: SourceRanker.defaultNearDuplicateThreshold, count: candidates.count)
    }
}

/// Scorer VOLONTAIREMENT NON CONFORME au contrat du protocole : il renvoie
/// moins de scores qu'il n'a reçu de candidats. Sert à prouver que la
/// lecture indexée avec repli `0` de `SourceRanker.score` tient — sans ce
/// test, cette branche défensive partirait en production sans jamais avoir
/// été exécutée.
private struct TruncatedSimilarityScorer: TextSimilarityScoring {
    let scores: [Double]

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        scores
    }
}

/// Langue toujours indéterminée : un seul groupe, donc exactement le port du
/// web. Épinglée dans tous les tests d'avant la décision 3, pour qu'aucun
/// d'eux ne dépende de la détection de langue du système sur ses extraits.
private struct UndeterminedLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

/// Ranker prêt à l'emploi pour les tests de scoring : scorer de pertinence
/// contrôlé, déduplication de contenu désactivée.
private func makeRanker(
    relevance: any TextSimilarityScoring,
    unfilteredFallbackCount: Int = SourceRanker.defaultUnfilteredFallbackCount
) -> SourceRanker {
    SourceRanker(
        relevanceScorer: relevance,
        duplicateScorer: NeverDuplicateScorer(),
        languageIdentifier: UndeterminedLanguageIdentifier(),
        unfilteredFallbackCount: unfilteredFallbackCount
    )
}

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
        #expect(SourceRanker.rankedContent(of: makeResult(url: "https://a.fr", title: "T", content: "Extrait")) == "Extrait")
        #expect(SourceRanker.rankedContent(of: makeResult(url: "https://a.fr", title: "T", content: nil)) == "T")
        #expect(SourceRanker.rankedContent(of: makeResult(url: "https://a.fr", title: "T", content: "")) == "T")
        // Divergence assumée avec JavaScript : " " est truthy en JS mais ne
        // vaut rien comme texte, on bascule donc aussi sur le titre.
        #expect(SourceRanker.rankedContent(of: makeResult(url: "https://a.fr", title: "T", content: "   \n")) == "T")
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

// MARK: - Classement de bout en bout

@MainActor
@Suite("SourceRanker — classement")
struct SourceRankerRankingTests {
    /// Jeu de données de référence du plan : la requête « JavaScript vs
    /// TypeScript », avec un extrait par source dans l'ordre RENDU PAR LE
    /// MOTEUR. Toutes les similarités sont égales dans ce test : c'est
    /// exactement ce qui isole l'effet combiné de la position et du
    /// multiplicateur de domaine, seuls facteurs qui restent en jeu.
    private func javaScriptVersusTypeScriptResults() -> [SearXNGSearchResult] {
        [
            makeResult(url: "https://blog-perso.example/js-vs-ts", content: "Mon avis sur JavaScript et TypeScript"),
            makeResult(url: "https://www.pinterest.com/pin/1", content: "Infographie JavaScript TypeScript"),
            makeResult(url: "https://developer.mozilla.org/fr/docs/Web/JavaScript", content: "Référence du langage JavaScript"),
            makeResult(url: "https://stackoverflow.com/questions/1", content: "Quand préférer TypeScript à JavaScript ?"),
            makeResult(url: "https://fr.wikipedia.org/wiki/TypeScript", content: "TypeScript est un langage à typage statique"),
            makeResult(url: "https://medium.example/ts", content: "Pourquoi j'ai migré vers TypeScript"),
        ]
    }

    @Test("Requête de référence du plan : ordre final décroissant et explicable")
    func javaScriptVersusTypeScriptOrdering() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let ranked = await ranker.rank(query: "JavaScript vs TypeScript", results: javaScriptVersusTypeScriptResults(), limit: 5)

        // À similarité égale, les 3 sources boostées passent devant malgré
        // des positions moins bonnes, et Pinterest tombe en dernier malgré
        // sa 2e place chez le moteur : c'est précisément ce que le scoring
        // du web apporte au classement brut.
        #expect(ranked.map(\.result.url) == [
            "https://developer.mozilla.org/fr/docs/Web/JavaScript",
            "https://stackoverflow.com/questions/1",
            "https://fr.wikipedia.org/wiki/TypeScript",
            "https://blog-perso.example/js-vs-ts",
            "https://medium.example/ts",
        ])
        // La 6e source (Pinterest, pénalisée) est bien celle qui saute.
        #expect(!ranked.map(\.result.url).contains("https://www.pinterest.com/pin/1"))
        // Tri effectivement décroissant.
        #expect(ranked.map(\.relevanceScore) == ranked.map(\.relevanceScore).sorted(by: >))
    }

    @Test("Le détail du score est conservé et cohérent avec la formule")
    func rankedSourceExposesEveryTermOfTheFormula() async throws {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let ranked = await ranker.rank(
            query: "q",
            results: [makeResult(url: "https://exemple.fr/a"), makeResult(url: "https://fr.wikipedia.org/wiki/X")],
            limit: 5
        )
        let wikipedia = try #require(ranked.first { $0.result.url.contains("wikipedia") })
        #expect(wikipedia.originalPosition == 1)
        #expect(wikipedia.similarity == 0.5)
        #expect(wikipedia.positionScore == SourceRanker.positionScore(forPosition: 1))
        #expect(wikipedia.domainMultiplier == SourceRanker.boostedMultiplier)
        #expect(wikipedia.relevanceScore == SourceRanker.relevanceScore(
            similarity: 0.5,
            positionScore: SourceRanker.positionScore(forPosition: 1),
            domainMultiplier: SourceRanker.boostedMultiplier
        ))
    }

    @Test("Limite : au plus `limit` sources renvoyées")
    func limitIsRespected() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let results = (0..<12).map { makeResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }

        #expect(await ranker.rank(query: "q", results: results, limit: 5).count == 5)
        #expect(await ranker.rank(query: "q", results: results, limit: 3).count == 3)
        #expect(await ranker.rank(query: "q", results: results, limit: 20).count == 12)
    }

    @Test("Limite nulle ou négative : rien, sans appeler le scorer")
    func nonPositiveLimitReturnsNothing() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let results = [makeResult(url: "https://exemple.fr/a")]
        #expect(await ranker.rank(query: "q", results: results, limit: 0).isEmpty)
        #expect(await ranker.rank(query: "q", results: results, limit: -1).isEmpty)
    }

    @Test("Liste vide : liste vide")
    func emptyInputReturnsEmptyOutput() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        #expect(await ranker.rank(query: "q", results: [], limit: 5).isEmpty)
    }

    @Test("Une seule source : conservée, avec son score complet")
    func singleSourceIsKept() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.9))
        let ranked = await ranker.rank(query: "q", results: [makeResult(url: "https://exemple.fr/a")], limit: 5)
        #expect(ranked.count == 1)
        #expect(ranked.first?.similarity == 0.9)
        #expect(ranked.first?.originalPosition == 0)
    }

    @Test("Scores identiques : tri stable, départagé par la position du moteur")
    func identicalScoresFallBackToEngineOrder() async {
        // Construire une VRAIE égalité de scores demande d'annuler le terme
        // de position : au-delà du 10e résultat, `positionScore` vaut 0 pour
        // tout le monde, donc le score se réduit à `similarity * 0,7`.
        // Les 10 premiers résultats sont là uniquement pour pousser les
        // suivants au-delà de ce seuil ; leur similarité (0,25) les garde
        // au-dessus du plancher anti-bruit tout en les laissant perdre
        // largement (au mieux 0,475 contre 0,7).
        let padding = (0..<10).map { makeResult(url: "https://exemple.fr/pad\($0)", content: "faible") }
        let tied = (0..<5).map { makeResult(url: "https://exemple.fr/ex\($0)", content: "fort \($0)") }

        let scorer = FixedSimilarityScorer(
            ["faible": 0.25],
            defaultScore: 1.0
        )
        let ranker = makeRanker(relevance: scorer)
        let ranked = await ranker.rank(query: "q", results: padding + tied, limit: 5)

        #expect(ranked.count == 5)
        #expect(Set(ranked.map(\.relevanceScore)).count == 1, "les 5 sources retenues doivent avoir exactement le même score")
        #expect(ranked.map(\.positionScore) == Array(repeating: 0.0, count: 5))
        // Départage déterministe : l'ordre du moteur, jamais l'ordre d'un tri
        // instable.
        #expect(ranked.map(\.originalPosition) == [10, 11, 12, 13, 14])
    }

    @Test("Filtre similarity > 0,2 : les résultats sous le plancher sortent")
    func belowThresholdResultsAreFiltered() async {
        let scorer = FixedSimilarityScorer([
            "pertinent": 0.9,
            "bruit": 0.1,
            // Exactement au seuil : la comparaison est STRICTE, donc éliminé.
            "limite": 0.2,
        ], defaultScore: 0.0)
        let ranker = makeRanker(relevance: scorer)
        let ranked = await ranker.rank(
            query: "q",
            results: [
                makeResult(url: "https://exemple.fr/a", content: "pertinent"),
                makeResult(url: "https://exemple.fr/b", content: "bruit"),
                makeResult(url: "https://exemple.fr/c", content: "limite"),
            ],
            limit: 5
        )
        #expect(ranked.map(\.result.url) == ["https://exemple.fr/a"])
    }

    @Test("Repli : si TOUT est filtré, on garde les premiers PAR POSITION")
    func fallbackKeepsTopResultsByPositionWhenEverythingIsFiltered() async {
        // Toutes les similarités sous le plancher : c'est le signal d'un
        // scorer en difficulté, pas d'une recherche sans rapport.
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.0), unfilteredFallbackCount: 5)
        let results = (0..<8).map { makeResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }
        let ranked = await ranker.rank(query: "q", results: results, limit: 5)

        #expect(ranked.count == 5)
        #expect(ranked.map(\.originalPosition) == [0, 1, 2, 3, 4])
    }

    @Test("Repli : ce sont les 5 premiers DU MOTEUR, pas les 5 meilleurs scores")
    func fallbackIgnoresDomainBoostWhenChoosingTheFive() async {
        // Une source boostée placée en 7e position par le moteur aurait le
        // meilleur score de tout le lot ; elle ne doit pourtant PAS entrer
        // dans le repli, qui tronque avant le tri.
        var results = (0..<6).map { makeResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }
        results.append(makeResult(url: "https://fr.wikipedia.org/wiki/X", content: "extrait wikipedia"))

        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.0), unfilteredFallbackCount: 5)
        let ranked = await ranker.rank(query: "q", results: results, limit: 5)

        #expect(!ranked.map(\.result.url).contains("https://fr.wikipedia.org/wiki/X"))
        #expect(ranked.map(\.originalPosition) == [0, 1, 2, 3, 4])
    }

    @Test("Contrat violé par le scorer : les candidats en trop valent 0, aucun ne disparaît")
    func missingScoresFallBackToZeroWithoutDroppingCandidates() async {
        // Le scorer ne renvoie que 2 scores pour 4 candidats. Sans la lecture
        // indexée de `SourceRanker.score`, un `zip` ferait disparaître les
        // deux derniers résultats sans la moindre trace.
        let ranker = SourceRanker(
            relevanceScorer: TruncatedSimilarityScorer(scores: [0.9, 0.8]),
            duplicateScorer: NeverDuplicateScorer(),
            languageIdentifier: UndeterminedLanguageIdentifier()
        )
        let results = (0..<4).map { makeResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }
        let ranked = await ranker.rank(query: "q", results: results, limit: 5)

        // Les deux premiers passent le plancher, les deux suivants (score 0)
        // sont filtrés — mais ils ont bien été SCORÉS, pas perdus.
        #expect(ranked.count == 2)
        #expect(ranked.map(\.originalPosition) == [0, 1])
        #expect(ranked.map(\.similarity) == [0.9, 0.8])
    }
}

// MARK: - Déduplication

@MainActor
@Suite("SourceRanker — déduplication")
struct SourceRankerDeduplicationTests {
    @Test("Niveau 1 : même URL normalisée, la mieux notée est conservée")
    func duplicateURLsCollapseKeepingTheBestScored() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let ranked = await ranker.rank(
            query: "q",
            results: [
                makeResult(url: "https://exemple.fr/article?utm_campaign=a", content: "extrait A"),
                makeResult(url: "https://www.exemple.fr/article/", content: "extrait B"),
                makeResult(url: "https://exemple.fr/article#intro", content: "extrait C"),
                makeResult(url: "https://autre.fr/page", content: "extrait D"),
            ],
            limit: 5
        )

        #expect(ranked.count == 2)
        // La 1re occurrence du groupe a le meilleur `positionScore`, c'est
        // donc elle qui survit.
        #expect(ranked.first?.originalPosition == 0)
        #expect(ranked.map(\.result.url).contains("https://autre.fr/page"))
    }

    @Test("Niveau 1 : des URLs différentes ne sont jamais fusionnées")
    func distinctURLsAreAllKept() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let ranked = await ranker.rank(
            query: "q",
            results: [
                makeResult(url: "https://exemple.fr/a", content: "extrait 1"),
                makeResult(url: "https://exemple.fr/b", content: "extrait 2"),
                makeResult(url: "https://exemple.fr/a?id=2", content: "extrait 3"),
            ],
            limit: 5
        )
        #expect(ranked.count == 3)
    }

    @Test("Niveau 2 : au-dessus du seuil, une seule source survit")
    func nearDuplicateContentCollapsesToOne() async {
        let ranker = SourceRanker(
            relevanceScorer: FixedSimilarityScorer(defaultScore: 0.5),
            duplicateScorer: AlwaysDuplicateScorer(),
            languageIdentifier: UndeterminedLanguageIdentifier()
        )
        let ranked = await ranker.rank(
            query: "q",
            results: (0..<4).map { makeResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") },
            limit: 5
        )
        #expect(ranked.count == 1)
        #expect(ranked.first?.originalPosition == 0)
    }

    @Test("Niveau 2 : comparaison STRICTE, un score pile au seuil ne déduplique pas")
    func thresholdComparisonIsStrict() async {
        let ranker = SourceRanker(
            relevanceScorer: FixedSimilarityScorer(defaultScore: 0.5),
            duplicateScorer: AtThresholdDuplicateScorer(),
            languageIdentifier: UndeterminedLanguageIdentifier()
        )
        let ranked = await ranker.rank(
            query: "q",
            results: [
                makeResult(url: "https://exemple.fr/a", content: "extrait 1"),
                makeResult(url: "https://exemple.fr/b", content: "extrait 2"),
            ],
            limit: 5
        )
        #expect(ranked.count == 2)
    }

    @Test("Calibrage réel du seuil 0,75 dans l'espace LEXICAL")
    func realLexicalScorerSeparatesCopiesFromIndependentArticles() async {
        // Ce test ancre la justification chiffrée écrite dans la doc de
        // `defaultNearDuplicateThreshold` : c'est lui qui hurlerait si une
        // évolution du tokenizer système déplaçait ces scores.
        let scorer = LexicalSimilarityScorer()

        let dispatch = "Le conseil municipal a voté mardi soir une enveloppe de 4,2 millions d'euros pour la rénovation du réseau d'eau potable de la commune."
        let dispatchRewritten = "Une enveloppe de 4,2 millions d'euros a été votée mardi soir par le conseil municipal pour rénover le réseau d'eau potable communal."
        let independentA = "TypeScript ajoute un système de types statiques à JavaScript. Le compilateur détecte les erreurs de type avant l'exécution."
        let independentB = "JavaScript reste un langage dynamique interprété par le navigateur. TypeScript, lui, est transpilé avant d'être exécuté."

        // Une reprise de dépêche passe au-dessus du seuil : c'est un doublon.
        #expect(await scorer.similarity(between: dispatch, and: dispatchRewritten) > SourceRanker.defaultNearDuplicateThreshold)
        // Deux articles indépendants sur le même sujet restent LARGEMENT en
        // dessous : ce sont deux sources légitimes, les supprimer serait le
        // pire échec possible de la déduplication.
        #expect(await scorer.similarity(between: independentA, and: independentB) < SourceRanker.defaultNearDuplicateThreshold)
    }

    @Test("Déduplication de bout en bout avec le vrai scorer lexical")
    func endToEndDeduplicationWithRealLexicalScorer() async {
        let ranker = SourceRanker(
            relevanceScorer: FixedSimilarityScorer(defaultScore: 0.5),
            duplicateScorer: LexicalSimilarityScorer(),
            languageIdentifier: UndeterminedLanguageIdentifier()
        )
        let dispatch = "Le conseil municipal a voté mardi soir une enveloppe de 4,2 millions d'euros pour la rénovation du réseau d'eau potable de la commune."
        let ranked = await ranker.rank(
            query: "budget rénovation réseau eau",
            results: [
                makeResult(url: "https://journal-a.example/article", content: dispatch),
                makeResult(url: "https://journal-b.example/reprise", content: "Mardi soir, le conseil municipal a voté une enveloppe de 4,2 millions d'euros destinée à la rénovation du réseau d'eau potable de la commune."),
                makeResult(url: "https://exemple.fr/autre", content: "La piscine municipale rouvrira en septembre après dix-huit mois de travaux d'isolation thermique."),
            ],
            limit: 5
        )

        #expect(ranked.count == 2)
        #expect(ranked.map(\.result.url).contains("https://journal-a.example/article"))
        #expect(!ranked.map(\.result.url).contains("https://journal-b.example/reprise"))
    }
}

// MARK: - Mode « sources fiables » (1.13)

@MainActor
@Suite("SourceRanker — sources fiables")
struct SourceRankerTrustedDomainsTests {
    private func mixedResults() -> [SearXNGSearchResult] {
        [
            makeResult(url: "https://blog.example/a", content: "extrait blog"),
            makeResult(url: "https://www.pinterest.com/pin/1", content: "extrait pinterest"),
            makeResult(url: "https://fr.wikipedia.org/wiki/X", content: "extrait wikipedia"),
            makeResult(url: "https://medium.example/b", content: "extrait medium"),
            makeResult(url: "https://arxiv.org/abs/1", content: "extrait arxiv"),
        ]
    }

    @Test("Filtre actif : seules les sources de domaines boostés survivent")
    func trustedOnlyKeepsBoostedDomains() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let ranked = await ranker.rank(query: "q", results: mixedResults(), limit: 5, trustedDomainsOnly: true)

        #expect(ranked.count == 2)
        #expect(Set(ranked.map(\.result.url)) == ["https://fr.wikipedia.org/wiki/X", "https://arxiv.org/abs/1"])
    }

    @Test("Le filtre ne décale PAS les positions : positionScore reste celui du moteur")
    func positionScoreKeepsTheOriginalIndexAfterFiltering() async throws {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let ranked = await ranker.rank(query: "q", results: mixedResults(), limit: 5, trustedDomainsOnly: true)

        let wikipedia = try #require(ranked.first { $0.result.url.contains("wikipedia") })
        // 3e résultat du moteur (index 2), pas 1er du sous-ensemble filtré.
        #expect(wikipedia.originalPosition == 2)
        #expect(wikipedia.positionScore == SourceRanker.positionScore(forPosition: 2))
    }

    @Test("Aucune source fiable : liste VIDE, jamais un repli non fiable")
    func noTrustedSourceReturnsEmptyRatherThanBreakingThePromise() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.9))
        let ranked = await ranker.rank(
            query: "q",
            results: [makeResult(url: "https://blog.example/a"), makeResult(url: "https://medium.example/b")],
            limit: 5,
            trustedDomainsOnly: true
        )
        #expect(ranked.isEmpty)
    }

    @Test("Filtre inactif par défaut : rien n'est retiré")
    func filterIsOffByDefault() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        #expect(await ranker.rank(query: "q", results: mixedResults(), limit: 10).count == 5)
    }
}

// MARK: - Pilotage par ResponseMode (1.13)

@MainActor
@Suite("SourceRanker — pilotage par ResponseMode")
struct SourceRankerResponseModeTests {
    private func tenNeutralResults() -> [SearXNGSearchResult] {
        (0..<10).map { makeResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }
    }

    @Test("Le mode traduit `targetSourceCount` en limite, sans logique en plus")
    func modeDrivesTheLimit() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let results = tenNeutralResults()

        #expect(await ranker.rank(query: "q", results: results, mode: .quick).count == ResponseMode.quick.targetSourceCount)
        #expect(await ranker.rank(query: "q", results: results, mode: .deep).count == ResponseMode.deep.targetSourceCount)
    }

    @Test("Le mode `reliable` active bien la restriction aux domaines fiables")
    func reliableModeRestrictsToTrustedDomains() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let results = [
            makeResult(url: "https://blog.example/a", content: "extrait blog"),
            makeResult(url: "https://fr.wikipedia.org/wiki/X", content: "extrait wikipedia"),
        ]

        let reliable = await ranker.rank(query: "q", results: results, mode: .reliable)
        #expect(reliable.map(\.result.url) == ["https://fr.wikipedia.org/wiki/X"])

        // Les deux autres modes ne filtrent rien : c'est la seule différence.
        #expect(await ranker.rank(query: "q", results: results, mode: .deep).count == 2)
        #expect(await ranker.rank(query: "q", results: results, mode: .quick).count == 2)
    }

    @Test("Les deux surcharges de `rank` donnent le même résultat")
    func bothOverloadsAgree() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let results = tenNeutralResults()

        let viaMode = await ranker.rank(query: "q", results: results, mode: .quick)
        let viaParameters = await ranker.rank(
            query: "q",
            results: results,
            limit: ResponseMode.quick.targetSourceCount,
            trustedDomainsOnly: ResponseMode.quick.restrictsToTrustedDomains
        )
        #expect(viaMode == viaParameters)
    }
}

// MARK: - Une langue à la fois (décision 3 de Ben)

/// Langue lue sur le préfixe « fr: » / « en: » du texte, `nil` sans préfixe.
private struct PrefixLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? {
        guard let separator = text.firstIndex(of: ":") else { return nil }
        return String(text[..<separator])
    }
}

/// Journal des lots reçus par le scorer, et du thread qui les a calculés.
private actor BatchLog {
    private(set) var batches: [[String]] = []
    private(set) var ranOnMainThread: [Bool] = []

    func record(_ batch: [String], onMainThread: Bool) {
        batches.append(batch)
        ranOnMainThread.append(onMainThread)
    }
}

/// Synchrone exprès : `Thread.isMainThread` n'est pas lisible directement
/// depuis un contexte `async` en Swift 6.
private func currentThreadIsMain() -> Bool { Thread.isMainThread }

private struct RecordingScorer: TextSimilarityScoring {
    let log: BatchLog
    let scores: [String: Double]

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        await log.record(candidates, onMainThread: currentThreadIsMain())
        return candidates.map { scores[$0] ?? 0.5 }
    }
}

/// Deux textes marqués « #dup » sont quasi-doublons l'un de l'autre.
private struct MarkerDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        candidates.map { reference.contains("#dup") && $0.contains("#dup") ? 1 : 0 }
    }
}

/// Le biais mesuré par F1, reproduit : le français (langue de la requête)
/// marque plus haut que l'anglais, quel que soit le sens. Constantes de
/// fichier (et non `static` de la suite `@MainActor`) pour rester utilisables
/// dans une valeur par défaut de paramètre.
private let biasedScores = ["fr: 1": 0.9, "fr: 2": 0.88, "fr: 3": 0.86, "en: 1": 0.5, "en: 2": 0.48]
private let bilingualResults = ["fr: 1", "fr: 2", "fr: 3", "en: 1", "en: 2"].enumerated().map {
    makeResult(url: "https://exemple.fr/\($0.offset)", content: $0.element)
}

@MainActor
@Suite("SourceRanker — une langue à la fois (décision 3)")
struct SourceRankerLanguageTests {
    private func ranker(
        scorer: any TextSimilarityScoring = FixedSimilarityScorer(biasedScores, defaultScore: 0.5),
        duplicates: any TextSimilarityScoring = NeverDuplicateScorer(),
        languages: any TextLanguageIdentifying = PrefixLanguageIdentifier()
    ) -> SourceRanker {
        SourceRanker(relevanceScorer: scorer, duplicateScorer: duplicates, languageIdentifier: languages)
    }

    @Test("Partition : un groupe par langue, `nil` versé dans le plus grand, langue de la requête en tête")
    func languageBucketsRules() {
        let items = ["a", "b", "c", "d"]
        let languages: [String?] = ["en", "fr", "en", nil]
        #expect(SourceRanker.languageBuckets(items, languages: languages, queryLanguage: nil) == [["a", "c", "d"], ["b"]])
        #expect(SourceRanker.languageBuckets(items, languages: languages, queryLanguage: "fr") == [["b"], ["a", "c", "d"]])
        #expect(SourceRanker.languageBuckets(items, languages: languages, queryLanguage: "de") == [["a", "c", "d"], ["b"]])
        // Égalité de taille : le premier groupe apparu reçoit les `nil`.
        #expect(SourceRanker.languageBuckets(["a", "b", "c"], languages: ["en", "fr", nil], queryLanguage: nil) == [["a", "c"], ["b"]])
        // Un `nil` en tête du moteur fait passer son nouveau groupe devant.
        #expect(SourceRanker.languageBuckets(["x", "e", "f", "g"], languages: [nil, "en", "fr", "fr"], queryLanguage: nil) == [["x", "f", "g"], ["e"]])
        #expect(SourceRanker.languageBuckets(["a", "b"], languages: [nil, nil], queryLanguage: "fr") == [["a", "b"]])
        #expect(SourceRanker.languageBuckets([String](), languages: [], queryLanguage: nil).isEmpty)
    }

    @Test("Tourniquet : premier de chaque groupe, puis deuxième, sans rien perdre ni dupliquer")
    func interleavedRoundRobin() {
        #expect(SourceRanker.interleaved([[1, 2, 3], [10], [20, 21]]) == [1, 10, 20, 2, 21, 3])
        #expect(SourceRanker.interleaved([[1, 2]]) == [1, 2])
        #expect(SourceRanker.interleaved([[Int]]()).isEmpty)
    }

    @Test("Requête française : les meilleures de chaque langue alternent, au lieu de tout le français d'abord")
    func languagesAlternateFromTheQueryLanguage() async {
        let ranked = await ranker().rank(query: "fr: question", results: bilingualResults, limit: 5)
        #expect(ranked.map(\.result.content) == ["fr: 1", "en: 1", "fr: 2", "en: 2", "fr: 3"])

        // Témoin : sans langue détectée, l'ordre du port web met tout le
        // français devant — exactement le biais que la décision 3 corrige.
        let singleBucket = await ranker(languages: UndeterminedLanguageIdentifier()).rank(query: "fr: question", results: bilingualResults, limit: 5)
        #expect(singleBucket.map(\.result.content) == ["fr: 1", "fr: 2", "fr: 3", "en: 1", "en: 2"])
    }

    @Test("Requête anglaise : l'anglais ouvre le tourniquet ; requête non reconnue : l'ordre du moteur décide")
    func queryLanguageOpensTheRoundRobin() async {
        let english = await ranker().rank(query: "en: question", results: bilingualResults, limit: 3)
        #expect(english.map(\.result.content) == ["en: 1", "fr: 1", "en: 2"])

        let unknown = await ranker().rank(query: "python", results: bilingualResults, limit: 3)
        #expect(unknown.map(\.result.content) == ["fr: 1", "en: 1", "fr: 2"])
    }

    @Test("Un lot de similarité par langue, calculé hors du main thread (@concurrent)")
    func oneHomogeneousBatchPerLanguageOffTheMainThread() async {
        let log = BatchLog()
        _ = await ranker(scorer: RecordingScorer(log: log, scores: biasedScores)).rank(query: "fr: question", results: bilingualResults, limit: 5)

        let batches = await log.batches
        #expect(batches == [["fr: 1", "fr: 2", "fr: 3"], ["en: 1", "en: 2"]])
        #expect(await log.ranOnMainThread == [false, false])
    }

    @Test("La déduplication se fait par langue AVANT la fusion : l'alternance tient malgré un doublon")
    func deduplicationPerLanguageKeepsTheAlternation() async {
        let contents = ["fr: a #dup", "fr: b #dup", "fr: c", "fr: d", "en: a", "en: b", "en: c"]
        let scores = zip(contents, [0.9, 0.85, 0.8, 0.7, 0.6, 0.5, 0.4]).reduce(into: [String: Double]()) { $0[$1.0] = $1.1 }
        let results = contents.enumerated().map { makeResult(url: "https://exemple.fr/\($0.offset)", content: $0.element) }

        let ranked = await ranker(scorer: FixedSimilarityScorer(scores, defaultScore: 0), duplicates: MarkerDuplicateScorer())
            .rank(query: "fr: question", results: results, limit: 5)

        #expect(ranked.map(\.result.content) == ["fr: a #dup", "en: a", "fr: c", "en: b", "fr: d"])
    }

    @Test("Une langue entièrement sous le plancher ne place rien ; tout sous le plancher : repli global par position")
    func floorAppliesPerLanguageWithGlobalFallback() async {
        let lowEnglish = ["fr: 1": 0.9, "fr: 2": 0.88, "fr: 3": 0.86, "en: 1": 0.1, "en: 2": 0.1]
        let withoutEnglish = await ranker(scorer: FixedSimilarityScorer(lowEnglish, defaultScore: 0)).rank(query: "fr: q", results: bilingualResults, limit: 5)
        #expect(withoutEnglish.map(\.result.content) == ["fr: 1", "fr: 2", "fr: 3"])

        let allLow = await ranker(scorer: FixedSimilarityScorer(defaultScore: 0.1)).rank(query: "fr: q", results: bilingualResults, limit: 5)
        #expect(allLow.map(\.originalPosition) == [0, 1, 2, 3, 4])
    }

    @Test("Détection réelle (NLLanguageRecognizer) : phrase française, phrase anglaise, texte trop court ou vide")
    func realLanguageIdentifier() {
        let identifier = NaturalLanguageTextIdentifier()
        #expect(identifier.dominantLanguage(of: "Comment fonctionne la photosynthèse chez les plantes vertes ?") == "fr")
        #expect(identifier.dominantLanguage(of: "How does photosynthesis work in green plants?") == "en")
        #expect(identifier.dominantLanguage(of: "   ") == nil)
        #expect(identifier.dominantLanguage(of: "") == nil)
    }
}
