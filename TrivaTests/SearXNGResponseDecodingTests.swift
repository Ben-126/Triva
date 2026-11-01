//
//  SearXNGResponseDecodingTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 01/11/2026.
//

import Foundation
import Testing
@testable import Triva

@Suite("Décodage de SearXNGSearchResponse (bug 5)")
struct SearXNGResponseDecodingTests {
    private func decode(_ json: String) throws -> SearXNGSearchResponse {
        try JSONDecoder().decode(SearXNGSearchResponse.self, from: Data(json.utf8))
    }

    @Test("Moteurs injoignables : noms lus depuis les paires [moteur, motif]")
    func decodesUnresponsiveEngines() throws {
        let response = try decode(#"{"results":[],"suggestions":[],"unresponsive_engines":[["reddit","Suspended: access denied"],["arxiv","timeout"]]}"#)
        #expect(response.results.isEmpty)
        #expect(response.unresponsiveEngines == ["reddit", "arxiv"])
    }

    @Test("Champ absent : nil, le reste de la réponse est décodé")
    func missingFieldIsNil() throws {
        let response = try decode(#"{"results":[],"suggestions":["a"]}"#)
        #expect(response.unresponsiveEngines == nil)
        #expect(response.suggestions == ["a"])
    }

    @Test("Forme inattendue : nil, jamais d'échec du décodage")
    func unexpectedShapeNeverBreaksDecoding() throws {
        let response = try decode(#"{"results":[],"suggestions":[],"unresponsive_engines":{"reddit":"x"}}"#)
        #expect(response.unresponsiveEngines == nil)
    }
}
