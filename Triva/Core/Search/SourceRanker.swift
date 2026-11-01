//
//  SourceRanker.swift
//  Triva
//
//  Created by ben podrojsky on 18/09/2026.
//

import Foundation
import NaturalLanguage

/// Langue dominante d'un texte, derrière un protocole pour la même raison que
/// `TextSimilarityScoring` : rendre le classement par langue
/// (`SourceRanker.rank`, décision 3 de Ben) entièrement prévisible en test,
/// sans dépendre des modèles de langue du système. Synchrone : une détection
/// sur un extrait de quelques centaines de caractères coûte une fraction de
/// milliseconde, et elle s'exécute déjà hors du main actor (voir le
/// `@concurrent` de `SourceRanker.rank`).
nonisolated protocol TextLanguageIdentifying: Sendable {
    /// Code de langue (`NLLanguage.rawValue` : « fr », « en »…), ou `nil`
    /// quand la détection n'est pas assez sûre pour trancher.
    func dominantLanguage(of text: String) -> String?
}

/// Implémentation réelle : `NLLanguageRecognizer` (framework Apple, aucune
/// dépendance). Le recognizer est une classe non-`Sendable` : créé, utilisé
/// et abandonné dans cette fonction synchrone, il ne traverse jamais de
/// frontière d'isolation (même précaution que
/// `NaturalLanguageSimilarityScorer.detectLanguage`).
nonisolated struct NaturalLanguageTextIdentifier: TextLanguageIdentifying {
    /// Même seuil, même justification mesurée que
    /// `NaturalLanguageSimilarityScorer(minimumLanguageConfidence:)` : une
    /// vraie phrase est reconnue au-delà de 0,97, un mot isolé (« python »)
    /// plafonne à 0,42 — en dessous de 0,5, on ne sait pas, on ne devine pas.
    static let defaultMinimumConfidence = 0.5

    /// Un extrait SearXNG suffit largement à reconnaître une langue ; borner
    /// l'échantillon évite de payer la détection sur un contenu anormalement long.
    static let maxSampleCharacters = 500

    private let minimumConfidence: Double

    init(minimumConfidence: Double = NaturalLanguageTextIdentifier.defaultMinimumConfidence) {
        self.minimumConfidence = minimumConfidence
    }

    func dominantLanguage(of text: String) -> String? {
        let sample = String(text.prefix(Self.maxSampleCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              best.value >= minimumConfidence
        else { return nil }
        return best.key.rawValue
    }
}

/// Un résultat de recherche accompagné du DÉTAIL de son score, et pas
/// seulement du `relevanceScore` final.
///
/// Garder chaque terme de la formule séparément est ce qui rend le
/// classement explicable : un test qui veut vérifier que le multiplicateur
/// de domaine a bien été appliqué n'a pas à refaire le calcul à l'envers, et
/// un futur écran de débogage (ou une info de source dans l'UI) peut montrer
/// pourquoi telle page est passée devant telle autre. Le web jette cette
/// information (`delete uniqueResult.metadata._similarity`) parce qu'elle y
/// transite par le réseau ; ici tout reste en mémoire, ça ne coûte rien.
///
/// `originalPosition` est l'index 0-based du résultat dans le tableau reçu
/// par `SourceRanker.rank` : il alimente `positionScore`, et sert aussi de
/// départage déterministe quand deux sources marquent exactement le même
/// score (voir `rank`).
nonisolated struct RankedSource: Sendable, Equatable {
    let result: SearXNGSearchResult
    let originalPosition: Int
    let similarity: Double
    let positionScore: Double
    let domainMultiplier: Double
    let relevanceScore: Double
}

/// Portage du scoring / ranking des sources (tâche 1.3), depuis
/// `src/lib/agents/search/researcher/actions/search/baseSearch.ts` (web) :
/// listes `BOOSTED_DOMAINS` / `PENALIZED_DOMAINS`, formule
/// `(similarity * 0,7 + positionScore * 0,3) * multiplicateur de domaine`,
/// filtre `similarity > 0,2` avec repli sur les premiers par position,
/// déduplication, puis troncature au top N.
///
/// LOGIQUE 100 % PURE ET DÉTERMINISTE, comme l'exige le plan : ce type ne
/// fait aucun appel réseau, ne calcule aucun embedding lui-même et ne lit
/// aucun état global. Tout ce qui n'est pas de l'arithmétique lui est
/// injecté sous forme de `TextSimilarityScoring` (fondation F1) — un scorer
/// factice rend donc la sortie entièrement prévisible dans les tests.
///
/// ## Deux scorers, pas un — divergence assumée vis-à-vis du web
///
/// Le web réutilise le MÊME embedding pour mesurer la pertinence ET pour
/// repérer les doublons (`similarity > 0.75` entre deux embeddings de
/// résultats). On sépare les deux rôles ici, pour deux raisons mesurées.
///
/// 1. Un seuil ABSOLU n'a pas de sens dans l'espace sémantique d'Apple.
///    Mesures de la fondation F1 sur macOS 27 : deux phrases françaises sans
///    aucun rapport marquent déjà 0,655, et un extrait réellement pertinent
///    plafonne autour de 0,90. Un seuil de 0,75 n'y sépare donc pas
///    "doublon" de "source distincte" — il supprimerait des sources
///    légitimes dès qu'elles parlent du même sujet, c'est-à-dire TOUS les
///    résultats d'une même recherche, par construction.
/// 2. "Quasi-doublon" est une question de recouvrement TEXTUEL, pas de
///    proximité sémantique. Deux articles indépendants sur le même sujet
///    sont sémantiquement quasi identiques mais lexicalement distincts ;
///    deux reprises d'une même dépêche sont lexicalement identiques.
///
/// D'où :
/// - `relevanceScorer` : sémantique (`NaturalLanguageSimilarityScorer` par
///   défaut, qui a déjà son propre repli lexical interne), pour mesurer la
///   pertinence vis-à-vis de la requête ;
/// - `duplicateScorer` : lexical (`LexicalSimilarityScorer` par défaut),
///   déterministe et hors-ligne, pour repérer les quasi-doublons.
///
/// Bénéfice secondaire : la déduplication ne dépend plus de la disponibilité
/// d'un modèle système, donc elle se comporte à l'identique dans toutes les
/// langues, sur tous les appareils et dans tous les tests.
///
/// ## Une langue à la fois — décision 3 de Ben, ajout sans équivalent web
///
/// La similarité est dominée par la LANGUE, pas par le sens (F1 : requête
/// française, extrait FR hors-sujet 0,881 devant extrait EN pertinent 0,842),
/// et `NaturalLanguageSimilarityScorer` choisit UN modèle par lot : mélangés,
/// les extraits anglais passent dans le modèle français, où leurs scores ne
/// veulent rien dire, même entre eux. `rank` traite donc chaque langue à
/// part : partition (`languageBuckets`), un appel de similarité PAR LANGUE,
/// plancher/tri/déduplication par langue, puis fusion en tourniquet
/// (`interleaved`). Aucun score n'est comparé d'une langue à l'autre.
/// Une seule langue : sortie identique au port du web. Pas de seuil absolu
/// sur ces scores (deux phrases sans rapport marquent déjà 0,655) : changer
/// ce mécanisme est un arbitrage produit réservé à Ben.
nonisolated struct SourceRanker: Sendable {

    // MARK: - Constantes portées du web

    /// Port littéral de `BOOSTED_DOMAINS` (`baseSearch.ts`). Sert AUSSI de
    /// définition des "sources fiables" du mode `reliable` (1.13) : le plan
    /// demande de restreindre aux domaines boostés, pas de maintenir une
    /// deuxième liste qui finirait par diverger de celle-ci.
    ///
    /// Conséquence à connaître : `github.com` et `stackoverflow.com` en font
    /// partie, donc le mode "fiable" accepte du contenu communautaire. C'est
    /// volontaire — c'est la liste du web, et sur une question technique ce
    /// sont effectivement les meilleures sources disponibles. Restreindre
    /// davantage est un arbitrage produit qui appartient à Ben, pas une
    /// correction à glisser en douce dans un portage.
    ///
    /// Trois formes de motifs, distinguées par `matches(host:pattern:)` :
    /// suffixe de domaine de premier niveau (`.gov`, `.edu`), préfixe de
    /// sous-domaine (`docs.`), et domaine complet (tout le reste).
    static let boostedDomains: [String] = [
        ".gov",
        ".edu",
        "wikipedia.org",
        "arxiv.org",
        "nature.com",
        "github.com",
        "stackoverflow.com",
        "developer.mozilla.org",
        "docs.",
        "w3.org",
        "pubmed.ncbi.nlm.nih.gov",
        "scholar.google.com",
    ]

    /// Port littéral de `PENALIZED_DOMAINS` (`baseSearch.ts`) : des sites de
    /// contenu généré par les utilisateurs, très bien référencés mais
    /// pauvres en information vérifiable.
    static let penalizedDomains: [String] = [
        "pinterest.com",
        "quora.com",
        "answers.yahoo.com",
        "ehow.com",
        "wikihow.com",
        "thoughtcatalog.com",
    ]

    /// Multiplicateurs du web, inchangés. `1,25` récompense sans écraser (une
    /// source boostée mal notée reste derrière une source neutre bien notée),
    /// `0,4` relègue franchement sans éliminer (une page Quora peut rester le
    /// seul résultat exploitable d'une recherche).
    static let boostedMultiplier = 1.25
    static let penalizedMultiplier = 0.4
    static let neutralMultiplier = 1.0

    /// Poids de la formule du web : `similarity * 0,7 + positionScore * 0,3`.
    /// La similarité domine, mais la position conserve 30 % — l'ordre rendu
    /// par le moteur de recherche est déjà un classement de qualité qu'il
    /// serait absurde de jeter entièrement.
    static let similarityWeight = 0.7
    static let positionWeight = 0.3

    /// `positionScore = max(0, 1 - position * 0,1)` : le 11e résultat et les
    /// suivants ne tirent plus aucun bénéfice de leur position.
    static let positionScoreDecay = 0.1

    /// Seuil de pertinence du web (`c.metadata._similarity > 0.2`), comparé
    /// en STRICT supérieur comme là-bas.
    ///
    /// Attention à l'interprétation : ce n'est PAS un seuil de "bonne"
    /// pertinence, c'est un plancher anti-bruit destiné à éliminer les
    /// résultats franchement hors-sujet. La fondation F1 prévient qu'un seuil
    /// absolu ne veut rien dire dans l'espace sémantique d'Apple, où les
    /// scores vivent dans une bande haute et étroite ; ici la conséquence est
    /// bénigne et VOULUE : avec ce scorer, à peu près rien ne passe sous 0,2,
    /// donc le filtre ne retire quasiment jamais rien. Il reste utile parce
    /// que le repli lexical de F1, lui, descend bien plus bas (mesuré : 0,13
    /// entre deux articles indépendants sur le même sujet) — c'est dans ce
    /// mode dégradé que le plancher travaille vraiment.
    static let minimumSimilarity = 0.2

    /// Seuil de quasi-doublon, comparé en STRICT supérieur comme le
    /// `similarity > 0.75` du web — mais interprété dans l'espace LEXICAL,
    /// pas sémantique (voir l'explication du double scorer en tête de type).
    ///
    /// La valeur 0,75 du web est conservée parce qu'elle est MESURÉE bonne
    /// dans ce nouvel espace, pas par fidélité aveugle. Relevés avec
    /// `LexicalSimilarityScorer` (macOS 27, textes français réalistes de
    /// longueur d'extrait SearXNG) :
    ///
    /// | Cas                                            | Score  |
    /// |------------------------------------------------|--------|
    /// | extrait comparé à lui-même                     | 1,0000 |
    /// | même dépêche, réécrite légèrement              | 0,9661 |
    /// | même dépêche, reformulée en profondeur         | 0,7857 |
    /// | même page, extrait tronqué différemment        | 0,8864 |
    /// | deux articles indépendants, même sujet         | 0,1291 à 0,2070 |
    /// | même fait, une source FR et une source EN      | 0,1612 |
    ///
    /// Le seuil tombe donc dans un vide de près de 0,58 entre le plus faible
    /// des vrais doublons (0,786) et le plus fort des faux (0,207) : aucun
    /// réglage fin n'est nécessaire, et les deux erreurs possibles ne se
    /// valent pas — laisser passer un doublon coûte une source redondante,
    /// supprimer un faux doublon coûte une source légitime. Le seuil est
    /// placé du côté prudent de ce vide.
    ///
    /// Limite connue et acceptée : le cross-langue marque 0,16, donc deux
    /// traductions du même article ne seront jamais dédoublonnées. Aucun
    /// scorer disponible ne sait faire mieux (F1 a mesuré que l'espace
    /// sémantique d'Apple est lui aussi disjoint d'une langue à l'autre), et
    /// le symptôme — deux sources disant la même chose dans deux langues —
    /// est bénin.
    static let defaultNearDuplicateThreshold = 0.75

    /// Nombre de résultats conservés quand le filtre `similarity > 0,2` a
    /// TOUT éliminé (`scored.slice(0, 5)` côté web).
    ///
    /// Ce repli compte, et le plan insiste pour qu'il soit porté : une
    /// similarité basse PARTOUT signale bien plus souvent un scorer en
    /// difficulté (langue non couverte par les modèles système, extraits
    /// vides renvoyés par l'instance) qu'une recherche réellement sans
    /// rapport. Mieux vaut répondre avec les premiers résultats du moteur que
    /// ne rien renvoyer du tout.
    static let defaultUnfilteredFallbackCount = 5

    // MARK: - Dépendances injectées

    private let relevanceScorer: any TextSimilarityScoring
    private let duplicateScorer: any TextSimilarityScoring
    private let languageIdentifier: any TextLanguageIdentifying
    private let nearDuplicateThreshold: Double
    private let unfilteredFallbackCount: Int

    /// - Parameters:
    ///   - relevanceScorer: mesure la pertinence extrait/requête. Sémantique
    ///     par défaut, avec son propre repli lexical interne (voir F1).
    ///   - duplicateScorer: mesure le recouvrement textuel entre deux
    ///     extraits déjà retenus. Lexical par défaut.
    ///   - languageIdentifier: partition par langue de `rank` (décision 3).
    ///   - nearDuplicateThreshold: voir `defaultNearDuplicateThreshold` pour
    ///     la justification mesurée de la valeur.
    ///   - unfilteredFallbackCount: voir `defaultUnfilteredFallbackCount`.
    init(
        relevanceScorer: any TextSimilarityScoring = NaturalLanguageSimilarityScorer(),
        duplicateScorer: any TextSimilarityScoring = LexicalSimilarityScorer(),
        languageIdentifier: any TextLanguageIdentifying = NaturalLanguageTextIdentifier(),
        nearDuplicateThreshold: Double = SourceRanker.defaultNearDuplicateThreshold,
        unfilteredFallbackCount: Int = SourceRanker.defaultUnfilteredFallbackCount
    ) {
        self.relevanceScorer = relevanceScorer
        self.duplicateScorer = duplicateScorer
        self.languageIdentifier = languageIdentifier
        self.nearDuplicateThreshold = nearDuplicateThreshold
        self.unfilteredFallbackCount = unfilteredFallbackCount
    }

    // MARK: - Point d'entrée

    /// Classe `results` par pertinence décroissante, déduplique, et tronque à
    /// `limit`.
    ///
    /// L'ORDRE D'ENTRÉE EST SIGNIFIANT : `positionScore` est dérivé de
    /// l'index dans `results`, qui doit donc être l'ordre rendu par
    /// l'instance de recherche. Passer un tableau déjà réordonné fausse 30 %
    /// de la formule sans qu'aucune erreur ne soit levée — c'est le seul
    /// contrat d'appel qu'aucun type ne peut faire respecter ici.
    ///
    /// - Parameters:
    ///   - query: la requête utilisateur, référence de la similarité.
    ///   - results: les résultats du moteur, DANS L'ORDRE RENDU.
    ///   - limit: nombre maximal de sources renvoyées, après déduplication.
    ///     Paramètre et non constante, pour rester aligné sur
    ///     `SearchOrchestrator.maxResultsUsedForContext` (5 aujourd'hui) et
    ///     sur `ResponseMode.targetSourceCount` (3 en mode rapide) sans
    ///     dupliquer la valeur.
    ///   - trustedDomainsOnly: mode `reliable` (1.13) — ne conserve que les
    ///     résultats dont l'hôte appartient à `boostedDomains`. Le filtre
    ///     s'applique AVANT le scoring, donc on ne paie pas de calcul de
    ///     similarité sur des sources qu'on va jeter.
    /// - Returns: au plus `limit` sources : triées par `relevanceScore`
    ///   décroissant à l'intérieur de chaque langue, langues alternées (voir
    ///   l'en-tête du type). **Peut être vide**, et l'appelant doit le gérer :
    ///   c'est le cas normal quand `trustedDomainsOnly` est actif et qu'aucun
    ///   résultat ne vient d'un domaine fiable. On ne retombe volontairement
    ///   PAS sur des sources non fiables dans ce cas — le mode "fiable"
    ///   promet une propriété à l'utilisateur, la trahir en silence serait
    ///   pire que de lui dire qu'on n'a rien trouvé de fiable.
    ///
    /// `@concurrent` : embeddings et détection de langue sont du calcul CPU
    /// (F1 : 2,65 ms pour 41 caractères, 42,9 ms pour 1 000). Sinon, une
    /// fonction `nonisolated async` tourne sur l'acteur de l'APPELANT
    /// (`NonisolatedNonsending` du projet), donc sur le main thread.
    @concurrent
    func rank(
        query: String,
        results: [SearXNGSearchResult],
        limit: Int,
        trustedDomainsOnly: Bool = false
    ) async -> [RankedSource] {
        guard limit > 0, !results.isEmpty else { return [] }

        let candidates = Self.candidates(from: results, trustedDomainsOnly: trustedDomainsOnly)
        guard !candidates.isEmpty else { return [] }

        let scoredBuckets = await scoredLanguageBuckets(query: query, candidates: candidates)
        let filteredBuckets = scoredBuckets.map { bucket in
            bucket.filter { $0.similarity > Self.minimumSimilarity }
        }

        guard filteredBuckets.contains(where: { !$0.isEmpty }) else {
            // Le repli reprend les N PREMIERS PAR POSITION, toutes langues
            // confondues, pas les N meilleurs scores : quand toutes les
            // similarités sont sous le plancher, elles ne veulent plus rien
            // dire, et seul l'ordre du moteur reste une information fiable.
            let byEnginePosition = scoredBuckets.joined().sorted { $0.originalPosition < $1.originalPosition }
            let fallback = Self.sortedByRelevance(Array(byEnginePosition.prefix(unfilteredFallbackCount)))
            return await deduplicated(fallback, limit: limit)
        }

        // Une langue dont TOUS les extraits sont sous le plancher (typiquement
        // une langue sans modèle, mesurée par le repli lexical contre une
        // requête d'une autre langue : ~0 partout) ne place aucune source.
        var dedupedBuckets: [[RankedSource]] = []
        for bucket in filteredBuckets where !bucket.isEmpty {
            dedupedBuckets.append(await deduplicated(Self.sortedByRelevance(bucket), limit: limit))
        }
        guard dedupedBuckets.count > 1 else { return dedupedBuckets.first ?? [] }

        // Déduplication par langue AVANT la fusion, pour que l'alternance
        // tienne : un doublon retiré après coup décalerait les tours au
        // profit de l'autre langue. Ce dernier passage n'attrape plus que les
        // doublons ENTRE langues (même URL) et applique la limite finale.
        return await deduplicated(Self.interleaved(dedupedBuckets), limit: limit)
    }

    /// Variante pilotée par le mode de réponse (1.13) : `ResponseMode` décrit
    /// déjà l'intention (`targetSourceCount`, `restrictsToTrustedDomains`),
    /// on se contente de la traduire en paramètres. Strictement aucune
    /// logique en plus ici, pour que les deux chemins ne puissent jamais
    /// diverger.
    func rank(
        query: String,
        results: [SearXNGSearchResult],
        mode: ResponseMode
    ) async -> [RankedSource] {
        await rank(
            query: query,
            results: results,
            limit: mode.targetSourceCount,
            trustedDomainsOnly: mode.restrictsToTrustedDomains
        )
    }

    // MARK: - Une langue à la fois (décision 3)

    /// Un résultat candidat et son index dans le tableau D'ORIGINE.
    typealias Candidate = (offset: Int, element: SearXNGSearchResult)

    /// Résultats soumis au scoring. L'index conservé est celui du tableau
    /// D'ORIGINE, y compris quand le filtre "sources fiables" a retiré des
    /// éléments avant : `positionScore` traduit la confiance du moteur de
    /// recherche dans son propre classement, pas le rang dans un
    /// sous-ensemble que nous avons choisi nous-mêmes.
    private static func candidates(from results: [SearXNGSearchResult], trustedDomainsOnly: Bool) -> [Candidate] {
        results.enumerated().filter { _, result in
            !trustedDomainsOnly || isTrustedDomain(result.url)
        }
    }

    /// Un appel `similarities` par langue : chaque lot est homogène, donc le
    /// scorer y choisit le modèle de cette langue (voir l'en-tête du type).
    private func scoredLanguageBuckets(query: String, candidates: [Candidate]) async -> [[RankedSource]] {
        let languages = candidates.map { languageIdentifier.dominantLanguage(of: Self.rankedContent(of: $0.element)) }
        let buckets = Self.languageBuckets(
            candidates,
            languages: languages,
            queryLanguage: languageIdentifier.dominantLanguage(of: query)
        )

        var scoredBuckets: [[RankedSource]] = []
        for bucket in buckets {
            let contents = bucket.map { Self.rankedContent(of: $0.element) }
            let similarities = await relevanceScorer.similarities(of: query, against: contents)
            scoredBuckets.append(Self.score(candidates: bucket, similarities: similarities))
        }
        return scoredBuckets
    }

    /// Partition par langue, pure et testable seule. Règles :
    /// - un groupe par langue détectée, ordre du moteur conservé dedans ;
    /// - langue indéterminée (`nil`, texte trop court pour trancher) versée
    ///   dans le PLUS GRAND groupe (le premier apparu à égalité) : un
    ///   résultat isolé non reconnu ne doit pas décrocher la 2e place par le
    ///   seul jeu de l'alternance. Que des `nil` : un seul groupe ;
    /// - ordre des groupes : par meilleure position chez le moteur, puis
    ///   celui de la langue de la requête ramené en tête — qui écrit en
    ///   français lit d'abord une source française. Requête non reconnue
    ///   (« python ») : l'ordre du moteur seul décide.
    ///
    /// Plus de deux langues : le tourniquet passe par toutes. Cas rare
    /// (SearXNG renvoie surtout la langue de la requête et l'anglais), et
    /// aucune règle de tri entre langues ne serait plus juste sans comparer
    /// des scores qui ne se comparent pas.
    static func languageBuckets<Element>(
        _ items: [Element],
        languages: [String?],
        queryLanguage: String?
    ) -> [[Element]] {
        var buckets: [(language: String, indices: [Int])] = []
        var undeterminedIndices: [Int] = []
        for index in items.indices {
            guard index < languages.count, let language = languages[index] else {
                undeterminedIndices.append(index)
                continue
            }
            if let bucketIndex = buckets.firstIndex(where: { $0.language == language }) {
                buckets[bucketIndex].indices.append(index)
            } else {
                buckets.append((language: language, indices: [index]))
            }
        }
        guard !buckets.isEmpty else { return items.isEmpty ? [] : [items] }

        // `reduce` plutôt que `max(by:)`, qui renverrait le DERNIER ex aequo.
        let largest = buckets.indices.reduce(0) { buckets[$1].indices.count > buckets[$0].indices.count ? $1 : $0 }
        buckets[largest].indices = (buckets[largest].indices + undeterminedIndices).sorted()

        // Chaque index n'appartient qu'à un groupe : aucun ex aequo possible,
        // donc ce tri est déterministe malgré un `sort` non stable.
        buckets.sort { ($0.indices.first ?? .max) < ($1.indices.first ?? .max) }
        if let queryLanguage,
           let preferred = buckets.firstIndex(where: { $0.language == queryLanguage }),
           preferred > 0 {
            buckets.insert(buckets.remove(at: preferred), at: 0)
        }
        return buckets.map { bucket in bucket.indices.map { items[$0] } }
    }

    /// Fusion en tourniquet : 1er de chaque groupe, puis 2e de chaque groupe,
    /// etc. Ne perd ni ne duplique aucun élément — seul l'ordre change.
    static func interleaved<Element>(_ groups: [[Element]]) -> [Element] {
        let rounds = groups.map(\.count).max() ?? 0
        return (0..<rounds).flatMap { round in
            groups.filter { round < $0.count }.map { $0[round] }
        }
    }

    // MARK: - Scoring

    /// Tri AVANT déduplication : c'est ce qui garantit que le membre le mieux
    /// noté d'un groupe de doublons est celui qu'on garde. Départage
    /// explicite par position d'origine, car `sorted(by:)` n'est pas garanti
    /// stable en Swift — sans ce départage, deux exécutions pourraient
    /// classer différemment deux sources à score identique.
    private static func sortedByRelevance(_ sources: [RankedSource]) -> [RankedSource] {
        sources.sorted { lhs, rhs in
            lhs.relevanceScore == rhs.relevanceScore
                ? lhs.originalPosition < rhs.originalPosition
                : lhs.relevanceScore > rhs.relevanceScore
        }
    }

    /// Assemble les `RankedSource` à partir des candidats et des scores du
    /// scorer. Isolée de `rank` pour garder les deux fonctions courtes et
    /// pour rendre lisible la précaution qu'elle contient.
    ///
    /// Lecture INDEXÉE avec repli `0`, jamais de `zip` : un `zip`
    /// tronquerait silencieusement la liste si une implémentation de scorer
    /// violait le contrat "exactement un score par candidat" — le résultat
    /// disparaîtrait du classement sans trace. Ici il reste présent, avec un
    /// score `0` visible (même précaution que
    /// `TextSimilarityScoring.rankedMatches`).
    private static func score(
        candidates: [(offset: Int, element: SearXNGSearchResult)],
        similarities: [Double]
    ) -> [RankedSource] {
        candidates.indices.map { candidateIndex in
            let candidate = candidates[candidateIndex]
            let similarity = candidateIndex < similarities.count ? similarities[candidateIndex] : 0
            let positionScore = Self.positionScore(forPosition: candidate.offset)
            let domainMultiplier = Self.domainMultiplier(for: candidate.element.url)

            return RankedSource(
                result: candidate.element,
                originalPosition: candidate.offset,
                similarity: similarity,
                positionScore: positionScore,
                domainMultiplier: domainMultiplier,
                relevanceScore: Self.relevanceScore(
                    similarity: similarity,
                    positionScore: positionScore,
                    domainMultiplier: domainMultiplier
                )
            )
        }
    }

    // MARK: - Déduplication à deux niveaux

    /// Un seul passage sur la liste DÉJÀ TRIÉE, conservant la première
    /// occurrence de chaque groupe (donc la mieux notée). Deux niveaux, dans
    /// cet ordre parce que le premier est gratuit :
    /// 1. URL normalisée (`normalizedURLKey`) — attrape les doublons stricts,
    ///    le cas le plus courant quand plusieurs moteurs agrégés par une même
    ///    instance SearXNG remontent la même page avec des paramètres de
    ///    suivi différents ;
    /// 2. quasi-doublon de contenu via `duplicateScorer` — attrape les
    ///    reprises d'une même dépêche publiées sur des URLs différentes.
    ///
    /// Un appel `similarities` PAR LOT par candidat (contre tout ce qui est
    /// déjà retenu), et non un appel par paire : c'est la primitive du
    /// protocole, et elle ne calcule la représentation du candidat qu'une
    /// fois pour tout le lot. Le lot est borné par `limit` (au plus `limit`
    /// textes retenus), pas par la taille du tableau d'entrée — le coût de la
    /// déduplication reste donc linéaire en nombre de résultats.
    private func deduplicated(_ ranked: [RankedSource], limit: Int) async -> [RankedSource] {
        var keptKeys: Set<String> = []
        var keptContents: [String] = []
        var kept: [RankedSource] = []

        for candidate in ranked {
            if kept.count >= limit { break }

            let key = Self.normalizedURLKey(for: candidate.result.url)
            if keptKeys.contains(key) { continue }

            let content = Self.rankedContent(of: candidate.result)
            if !keptContents.isEmpty {
                let duplicateScores = await duplicateScorer.similarities(of: content, against: keptContents)
                // Comparaison STRICTE, comme `similarity > 0.75` côté web.
                if duplicateScores.contains(where: { $0 > nearDuplicateThreshold }) { continue }
            }

            keptKeys.insert(key)
            keptContents.append(content)
            kept.append(candidate)
        }

        return kept
    }

    // MARK: - Fonctions pures (testables seules)

    /// Texte représentant un résultat pour le calcul de similarité. Port de
    /// `r.content || r.title` (web) : en JavaScript une chaîne vide est
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
    /// `docs.quora.com` vaut 1,25 et non 0,4. C'est le comportement du web,
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
    /// DIVERGENCE VOLONTAIRE vis-à-vis du web, qui fait un simple
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
    /// strictement plus juste, et la seule chose qu'on "perd" par rapport au
    /// web est la correspondance sur des mentions hors-hôte, qui n'avait
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
    /// littérales de celles du web :
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
    /// (vrai portail public britannique, que le `includes('.gov')` du web
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
