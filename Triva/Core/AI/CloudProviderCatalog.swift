//
//  CloudProviderCatalog.swift
//  Triva
//
//  Created by ben podrojsky on 05/09/2026.
//

import Foundation

/// Un fournisseur cloud BYOK compatible OpenAI (0.6 élargi) : tous exposent
/// le même contrat `POST {baseURL}/chat/completions`, seuls l'URL de base et
/// le modèle changent — voir `OpenAICompatibleClient`. Claude reste à part
/// (`CloudBYOKProvider`, son propre package Foundation Models), il n'est pas
/// dans ce catalogue.
///
/// Sert aussi de type pour les entrées "Personnalisé" créées par
/// l'utilisateur (voir `CustomProviderStore`) — mêmes champs, juste pas dans
/// le catalogue statique ci-dessous.
struct CloudProviderPreset: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let displayName: String
    let baseURL: URL
    /// Valeur de départ raisonnable, éditable par l'utilisateur — pas de
    /// garantie qu'elle reste à jour indéfiniment (les fournisseurs
    /// renomment/déprécient leurs modèles régulièrement).
    let defaultModel: String
}

enum CloudProviderCatalog {
    static let presets: [CloudProviderPreset] = [
        CloudProviderPreset(
            id: "openai",
            displayName: "OpenAI",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            defaultModel: "gpt-4o-mini"
        ),
        CloudProviderPreset(
            id: "groq",
            displayName: "Groq",
            baseURL: URL(string: "https://api.groq.com/openai/v1")!,
            defaultModel: "llama-3.3-70b-versatile"
        ),
        CloudProviderPreset(
            id: "openrouter",
            displayName: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            defaultModel: "openai/gpt-4o-mini"
        ),
        CloudProviderPreset(
            id: "gemini",
            displayName: "Google Gemini",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!,
            defaultModel: "gemini-2.5-flash"
        ),
        CloudProviderPreset(
            id: "mistral",
            displayName: "Mistral",
            baseURL: URL(string: "https://api.mistral.ai/v1")!,
            defaultModel: "mistral-large-latest"
        ),
        CloudProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com/v1")!,
            defaultModel: "deepseek-chat"
        ),
        CloudProviderPreset(
            id: "xai",
            displayName: "xAI (Grok)",
            baseURL: URL(string: "https://api.x.ai/v1")!,
            defaultModel: "grok-4.6"
        ),
        CloudProviderPreset(
            id: "together",
            displayName: "Together AI",
            baseURL: URL(string: "https://api.together.xyz/v1")!,
            defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo"
        ),
        CloudProviderPreset(
            id: "fireworks",
            displayName: "Fireworks AI",
            baseURL: URL(string: "https://api.fireworks.ai/inference/v1")!,
            defaultModel: "accounts/fireworks/models/llama-v3p3-70b-instruct"
        ),
        CloudProviderPreset(
            id: "cerebras",
            displayName: "Cerebras",
            baseURL: URL(string: "https://api.cerebras.ai/v1")!,
            defaultModel: "gpt-oss-120b"
        ),
        CloudProviderPreset(
            id: "perplexity",
            displayName: "Perplexity",
            baseURL: URL(string: "https://api.perplexity.ai")!,
            defaultModel: "sonar-pro"
        ),
    ]

    /// `{baseURL}/chat/completions`, en gérant proprement la présence ou non
    /// d'un slash final sur `baseURL` (ex. Gemini vs. les autres presets).
    static func chatCompletionsURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
    }
}
