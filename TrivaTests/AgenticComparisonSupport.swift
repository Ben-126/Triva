//
//  AgenticComparisonSupport.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation
import Synchronization
@testable import Triva

// Logique PURE du banc de comparaison 2.4 (spec §7). Aucun modèle, aucun réseau : testée dans la suite normale
// (`AgenticComparisonSupportTests`). Le banc lui-même est `AgenticResearchComparisonTests` (`TRIVA_EVAL=1`).

// MARK: - Faits attendus

/// Faits attendus d'une question : groupes de mots, sans accents ni casse, UN SEUL mot par groupe suffit.
nonisolated enum AgenticEvalFacts {
    /// Minuscules et sans accents, comme `LexicalRelevance`.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
    }

    /// Nombre de groupes dont au moins un mot figure dans `answer`.
    static func foundGroupCount(in answer: String, groups: [[String]]) -> Int {
        let folded = fold(answer)
        return groups.filter { group in group.contains { contains(token: fold($0), in: folded) } }.count
    }

    /// Un nombre (« 20 », « 40,8 ») ne se lit pas DANS un nombre plus long (« 2024 ») ; un mot ou une
    /// souche (« hepat ») est cherché tel quel.
    static func contains(token: String, in folded: String) -> Bool {
        guard !token.isEmpty else { return false }
        guard token.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }) else { return folded.contains(token) }
        var searchStart = folded.startIndex
        while let range = folded.range(of: token, range: searchStart..<folded.endIndex) {
            let before = range.lowerBound == folded.startIndex ? nil : folded[folded.index(before: range.lowerBound)]
            let after = range.upperBound == folded.endIndex ? nil : folded[range.upperBound]
            if !(before?.isNumber ?? false), !(after?.isNumber ?? false) { return true }
            searchStart = range.upperBound
        }
        return false
    }
}

// MARK: - Plage de questions

nonisolated enum AgenticEvalRange {
    /// `TRIVA_EVAL_RANGE` : « a-b » (inclusif, indices de 0) ou « a ». Absent ou illisible : tout le jeu.
    /// Borné au jeu ; `nil` si la plage demandée est entièrement hors du jeu.
    static func parse(_ raw: String?, questionCount: Int) -> ClosedRange<Int>? {
        let full = 0...(questionCount - 1)
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return full }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, (1...2).contains(numbers.count) else { return full }
        let lower = numbers[0]
        let upper = numbers.count == 2 ? numbers[1] : numbers[0]
        guard lower >= 0, lower <= upper else { return full }
        guard lower <= full.upperBound else { return nil }
        return lower...min(upper, full.upperBound)
    }
}

// MARK: - Citations

nonisolated struct AgenticCitationStats: Sendable, Equatable {
    /// Tous les marqueurs `[n]` du texte.
    let total: Int
    /// Marqueurs vers une source affichée ET lue (`1...sourceCount`, hors `unread`).
    let valid: Int
    let validIndices: [Int]
    var invalid: Int { total - valid }

    /// Même règle que `CitationParser.parse(_:sourceCount:unread:)` : un marqueur hors limites ou vers une
    /// source non lue n'est pas une citation valide.
    static func compute(text: String, sourceCount: Int, unread: Set<Int>) -> AgenticCitationStats {
        let indices = text.matches(of: /\[(\d{1,4})\]/).compactMap { Int($0.output.1) }
        let validOnes = indices.filter { $0 >= 1 && $0 <= sourceCount && !unread.contains($0) }
        return AgenticCitationStats(total: indices.count, valid: validOnes.count, validIndices: Array(Set(validOnes)).sorted())
    }
}

// MARK: - Confidentialité

