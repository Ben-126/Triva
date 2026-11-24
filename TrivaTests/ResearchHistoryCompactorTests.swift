//
//  ResearchHistoryCompactorTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 24/11/2026.
//

import Testing
import Foundation
import FoundationModels
@testable import Triva

private func textSegment(_ text: String) -> Transcript.Segment {
    .text(Transcript.TextSegment(content: text))
}

private func output(_ tool: String, _ text: String, id: String = UUID().uuidString) -> Transcript.Entry {
    .toolOutput(Transcript.ToolOutput(id: id, toolName: tool, segments: [textSegment(text)]))
}

private func call(_ tool: String) -> Transcript.Entry {
    let call = Transcript.ToolCall(id: UUID().uuidString, toolName: tool, arguments: GeneratedContent(properties: ["query": "x"]))
    return .toolCalls(Transcript.ToolCalls([call]))
}

private func outputText(_ entry: Transcript.Entry) -> String? {
    guard case .toolOutput(let output) = entry else { return nil }
    return output.segments.compactMap { segment -> String? in
        if case .text(let text) = segment { return text.content }
        return nil
    }.joined(separator: "\n")
}

private let searchText = "[1] Premier titre — a.fr\n[2] Deuxième titre — b.org\n[3] Troisième — c.com"
private let readText = "[2] lue, 4210 caractères.\nPassage : La tour Eiffel mesure 330 mètres."

private func fullTranscript() -> [Transcript.Entry] {
    [
        .instructions(Transcript.Instructions(segments: [textSegment("Consignes")], toolDefinitions: [])),
        .prompt(Transcript.Prompt(segments: [textSegment("Question")])),
        call("webSearch"), output("webSearch", searchText),
        call("readPage"), output("readPage", readText),
        call("webSearch"), output("webSearch", "[6] Autre — d.net\n[7] Encore — e.io"),
        call("readPage"), output("readPage", "[6] lue, 100 caractères.\nPassage : Un passage récent."),
    ]
}

@Suite("ResearchHistoryCompactor")
struct ResearchHistoryCompactorTests {
    @Test("Les deux dernières sorties d'outil restent entières, les anciennes tiennent sur une ligne")
    func keepsTheLastTwoOutputs() {
        let compacted = ResearchHistoryCompactor.compact(fullTranscript())
        let outputs = compacted.compactMap(outputText)
        #expect(outputs.count == 4)
        #expect(outputs[2] == "[6] Autre — d.net\n[7] Encore — e.io")
        #expect(outputs[3].contains("Passage : Un passage récent."))
        #expect(!outputs[0].contains("\n"))
        #expect(!outputs[1].contains("\n"))
    }

    @Test("Une recherche compactée garde ses NUMÉROS et ses domaines")
    func compactedSearchKeepsNumbers() {
        let outputs = ResearchHistoryCompactor.compact(fullTranscript()).compactMap(outputText)
        #expect(outputs[0] == "Résultats : [1] a.fr ; [2] b.org ; [3] c.com")
    }

    @Test("Une lecture compactée garde sa première ligne")
    func compactedReadKeepsFirstLine() {
        let outputs = ResearchHistoryCompactor.compact(fullTranscript()).compactMap(outputText)
        #expect(outputs[1] == "[2] lue, 4210 caractères.")
    }

    @Test("Instructions, prompt, appels d'outil et réponses passent tels quels, dans le même ordre")
    func otherEntriesAreUntouched() {
        let original = fullTranscript()
        let compacted = ResearchHistoryCompactor.compact(original)
        #expect(compacted.count == original.count)
        for (before, after) in zip(original, compacted) {
            if case .toolOutput = before { continue }
            #expect(before == after)
        }
    }

    @Test("Identifiant et nom d'outil de la sortie compactée sont conservés")
    func idsAndToolNamesSurvive() throws {
        let original = fullTranscript()
        let compacted = ResearchHistoryCompactor.compact(original)
        func outputs(_ entries: [Transcript.Entry]) -> [Transcript.ToolOutput] {
            entries.compactMap { entry in
                if case .toolOutput(let output) = entry { return output }
                return nil
            }
        }
        let before = outputs(original)
        let after = outputs(compacted)
        #expect(before.count == after.count)
        for (old, new) in zip(before, after) {
            #expect(new.id == old.id)
            #expect(new.toolName == old.toolName)
            #expect(new.segments.count == 1)
        }
    }

    @Test("Deux sorties ou moins : rien ne change")
    func twoOutputsOrFewerAreUntouched() {
        let transcript: [Transcript.Entry] = [call("webSearch"), output("webSearch", searchText), call("readPage"), output("readPage", readText)]
        #expect(ResearchHistoryCompactor.compact(transcript) == transcript)
        #expect(ResearchHistoryCompactor.compact([]).isEmpty)
    }

    @Test("Idempotent : compacter deux fois donne le même résultat")
    func isIdempotent() {
        let once = ResearchHistoryCompactor.compact(fullTranscript())
        #expect(ResearchHistoryCompactor.compact(once).map(outputText) == once.map(outputText))
    }

    @Test("La fonction est pure : le transcript d'origine n'est pas modifié")
    func doesNotMutateTheInput() {
        let original = fullTranscript()
        let copy = original
        _ = ResearchHistoryCompactor.compact(original)
        #expect(original == copy)
    }

    @Test("Une ligne compactée ne dépasse jamais 200 caractères")
    func lineIsCapped() {
        let long = (1...5).map { "[\($0)] \(String(repeating: "t", count: 70)) — domaine-\($0)-\(String(repeating: "x", count: 60)).org" }.joined(separator: "\n")
        let transcript: [Transcript.Entry] = [output("webSearch", long), output("readPage", "[1] " + String(repeating: "m", count: 500)), output("readPage", "a"), output("readPage", "b")]
        let outputs = ResearchHistoryCompactor.compact(transcript).compactMap(outputText)
        #expect(outputs[0].count <= ResearchHistoryCompactor.maxLineCharacters)
        #expect(outputs[1].count <= ResearchHistoryCompactor.maxLineCharacters)
    }

    @Test("Sortie vide ou sans format de liste : pas de plantage")
    func degenerateOutputs() {
        let transcript: [Transcript.Entry] = [
            output("webSearch", ""),
            output("webSearch", "Aucun résultat. Essaie d'autres mots."),
            output("finish", "ok"), output("finish", "ok"),
        ]
        let outputs = ResearchHistoryCompactor.compact(transcript).compactMap(outputText)
        #expect(outputs[0] == "")
        #expect(outputs[1] == "Aucun résultat. Essaie d'autres mots.")
    }

    @Test("Une sortie sans segment texte devient une ligne vide, sans plantage")
    func outputWithoutTextSegments() {
        let bare = Transcript.Entry.toolOutput(Transcript.ToolOutput(id: "x", toolName: "readPage", segments: []))
        let transcript = [bare, output("readPage", "a"), output("readPage", "b")]
        #expect(ResearchHistoryCompactor.compact(transcript).compactMap(outputText).first == "")
    }
}
