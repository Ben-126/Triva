//
//  CloudProviderCatalogTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 05/09/2026.
//

import Testing
import Foundation
@testable import Triva

@MainActor
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

    @Test("Aucun modèle par défaut n'est un modèle retiré ou déprécié (revue du 2026-11-10)")
    func defaultsAreNotRetiredModels() {
        let retired: Set<String> = [
            "gpt-4o-mini", "openai/gpt-4o-mini", "gemini-2.5-flash", "deepseek-chat", "deepseek-reasoner",
            "meta-llama/Llama-3.3-70B-Instruct-Turbo", "accounts/fireworks/models/llama-v3p3-70b-instruct",
            "mistral-large-latest", "llama-3.3-70b-versatile",
        ]
        for preset in CloudProviderCatalog.presets {
            #expect(!retired.contains(preset.defaultModel), "\(preset.id) : \(preset.defaultModel)")
        }
    }

    @Test("Modèles par défaut vérifiés dans la documentation officielle le 2026-11-10")
    func reviewedDefaults() {
        let defaults = Dictionary(uniqueKeysWithValues: CloudProviderCatalog.presets.map { ($0.id, $0.defaultModel) })
        #expect(defaults["openai"] == "gpt-6-luna")
        #expect(defaults["groq"] == "openai/gpt-oss-120b")
        #expect(defaults["openrouter"] == "openai/gpt-6-luna")
        #expect(defaults["gemini"] == "gemini-3.5-flash-lite")
        #expect(defaults["deepseek"] == "deepseek-flash")
        #expect(defaults["xai"] == "grok-4.3")
        #expect(defaults["together"] == "openai/gpt-oss-120b")
        #expect(defaults["fireworks"] == "accounts/fireworks/models/deepseek-v4p1-flash-1017")
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
