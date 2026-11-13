//
//  SourceRankerRankingTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

// Sorti de `SourceRankerTests.swift` (mission E1c) : suites de classement, déduplication, sources fiables et pilotage par ResponseMode. Déplacement pur.

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
            makeSourceResult(url: "https://blog-perso.example/js-vs-ts", content: "Mon avis sur JavaScript et TypeScript"),
            makeSourceResult(url: "https://www.pinterest.com/pin/1", content: "Infographie JavaScript TypeScript"),
            makeSourceResult(url: "https://developer.mozilla.org/fr/docs/Web/JavaScript", content: "Référence du langage JavaScript"),
            makeSourceResult(url: "https://stackoverflow.com/questions/1", content: "Quand préférer TypeScript à JavaScript ?"),
            makeSourceResult(url: "https://fr.wikipedia.org/wiki/TypeScript", content: "TypeScript est un langage à typage statique"),
            makeSourceResult(url: "https://medium.example/ts", content: "Pourquoi j'ai migré vers TypeScript"),
        ]
    }

    @Test("Requête de référence du plan : ordre final décroissant et explicable")
    func javaScriptVersusTypeScriptOrdering() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let ranked = await ranker.rank(query: "JavaScript vs TypeScript", results: javaScriptVersusTypeScriptResults(), limit: 5)

        // À similarité égale, les 3 sources boostées passent devant malgré
        // des positions moins bonnes, et Pinterest tombe en dernier malgré
        // sa 2e place chez le moteur : c'est précisément ce que le scoring
        // de la version web d'origine apporte au classement brut.
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
            results: [makeSourceResult(url: "https://exemple.fr/a"), makeSourceResult(url: "https://fr.wikipedia.org/wiki/X")],
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
        let results = (0..<12).map { makeSourceResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }

        #expect(await ranker.rank(query: "q", results: results, limit: 5).count == 5)
        #expect(await ranker.rank(query: "q", results: results, limit: 3).count == 3)
        #expect(await ranker.rank(query: "q", results: results, limit: 20).count == 12)
    }

    @Test("Limite nulle ou négative : rien, sans appeler le scorer")
    func nonPositiveLimitReturnsNothing() async {
        let ranker = makeRanker(relevance: FixedSimilarityScorer(defaultScore: 0.5))
        let results = [makeSourceResult(url: "https://exemple.fr/a")]
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
        let ranked = await ranker.rank(query: "q", results: [makeSourceResult(url: "https://exemple.fr/a")], limit: 5)
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
        let padding = (0..<10).map { makeSourceResult(url: "https://exemple.fr/pad\($0)", content: "faible") }
        let tied = (0..<5).map { makeSourceResult(url: "https://exemple.fr/ex\($0)", content: "fort \($0)") }

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
                makeSourceResult(url: "https://exemple.fr/a", content: "pertinent"),
                makeSourceResult(url: "https://exemple.fr/b", content: "bruit"),
                makeSourceResult(url: "https://exemple.fr/c", content: "limite"),
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
        let results = (0..<8).map { makeSourceResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }
        let ranked = await ranker.rank(query: "q", results: results, limit: 5)

        #expect(ranked.count == 5)
        #expect(ranked.map(\.originalPosition) == [0, 1, 2, 3, 4])
    }

    @Test("Repli : ce sont les 5 premiers DU MOTEUR, pas les 5 meilleurs scores")
    func fallbackIgnoresDomainBoostWhenChoosingTheFive() async {
        // Une source boostée placée en 7e position par le moteur aurait le
        // meilleur score de tout le lot ; elle ne doit pourtant PAS entrer
        // dans le repli, qui tronque avant le tri.
        var results = (0..<6).map { makeSourceResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }
        results.append(makeSourceResult(url: "https://fr.wikipedia.org/wiki/X", content: "extrait wikipedia"))

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
            duplicateScorer: SourceRankerNeverDuplicateScorer(),
            languageIdentifier: UndeterminedLanguageIdentifier()
        )
        let results = (0..<4).map { makeSourceResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }
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
                makeSourceResult(url: "https://exemple.fr/article?utm_campaign=a", content: "extrait A"),
                makeSourceResult(url: "https://www.exemple.fr/article/", content: "extrait B"),
                makeSourceResult(url: "https://exemple.fr/article#intro", content: "extrait C"),
                makeSourceResult(url: "https://autre.fr/page", content: "extrait D"),
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
                makeSourceResult(url: "https://exemple.fr/a", content: "extrait 1"),
                makeSourceResult(url: "https://exemple.fr/b", content: "extrait 2"),
                makeSourceResult(url: "https://exemple.fr/a?id=2", content: "extrait 3"),
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
            results: (0..<4).map { makeSourceResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") },
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
                makeSourceResult(url: "https://exemple.fr/a", content: "extrait 1"),
                makeSourceResult(url: "https://exemple.fr/b", content: "extrait 2"),
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
                makeSourceResult(url: "https://journal-a.example/article", content: dispatch),
                makeSourceResult(url: "https://journal-b.example/reprise", content: "Mardi soir, le conseil municipal a voté une enveloppe de 4,2 millions d'euros destinée à la rénovation du réseau d'eau potable de la commune."),
                makeSourceResult(url: "https://exemple.fr/autre", content: "La piscine municipale rouvrira en septembre après dix-huit mois de travaux d'isolation thermique."),
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
            makeSourceResult(url: "https://blog.example/a", content: "extrait blog"),
            makeSourceResult(url: "https://www.pinterest.com/pin/1", content: "extrait pinterest"),
            makeSourceResult(url: "https://fr.wikipedia.org/wiki/X", content: "extrait wikipedia"),
            makeSourceResult(url: "https://medium.example/b", content: "extrait medium"),
            makeSourceResult(url: "https://arxiv.org/abs/1", content: "extrait arxiv"),
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
            results: [makeSourceResult(url: "https://blog.example/a"), makeSourceResult(url: "https://medium.example/b")],
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
        (0..<10).map { makeSourceResult(url: "https://exemple.fr/\($0)", content: "extrait \($0)") }
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
            makeSourceResult(url: "https://blog.example/a", content: "extrait blog"),
            makeSourceResult(url: "https://fr.wikipedia.org/wiki/X", content: "extrait wikipedia"),
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
