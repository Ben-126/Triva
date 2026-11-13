//
//  SourceRankerLanguageTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
@testable import Triva

// Sorti de `SourceRankerTests.swift` (mission E1c) : suite « une langue à la fois » et ses doublures privées. Déplacement pur.

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
    makeSourceResult(url: "https://exemple.fr/\($0.offset)", content: $0.element)
}

@MainActor
@Suite("SourceRanker — une langue à la fois (décision 3)")
struct SourceRankerLanguageTests {
    private func ranker(
        scorer: any TextSimilarityScoring = FixedSimilarityScorer(biasedScores, defaultScore: 0.5),
        duplicates: any TextSimilarityScoring = SourceRankerNeverDuplicateScorer(),
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

        // Témoin : sans langue détectée, l'ordre du port de la version web d'origine met tout le
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
        let results = contents.enumerated().map { makeSourceResult(url: "https://exemple.fr/\($0.offset)", content: $0.element) }

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
