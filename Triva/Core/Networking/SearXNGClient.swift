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

        return components.url
    }
}
