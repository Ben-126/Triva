//
//  ResearchHistoryCompactor.swift
//  Triva
//
//  Created by ben podrojsky on 20/11/2026.
//

import Foundation
import FoundationModels

/// Réduit l'historique envoyé au modèle entre deux appels d'outil (`.historyTransform`, spec 2.4 §2.3) :
/// chaque sortie d'outil, SAUF les deux dernières, devient une seule ligne. Fonction pure ; le transcript
/// de la session n'est pas modifié (prototype M1 : seule la version transformée est vue par le modèle).
///
/// Mesuré par le prototype (W3-A1) : l'Approfondie complète tient en ~1 600 tokens sans compaction, donc
/// la compaction n'est pas indispensable ; elle est gardée comme marge sur les petites fenêtres.
nonisolated enum ResearchHistoryCompactor {
    /// Sorties d'outil gardées en entier (les plus récentes).
    static let keptOutputs = 2
    /// Longueur maximale d'une ligne compactée.
    static let maxLineCharacters = 200

    /// `entries` sans changement, sauf les `toolOutput` anciens. `Transcript.Entry` n'est PAS exhaustif
    /// (cas ajoutés avec les versions d'OS : `.data` en 27.2) : aucun `switch` complet, tout le reste passe tel quel.
    static func compact(_ entries: [Transcript.Entry]) -> [Transcript.Entry] {
        let outputIndices = entries.indices.filter { index in
            if case .toolOutput = entries[index] { return true }
            return false
        }
        let toCompact = Set(outputIndices.dropLast(keptOutputs))
        return entries.enumerated().map { index, entry in
            guard toCompact.contains(index), case .toolOutput(let output) = entry else { return entry }
            return .toolOutput(Transcript.ToolOutput(
                id: output.id,
                toolName: output.toolName,
                segments: [.text(Transcript.TextSegment(content: oneLine(output)))]
            ))
        }
    }

    /// Une recherche garde les NUMÉROS et les domaines (« Résultats : [6] a.fr ; [7] b.org ») : `readPage`
    /// ne prend que des numéros, les perdre rendrait ces résultats inaccessibles. Toute autre sortie
    /// garde sa première ligne (« [3] lue, 4210 caractères. »).
    static func oneLine(_ output: Transcript.ToolOutput) -> String {
        let lines = text(of: output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        if output.toolName == ResearchToolKind.search.rawValue, let listing = searchListing(lines) {
            return ResearchToolOutput.truncated(listing, to: maxLineCharacters)
        }
        return ResearchToolOutput.truncated(first, to: maxLineCharacters)
    }

    private static func text(of output: Transcript.ToolOutput) -> String {
        output.segments.compactMap { segment in
            if case .text(let text) = segment { return text.content }
            return nil
        }.joined(separator: "\n")
    }

    /// « Résultats : [6] a.fr ; [7] b.org » à partir des lignes « [k] titre — domaine ». `nil` si aucune ligne n'a ce format.
    private static func searchListing(_ lines: [String]) -> String? {
        let items: [String] = lines.compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let separator = line.range(of: " — ", options: .backwards) else { return nil }
            let number = line[line.startIndex...close]
            let domain = line[separator.upperBound...]
            return domain.isEmpty ? nil : "\(number) \(domain)"
        }
        return items.isEmpty ? nil : "Résultats : " + items.joined(separator: " ; ")
    }
}
