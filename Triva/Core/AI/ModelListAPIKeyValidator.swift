//
//  ModelListAPIKeyValidator.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

/// Valide une clé BYOK en demandant au fournisseur la LISTE de ses modèles (`GET /models`), plutôt
/// qu'en envoyant une vraie génération avec un nom de modèle codé en dur.
///
/// POURQUOI (décision de Ben du 2026-11-11) : l'ancien validateur (`OpenAICompatibleAPIKeyValidator`,
/// `ClaudeAPIKeyValidator`) générait une réponse avec `defaultModel`. Quand un fournisseur retire ce
/// modèle, la génération échoue et la clé, pourtant valide, était refusée à l'enregistrement : un
/// nom de modèle périmé bloquait toute l'app (l'écran « Fournisseur et modèle » dépend ensuite de la
/// clé). La liste des modèles ne dépend d'aucun nom, coûte zéro jeton et prouve que la clé est
/// acceptée. Elle réutilise `CloudModelListService` : mêmes en-têtes, session sans cache (la clé ne
/// finit jamais dans `Cache.db`) et messages d'erreur fixes qui ne contiennent jamais la clé.
///
/// REPLI sur la génération (`fallback`) uniquement quand la liste est inutilisable sans que la clé
/// soit en cause : fournisseur sans liste (Perplexity, certains fournisseurs personnalisés :
/// `listUnavailable`, `decoding`, liste fixe) ou clé limitée qui ne peut pas lister (`forbidden`).
/// Une panne réseau, un délai dépassé ou une limite de débit ne sont PAS des clés refusées : elles
/// remontent en `.unverifiable`, que l'écran affiche telle quelle au lieu de « clé invalide ».
nonisolated struct ModelListAPIKeyValidator: APIKeyValidating {
    private let providerID: String
    private let source: CloudModelListSource
    private let service: CloudModelListService
    private let fallback: any APIKeyValidating

    init(
        providerID: String,
        source: CloudModelListSource,
        fallback: any APIKeyValidating,
        service: CloudModelListService = CloudModelListService()
    ) {
        self.providerID = providerID
        self.source = source
        self.fallback = fallback
        self.service = service
    }

    func validate(apiKey: String) async throws {
        if case .staticList = source {
            try await fallback.validate(apiKey: apiKey)
            return
        }
        do {
            _ = try await service.models(providerID: providerID, source: source, apiKey: apiKey, forceRefresh: true)
        } catch let error as CloudModelListError {
            try await handle(error, apiKey: apiKey)
        } catch {
            // Annulation de la tâche ou erreur imprévue : jamais la description brute, qui pourrait
            // contenir une valeur venue du réseau.
            throw APIKeyValidationError.unverifiable(message: CloudModelListError.network.message)
        }
    }

    private func handle(_ error: CloudModelListError, apiKey: String) async throws {
        switch error {
        case .invalidKey:
            throw APIKeyValidationError.invalidKey(description: error.message)
        case .forbidden, .listUnavailable, .decoding:
            try await fallback.validate(apiKey: apiKey)
        case .rateLimited, .serverUnavailable, .unexpectedStatus, .timeout, .network:
            throw APIKeyValidationError.unverifiable(message: error.message)
        }
    }
}
