//
//  PerplexityAgentProvider.swift
//  Triva
//
//  Created by ben podrojsky on 28/10/2026.
//

import Foundation

/// Génération de texte via l'Agent API Perplexity (BYOK). Remplace, pour Perplexity, le
/// chemin OpenAI-compatible `/chat/completions` (Sonar Chat Completions arrêté le
/// 2026-09-27, voir `PerplexityAgentClient`). Le « modèle » est un niveau d'effort.
///
/// Les sources de la recherche web de Perplexity (événements `.sources`) sont reçues mais ne
/// sont pas exposées par `AIGenerating` (qui ne renvoie que du texte) : voir
/// `onSources` pour les récupérer le jour où l'interface voudra les afficher.
struct PerplexityAgentProvider: AIGenerating {
    let account: String
    let model: String
    private let baseURL: URL
    private let keyStore: any APIKeyStoring
    private let client: any PerplexityAgentRequesting
    private let onSources: @Sendable ([PerplexitySource]) -> Void

    init(
        account: String = "perplexity",
        baseURL: URL,
        model: String,
        keyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        client: any PerplexityAgentRequesting = PerplexityAgentClient(),
        onSources: @escaping @Sendable ([PerplexitySource]) -> Void = { _ in }
    ) {
        self.account = account
        self.baseURL = baseURL
        self.model = model
        self.keyStore = keyStore
        self.client = client
        self.onSources = onSources
    }

    func generate(prompt: String) async throws -> String {
        let apiKey = try readAPIKey()
        return try await client.generate(baseURL: baseURL, apiKey: apiKey, model: model, prompt: prompt)
    }

    /// Streaming réel. Comme les autres providers, chaque yield est un instantané CUMULATIF
    /// du texte (et non un delta) : c'est ce qu'attend `ChatViewModel`.
    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let apiKey: String
            do {
                apiKey = try readAPIKey()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let events = client.stream(baseURL: baseURL, apiKey: apiKey, model: model, prompt: prompt)
            let onSources = onSources
            let task = Task {
                var accumulated = ""
                var sources: [PerplexitySource] = []
                do {
                    for try await event in events {
                        switch event {
                        case .textDelta(let delta):
                            accumulated += delta
                            continuation.yield(accumulated)
                        case .sources(let batch):
                            sources += batch
                        }
                    }
                    if !sources.isEmpty { onSources(sources) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func readAPIKey() throws -> String {
        let storedKey: String?
        do {
            storedKey = try keyStore.apiKey(account: account)
        } catch {
            throw PerplexityAgentError.keychainUnavailable
        }
        guard let apiKey = storedKey, !apiKey.isEmpty else {
            throw PerplexityAgentError.missingAPIKey
        }
        return apiKey
    }
}
