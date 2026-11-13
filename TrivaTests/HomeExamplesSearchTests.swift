//
//  HomeExamplesSearchTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 13/11/2026.
//

import Foundation
import Synchronization
import Testing
@testable import Triva

/// Faux Wikipédia (et Marginalia en panne) : une page par sujet, dans le format réel de l'API
/// MediaWiki (`formatversion=2`), et un journal des requêtes. Aucun réseau.
nonisolated final class HomeExampleRequester: HTTPDataRequesting, Sendable {
    private let requests = Mutex<[URL]>([])

    var hosts: [String] { requests.withLock { $0.compactMap { $0.host() } } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        requests.withLock { $0.append(url) }
        guard url.host() == "fr.wikipedia.org" else { throw URLError(.cannotConnectToHost) }
        let terms = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "gsrsearch" }?.value?.lowercased() ?? ""
        let page = terms.contains("eiffel")
            ? ("Tour Eiffel", "La tour Eiffel a été construite pour l'Exposition universelle de 1889.")
            : ("Trou noir", "Un trou noir se forme à la fin de la vie d'une étoile massive.")
        let body = #"{"query":{"pages":[{"title":"\#(page.0)","index":1,"extract":"\#(page.1)","fullurl":"https://fr.wikipedia.org/wiki/\#(page.0.replacingOccurrences(of: " ", with: "_"))"}]}}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// Les deux exemples d'accueil SANS clé de recherche (`ChatEmptyStateView.examplesWithoutSearchKey`) doivent
/// mener à une recherche avec sources, jamais à une réponse de mémoire (mission E2d, item 5).
@MainActor
@Suite("Exemples d'accueil sans clé — recherche et sources")
struct HomeExamplesSearchTests {
    private static let classificationFormat = #"{"classification":{"skipSearch":%@,"personalSearch":false,"academicSearch":false,"discussionSearch":false,"showWeatherWidget":false,"showStockWidget":false,"showCalculationWidget":false},"standaloneFollowUp":"%@"}"#

    private static func classification(skipSearch: Bool, followUp: String) -> String {
        String(format: classificationFormat, skipSearch ? "true" : "false", followUp)
    }

    private func makeViewModel(requester: HomeExampleRequester, aiProvider: ChainAIProvider, mode: ResponseMode) -> ChatViewModel {
        let manager = FailoverManager(client: ChainSearXNGClient(shouldFail: true), instances: [ChainFixtures.instance])
        // La chaîne d'un utilisateur sans clé : SearXNG (ici en panne), puis les sources ouvertes.
        let chain = WebSearchChain(
            searxng: SearXNGWebSearchProvider(failover: manager),
            openSources: OpenSourceSearchChain(requester: requester, arXivSpacer: ArXivRequestSpacer(interval: .zero)),
            fallbackLanguage: "fr"
        )
        return ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { manager },
            resolveWebSearchChain: { _ in chain },
            readResponseMode: { mode },
            generateSuggestions: { _, _ in [] }
        )
    }

    @Test("Chaque exemple d'accueil mène à Wikipédia : réponse avec sources, texte de la page dans le prompt de rédaction")
    func everyExampleLeadsToASourcedSearch() async throws {
        #expect(ChatEmptyStateView.examplesWithoutSearchKey.count == 2)
        for example in ChatEmptyStateView.examplesWithoutSearchKey {
            try await verifySourcedSearch(for: example)
        }
    }

    private func verifySourcedSearch(for example: String) async throws {
        let requester = HomeExampleRequester()
        let aiProvider = ChainAIProvider(classification: Self.classification(skipSearch: false, followUp: example))
        let viewModel = makeViewModel(requester: requester, aiProvider: aiProvider, mode: .quick)

        await viewModel.send(query: example)

        let answer = try #require(viewModel.messages.last)
        #expect(answer.status == .completed)
        #expect(viewModel.errorDescription == nil)
        #expect(answer.sources.map(\.url).allSatisfy { $0.hasPrefix("https://fr.wikipedia.org/wiki/") })
        #expect(!answer.sources.isEmpty)
        #expect(requester.hosts.first == "fr.wikipedia.org")
        let writerPrompt = try #require(aiProvider.receivedPrompts.last)
        #expect(writerPrompt.contains(answer.sources[0].title))
    }

    @Test("Les exemples ne sont ni des salutations ni des calculs : jamais exemptés de la recherche en mode Fiable")
    func examplesAreNeitherGreetingsNorCalculations() {
        for example in ChatEmptyStateView.examplesWithoutSearchKey {
            #expect(!SmallTalk.isGreeting(example), "\(example)")
            // Même si le classifieur se trompait (skipSearch vrai), le mode Fiable cherche quand même.
            let misclassified = QueryClassification(
                skipSearch: true, personalSearch: false, academicSearch: false, discussionSearch: false,
                showWeatherWidget: false, showStockWidget: false, showCalculationWidget: false,
                standaloneFollowUp: example
            )
            #expect(SearchRoute.resolve(for: misclassified, hasAttachments: false, mode: .reliable, query: example) == .web(.general))
        }
    }
}
