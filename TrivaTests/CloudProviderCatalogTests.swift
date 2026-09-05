//
//  CloudProviderCatalogTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/09/2026.
//

import Testing
import Foundation
@testable import Triva

@Suite("CloudProviderCatalog")
struct CloudProviderCatalogTests {
    @Test("Contient exactement les fournisseurs génériques attendus, sans doublon")
    func containsExpectedPresetsWithoutDuplicates() {
        let ids = CloudProviderCatalog.presets.map(\.id)
        let expected: Set<String> = [
            "openai", "groq", "openrouter", "gemini", "mistral",
            "deepseek", "xai", "together", "fireworks", "cerebras", "perplexity",
        ]

        #expect(Set(ids) == expected)
        #expect(ids.count == Set(ids).count)
    }

    @Test("Chaque preset a un nom affiché et un modèle par défaut non vides")
    func presetsHaveNonEmptyFields() {
        for preset in CloudProviderCatalog.presets {
            #expect(!preset.displayName.isEmpty)
            #expect(!preset.defaultModel.isEmpty)
        }
    }

    @Test("chatCompletionsURL ajoute /chat/completions sans doubler le slash final")
    func chatCompletionsURLHandlesTrailingSlash() {
        let withoutTrailingSlash = URL(string: "https://api.groq.com/openai/v1")!
        let withTrailingSlash = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
        let bareHost = URL(string: "https://api.perplexity.ai")!

        #expect(
            CloudProviderCatalog.chatCompletionsURL(baseURL: withoutTrailingSlash).absoluteString
                == "https://api.groq.com/openai/v1/chat/completions"
        )
        #expect(
            CloudProviderCatalog.chatCompletionsURL(baseURL: withTrailingSlash).absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
        #expect(
            CloudProviderCatalog.chatCompletionsURL(baseURL: bareHost).absoluteString
                == "https://api.perplexity.ai/chat/completions"
        )
    }
}
