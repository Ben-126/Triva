//
//  MLXModelCatalogTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation
import Testing
@testable import Triva

@Suite("MLXModelCatalog")
struct MLXModelCatalogTests {
    @Test("Décode et trie les modèles par capacité croissante, quel que soit l'ordre dans le JSON")
    func parsesAndSortsByCapabilityScore() throws {
        let json = """
        {
          "models": [
            \(Self.entryJSON(id: "b", score: 2)),
            \(Self.entryJSON(id: "a", score: 1)),
            \(Self.entryJSON(id: "c", score: 3, registryKey: nil))
          ]
        }
        """

        let entries = try MLXModelCatalog.parse(Data(json.utf8))

        #expect(entries.map(\.id) == ["a", "b", "c"])
        #expect(entries[2].registryKey == nil)
    }

    @Test("Lève invalidFormat quand la liste de modèles est vide")
    func throwsOnEmptyModelList() {
        let json = #"{"models": []}"#

        #expect(throws: MLXModelCatalogError.invalidFormat) {
            try MLXModelCatalog.parse(Data(json.utf8))
        }
    }

    @Test("Lève une erreur de décodage sur un JSON malformé")
    func throwsOnMalformedJSON() {
        let json = "not json"

        #expect(throws: (any Error).self) {
            try MLXModelCatalog.parse(Data(json.utf8))
        }
    }

    private static func entryJSON(id: String, score: Int, registryKey: String? = "some_key") -> String {
        let registryKeyJSON = registryKey.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "id": "\(id)", "displayName": "\(id)", "huggingFaceRepo": "mlx-community/\(id)",
          "registryKey": \(registryKeyJSON), "license": "Apache 2.0",
          "downloadSizeBytes": 1000, "recommendedGPUWorkingSetBytes": 2000,
          "capabilityScore": \(score), "supportsThinkingMode": true,
          "isMixtureOfExperts": false, "isAdvancedOnly": false,
          "summary": "s", "strengths": [], "tradeoffs": []
        }
        """
    }
}
