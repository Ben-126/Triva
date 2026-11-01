//
//  OpenSourceSearchArXivAndChainTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/10/2026.
//

import Testing
import Foundation
@testable import Triva

// Les outils (`OSSTestRequester`, `OSSFakeSleeper`…) sont dans OpenSourceSearchProvidersTests.swift.

// MARK: - Fixtures arXiv

/// Flux Atom calqué sur une réponse réelle (export.arxiv.org, 2026-10-27) : titre et id du flux,
/// `<id>` en http, titre sur plusieurs lignes, 4 auteurs, métadonnées arXiv à ignorer.
let ossArXivFixture = """
<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/" xmlns:arxiv="http://arxiv.org/schemas/atom" xmlns="http://www.w3.org/2005/Atom">
  <id>https://arxiv.org/api/JKVmL88lxJ3xzQ4EOGBGHS3/cCQ</id>
  <title>arXiv Query: search_query=all:transformer&amp;id_list=&amp;start=0&amp;max_results=2</title>
  <updated>2026-10-27T11:47:41Z</updated>
  <opensearch:totalResults>183298</opensearch:totalResults>
  <entry>
    <id>http://arxiv.org/abs/2201.00978v1</id>
    <title>PyramidTNT: Improved Transformer-in-Transformer
  Baselines with Pyramid Architecture</title>
    <updated>2022-01-04T04:56:57Z</updated>
    <link href="https://arxiv.org/abs/2201.00978v1" rel="alternate" type="text/html"/>
    <link href="https://arxiv.org/pdf/2201.00978v1" rel="related" type="application/pdf" title="pdf"/>
    <summary>Transformer networks have achieved great progress
  for computer vision tasks. Code will be available.</summary>
    <category term="cs.CV" scheme="http://arxiv.org/schemas/atom"/>
    <arxiv:comment>Tech Report.</arxiv:comment>
    <author><name>Kai Han</name></author>
    <author><name>Jianyuan Guo</name></author>
    <author><name>Yehui Tang</name></author>
    <author><name>Yunhe Wang</name></author>
  </entry>
  <entry>
    <id>http://arxiv.org/abs/2301.00001v2</id>
    <title>Un article sans lien alternate</title>
    <summary>Résumé.</summary>
    <author><name>Ada Lovelace</name></author>
  </entry>
</feed>
"""

/// Erreur de requête arXiv : un flux Atom valide (statut 200) avec une entrée « Error ».
let ossArXivErrorFixture = """
<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>https://arxiv.org/api/errors</id>
  <title>ArXiv Query: id_list=1234.12345</title>
  <entry>
    <id>http://arxiv.org/api/errors#incorrect_id_format_for_1234.12345</id>
    <title>Error</title>
    <summary>incorrect id format for 1234.12345</summary>
    <author><name>arXiv api core</name></author>
  </entry>
</feed>
"""

let ossArXivEmptyFeed = """
<?xml version='1.0' encoding='UTF-8'?>
<feed xmlns="http://www.w3.org/2005/Atom"><id>x</id><title>arXiv Query</title></feed>
"""

// MARK: - arXiv

@Suite("ArXivSearchProvider")
struct ArXivSearchProviderTests {
    private static let academic = WebSearchOptions(category: .academic, maxResults: 10)

    @Test("search_query : mots vides retirés, ponctuation de syntaxe arXiv supprimée",
          arguments: [
            ("What are the latest advances in transformers?", "all:advances all:transformers"),
            ("quelle est la complexité de l'algorithme de Dijkstra", "all:complexité all:algorithme all:Dijkstra"),
            ("ti:\"injection\" (AND) attaque+", "all:ti all:injection all:attaque"),
            ("what is the", "all:what all:is all:the"),
            ("quantum 2024", "all:quantum all:2024"),
          ])
    func buildsSearchQuery(input: String, expected: String) {
        #expect(ArXivSearchProvider.searchQuery(from: input) == expected)
    }

    @Test("search_query : 8 termes au plus, rien si aucun mot")
    func searchQueryLimits() {
        let long = (1...20).map { "terme\($0)" }.joined(separator: " ")
        #expect(ArXivSearchProvider.searchQuery(from: long)?.split(separator: " ").count == 8)
        #expect(ArXivSearchProvider.searchQuery(from: "?! :: ()") == nil)
        #expect(ArXivSearchProvider.searchQuery(from: "") == nil)
    }

