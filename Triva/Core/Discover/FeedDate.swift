//
//  FeedDate.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Lit les deux formats de date des flux : RFC 822 (`pubDate` du RSS) et ISO 8601
/// (`published`/`updated` d'Atom, `dc:date`).
///
/// ## Pourquoi pas un `DateFormatter`
/// Un `DateFormatter` partagé en `static let` n'est pas `Sendable` : erreur de compilation
/// en Swift 6 dans un type `nonisolated`. Et ESPN écrit ses dates avec un fuseau nommé
/// (`Wed, 11 Nov 2026 00:45:22 EST`) que les formateurs lisent différemment selon la
/// locale de l'appareil. La lecture à la main ci-dessous est la même partout, ne crée
/// aucun objet partagé, et tourne sans le main actor.
nonisolated enum FeedDate {
    /// Date lue, ou `nil` si le texte ne ressemble à aucun des deux formats. Une date
    /// illisible vaut « pas de date » : `DiscoverService` écarte alors l'article, plutôt que
    /// d'inventer une fraîcheur qu'on ne connaît pas.
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return parseISO8601(text) ?? parseRFC822(text)
    }

    // MARK: ISO 8601

    private static func parseISO8601(_ text: String) -> Date? {
        guard text.first?.isNumber == true, text.contains("-") else { return nil }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? Date(text, strategy: withFraction) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    // MARK: RFC 822

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// Fuseaux nommés admis par la RFC 822, en secondes depuis UTC.
    private static let namedZones: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0,
        "EST": -5 * 3600, "EDT": -4 * 3600, "CST": -6 * 3600, "CDT": -5 * 3600,
        "MST": -7 * 3600, "MDT": -6 * 3600, "PST": -8 * 3600, "PDT": -7 * 3600,
    ]

    /// `[Mer,] 11 Nov 2026 00:45[:22] EST` ou `+0100`. Le jour de la semaine est ignoré :
    /// il ne sert qu'à la lecture humaine, et une erreur de l'éditeur dessus ne doit pas
    /// faire perdre la date.
    private static func parseRFC822(_ text: String) -> Date? {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = tokens.first, first.hasSuffix(",") { tokens.removeFirst() }
        guard tokens.count >= 4,
              let day = Int(tokens[0]),
              let month = months[String(tokens[1].prefix(3)).lowercased()],
              let year = Int(tokens[2])
        else { return nil }
        let clock = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard clock.count >= 2 else { return nil }
        let zone = tokens.count > 4 ? zoneOffset(tokens[4]) : 0
        guard let zone else { return nil }

        var components = DateComponents()
        components.year = year < 100 ? 2000 + year : year
        components.month = month
        components.day = day
        components.hour = clock[0]
        components.minute = clock[1]
        components.second = clock.count > 2 ? clock[2] : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let utc = calendar.date(from: components) else { return nil }
        return utc.addingTimeInterval(-TimeInterval(zone))
    }

    /// `+0100`, `-0500` ou un nom de fuseau ; `nil` pour un fuseau inconnu.
    private static func zoneOffset(_ token: String) -> Int? {
        if let named = namedZones[token.uppercased()] { return named }
        guard token.count == 5, let sign = token.first, sign == "+" || sign == "-",
              let hours = Int(token.dropFirst().prefix(2)),
              let minutes = Int(token.suffix(2))
        else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }
}
