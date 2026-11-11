//
//  WikipediaSearchTermsTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Testing
import Foundation
@testable import Triva

/// Mission A5, point 2. CirrusSearch (Wikipédia) exige TOUS les mots : on envoie
/// les mots pleins de la question, pas la phrase entière. Mesure sur l'API réelle
/// (2026-11-11, fr.wikipedia.org) : « Décrire le processus de la photosynthèse
/// étape par étape » donnait Respiration, Évolution (biologie)… et pas l'article
/// « Photosynthèse » ; « photosynthèse » le met en tête.
@MainActor
@Suite("WikipediaSearchProvider — mots pleins (mission A5)")
struct WikipediaSearchTermsTests {
    @Test("Les mots vides de LexicalRelevance sont retirés, les accents et la casse gardés", arguments: [
        ("Décrire le processus de la photosynthèse étape par étape", "photosynthèse"),
        ("Quelle est la hauteur de la tour Eiffel ?", "hauteur tour Eiffel"),
        ("Comment créer une liste chaînée en Python ?", "liste chaînée Python"),
        ("Qui a inventé le vaccin contre la rage ?", "inventé vaccin rage"),
        ("Cite les 27 pays de l'UE et la capitale de chacun", "27 pays UE capitale"),
        ("What is the height of the Eiffel Tower?", "height Eiffel Tower"),
    ])
    func keepsFullWords(query: String, expected: String) {
        #expect(WikipediaSearchProvider.searchTerms(for: query) == expected)
    }

    @Test("Une requête déjà réduite reste identique")
    func shortQueryIsUnchanged() {
        #expect(WikipediaSearchProvider.searchTerms(for: "tour eiffel") == "tour eiffel")
    }

    @Test("Repli : une requête faite de mots vides part telle quelle (rognée), jamais vide", arguments: [
        "Comment faire ça ?", "  Quel est le   processus ?  ",
    ])
    func fallsBackWhenNothingRemains(query: String) {
        let terms = WikipediaSearchProvider.searchTerms(for: query)
        #expect(!terms.isEmpty)
        #expect(terms == query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("buildRequest envoie les mots pleins dans gsrsearch")
    func requestCarriesFullWords() async throws {
        let requester = OSSTestRequester(body: #"{"query":{"pages":[]}}"#)
        let provider = WikipediaSearchProvider(requester: requester)
        _ = try await provider.search(
            query: "Décrire le processus de la photosynthèse étape par étape",
            options: WebSearchOptions(language: "fr", maxResults: 5)
        )
        let request = try #require(requester.requests.first)
        #expect(ossQueryValue("gsrsearch", in: request) == "photosynthèse")
    }

    @Test("Une requête vide ne déclenche toujours aucune requête")
    func emptyQueryStillSkipsTheRequest() async throws {
        let requester = OSSTestRequester(body: "{}")
        let provider = WikipediaSearchProvider(requester: requester)
        _ = try await provider.search(query: "   ", options: WebSearchOptions(language: "fr", maxResults: 5))
        #expect(requester.requests.isEmpty)
    }

    @Test("LexicalRelevance.contentWords : ponctuation, apostrophes et mots d'une lettre écartés")
    func contentWordsSplitsOnPunctuation() {
        #expect(LexicalRelevance.contentWords(of: "L'histoire d'Anubis, dieu égyptien") == ["histoire", "Anubis", "dieu", "égyptien"])
        #expect(LexicalRelevance.contentWords(of: "") == [])
    }
}
