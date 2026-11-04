//
//  ChatViewModel+ErrorMessages.swift
//  Triva
//
//  Created by ben podrojsky on 04/11/2026.
//

import Foundation

// Sorti tel quel de `ChatViewModel.swift` (mission RI2), qui dépassait 800 lignes.
extension ChatViewModel {
    // MARK: - Messages d'erreur

    /// Erreur en français clair pour les cas connus ; sinon
    /// `String(describing:)` (un nom brut mais réel vaut mieux qu'un message
    /// inventé). Les erreurs des moteurs et du cloud ne sont JAMAIS
    /// interpolées : leur `generationFailed(description:)` peut porter le
    /// texte brut d'un serveur BYOK — pour un fournisseur « Personnalisé », un
    /// serveur quelconque, qui pourrait renvoyer l'en-tête
    /// `Authorization: Bearer <clé>` dans son JSON d'erreur. Messages fixes ;
    /// seuls y entrent le nom du fournisseur (celui des Réglages) et un statut
    /// HTTP, jamais un texte venu du réseau.
    static func userFacingMessage(for error: Error) -> String {
        pipelineMessage(for: error)
            ?? engineMessage(for: error)
            ?? cloudMessage(for: error)
            ?? String(describing: error)
    }

    private static func pipelineMessage(for error: Error) -> String? {
        if let chainError = error as? WebSearchChainError {
            // Texte fixe, sans le détail des sources : `SearchKeyInvitation` dit le reste.
            return chainError.userFacingMessage
        }
        if let resolverError = error as? ActiveAIProviderResolverError {
            return resolverMessage(for: resolverError)
        }
        if let failoverError = error as? FailoverError {
            switch failoverError {
            case .noInstancesConfigured:
                return "Aucune instance de recherche n'est configurée."
            case .allInstancesUnavailable:
                return "Aucune instance de recherche n'a répondu. Réessaie dans un instant."
            }
        }
        if error is ChatViewModelError {
            return "Le moteur IA n'a renvoyé aucune réponse. Réessaie."
        }
        if let sessionError = error as? SearchSessionError {
            // `switch` exhaustif : un nouveau cas exigera son propre message.
            switch sessionError {
            case .sessionEnded:
                // Fenêtre fermée ou moteur changé en pleine génération (voir `SearchSessionError`).
                return "Réponse interrompue : la fenêtre a été fermée ou le moteur IA a changé."
            }
        }
        if let historyError = error as? ChatHistoryStoreError {
            return historyError.userFacingMessage
        }
        if let favoritesError = error as? FavoritesStoreError {
            return favoritesError.userFacingMessage
        }
        return nil
    }

    private static func resolverMessage(for error: ActiveAIProviderResolverError) -> String {
        switch error {
        case .noEngineSelected:
            return "Aucun moteur IA sélectionné. Choisis-en un dans les Réglages."
        case .appleIntelligenceUnavailable:
            return "Apple Intelligence n'est pas disponible sur cet appareil."
        case .noMLXModelSelected:
            return "Aucun modèle local choisi. Sélectionne un modèle MLX dans les Réglages."
        case .mlxModelNotInCatalog:
            return "Le modèle local choisi n'est plus disponible. Choisis-en un autre dans les Réglages."
        case .noCloudSelectionStored:
            return "Aucun fournisseur configuré. Va dans Réglages pour en choisir un."
        case .cloudSelectionUnresolvable:
            return "Le fournisseur choisi n'est plus disponible. Vérifie tes Réglages."
        }
    }

    /// Moteurs sur l'appareil (bug 6) : sans ces cas, un échec affichait
    /// « generationFailed(description: …) ». Une cause TYPÉE par
    /// `AppleIntelligenceProvider.mapGenerationError` (contexte dépassé,
    /// garde-fous, refus, débit, langue, délai) porte son propre message.
    /// `generationFailed` ne reste que pour une cause non classée — et pour
    /// MLX, qui n'a rien de plus à distinguer (voir
    /// `MLXProvider.mapGenerationError`) : message neutre qui cite la cause la
    /// plus fréquente. Jamais d'analyse de la description.
    private static func engineMessage(for error: Error) -> String? {
        if let generationError = error as? AppleIntelligenceGenerationError {
            return generationError.userFacingMessage
        }
        if let appleError = error as? AppleIntelligenceError {
            switch appleError {
            case .generationFailed:
                return "Apple Intelligence n'a pas pu répondre. Si la conversation est longue, commence-en une nouvelle."
            case .modelNotReady:
                return "Apple Intelligence se prépare encore sur cet appareil. Réessaie dans quelques minutes."
            case .deviceNotEligible, .appleIntelligenceNotEnabled, .unavailableForOtherReason:
                return "Apple Intelligence n'est pas disponible sur cet appareil."
            }
        }
        if let mlxError = error as? MLXProviderError {
            switch mlxError {
            case .simulatorUnsupported:
                // Garde-fou anti-crash de `MLXProvider` (Metal absent du Simulateur).
                return "Les modèles locaux (MLX) ne fonctionnent pas sur le Simulateur — teste sur un appareil réel."
            case .generationFailed, .modelNotLoaded:
                return "Le modèle local n'a pas pu répondre. Si la conversation est longue, commence-en une nouvelle."
            case .downloadFailed:
                return "Le téléchargement du modèle local a échoué. Vérifie ta connexion et réessaie."
            }
        }
        return nil
    }

    /// Cloud (bug 6) : une cause TYPÉE (`providerFailure` — clé refusée,
    /// débit, contexte, panne, réseau, requête refusée) porte un message qui
    /// nomme le fournisseur (`CloudProviderFailure.userFacingMessage`).
    /// `generationFailed` = cause non classée, dont l'erreur au statut perdu
    /// des fournisseurs compatibles OpenAI : message neutre qui n'accuse pas
    /// la clé d'emblée mais la garde en piste, cause la plus probable en BYOK.
    /// Clé ABSENTE : cas typé, message précis. `switch` exhaustifs : un
    /// nouveau cas exigera son message.
    private static func cloudMessage(for error: Error) -> String? {
        let missingKey = "Aucune clé API n'est enregistrée pour ce fournisseur. Ajoute-la dans les Réglages."
        let neutral = "Le fournisseur IA n'a pas pu répondre. Réessaie dans un instant ; si ça continue, vérifie ta clé API dans les Réglages."
        if let openAIError = error as? OpenAICompatibleProviderError {
            switch openAIError {
            case .missingAPIKey: return missingKey
            case .providerFailure(let provider, let reason): return reason.userFacingMessage(provider: provider)
            case .generationFailed: return neutral
            }
        }
        if let byokError = error as? CloudBYOKError {
            switch byokError {
            case .missingAPIKey: return missingKey
            case .providerFailure(let provider, let reason): return reason.userFacingMessage(provider: provider)
            case .generationFailed: return neutral
            }
        }
        if let perplexityError = error as? PerplexityAgentError {
            // Déjà des messages français fixes (`LocalizedError`).
            return perplexityError.errorDescription ?? neutral
        }
        return nil
    }
}
