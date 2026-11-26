//
//  AgenticComparisonWorld.swift
//  TrivaTests
//
//  Created by ben podrojsky on 26/11/2026.
//

import Testing
import Foundation
import FoundationModels
@testable import Triva

/// Ce que `streamAnswer` a donné, ou l'erreur classée ; rien d'autre ne sort d'une exécution.
nonisolated struct AgenticEvalStreamed: Sendable {
    var artifacts: SearchArtifacts?
    var text = ""
    var researchSeconds: Double?
    var firstTokenSeconds: Double?
    var totalSeconds = 0.0
    var error: String?
}

/// Environnement partagé de TOUTES les exécutions d'un lancement : un seul `FailoverManager` (mémoire de
/// fiabilité en mémoire, jamais le store persisté de Ben), une seule chaîne de recherche, le nettoyeur de
/// sorties et le dossier de sortie.
@MainActor
final class AgenticEvalWorld {
    nonisolated static let runTimeout: Duration = .seconds(300)

    /// `nil` si la liste d'instances est illisible ou vide : sans elle, pas de nettoyeur, donc pas de banc.
    static let shared: AgenticEvalWorld? = AgenticEvalWorld()

    private let failover: FailoverManager
    private let chain: WebSearchChain
    private let scrubber: AgenticEvalScrubber
    let outputDirectory: URL

    private init?() {
        guard let instances = try? PublicInstanceList.load(), let scrubber = AgenticEvalScrubber(instances: instances) else { return nil }
        let manager = FailoverManager(instances: instances)
        self.failover = manager
        self.scrubber = scrubber
        self.chain = WebSearchChain(
            searxng: SearXNGWebSearchProvider(failover: manager),
            fallbackLanguage: SearchSession.fallbackSearchLanguage()
        )
        .retryingTransientFailures(after: WebSearchChain.transientRetryDelay)
        self.outputDirectory = Self.resolveOutputDirectory()
        log("dossier=\(outputDirectory.path)")
    }

    // MARK: - Dossier de sortie

    private static func resolveOutputDirectory() -> URL {
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("triva-eval-2.4", isDirectory: true)
        guard let path = AgenticEvalGate.environment["TRIVA_EVAL_OUT"], !path.isEmpty else { return fallback }
        let requested = URL(fileURLWithPath: path, isDirectory: true)
        let probe = requested.appendingPathComponent(".ecriture-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return requested
        } catch {
            return fallback
        }
    }

    /// Ligne `EVAL|` sur la sortie standard, nettoyée comme les fichiers.
    func log(_ message: String) {
        print("EVAL|\(scrubber.redact(message).text)")
    }

    // MARK: - Une exécution

    func runAndWrite(question: AgenticEvalQuestion, mode: ResponseMode, pass: Int, side: AgenticEvalSide, position: Int) async {
        var record = AgenticEvalRecord(
            question: question.number, questionText: question.text, mode: mode.rawValue, pass: pass, side: side.rawValue
        )
        record.position = position
        if AgenticEvalWriter.exists(record, in: outputDirectory) {
            log("q\(question.number) \(mode.rawValue) p\(pass) \(side.rawValue) déjà fait, sauté")
            return
        }
        record = await run(question: question, mode: mode, pass: pass, side: side, position: position)
        do {
            try AgenticEvalWriter.write(record, to: outputDirectory, scrubber: scrubber)
            log("q\(record.question) \(record.mode) p\(pass) \(record.side) chemin=\(record.path) verdict=\(record.verdict) "
                + "faits=\(record.factsFound)/\(record.factsTotal) pages=\(record.pagesRead) total=\(Int(record.totalSeconds))s "
                + "erreur=\(record.error ?? "-")")
        } catch {
            log("q\(record.question) \(record.mode) p\(pass) \(record.side) NON ÉCRIT (confidentialité ou disque)")
            Issue.record("Exécution non écrite : \(AgenticEvalError.describe(error))")
        }
    }