    @Test("la requête cible export.arxiv.org en HTTPS, triée par pertinence, avec le User-Agent")
    func requestShape() async throws {
        let requester = OSSTestRequester(body: ossArXivFixture)
        let sleeper = OSSFakeSleeper()
        _ = try await ArXivSearchProvider(requester: requester, spacer: sleeper.makeSpacer())
            .search(query: "transformer attention", options: Self.academic)

        let request = try #require(requester.requests.first)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "export.arxiv.org")
        #expect(request.url?.path == "/api/query")
        #expect(ossQueryValue("search_query", in: request) == "all:transformer all:attention")
        #expect(ossQueryValue("max_results", in: request) == "10")
        #expect(ossQueryValue("sortBy", in: request) == "relevance")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == OpenSourceSearchHTTP.userAgent)
    }

    @Test("max_results est borné à 1...50")
    func clampsMaxResults() throws {
        let provider = ArXivSearchProvider(requester: OSSTestRequester(body: "x"))
        let high = try provider.buildRequest(query: "x1", options: WebSearchOptions(category: .academic, maxResults: 9999))
        let low = try provider.buildRequest(query: "x1", options: WebSearchOptions(category: .academic, maxResults: 0))
        #expect(ossQueryValue("max_results", in: high) == "50")
        #expect(ossQueryValue("max_results", in: low) == "1")
    }

    @Test("le flux Atom est décodé : entrées seulement, HTTPS, lignes fusionnées, auteurs")
    func parsesAtomFeed() throws {
        let response = try ArXivSearchProvider.parse(Data(ossArXivFixture.utf8), maxResults: 10)
        #expect(response.results.count == 2)

        let first = response.results[0]
        // Ni le titre ni l'id du FLUX ne doivent apparaître comme résultat.
        #expect(first.title == "PyramidTNT: Improved Transformer-in-Transformer Baselines with Pyramid Architecture")
        #expect(first.url == "https://arxiv.org/abs/2201.00978v1")
        #expect(first.content == "Transformer networks have achieved great progress for computer vision tasks. Code will be available.")
        #expect(first.author == "Kai Han, Jianyuan Guo, Yehui Tang et al.")

        // Sans lien `alternate` : repli sur l'<id>, passé de http à https.
        #expect(response.results[1].url == "https://arxiv.org/abs/2301.00001v2")
        #expect(response.results[1].author == "Ada Lovelace")
    }

    @Test("flux vide : réponse vide valide")
    func emptyFeed() throws {
        let response = try ArXivSearchProvider.parse(Data(ossArXivEmptyFeed.utf8), maxResults: 10)
        #expect(response.results.isEmpty)
    }

    @Test("l'entrée « Error » d'arXiv n'est jamais renvoyée comme résultat")
    func errorEntryIsNotAResult() {
        #expect(throws: WebSearchError.invalidResponse) {
            try ArXivSearchProvider.parse(Data(ossArXivErrorFixture.utf8), maxResults: 10)
        }
    }

    @Test("XML illisible : réponse invalide")
    func malformedXML() {
        #expect(throws: WebSearchError.invalidResponse) {
            try ArXivSearchProvider.parse(Data("<feed><entry>".utf8), maxResults: 10)
        }
        #expect(throws: WebSearchError.invalidResponse) {
            try ArXivSearchProvider.parse(Data("pas du xml".utf8), maxResults: 10)
        }
    }

    @Test("les catégories general et discussion ne sont pas prises en charge",
          arguments: [WebSearchCategory.general, .discussion])
    func unsupportedCategories(category: WebSearchCategory) async {
        let requester = OSSTestRequester(body: ossArXivFixture)
        let error = await ossThrownError {
            _ = try await ArXivSearchProvider(requester: requester, spacer: OSSFakeSleeper().makeSpacer())
                .search(query: "x1", options: WebSearchOptions(category: category))
        }
        #expect(error as? WebSearchError == .unsupportedCategory)
        #expect(requester.requests.isEmpty)
    }

    @Test("requête sans mot : aucune requête réseau, aucune attente")
    func emptyQueryMakesNoRequest() async throws {
        let requester = OSSTestRequester(body: ossArXivFixture)
        let sleeper = OSSFakeSleeper()
        let response = try await ArXivSearchProvider(requester: requester, spacer: sleeper.makeSpacer())
            .search(query: " ?! ", options: Self.academic)
        #expect(response.results.isEmpty)
        #expect(requester.requests.isEmpty)
        #expect(sleeper.delays.isEmpty)
    }

    @Test("trois recherches de suite sont espacées de 3 s chacune (sommeil simulé)")
    func throttlesConsecutiveRequests() async throws {
        let requester = OSSTestRequester(body: ossArXivFixture)
        let sleeper = OSSFakeSleeper()
        let provider = ArXivSearchProvider(requester: requester, spacer: sleeper.makeSpacer())
        for _ in 0..<3 {
            _ = try await provider.search(query: "transformer", options: Self.academic)
        }
        #expect(requester.requests.count == 3)
        // 1re : aucune attente. 2e et 3e : l'horloge simulée n'avance que par les sommeils, donc
        // chacune attend l'intervalle complet.
        #expect(sleeper.delays == [.seconds(3), .seconds(3)])
    }

    @Test("statuts HTTP : jamais de clé accusée")
    func statusMapping() async {
        for (status, expected) in [(429, WebSearchError.rateLimited), (403, .unavailable), (500, .unavailable), (400, .invalidResponse)] {
            let requester = OSSTestRequester(status: status, body: "")
            let error = await ossThrownError {
                _ = try await ArXivSearchProvider(requester: requester, spacer: OSSFakeSleeper().makeSpacer())
                    .search(query: "transformer", options: Self.academic)
            }
            #expect(error as? WebSearchError == expected)
        }
    }
}

