//
//  ResearchToolOutput.swift
//  Triva
//
//  Created by ben podrojsky on 20/11/2026.
//

import Foundation

/// Textes que les outils de l'enquêteur rendent AU MODÈLE (jamais affichés à l'utilisateur) et fonctions
/// pures qui les fabriquent (spec 2.4 §2.2). Courts par construction : le contexte de l'appareil est de
/// 4 à 8K tokens. Comptes en caractères (`Character`), points de suspension compris.
nonisolated enum ResearchToolOutput {
    /// Longueur maximale d'un titre dans la liste des résultats.
    static let maxTitleCharacters = 80
    /// Longueur maximale du passage rendu après une lecture.
    static let maxPassageCharacters = 300

    static let duplicateSearch = "Requête déjà faite : aucun résultat nouveau. Change les mots de la requête."
    static let emptyQuery = "Requête vide. Donne 3 à 12 mots."
    static let noResults = "Aucun résultat. Essaie d'autres mots."
    static let searchFailed = "La recherche a échoué. Essaie d'autres mots ou appelle finish."

    // MARK: - Recherche

    /// « [k] titre — domaine », une ligne par résultat (5 au plus : le registre n'en rend pas davantage).
    static func searchOutput(_ entries: [ResearchEntry]) -> String {
        guard !entries.isEmpty else { return noResults }
        return entries
            .map { "[\($0.number)] \(truncated($0.result.title, to: maxTitleCharacters)) — \(domain(of: $0.result.url))" }
            .joined(separator: "\n")
    }

    // MARK: - Lecture

    static func unknownNumber(_ number: Int) -> String {
        "Numéro \(number) inconnu : choisis un numéro de la liste des résultats."
    }

    static func alreadyRead(_ number: Int) -> String {
        "[\(number)] déjà lue."
    }

    /// Accusé de lecture : « [k] lue, N caractères. » puis le passage le plus proche de la question,
    /// ou « [k] refusée par le site. » / « [k] illisible. » quand la page n'a rien donné.
    static func readOutput(number: Int, page: ScrapedPage, query: String) -> String {
        if page.refusedBySite { return "[\(number)] refusée par le site." }
        guard page.succeeded, !page.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "[\(number)] illisible."
        }
        let passage = bestPassage(in: page.content, query: query)
        return "[\(number)] lue, \(page.content.count) caractères.\nPassage : \(passage)"
    }

    // MARK: - Passage

    /// Le passage de `text` le plus proche de `query` (300 caractères au plus) : la phrase qui reprend
    /// le plus de mots pleins de la question (même règle de correspondance que `LexicalRelevance`,
    /// donc mêmes mots vides, mêmes préfixes), complétée par les phrases suivantes tant que ça tient.
    /// Égalité : la première. Aucune phrase ne reprend de mot : le début du texte.
    static func bestPassage(in text: String, query: String) -> String {
        let sentences = sentences(of: text)
        guard !sentences.isEmpty else { return "" }
        let relevance = LexicalRelevance(query: query)
        var bestIndex = 0
        var bestScore = -1
        for (index, sentence) in sentences.enumerated() {
            let score = relevance.matchedTerms(in: probe(sentence)).count
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        var passage = sentences[bestIndex]
        guard passage.count <= maxPassageCharacters else { return truncated(passage, to: maxPassageCharacters) }
        for next in sentences[(bestIndex + 1)...] {
            let candidate = passage + " " + next
            guard candidate.count <= maxPassageCharacters else { break }
            passage = candidate
        }
        return passage
    }

    /// Phrases du texte, blancs normalisés : coupées après `.`, `!`, `?` suivis d'un blanc (ou de la fin),
    /// et à chaque saut de ligne. « 3.5 » ne se coupe pas ; « M. Dupont » si (approximation assumée).
    static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isNewline {
                result.append(current)
                current = ""
                continue
            }
            current.append(character)
            guard ".!?".contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if next == nil || next?.isWhitespace == true {
                result.append(current)
                current = ""
            }
        }
        result.append(current)
        return result
            .map { collapsed($0) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Texte

    /// `text` aux blancs normalisés, coupé à `limit` caractères au plus (« … » compris).
    static func truncated(_ text: String, to limit: Int) -> String {
        let clean = collapsed(text)
        guard limit > 0 else { return "" }
        guard clean.count > limit else { return clean }
        guard limit > 1 else { return "…" }
        return String(clean.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Hôte lisible de l'URL (sans `www.`), « source » si l'URL n'en a pas.
    static func domain(of url: String) -> String {
        SourceRanker.normalizedHost(of: url) ?? "source"
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Résultat factice qui ne porte que la phrase, pour réutiliser `LexicalRelevance.matchedTerms`
    /// (une seule règle de correspondance dans tout le projet).
    private static func probe(_ sentence: String) -> SearXNGSearchResult {
        SearXNGSearchResult(
            title: sentence, url: "", content: nil, imgSrc: nil,
            thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
    }
}
