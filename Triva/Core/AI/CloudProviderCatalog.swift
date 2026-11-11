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

/// MODÈLES PAR DÉFAUT — revue du 2026-11-10, sur les documentations officielles. On prend le
/// modèle ÉCONOMIQUE récent de chaque fournisseur : l'utilisateur paie ses propres requêtes et
/// peut changer de modèle dans « Fournisseur et modèle ».
/// - OpenAI : `gpt-6-luna` (« most efficient », 0,10 $ / 0,50 $ par M de jetons) remplace
///   `gpt-4o-mini` (0,15 $ / 0,60 $). Essayé en réel (chat et recherche web) le 2026-11-10.
///   https://developers.openai.com/api/docs/pricing
/// - OpenRouter : `openai/gpt-6-luna`, id présent dans `GET /api/v1/models` (public) le 2026-11-10.
/// - Gemini : `gemini-2.5-flash` est déprécié et sera redirigé vers `gemini-3.5-flash-lite` le
///   2026-12-01 (https://aistudio.google.com/docs/models).
/// - DeepSeek : `deepseek-chat` / `deepseek-reasoner` étaient annoncés comme dépréciés le
///   2026-07-24 ; la page des tarifs donne `deepseek-flash` comme nom de modèle
///   (https://api-docs.deepseek.com/quick_start/pricing).
/// - xAI : `grok-4.3` (1,25 $ / 2,50 $) est le moins cher de la liste, `grok-4.6` coûte 2 $ / 6 $
///   (https://docs.x.ai/docs/models).
/// - Mistral : `mistral-small-latest` (Small 4) au lieu de `mistral-large-latest`, dont la version
///   datée Large 3 sera retirée le 2027-04-30 (https://docs.mistral.ai/getting-started/models/).
///   La doc consultée ne dit pas vers quelle version pointe chaque alias `-latest`.
/// - Together : `meta-llama/Llama-3.3-70B-Instruct-Turbo` n'est plus dans la liste des modèles
///   serverless (https://docs.together.ai/docs/serverless-models) ; `openai/gpt-oss-120b` y figure.
/// - Fireworks : Llama 3.3 70B retiré du serverless le 2026-05-14 et GPT-OSS 120B le 2026-11-07
///   (https://docs.fireworks.ai/updates/changelog) ; `deepseek-v4p1-flash-1017` y est ajouté.
/// - Groq : la page de `llama-3.3-70b-versatile` porte désormais l'étiquette « Enterprise » et la
///   liste des modèles n'en donne plus le prix (« contact sales »,
///   https://console.groq.com/docs/models) : une clé ordinaire risque d'être refusée, et ce modèle
///   sert aussi à TESTER la clé à l'enregistrement. `openai/gpt-oss-120b` (0,15 $ / 0,60 $) y est en
///   production avec un prix public.
/// - INCHANGÉS : Cerebras (`gpt-oss-120b` toujours listé) et Perplexity (niveau d'effort `fast`).
/// Les ids de Gemini, Mistral, DeepSeek, xAI, Together et Fireworks n'ont PAS été essayés en réel
/// (pas de clé) : ils viennent de la documentation. Sans cette garantie, la liste des modèles du
/// fournisseur (`CloudModelListService`) reste le filet : l'utilisateur peut en choisir un autre.
enum CloudProviderCatalog {
    static let presets: [CloudProviderPreset] = [
        CloudProviderPreset(
            id: "openai",
            displayName: "OpenAI",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            defaultModel: "gpt-6-luna"
        ),
        CloudProviderPreset(
            id: "groq",
            displayName: "Groq",
            baseURL: URL(string: "https://api.groq.com/openai/v1")!,
            defaultModel: "openai/gpt-oss-120b"
        ),
        CloudProviderPreset(
            id: "openrouter",
            displayName: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            defaultModel: "openai/gpt-6-luna"
        ),
        CloudProviderPreset(
            id: "gemini",
            displayName: "Google Gemini",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!,
            defaultModel: "gemini-3.5-flash-lite"
        ),
        CloudProviderPreset(
            id: "mistral",
            displayName: "Mistral",
            baseURL: URL(string: "https://api.mistral.ai/v1")!,
            defaultModel: "mistral-small-latest"
        ),
        CloudProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: URL(string: "https://api.deepseek.com/v1")!,
            defaultModel: "deepseek-flash"
        ),
        CloudProviderPreset(
            id: "xai",
            displayName: "xAI (Grok)",
            baseURL: URL(string: "https://api.x.ai/v1")!,
            defaultModel: "grok-4.3"
        ),
        CloudProviderPreset(
            id: "together",
            displayName: "Together AI",
            baseURL: URL(string: "https://api.together.xyz/v1")!,
            defaultModel: "openai/gpt-oss-120b"
        ),
        CloudProviderPreset(
            id: "fireworks",
            displayName: "Fireworks AI",
            baseURL: URL(string: "https://api.fireworks.ai/inference/v1")!,
            defaultModel: "accounts/fireworks/models/deepseek-v4p1-flash-1017"
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
            // Chat via l'Agent API (`POST /v1/agent`, voir `PerplexityAgentClient`) :
            // Sonar Chat Completions est arrêté depuis le 2026-09-27 (docs.perplexity.ai,
            // consultée le 2026-10-28). Le « modèle » est un niveau d'effort.
            baseURL: URL(string: "https://api.perplexity.ai")!,
            defaultModel: "fast"
        ),
    ]

    /// `{baseURL}/chat/completions`, en gérant proprement la présence ou non
    /// d'un slash final sur `baseURL` (ex. Gemini vs. les autres presets).
    static func chatCompletionsURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
    }
}
