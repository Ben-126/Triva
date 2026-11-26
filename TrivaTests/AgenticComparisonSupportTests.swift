//
//  AgenticComparisonSupportTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Logique pure du banc de comparaison 2.4 (spec §7), SANS modèle ni réseau : ces tests tournent dans la
/// suite normale (le banc lui-même, `AgenticResearchComparisonTests`, n'est lancé que par `TRIVA_EVAL=1`).
/// Les hôtes utilisés ici sont réservés (`.invalid`, RFC 2606).
@Suite("Banc de comparaison 2.4 : fonctions pures")
struct AgenticComparisonSupportTests {
    // MARK: - Faits attendus

    @Test("Un seul mot d'un groupe suffit, sans accents ni casse")
    func oneWordPerGroupIsEnough() {
        let answer = "Le réalisateur est Jean-Pierre JEUNET ; le film date de 2001."
        let groups = [["jeunet"], ["2001"]]
        #expect(AgenticEvalFacts.foundGroupCount(in: answer, groups: groups) == 2)
        #expect(AgenticEvalFacts.foundGroupCount(in: "Réalisé par Jeunet.", groups: groups) == 1)
        #expect(AgenticEvalFacts.foundGroupCount(in: "Aucun rapport.", groups: groups) == 0)
    }

    @Test("Un nombre n'est pas pris dans un nombre plus long")
    func numbersRespectDigitBoundaries() {
        #expect(AgenticEvalFacts.foundGroupCount(in: "Le taux normal est de 20 %.", groups: [["20"]]) == 1)
        #expect(AgenticEvalFacts.foundGroupCount(in: "Il date de 2024 et coûte 1200 euros.", groups: [["20"]]) == 0)
        #expect(AgenticEvalFacts.foundGroupCount(in: "330 m, antenne comprise.", groups: [["330"]]) == 1)
        #expect(AgenticEvalFacts.foundGroupCount(in: "Résultat : 40,8.", groups: [["40,8", "40.8"]]) == 1)
    }

    @Test("Les alternatives d'un groupe : l'accent, la casse et les mots-souches comptent")
    func stemsAndAccents() {
        #expect(AgenticEvalFacts.foundGroupCount(in: "Atteinte HÉPATIQUE possible.", groups: [["foie", "hepat"]]) == 1)
        #expect(AgenticEvalFacts.foundGroupCount(in: "Étude sur la productivité.", groups: [["etude", "study"], ["productivit"]]) == 2)
        #expect(AgenticEvalFacts.foundGroupCount(in: "Rien.", groups: []) == 0)
    }

    // MARK: - Plage de questions

    @Test("TRIVA_EVAL_RANGE : « a-b » inclusif, borné au jeu de questions")
    func rangeParsing() {
        #expect(AgenticEvalRange.parse("0-9", questionCount: 20) == 0...9)
        #expect(AgenticEvalRange.parse("10-19", questionCount: 20) == 10...19)
        #expect(AgenticEvalRange.parse("5", questionCount: 20) == 5...5)
        #expect(AgenticEvalRange.parse(" 3 - 30 ", questionCount: 20) == 3...19)
        #expect(AgenticEvalRange.parse(nil, questionCount: 20) == 0...19)
        #expect(AgenticEvalRange.parse("", questionCount: 20) == 0...19)
        #expect(AgenticEvalRange.parse("9-3", questionCount: 20) == 0...19)
        #expect(AgenticEvalRange.parse("abc", questionCount: 20) == 0...19)
        #expect(AgenticEvalRange.parse("25-30", questionCount: 20) == nil)
    }

    // MARK: - Citations

    @Test("Citations : valides, hors limites et vers une source non lue sont comptées à part")
    func citationStats() {
        let text = "Elle mesure 330 m [1][2]. Autre fait [7]. Encore [3] et [0]."
        let stats = AgenticCitationStats.compute(text: text, sourceCount: 3, unread: [3])
        #expect(stats.total == 5)
        #expect(stats.valid == 2)
        #expect(stats.invalid == 3)
        #expect(stats.validIndices == [1, 2])
    }

    @Test("Citations : texte sans marqueur, ou marqueur qui n'en est pas un")
    func citationStatsWithoutMarkers() {
        let stats = AgenticCitationStats.compute(text: "Aucune citation, juste un tableau t[1x] et [a].", sourceCount: 2, unread: [])
        #expect(stats.total == 0)
        #expect(stats.valid == 0)
        #expect(AgenticCitationStats.compute(text: "", sourceCount: 0, unread: []).total == 0)
    }

    // MARK: - Confidentialité des sorties