/// Garde-fou des sorties : AUCUN hôte d'instance SearXNG dans un fichier du banc (l'instance personnelle de Ben
/// ne doit jamais en sortir). Construit sur la liste d'instances réellement chargée ; sans liste, pas de
/// nettoyeur, donc pas d'écriture (on n'écrit pas ce qu'on ne peut pas vérifier).
nonisolated struct AgenticEvalScrubber: Sendable {
    static let placeholder = "[instance]"
    private let hosts: [String]

    init?(instances: [URL]) {
        var set = Set<String>()
        for url in instances {
            guard var host = url.host?.lowercased(), !host.isEmpty else { continue }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            set.insert(host)
        }
        guard !set.isEmpty else { return nil }
        hosts = set.sorted { $0.count > $1.count }
    }

    func containsInstanceHost(_ text: String) -> Bool {
        hosts.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Remplace chaque occurrence (casse ignorée, avec ou sans `www.`) ; rend le nombre de remplacements.
    func redact(_ text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        for host in hosts {
            while let range = result.range(of: host, options: .caseInsensitive) {
                result.replaceSubrange(range, with: Self.placeholder)
                count += 1
            }
        }
        return (result, count)
    }
}

// MARK: - Erreurs

nonisolated enum AgenticEvalError {
    /// Nom du CAS d'erreur, jamais son texte (un échec de basculement peut porter l'adresse d'une instance).
    static func describe(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is AppleIntelligenceError || error is AppleIntelligenceGenerationError {
            return caseName(of: error)
        }
        if let failure = error as? AgenticResearchFailure { return "researcher:\(String(describing: failure.reason))" }
        return "other:\(String(describing: type(of: error)))"
    }

    private static func caseName(of value: Any) -> String {
        if let label = Mirror(reflecting: value).children.first?.label { return label }
        return String(describing: value).prefix { $0 != "(" }.description
    }
}

// MARK: - Statistiques

nonisolated enum AgenticEvalStats {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

// MARK: - Enregistrement d'une exécution

/// Une exécution du banc (une question, un mode, un passage, un côté). Fabriqué à la main : on n'encode JAMAIS
/// un `SearXNGSearchResult` entier (`imgSrc`, `thumbnail` peuvent passer par le proxy d'une instance).
nonisolated struct AgenticEvalRecord: Codable, Sendable, Equatable {
    nonisolated struct Source: Codable, Sendable, Equatable {
        var host: String
        var title: String
        /// Page réellement lue (scrape réussi) pendant cette exécution.
        var read: Bool
        /// Domaine fiable (`SourceRanker.isTrustedDomain`).
        var trusted: Bool
        /// Citable par le rédacteur (pas dans `uncitableSourceNumbers`).
        var citable: Bool
    }

    nonisolated struct Investigator: Codable, Sendable, Equatable {
        var calls: Int
        var searches: Int
        var reads: Int
        var toolCalls: Int
        var queries: [String]
        var stop: String
        var failure: String?
    }

    var schema = 1
    var question: Int
    var questionText: String
    var mode: String
    var pass: Int
    var side: String
    /// 1 si ce côté est passé en premier dans la paire (A puis B au passage 1, B puis A au passage 2).
    var position = 1
    var platform = ""
    /// `classic`, `agentic` ou `fellBack:<raison>`.
    var path = "classic"
    var answer = ""
    /// `answered`, `empty` (flux vide : rien de fiable en mode Fiable), `rejected` (garde de citation du mode
    /// Fiable) ou `error`.
    var verdict = "answered"
    var sources: [Source] = []
    var distinctDomains = 0
    var factsFound = 0
    var factsTotal = 0
    /// Faits jugés à la main (pas de groupes attendus, ou chiffres à comparer).
    var factsManual = false
    var citationsTotal = 0
    var citationsValid = 0
    var citationsInvalid = 0
    var citesReadPage = false
    var pagesRead = 0
    var investigator: Investigator?
    /// Appels au modèle d'Apple Intelligence faits par le pipeline (classification, widgets, planner, rédaction).
    var modelCalls = 0
    var promptCharacters = 0
    /// Délai jusqu'au retour de `streamAnswer` (recherche terminée, avant le 1er token).
    var researchSeconds: Double?
    var firstTokenSeconds: Double?
    var totalSeconds = 0.0
    var searchPerformed = false
    var searchQuery: String?
    var widgets: [String] = []
    /// Mode Fiable : toutes les sources affichées passent `isTrustedDomain` (nil hors Fiable).
    var allSourcesTrusted: Bool?
    /// Témoin de la question respecté (nil : pas de témoin ici, ou non applicable).
    var witnessOK: Bool?
    var error: String?
}

// MARK: - Écriture

nonisolated enum AgenticEvalWriter {
    static func fileName(for record: AgenticEvalRecord) -> String {
        String(format: "q%02d-%@-p%d-%@.json", record.question, record.mode, record.pass, record.side)
    }

    static func exists(_ record: AgenticEvalRecord, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName(for: record)).path)
    }

    struct HostLeak: Error {}

    /// JSON de l'enregistrement, nettoyé des hôtes d'instance ; lève si un hôte survivait (on n'écrit alors rien).
    static func encode(_ record: AgenticEvalRecord, scrubber: AgenticEvalScrubber) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let raw = String(decoding: try encoder.encode(record), as: UTF8.self)
        let clean = scrubber.redact(raw).text
        guard !scrubber.containsInstanceHost(clean) else { throw HostLeak() }
        return clean
    }

    static func write(_ record: AgenticEvalRecord, to directory: URL, scrubber: AgenticEvalScrubber) throws {
        let json = try encode(record, scrubber: scrubber)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json.write(to: directory.appendingPathComponent(fileName(for: record)), atomically: true, encoding: .utf8)
    }

    /// Tous les enregistrements déjà écrits dans `directory`, triés par nom.
    static func readAll(in directory: URL) -> [AgenticEvalRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0.hasPrefix("q") }.sorted().compactMap { name in
            let data = try? Data(contentsOf: directory.appendingPathComponent(name))
            return data.flatMap { try? JSONDecoder().decode(AgenticEvalRecord.self, from: $0) }
        }
    }
}

