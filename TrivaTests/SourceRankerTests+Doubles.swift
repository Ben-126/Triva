//
//  SourceRankerTests+Doubles.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

// Sorti de `SourceRankerTests.swift` (mission E1c) : fabriques et doublures partagées par les suites SourceRanker*. Déplacement pur ; `private` retiré, et `makeSourceResult` / `SourceRankerNeverDuplicateScorer` renommés (`makeSourceResult` / `SourceRankerNeverDuplicateScorer`) pour ne pas entrer en collision avec les helpers privés d'autres fichiers de test.

// MARK: - Fabriques et scorers factices

/// Fabrique un résultat SearXNG minimal : seuls `url`, `title` et `content`
/// comptent pour le ranking, tous les autres champs (images, iframe, auteur)
/// ne sont jamais lus par `SourceRanker`.
func makeSourceResult(
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
struct FixedSimilarityScorer: TextSimilarityScoring {
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
struct SourceRankerNeverDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

/// Scorer de doublons saturé : tout est quasi-doublon de tout.
struct AlwaysDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 1, count: candidates.count)
    }
}

/// Renvoie EXACTEMENT le seuil de quasi-doublon : sert à prouver que la
/// comparaison est stricte (`> seuil`), comme le `similarity > 0.75` du web.
struct AtThresholdDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: SourceRanker.defaultNearDuplicateThreshold, count: candidates.count)
    }
}

/// Scorer VOLONTAIREMENT NON CONFORME au contrat du protocole : il renvoie
/// moins de scores qu'il n'a reçu de candidats. Sert à prouver que la
/// lecture indexée avec repli `0` de `SourceRanker.score` tient — sans ce
/// test, cette branche défensive partirait en production sans jamais avoir
/// été exécutée.
struct TruncatedSimilarityScorer: TextSimilarityScoring {
    let scores: [Double]

    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        scores
    }
}

/// Langue toujours indéterminée : un seul groupe, donc exactement le port du
/// web. Épinglée dans tous les tests d'avant la décision 3, pour qu'aucun
/// d'eux ne dépende de la détection de langue du système sur ses extraits.
struct UndeterminedLanguageIdentifier: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

/// Ranker prêt à l'emploi pour les tests de scoring : scorer de pertinence
/// contrôlé, déduplication de contenu désactivée.
func makeRanker(
    relevance: any TextSimilarityScoring,
    unfilteredFallbackCount: Int = SourceRanker.defaultUnfilteredFallbackCount
) -> SourceRanker {
    SourceRanker(
        relevanceScorer: relevance,
        duplicateScorer: SourceRankerNeverDuplicateScorer(),
        languageIdentifier: UndeterminedLanguageIdentifier(),
        unfilteredFallbackCount: unfilteredFallbackCount
    )
}

