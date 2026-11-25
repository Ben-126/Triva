//
//  AnswerPlainText.swift
//  Triva
//
//  Chantier 2.1 (mission B) : le texte d'une réponse tel que Siri ou Raccourcis le lit. Marques [n] retirées,
//  mise en forme retirée, 400 caractères au plus coupés à une fin de phrase, puis une phrase fixe SEULEMENT si l'extrait est coupé.
//  Logique pure.
//

import Foundation

nonisolated enum AnswerPlainText {
    /// Longueur maximale de l'extrait lu à voix haute.
    static let maxSpokenLength = 400
    static let completionSuffix = "La réponse complète est dans Triva."

    /// Plus grand numéro de source reconnu comme marque (`CitationParser` en accepte 4 chiffres).
    private static let largestSourceNumber = 9_999
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    /// Une ligne qui finit ainsi n'a pas besoin d'un point avant la suivante.
    private static let lineEnds: Set<Character> = [".", "!", "?", "…", ":", ";"]
    private static let bulletPrefixes = ["- ", "* ", "+ ", "• "]

    // MARK: - Texte brut

    /// Le texte sans marques de source ni mise en forme, sur une seule ligne.
    static func plain(from text: String) -> String {
        let withoutMarks = removingCitationMarks(from: text)
        var sentences: [String] = []
        for rawLine in withoutMarks.split(whereSeparator: \.isNewline) {
            guard let line = cleanedLine(String(rawLine)) else { continue }
            sentences.append(line)
        }
        var joined = ""
        for line in sentences {
            if let last = joined.last, !lineEnds.contains(last) { joined += "." }
            if !joined.isEmpty { joined += " " }
            joined += line
        }
        return tidied(joined)
    }

    private static func removingCitationMarks(from text: String) -> String {
        let parsed = CitationParser.parse(text, sourceCount: largestSourceNumber)
        return parsed.segments.filter { $0.citationIndex == nil }.map(\.text).joined() + parsed.pendingSuffix
    }

    /// Une ligne sans titre, citation, puce ni gras ; `nil` si rien ne reste (ligne vide ou simple filet).
    private static func cleanedLine(_ raw: String) -> String? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard !isRule(line) else { return nil }
        line = strippingLinePrefix(line)
        line = replacingLinks(in: line)
        for marker in ["**", "__", "`"] {
            line = line.replacingOccurrences(of: marker, with: "")
        }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    /// `---`, `***`, `___`, `===` : un filet, rien à lire.
    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_=".contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static func strippingLinePrefix(_ line: String) -> String {
        var result = Substring(line)
        while result.first == "#" { result = result.dropFirst() }
        if result.count < line.count {
            return String(result).trimmingCharacters(in: .whitespaces)
        }
        if result.hasPrefix("> ") { return String(result.dropFirst(2)) }
        for prefix in bulletPrefixes where result.hasPrefix(prefix) {
            return String(result.dropFirst(prefix.count))
        }
        return line
    }

    /// `[texte](adresse)` devient `texte` ; un crochet seul reste.
    private static func replacingLinks(in line: String) -> String {
        var result = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "[") {
            result += rest[..<open]
            let afterOpen = rest[rest.index(after: open)...]
            if let middle = afterOpen.range(of: "]("),
               !afterOpen[..<middle.lowerBound].contains(where: { $0 == "[" || $0 == "]" }),
               let close = afterOpen[middle.upperBound...].firstIndex(of: ")") {
                result += afterOpen[..<middle.lowerBound]
                rest = afterOpen[afterOpen.index(after: close)...]
            } else {
                result += "["
                rest = afterOpen
            }
        }
        return result + rest
    }

    /// Espaces multiples, espace avant un point ou une virgule (reste d'une marque retirée).
    private static func tidied(_ text: String) -> String {
        var result = text
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        for mark in [".", ","] {
            result = result.replacingOccurrences(of: " " + mark, with: mark)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Extrait

    /// `plain` en `limit` caractères au plus : coupé à la dernière fin de phrase qui tient ; sinon entre deux
    /// mots, avec des points de suspension. Un point suivi d'un chiffre (3.5) n'est pas une fin de phrase.
    static func excerpt(of plain: String, limit: Int = AnswerPlainText.maxSpokenLength) -> String {
        let characters = Array(plain)
        guard characters.count > limit, limit > 1 else { return plain }
        if let end = lastSentenceEnd(in: characters, limit: limit) {
            return String(characters[..<end]).trimmingCharacters(in: .whitespaces)
        }
        let head = characters[..<(limit - 1)]
        let cut = head.lastIndex(where: \.isWhitespace) ?? head.endIndex
        let text = String(characters[..<cut]).trimmingCharacters(in: .whitespaces)
        return text + "…"
    }

    /// Position juste après la dernière fin de phrase des `limit` premiers caractères.
    private static func lastSentenceEnd(in characters: [Character], limit: Int) -> Int? {
        for index in stride(from: limit - 1, through: 0, by: -1) where sentenceEnds.contains(characters[index]) {
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if next.isWhitespace { return index + 1 }
        }
        return nil
    }

    // MARK: - Lecture

    /// Ce que Siri lit : l'extrait ; la phrase fixe s'y ajoute SEULEMENT quand l'extrait est coupé (une réponse qui
    /// tient en entier n'a pas de « suite » dans Triva). Texte vide (ne devrait pas arriver) : la phrase fixe seule.
    static func spoken(from text: String) -> String {
        let plainText = plain(from: text)
        let excerpt = excerpt(of: plainText)
        guard !excerpt.isEmpty else { return completionSuffix }
        let wasCut = plainText.count > maxSpokenLength
        return wasCut ? excerpt + " " + completionSuffix : excerpt
    }
}