// MARK: - Espaceur arXiv

/// Hors `@MainActor` et sans mesure de temps réel : l'horloge est simulée.
@Suite("ArXivRequestSpacer")
struct ArXivRequestSpacerTests {
    @Test("le premier appel ne dort pas, les suivants attendent l'intervalle restant")
    func firstCallIsImmediate() async throws {
        let sleeper = OSSFakeSleeper()
        let spacer = sleeper.makeSpacer(interval: .seconds(3))
        try await spacer.waitForTurn()
        #expect(sleeper.delays.isEmpty)
        try await spacer.waitForTurn()
        #expect(sleeper.delays == [.seconds(3)])
    }

    @Test("si l'intervalle est déjà écoulé, aucune attente")
    func elapsedIntervalNeedsNoWait() async throws {
        let sleeper = OSSFakeSleeper()
        let spacer = sleeper.makeSpacer(interval: .seconds(3))
        try await spacer.waitForTurn()
        sleeper.sleep(.seconds(10))
        let before = sleeper.delays.count
        try await spacer.waitForTurn()
        #expect(sleeper.delays.count == before)
    }

    @Test("des appels concurrents reçoivent des créneaux distincts")
    func concurrentCallsGetDistinctSlots() async throws {
        let sleeper = OSSFakeSleeper()
        let spacer = sleeper.makeSpacer(interval: .seconds(3))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { try await spacer.waitForTurn() } }
            try await group.waitForAll()
        }
        // Trois créneaux réservés : le premier part tout de suite, les deux autres attendent.
        // (Avec la vraie horloge ce seraient 3 s puis 6 s ; l'horloge simulée avance à chaque
        // sommeil, d'où des attentes de 3 s ici — seul compte que chacun ait attendu.)
        #expect(sleeper.delays.count == 2)
        #expect(sleeper.delays.sorted().first! >= .seconds(3))
    }

    @Test("une annulation pendant l'attente est propagée")
    func cancellationPropagates() async {
        let spacer = ArXivRequestSpacer(interval: .seconds(3), sleep: { _ in throw CancellationError() })
        try? await spacer.waitForTurn()
        let error = await ossThrownError { try await spacer.waitForTurn() }
        #expect(error is CancellationError)
    }
}

// MARK: - Propriétés communes aux quatre sources

@Suite("Sources ouvertes : propriétés communes")
struct OpenSourceCommonTests {
    /// Réponse minimale valide selon l'hôte appelé.
    private static func requester(status: Int = 200) -> OSSTestRequester {
        OSSTestRequester { request in
            let body: String
            switch request.url?.host {
            case "api2.marginalia-search.com", "api.openalex.org": body = #"{"results":[]}"#
            case "export.arxiv.org": body = ossArXivEmptyFeed
            default: body = #"{"batchcomplete":true}"#
            }
            return (Data(body.utf8), status)
        }
    }

    private static func allProviders(requester: OSSTestRequester) -> [any WebSearchProviding] {
        [
            WikipediaSearchProvider(requester: requester),
            OpenAlexSearchProvider(requester: requester),
            ArXivSearchProvider(requester: requester, spacer: OSSFakeSleeper().makeSpacer()),
            MarginaliaSearchProvider(requester: requester),
        ]
    }

    @Test("le User-Agent suit la politique Wikimedia : client/version (contact), sans e-mail ni navigateur")
    func userAgentShape() {
        let agent = OpenSourceSearchHTTP.userAgent
        #expect(agent.hasPrefix("Triva/1.0 ("))
        #expect(agent.hasSuffix(")"))
        #expect(agent.contains(OpenSourceSearchHTTP.contact))
        #expect(!agent.contains("@"))
        #expect(!agent.contains("Mozilla"))
    }

