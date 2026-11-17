//
//  RobotsTxt.swift
//  Triva
//
//  Lecture de `robots.txt` selon la RFC 9309 (https://www.rfc-editor.org/rfc/rfc9309).
//  Logique pure : aucune entrée-sortie, entièrement testable.
//

import Foundation

/// Règles `robots.txt` qui s'appliquent à Triva pour UN site.
///
/// Règles de la RFC 9309 appliquées ici :
/// - un groupe qui nomme « Triva » (insensible à la casse) l'emporte entièrement sur le groupe `*` ;
///   à défaut, c'est le groupe `*` ; les groupes du même agent sont fusionnés (§2.2.1) ;
/// - la règle la plus SPÉCIFIQUE gagne : le motif le plus long ; à longueur égale, `Allow` (§2.2.2) ;
/// - `*` (toute suite de caractères) et `$` (fin de l'adresse) sont les seuls jokers (§2.2.3) ;
/// - un `Disallow:` vide n'interdit rien ;
/// - au-delà de 500 Kio, le reste du fichier est ignoré (§2.5) : géré par l'appelant (lecture bornée).
nonisolated struct RobotsRules: Sendable, Equatable {
    struct Rule: Sendable, Equatable {
        let allows: Bool
        let pattern: String
    }

    /// Jeton de produit de Triva dans `User-agent:` (premier mot du User-Agent envoyé).
    static let productToken = "triva"

    let rules: [Rule]

    /// Tout est permis (`robots.txt` absent ou groupe sans règle).
    static let allowAll = RobotsRules(rules: [])
    /// Tout est interdit (`robots.txt` injoignable : prudence de la RFC 9309 §2.3.1.4).
    static let disallowAll = RobotsRules(rules: [Rule(allows: false, pattern: "/")])

    // MARK: - Lecture du fichier

    static func parse(_ text: String) -> RobotsRules {
        var specific: [Rule] = []
        var wildcard: [Rule] = []
        var hasSpecificGroup = false
        var hasWildcardGroup = false

        var currentAgents: [String] = []
        var lastLineWasAgent = false

        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "user-agent":
                if !lastLineWasAgent { currentAgents = [] }
                currentAgents.append(value.lowercased())
                lastLineWasAgent = true
                if value.lowercased() == productToken { hasSpecificGroup = true }
                if value == "*" { hasWildcardGroup = true }
            case "allow", "disallow":
                lastLineWasAgent = false
                guard !currentAgents.isEmpty else { continue }
                // `Disallow:` vide : n'interdit rien ; `Allow:` vide : sans effet.
                guard !value.isEmpty else { continue }
                let rule = Rule(allows: key == "allow", pattern: value)
                if currentAgents.contains(productToken) { specific.append(rule) }
                if currentAgents.contains("*") { wildcard.append(rule) }
            default:
                // `Sitemap:`, `Crawl-delay:` et inconnues : ignorées (§2.2.4) ; ne ferment pas le groupe.
                continue
            }
        }
        if hasSpecificGroup { return RobotsRules(rules: specific) }
        if hasWildcardGroup { return RobotsRules(rules: wildcard) }
        return .allowAll
    }

    // MARK: - Décision

    /// `pathAndQuery` : chemin encodé suivi de `?requête`, tel qu'envoyé au serveur (« / » si vide).
    func isAllowed(pathAndQuery: String) -> Bool {
        let path = Array((pathAndQuery.isEmpty ? "/" : pathAndQuery).utf8)
        var bestLength = -1
        var bestAllows = true
        for rule in rules {
            let pattern = Array(rule.pattern.utf8)
            guard Self.matches(pattern, path) else { continue }
            if pattern.count > bestLength || (pattern.count == bestLength && rule.allows) {
                bestLength = pattern.count
                bestAllows = rule.allows
            }
        }
        return bestAllows
    }

    func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        var target = components.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = components.percentEncodedQuery { target += "?" + query }
        return isAllowed(pathAndQuery: target)
    }

    // MARK: - Correspondance d'un motif (jokers `*` et `$`)

    static func matches(_ pattern: [UInt8], _ path: [UInt8]) -> Bool {
        var body = pattern
        var anchored = false
        if body.last == UInt8(ascii: "$") {
            anchored = true
            body.removeLast()
        }
        let parts = body.split(separator: UInt8(ascii: "*"), omittingEmptySubsequences: false).map(Array.init)
        guard let first = parts.first, path.starts(with: first) else { return false }
        var position = first.count
        guard parts.count > 1 else { return anchored ? position == path.count : true }

        let lastIndex = parts.count - 1
        for index in 1...lastIndex {
            let part = parts[index]
            if index == lastIndex, anchored {
                if part.isEmpty { return true }
                guard path.count - part.count >= position else { return false }
                return Array(path.suffix(part.count)) == part
            }
            if part.isEmpty { continue }
            guard let found = firstRange(of: part, in: path, from: position) else { return false }
            position = found + part.count
        }
        return true
    }

    private static func firstRange(of part: [UInt8], in path: [UInt8], from start: Int) -> Int? {
        guard part.count <= path.count - start else { return nil }
        var index = start
        while index <= path.count - part.count {
            if path[index] == part[0], path[index..<index + part.count].elementsEqual(part) { return index }
            index += 1
        }
        return nil
    }
}