    @Test("Le nettoyeur retire l'hôte d'une instance, casse comprise, dans le texte comme dans les URL")
    func scrubberRemovesInstanceHosts() throws {
        let first = try #require(URL(string: "https://Instance-Secrete.invalid"))
        let second = try #require(URL(string: "https://autre.invalid:8443/search"))
        let scrubber = try #require(AgenticEvalScrubber(instances: [first, second]))
        let text = "Vu sur https://instance-secrete.invalid/search?q=a et AUTRE.INVALID, hôte www.autre.invalid."
        let redacted = scrubber.redact(text)
        #expect(!scrubber.containsInstanceHost(redacted.text))
        #expect(redacted.count == 3)
        #expect(!redacted.text.lowercased().contains("secrete"))
        #expect(scrubber.containsInstanceHost(text))
    }

    @Test("Aucune liste d'instances : pas de nettoyeur (on n'écrit rien sans pouvoir vérifier)")
    func scrubberNeedsInstances() {
        #expect(AgenticEvalScrubber(instances: []) == nil)
    }

    @Test("Le JSON écrit pour un FAUX enregistrement ne contient ni hôte d'instance ni URL d'instance")
    func writtenJSONNeverContainsInstanceHost() throws {
        let instance = try #require(URL(string: "https://instance-secrete.invalid"))
        let scrubber = try #require(AgenticEvalScrubber(instances: [instance]))
        var record = AgenticEvalRecord.fake()
        // Pièges : l'hôte dans la réponse, dans un titre, dans une requête de l'enquêteur, dans un hôte de source.
        record.answer = "Voir https://instance-secrete.invalid/image_proxy?url=x pour la photo."
        record.sources = [
            AgenticEvalRecord.Source(host: "instance-secrete.invalid", title: "Titre de instance-secrete.invalid", read: true, trusted: false, citable: true),
        ]
        record.investigator = AgenticEvalRecord.Investigator(
            calls: 1, searches: 1, reads: 0, toolCalls: 1, queries: ["instance-secrete.invalid recherche"], stop: "finished", failure: nil
        )
        record.error = "échec chez instance-secrete.invalid"

        let json = try AgenticEvalWriter.encode(record, scrubber: scrubber)
        #expect(!json.lowercased().contains("instance-secrete"))
        #expect(!scrubber.containsInstanceHost(json))
        // Le JSON reste valide et relisible.
        let decoded = try JSONDecoder().decode(AgenticEvalRecord.self, from: Data(json.utf8))
        #expect(decoded.question == record.question)
    }

    @Test("Écriture : un fichier par exécution, jamais écrasé ; l'existant est reconnu")
    func writerCreatesOneFilePerRunAndSkipsExisting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("triva-eval-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instance = try #require(URL(string: "https://x.invalid"))
        let scrubber = try #require(AgenticEvalScrubber(instances: [instance]))
        let record = AgenticEvalRecord.fake()

        #expect(!AgenticEvalWriter.exists(record, in: directory))
        try AgenticEvalWriter.write(record, to: directory, scrubber: scrubber)
        #expect(AgenticEvalWriter.exists(record, in: directory))
        let name = AgenticEvalWriter.fileName(for: record)
        #expect(name == "q01-deep-p1-classic.json")
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        #expect((try? JSONDecoder().decode(AgenticEvalRecord.self, from: data)) != nil)
    }

    // MARK: - Mesures

    @Test("Médiane : valeurs impaires, paires et vides")
    func medianOfDurations() {
        #expect(AgenticEvalStats.median([3, 1, 2]) == 2)
        #expect(AgenticEvalStats.median([4, 1, 3, 2]) == 2.5)
        #expect(AgenticEvalStats.median([]) == nil)
    }

    @Test("Erreur du banc : nom du cas seulement, jamais le texte ni l'hôte")
    func errorClassificationKeepsOnlyTheCaseName() {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "échec chez instance-secrete.invalid (secret)" }
        }
        #expect(AgenticEvalError.describe(CancellationError()) == "cancelled")
        #expect(AgenticEvalError.describe(Boom()) == "other:Boom")
        #expect(AgenticEvalError.describe(AppleIntelligenceError.generationFailed(description: "instance-secrete.invalid")) == "generationFailed")
    }

    // MARK: - Résumé

    @Test("Résumé Markdown : une ligne par exécution et des totaux par mode et par côté")
    func summaryListsEveryRun() {
        var classic = AgenticEvalRecord.fake()
        classic.factsFound = 1
        classic.factsTotal = 1
        var agentic = AgenticEvalRecord.fake()
        agentic.side = "agentic"
        agentic.path = "agentic"
        agentic.error = "contextWindowExceeded"
        let markdown = AgenticEvalSummary.markdown(records: [classic, agentic])
        #expect(markdown.contains("q01"))
        #expect(markdown.contains("classic"))
        #expect(markdown.contains("agentic"))
        #expect(markdown.contains("contextWindowExceeded"))
        #expect(markdown.components(separatedBy: "\n").filter { $0.hasPrefix("| q01") }.count == 2)
    }
}

extension AgenticEvalRecord {
    /// Enregistrement factice, aucun contenu réel.
    static func fake() -> AgenticEvalRecord {
        AgenticEvalRecord(question: 1, questionText: "Question factice ?", mode: "deep", pass: 1, side: "classic")
    }
}
