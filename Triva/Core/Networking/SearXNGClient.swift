//
//  SearXNGClient.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

/// Erreurs pouvant survenir lors d'une requête vers une instance SearXNG.
enum SearXNGClientError: Error, Sendable, Equatable {
    case invalidURL
    case requestFailed(statusCode: Int)
    case timeout
    case decodingFailed
    case transportError
}

/// Abstraction du client SearXNG, pour permettre le mock dans les tests
/// de `FailoverManager` sans appel réseau réel.
nonisolated protocol SearXNGSearching: Sendable {
    func search(
        query: String,
        options: SearXNGSearchOptions,
        instance: URL
    ) async throws -> SearXNGSearchResponse
}

/// Client HTTP réel vers une instance SearXNG publique.
/// Port direct de `searchSearxng` (src/lib/searxng.ts) : `GET {instance}/search?format=json`,
/// timeout de 10s, mêmes paramètres de requête.
struct SearXNGClient: SearXNGSearching {
    private let urlSession: URLSession
    private let timeoutInterval: TimeInterval

    init(urlSession: URLSession = .shared, timeoutInterval: TimeInterval = 10) {
        self.urlSession = urlSession
        self.timeoutInterval = timeoutInterval
    }

    func search(
        query: String,
        options: SearXNGSearchOptions,
        instance: URL
    ) async throws -> SearXNGSearchResponse {
        guard let url = Self.buildURL(instance: instance, query: query, options: options) else {
            throw SearXNGClientError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw SearXNGClientError.timeout
        } catch let error as URLError where error.indicatesNoConnection {
            // Appareil hors ligne : le code passe tel quel, pour que `FailoverManager` le dise à
            // la chaîne de repli. `URLError` neuve : l'originale porte l'URL, donc la question.
            // Côté fiabilité, `InstanceFailureReason.classify` la range en `.network`, comme avant.
            throw URLError(error.code)
        } catch {
            throw SearXNGClientError.transportError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearXNGClientError.transportError
        }
        guard httpResponse.statusCode == 200 else {
            throw SearXNGClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(SearXNGSearchResponse.self, from: data)
        } catch {
            // Certaines instances renvoient une page HTML (challenge anti-bot,
            // rate-limit) avec un statut 200 : on traite ça comme un échec
            // de l'instance plutôt qu'un crash, pour laisser FailoverManager basculer.
            throw SearXNGClientError.decodingFailed
        }
    }

    /// Construit `GET {instance}/search?format=json&q=…`, plus les options renseignées.
    ///
    /// **Le « + » doit partir en `%2B` (bug 12 de la revue V1).** `URLComponents`
    /// suit la RFC 3986, pour laquelle `+` est un caractère légal dans une query :
    /// son setter `queryItems` le laisse donc tel quel (vérifié sur macOS 27 le
    /// 2026-09-30 : « tutoriel C++ » donnait `q=tutoriel%20C++`). Or SearXNG
    /// (Flask/werkzeug) décode la query string au format
    /// `application/x-www-form-urlencoded`, où `+` vaut une espace : « tutoriel
    /// C++ » était cherché comme « tutoriel C » suivi de deux espaces, « 2+2 »
    /// comme « 2 2 », et « Canal+ » ou « Disney+ » perdaient leur « + ». Apple
    /// décrit ce conflit dans la documentation de `URLComponents.queryItems` et
    /// conseille d'encoder soi-même le `+` quand le serveur suit la convention
    /// des formulaires. On le fait APRÈS le setter, sur `percentEncodedQuery` :
    /// encoder la valeur avant de la confier à `queryItems` donnerait `%252B`,
    /// puisque le setter réencode le `%`.
    ///
    /// Ce n'est PAS un écart assumé avec le web : `searxng.ts` passe par
    /// `URLSearchParams.append`, qui sérialise déjà `+` en `%2B`. Le web n'a
    /// jamais eu ce bug, et ce correctif rétablit la parité.
    ///
    /// Pourquoi le remplacement sur toute la query est sûr : après le setter
    /// `queryItems`, un `+` restant ne peut être qu'un `+` littéral venu d'une
    /// valeur (Foundation encode l'espace en `%20`, jamais en `+`, et les noms de
    /// paramètres sont fixes). Un `%` tapé par l'utilisateur est déjà devenu
    /// `%25`, donc un « %2B » saisi tel quel part en `%252B` et n'est pas touché.
    /// Le résultat reste un encodage valide : le setter `percentEncodedQuery`,
    /// qui déclenche un `fatalError` sur un encodage invalide, ne peut pas planter
    /// ici. Les espaces restent en `%20`, que le serveur décode correctement :
    /// inutile de les convertir en `+`.
    private static func buildURL(instance: URL, query: String, options: SearXNGSearchOptions) -> URL? {
        guard var components = URLComponents(
            url: instance.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "q", value: query),
        ]
        if !options.categories.isEmpty {
            queryItems.append(URLQueryItem(name: "categories", value: options.categories.joined(separator: ",")))
        }
        if !options.engines.isEmpty {
            queryItems.append(URLQueryItem(name: "engines", value: options.engines.joined(separator: ",")))
        }
        if let language = options.language {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        if let pageNumber = options.pageNumber {
            queryItems.append(URLQueryItem(name: "pageno", value: String(pageNumber)))
        }
        if let timeRange = options.timeRange {
            queryItems.append(URLQueryItem(name: "time_range", value: timeRange))
        }
        components.queryItems = queryItems
        // `+` littéral -> `%2B`, sinon SearXNG le lit comme une espace (voir la doc ci-dessus).
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        return components.url
    }
}