// MARK: - Résumé Markdown

nonisolated enum AgenticEvalSummary {
    static func markdown(records: [AgenticEvalRecord]) -> String {
        var lines = ["# Banc de comparaison 2.4 : résumé", "", "\(records.count) exécutions.", ""]
        lines += ["## Par mode et par côté", "",
                  "| mode | côté | exécutions | erreurs | replis | questions complètes | citations valides | 1er token médian (s) | durée médiane (s) |",
                  "|---|---|---|---|---|---|---|---|---|"]
        for mode in Set(records.map(\.mode)).sorted() {
            for side in ["classic", "agentic"] {
                let group = records.filter { $0.mode == mode && $0.side == side }
                guard !group.isEmpty else { continue }
                let complete = group.filter { !$0.factsManual && $0.factsTotal > 0 && $0.factsFound == $0.factsTotal }.count
                let total = group.map(\.citationsTotal).reduce(0, +)
                let valid = group.map(\.citationsValid).reduce(0, +)
                lines.append("| \(mode) | \(side) | \(group.count) | \(group.filter { $0.error != nil }.count) | "
                    + "\(group.filter { $0.path.hasPrefix("fellBack") }.count) | \(complete) | \(valid)/\(total) | "
                    + "\(format(AgenticEvalStats.median(group.compactMap(\.firstTokenSeconds)))) | "
                    + "\(format(AgenticEvalStats.median(group.map(\.totalSeconds)))) |")
            }
        }
        lines += ["", "## Chaque exécution", "",
                  "| question | mode | passage | côté | chemin | faits | citations | pages lues | 1er token | durée | erreur |",
                  "|---|---|---|---|---|---|---|---|---|---|---|"]
        for record in records {
            let facts = record.factsManual ? "à la main" : "\(record.factsFound)/\(record.factsTotal)"
            lines.append(String(format: "| q%02d | %@ | p%d | %@ | %@ | %@ | %d/%d | %d | %@ | %@ | %@ |",
                                record.question, record.mode, record.pass, record.side, record.path, facts,
                                record.citationsValid, record.citationsTotal, record.pagesRead,
                                format(record.firstTokenSeconds), format(record.totalSeconds), record.error ?? ""))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.1f", $0) } ?? "-"
    }
}
