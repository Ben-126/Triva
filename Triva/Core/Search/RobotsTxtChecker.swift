//
//  RobotsTxtChecker.swift
//  Triva
//
//  Consultation de `robots.txt` (RFC 9309) et des signaux d'opposition lisibles par machine
//  avant la lecture AUTOMATIQUE d'une page (CPI L122-5-3 III : l'opposition doit être exprimée
//  « par un procédé lisible par machine » — qualification À FAIRE VALIDER PAR UN JURISTE).
//

import Foundation

/// Cache des règles par origine (schéma + hôte + port), en mémoire seulement.
/// Durée : 24 h au plus (RFC 9309 §2.4), 5 min seulement quand le fichier était injoignable,
/// pour qu'une panne passagère ne ferme pas un site pour la journée.
actor RobotsRulesCache {
    static let shared = RobotsRulesCache()

    static let rulesLifetime: TimeInterval = 24 * 3600
    static let unavailableLifetime: TimeInterval = 5 * 60

    private struct Entry {
        let rules: RobotsRules
        let expiry: Date
    }

    private var entries: [String: Entry] = [:]

    func rules(forOrigin origin: String, now: Date) -> RobotsRules? {
        guard let entry = entries[origin] else { return nil }
        guard entry.expiry > now else {
            entries[origin] = nil
            return nil
        }
        return entry.rules
    }

    func store(_ rules: RobotsRules, forOrigin origin: String, lifetime: TimeInterval, now: Date) {
        entries[origin] = Entry(rules: rules, expiry: now.addingTimeInterval(lifetime))
    }

    func removeAll() { entries.removeAll() }
}

/// Décide si Triva peut lire une page AUTOMATIQUEMENT. Jamais appelé pour une lecture demandée
/// par l'utilisateur (bouton « Lire cette page »).
nonisolated struct RobotsTxtChecker: Sendable {
    /// Plafond de lecture du fichier (RFC 9309 §2.5 : au moins 500 Kio analysés).
    static let maxFileBytes = 512 * 1024
    static let fetchTimeout: TimeInterval = 5

    private let fetcher: any URLFetching
    private let cache: RobotsRulesCache
    private let now: @Sendable () -> Date

    init(
        fetcher: any URLFetching,
        cache: RobotsRulesCache = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.cache = cache
        self.now = now
    }

    /// `true` si `robots.txt` du site autorise Triva à lire cette page.
    /// - 2xx : fichier lu et appliqué ; 4xx : « pas de fichier », tout est permis (RFC §2.3.1.3) ;
    /// - 5xx, réseau, délai : prudence, la page n'est PAS lue (RFC §2.3.1.4).
    func isAllowed(_ url: URL) async -> Bool {
        guard let origin = Self.origin(of: url) else { return false }
        if let cached = await cache.rules(forOrigin: origin, now: now()) {
            return cached.isAllowed(url)
        }
        let (rules, lifetime) = await fetchRules(origin: origin)
        if let lifetime {
            await cache.store(rules, forOrigin: origin, lifetime: lifetime, now: now())
        }
        return rules.isAllowed(url)
    }

    /// `lifetime == nil` : ne pas mettre en cache (tâche annulée, ce n'est pas une réponse du site).
    private func fetchRules(origin: String) async -> (RobotsRules, TimeInterval?) {
        guard let robotsURL = URL(string: origin + "/robots.txt") else { return (.disallowAll, nil) }
        do {
            let stream = try await fetcher.streamBytes(url: robotsURL, timeout: Self.fetchTimeout)
            defer { stream.cancel() }
            guard let http = stream.response as? HTTPURLResponse else {
                return (.disallowAll, RobotsRulesCache.unavailableLifetime)
            }
            switch http.statusCode {
            case 200..<300:
                let body = await ScrapeService.readBoundedBody(
                    stream.bytes, maxBytes: Self.maxFileBytes, expectedLength: http.expectedContentLength
                )
                if Task.isCancelled { return (.disallowAll, nil) }
                let text = String(decoding: body.bytes, as: UTF8.self)
                return (RobotsRules.parse(text), RobotsRulesCache.rulesLifetime)
            case 400..<500:
                return (.allowAll, RobotsRulesCache.rulesLifetime)
            default:
                return (.disallowAll, RobotsRulesCache.unavailableLifetime)
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return (.disallowAll, nil) }
            return (.disallowAll, RobotsRulesCache.unavailableLifetime)
        }
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }
}

/// Signaux d'opposition portés par la RÉPONSE de la page elle-même (aucune requête de plus).
///
/// Retenus :
/// - `tdm-reservation: 1` (TDM Reservation Protocol, W3C Community Group, https://www.w3.org/community/reports/tdmrep/CG-FINAL-tdmrep-20240510/) :
///   conçu pour exprimer la réserve de droits du droit européen de la fouille de textes ;
/// - `X-Robots-Tag: noai` (adressé à tous ou à `triva`) : refus explicite d'un usage par IA.
/// Ignorés volontairement : `noindex`, `nofollow`, `noarchive`… ; ils concernent l'indexation par
/// un moteur de recherche, pas la lecture d'une page à la demande d'un utilisateur.
nonisolated enum SiteReadSignals {
    static func optsOutOfAI(_ response: HTTPURLResponse) -> Bool {
        if let tdm = response.value(forHTTPHeaderField: "tdm-reservation"),
           tdm.trimmingCharacters(in: .whitespaces) == "1" { return true }
        if let robotsTag = response.value(forHTTPHeaderField: "X-Robots-Tag") {
            return xRobotsTagForbidsAI(robotsTag)
        }
        return false
    }

    /// Valeur d'en-tête : « noai », « triva: noai, noindex », « googlebot: noindex, noai ».
    /// Une directive précédée d'un autre agent ne nous concerne pas.
    static func xRobotsTagForbidsAI(_ value: String) -> Bool {
        let dateDirectives: Set<String> = ["unavailable_after", "max-snippet", "max-image-preview", "max-video-preview"]
        var applies = true
        for rawPart in value.lowercased().split(separator: ",") {
            var part = rawPart.trimmingCharacters(in: .whitespaces)
            if let colon = part.firstIndex(of: ":") {
                let head = String(part[..<colon]).trimmingCharacters(in: .whitespaces)
                if !dateDirectives.contains(head) {
                    applies = head == RobotsRules.productToken
                    part = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if applies, part == "noai" { return true }
        }
        return false
    }
}