    @Test("aucune source sans clé ne répond jamais « clé refusée » ou « clé absente »",
          arguments: [401, 403, 429, 500, 503, 400])
    func neverBlamesAKey(status: Int) async {
        for category in WebSearchCategory.allCases {
            let requester = Self.requester(status: status)
            for provider in Self.allProviders(requester: requester) {
                let error = await ossThrownError {
                    _ = try await provider.search(query: "swift", options: WebSearchOptions(category: category))
                }
                #expect(error as? WebSearchError != .unauthorized)
                #expect(error as? WebSearchError != .missingKey)
            }
        }
    }

    @Test("une annulation réseau reste une annulation, jamais une indisponibilité")
    func cancellationIsPreserved() async {
        let requester = OSSTestRequester { _ in throw URLError(.cancelled) }
        for provider in Self.allProviders(requester: requester) {
            let error = await ossThrownError {
                _ = try await provider.search(query: "swift", options: WebSearchOptions(category: .academic))
            }
            // Une source qui ne couvre pas `.academic` (Marginalia) lève avant tout appel réseau.
            #expect(error is CancellationError || error as? WebSearchError == .unsupportedCategory)
        }
    }

    @Test("un transport en échec devient `.unavailable`, sans fuite d'URL", arguments: WebSearchCategory.allCases)
    func transportFailure(category: WebSearchCategory) async {
        let requester = OSSTestRequester { _ in throw URLError(.notConnectedToInternet) }
        for provider in Self.allProviders(requester: requester) {
            let error = await ossThrownError {
                _ = try await provider.search(query: "swift", options: WebSearchOptions(category: category))
            }
            #expect(error as? WebSearchError == .unavailable || error as? WebSearchError == .unsupportedCategory)
        }
    }
}

// MARK: - Fabrique

@Suite("OpenSourceSearchChain")
struct OpenSourceSearchChainTests {
    @Test("ordre des sources par catégorie")
    func order() {
        #expect(OpenSourceSearchChain.kinds(for: .general) == [.wikipedia, .marginalia])
        #expect(OpenSourceSearchChain.kinds(for: .academic) == [.openAlex, .arXiv, .wikipedia])
        #expect(OpenSourceSearchChain.kinds(for: .discussion) == [.marginalia, .wikipedia])
    }

    @Test("les sources instanciées suivent les types annoncés", arguments: WebSearchCategory.allCases)
    func providersMatchKinds(category: WebSearchCategory) {
        let chain = OpenSourceSearchChain(
            requester: OSSTestRequester(body: "{}"),
            arXivSpacer: OSSFakeSleeper().makeSpacer()
        )
        #expect(chain.providers(for: category).map(\.kind) == OpenSourceSearchChain.kinds(for: category))
    }

    @Test("aucune source de la chaîne ne refuse la catégorie pour laquelle elle est proposée",
          arguments: WebSearchCategory.allCases)
    func everyProviderSupportsItsCategory(category: WebSearchCategory) async {
        let requester = OSSTestRequester { request in
            switch request.url?.host {
            case "export.arxiv.org": (Data(ossArXivEmptyFeed.utf8), 200)
            case "api.openalex.org", "api2.marginalia-search.com": (Data(#"{"results":[]}"#.utf8), 200)
            default: (Data(#"{"batchcomplete":true}"#.utf8), 200)
            }
        }
        let chain = OpenSourceSearchChain(requester: requester, arXivSpacer: OSSFakeSleeper().makeSpacer())
        for provider in chain.providers(for: category) {
            let error = await ossThrownError {
                _ = try await provider.search(query: "swift concurrency", options: WebSearchOptions(category: category))
            }
            #expect(error == nil, "\(provider.kind) a échoué pour \(category)")
        }
    }

    @Test("l'e-mail de contact OpenAlex est transmis à la source, vide par défaut")
    func contactEmailPropagates() async throws {
        let withEmail = OSSTestRequester(body: #"{"results":[]}"#)
        let chain = OpenSourceSearchChain(requester: withEmail, openAlexContactEmail: "moi@example.org")
        _ = try await chain.providers(for: .academic)[0].search(query: "x", options: WebSearchOptions(category: .academic))
        #expect(withEmail.requests.first.flatMap { ossQueryValue("mailto", in: $0) } == "moi@example.org")

        let plain = OSSTestRequester(body: #"{"results":[]}"#)
        _ = try await OpenSourceSearchChain(requester: plain).providers(for: .academic)[0]
            .search(query: "x", options: WebSearchOptions(category: .academic))
        #expect(plain.requests.first.flatMap { ossQueryValue("mailto", in: $0) } == nil)
    }
}