    func writeSummary() {
        let records = AgenticEvalWriter.readAll(in: outputDirectory)
        let markdown = AgenticEvalSummary.markdown(records: records)
        try? scrubber.redact(markdown).text.write(to: outputDirectory.appendingPathComponent("resume.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - Construction d'un côté

    private struct Side {
        let orchestrator: SearchOrchestrator
        let scraper: RecordingScraper
        let counter: EvalModelCounter
        let researcher: RecordingResearcher?
    }

    /// Même fabrique pour les deux côtés : seul `agenticResearcher` change.
    private func makeSide(_ side: AgenticEvalSide, mode: ResponseMode) -> Side {
        let scraper = RecordingScraper(inner: ScrapeService())
        let counter = EvalModelCounter()
        let researcher = side == .agentic ? RecordingResearcher(inner: AppleAgenticResearcher()) : nil
        let orchestrator = SearchOrchestrator(
            failoverManager: failover,
            aiProvider: RecordingGenerator(inner: AppleIntelligenceProvider(), counter: counter),
            responseMode: mode,
            configuration: .appleIntelligence,
            scrapeService: scraper,
            webSearchChain: chain,
            agenticResearcher: researcher
        )
        return Side(orchestrator: orchestrator, scraper: scraper, counter: counter, researcher: researcher)
    }

    private func run(question: AgenticEvalQuestion, mode: ResponseMode, pass: Int, side: AgenticEvalSide, position: Int) async -> AgenticEvalRecord {
        var record = AgenticEvalRecord(
            question: question.number, questionText: question.text, mode: mode.rawValue, pass: pass, side: side.rawValue
        )
        record.position = position
        record.platform = Self.platform
        var history: [ClassifierChatMessage] = []
        if let firstTurn = question.firstTurn {
            // Question 14 : le premier tour passe par le MÊME côté ; seul le second est mesuré.
            let first = makeSide(side, mode: mode)
            let streamed = await Self.stream(first.orchestrator, query: firstTurn, history: [])
            guard streamed.error == nil else {
                record.error = "tour1:\(streamed.error ?? "?")"
                record.verdict = "error"
                return record
            }
            history = [
                ClassifierChatMessage(role: .user, content: firstTurn),
                ClassifierChatMessage(role: .assistant, content: Self.visibleText(streamed.text)),
            ]
        }
        let current = makeSide(side, mode: mode)
        let streamed = await Self.streamWithTimeout(current.orchestrator, query: question.text, history: history)
        return fill(record, question: question, mode: mode, side: side, streamed: streamed, current: current)
    }

    private static var platform: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS Simulator"
        #endif
    }

    // MARK: - Lecture du flux

    nonisolated private static func streamWithTimeout(_ orchestrator: SearchOrchestrator, query: String, history: [ClassifierChatMessage]) async -> AgenticEvalStreamed {
        await withTaskGroup(of: AgenticEvalStreamed?.self) { group in
            group.addTask { await stream(orchestrator, query: query, history: history) }
            group.addTask {
                try? await Task.sleep(for: runTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            return AgenticEvalStreamed(totalSeconds: Double(runTimeout.components.seconds), error: "timeout")
        }
    }

    /// Délai jusqu'au retour de `streamAnswer` (recherche finie), jusqu'au 1er texte non vide, puis jusqu'à la fin.
    nonisolated private static func stream(_ orchestrator: SearchOrchestrator, query: String, history: [ClassifierChatMessage]) async -> AgenticEvalStreamed {
        let clock = ContinuousClock()
        let start = clock.now
        var result = AgenticEvalStreamed()
        do {
            let streaming = try await orchestrator.streamAnswer(query: query, chatHistory: history)
            result.artifacts = streaming.artifacts
            result.researchSeconds = seconds(start.duration(to: clock.now))
            for try await snapshot in streaming.textStream {
                if result.firstTokenSeconds == nil, !snapshot.isEmpty { result.firstTokenSeconds = seconds(start.duration(to: clock.now)) }
                result.text = snapshot
            }
        } catch {
            result.error = AgenticEvalError.describe(error)
        }
        result.totalSeconds = seconds(start.duration(to: clock.now))
        return result
    }

    nonisolated private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Ce que l'utilisateur lit : TL;DR puis corps, jamais le bloc `<think>`.
    nonisolated static func visibleText(_ text: String) -> String {
        let segments = ReasoningSegmenter.segment(text, isStreaming: false)
        return [segments.tldr ?? "", segments.body].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Enregistrement

    private func fill(
        _ base: AgenticEvalRecord, question: AgenticEvalQuestion, mode: ResponseMode, side: AgenticEvalSide,
        streamed: AgenticEvalStreamed, current: Side
    ) -> AgenticEvalRecord {
        var record = base
        record.error = streamed.error
        record.researchSeconds = streamed.researchSeconds
        record.firstTokenSeconds = streamed.firstTokenSeconds
        record.totalSeconds = streamed.totalSeconds
        record.modelCalls = current.counter.calls
        record.promptCharacters = current.counter.promptCharacters
        record.pagesRead = current.scraper.readCount
        record.investigator = current.researcher?.summary
        let visible = Self.visibleText(streamed.text)
        record.answer = visible
        guard let artifacts = streamed.artifacts else {
            record.verdict = "error"
            return record
        }
        record.path = Self.pathName(artifacts.researchPath)
        record.searchPerformed = artifacts.searchPerformed
        record.searchQuery = artifacts.searchQuery
        record.widgets = artifacts.widgets.map { $0.kind.rawValue }
        record.sources = artifacts.sources.enumerated().map { index, source in
            AgenticEvalRecord.Source(
                host: Self.host(of: source.url), title: String(source.title.prefix(120)),
                read: current.scraper.hasRead(source.url), trusted: SourceRanker.isTrustedDomain(source.url),
                citable: !artifacts.uncitableSourceNumbers.contains(index + 1)
            )
        }
        record.distinctDomains = Set(record.sources.map(\.host)).count
        record.allSourcesTrusted = mode == .reliable && !record.sources.isEmpty ? record.sources.allSatisfy(\.trusted) : nil
        fillMeasures(&record, question: question, artifacts: artifacts, visible: visible, text: streamed.text, side: side, researcher: current.researcher)
        return record
    }

    private func fillMeasures(
        _ record: inout AgenticEvalRecord, question: AgenticEvalQuestion, artifacts: SearchArtifacts,
        visible: String, text: String, side: AgenticEvalSide, researcher: RecordingResearcher?
    ) {
        record.factsManual = question.manualFacts
        record.factsTotal = question.expected.count
        record.factsFound = AgenticEvalFacts.foundGroupCount(in: visible, groups: question.expected)
        let stats = AgenticCitationStats.compute(text: visible, sourceCount: artifacts.sources.count, unread: artifacts.uncitableSourceNumbers)
        record.citationsTotal = stats.total
        record.citationsValid = stats.valid
        record.citationsInvalid = stats.invalid
        record.citesReadPage = stats.validIndices.contains { index in record.sources.indices.contains(index - 1) && record.sources[index - 1].read }
        if record.error != nil {
            record.verdict = "error"
        } else if artifacts.lacksReliableSources || text.isEmpty {
            record.verdict = "empty"
        } else if artifacts.rejectsReliableAnswer(text) {
            record.verdict = "rejected"
        } else {
            record.verdict = "answered"
        }
        guard side == .agentic else { return }
        switch question.witness {
        case .researcherNeverCalled: record.witnessOK = (researcher?.calls ?? 0) == 0
        case .researcherNotCalledWhenWidgetAnswered:
            record.witnessOK = record.widgets.contains("weather") ? (researcher?.calls ?? 0) == 0 : nil
        case .none, .sameVerdictBothSides: break
        }
    }

    nonisolated private static func pathName(_ path: ResearchPath) -> String {
        switch path {
        case .classic: "classic"
        case .agentic: "agentic"
        case .agenticFellBack(let reason): "fellBack:\(String(describing: reason))"
        }
    }

    nonisolated private static func host(of url: String) -> String {
        guard var host = URL(string: url)?.host?.lowercased() else { return "?" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
