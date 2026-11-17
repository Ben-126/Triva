//
//  AnswerShareText.swift
//  Triva
//
//  Texte d'une réponse quand elle quitte l'app (Copier, Partager). Mission C5 (audit légal,
//  constat 10 : marquage « généré par IA », règlement (UE) 2024/1689 art. 50(2)).
//  Tout passe par `AIGeneratedMarking.marked(_:)` : aucun chemin ne contourne le marquage.
//

import Foundation

nonisolated enum AnswerShareText {
    /// Texte à copier ou partager : TL;DR puis corps (le raisonnement n'en fait jamais partie), les
    /// sources web numérotées comme les renvois `[n]` du texte, puis la mention « générée par IA ».
    /// `nil` quand la réponse n'a pas de texte (rien à copier).
    static func text(tldr: String?, body: String, sources: [SearXNGSearchResult]) -> String? {
        var parts: [String] = []
        if let tldr = tldr?.trimmingCharacters(in: .whitespacesAndNewlines), !tldr.isEmpty { parts.append(tldr) }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty { parts.append(trimmedBody) }
        guard !parts.isEmpty else { return nil }
        let lines = sourceLines(sources)
        if !lines.isEmpty { parts.append(lines.joined(separator: "\n")) }
        return AIGeneratedMarking.marked(parts.joined(separator: "\n\n"))
    }

    /// « [2] Titre — https://… » ; les fichiers joints n'ont pas d'adresse à donner.
    private static func sourceLines(_ sources: [SearXNGSearchResult]) -> [String] {
        sources.enumerated().compactMap { offset, source in
            guard !SourcesListPresentation.isAttachment(source) else { return nil }
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "[\(offset + 1)] \(source.url)" : "[\(offset + 1)] \(title) — \(source.url)"
        }
    }

    /// Les boutons n'apparaissent que sous une réponse terminée qui a du texte.
    static func isOffered(state: MessageBubblePresentation.AnswerState, hasText: Bool) -> Bool {
        hasText && state == .completed
    }

    // À VALIDER (texte légal) : libellés VoiceOver et infobulles.
    static let copyTitle = "Copier la réponse"
    static let copiedTitle = "Réponse copiée"
    static let shareTitle = "Partager la réponse"
}
