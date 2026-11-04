//
//  EngineErrorMessagesTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 02/11/2026.
//

import Testing
import Foundation
import FoundationModels
@testable import Triva

/// Erreur dont la description reprend un texte de serveur porteur de la clé,
/// comme le ferait un fournisseur « Personnalisé » malveillant.
private struct SecretEchoError: Error, CustomStringConvertible {
    let secret: String
    var description: String { "Invalid header: Bearer \(secret)" }
}

/// Chaîne complète du bug 6, en fonctions PURES : erreur brute (SDK OS27,
/// client HTTP, package Claude) → mapper `nonisolated static` du provider →
/// `ChatViewModel.userFacingMessage(for:)`. Les erreurs du SDK sont construites
/// par leurs inits publics : aucune `LanguageModelSession` ouverte, aucun
/// modèle MLX chargé, aucun réseau — sur Mac, Foundation Models et MLX
/// tourneraient pour de vrai. Fichier séparé de `ChatViewModelTests` : ce
/// dernier est partagé avec d'autres chantiers.
@MainActor
@Suite("Messages d'erreur typés des moteurs IA (bug 6)")
struct EngineErrorMessagesTests {
    @Test("Chaque cause typée d'Apple Intelligence a son propre message, distinct du message générique")
    func appleIntelligenceCausesHaveTheirOwnMessages() {
        let causes = AppleIntelligenceGenerationError.allCases
        let generic = ChatViewModel.userFacingMessage(for: AppleIntelligenceError.generationFailed(description: "x"))
        let messages = causes.map { ChatViewModel.userFacingMessage(for: $0) }

        #expect(messages == causes.map(\.userFacingMessage))
        #expect(Set(messages).count == causes.count)
        #expect(!messages.contains(generic))
        #expect(messages.allSatisfy { $0.contains("Apple Intelligence") })
    }

    @Test("Apple Intelligence : contexte dépassé du SDK → message qui dit quoi faire")
    func appleIntelligenceContextOverflowChain() {
        let sdkError = LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "exceeded"))
        let message = ChatViewModel.userFacingMessage(for: AppleIntelligenceProvider.mapGenerationError(sdkError))
        #expect(message == "La conversation et ses sources sont trop longues pour Apple Intelligence. Commence une nouvelle conversation ou choisis un autre moteur dans les Réglages.")
    }

    @Test("Compatible OpenAI : le statut HTTP devient un message qui nomme le fournisseur")
    func openAICompatibleStatusChain() {
        let rejected = OpenAICompatibleProvider.mapClientError(OpenAICompatibleClientError.requestFailed(statusCode: 401), provider: "OpenAI")
        let limited = OpenAICompatibleProvider.mapClientError(OpenAICompatibleClientError.requestFailed(statusCode: 429), provider: "Groq")
        let down = OpenAICompatibleProvider.mapClientError(OpenAICompatibleClientError.requestFailed(statusCode: 503), provider: "Mistral")
        let offline = OpenAICompatibleProvider.mapClientError(OpenAICompatibleClientError.transportError, provider: "Mon LLM")

        #expect(ChatViewModel.userFacingMessage(for: rejected) == "Clé API refusée par OpenAI. Vérifie-la dans les Réglages.")
        #expect(ChatViewModel.userFacingMessage(for: limited) == "Limite de requêtes atteinte chez Groq. Réessaie dans un instant, ou vérifie le crédit de ton compte Groq.")
        #expect(ChatViewModel.userFacingMessage(for: down) == "Mistral est momentanément indisponible. Réessaie dans un instant.")
        #expect(ChatViewModel.userFacingMessage(for: offline) == "Impossible de joindre Mon LLM. Vérifie ta connexion et réessaie.")
    }

    @Test("Claude : erreur typée du package → message au nom de Claude")
    func claudePackageErrorChain() {
        let limited = CloudBYOKProvider.mapGenerationError(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "429")))
        let tooLong = CloudBYOKProvider.mapGenerationError(LanguageModelError.contextSizeExceeded(.init(contextSize: 0, tokenCount: 0, debugDescription: "413")))

        #expect(ChatViewModel.userFacingMessage(for: limited) == "Limite de requêtes atteinte chez Claude. Réessaie dans un instant, ou vérifie le crédit de ton compte Claude.")
        #expect(ChatViewModel.userFacingMessage(for: tooLong) == "La conversation et ses sources sont trop longues pour Claude. Commence une nouvelle conversation ou choisis un autre modèle dans les Réglages.")
    }

    @Test("providerFailure : même message, que l'erreur vienne de Claude ou d'un compatible OpenAI")
    func bothCloudPathsShareTheirMessages() {
        let reasons: [CloudProviderFailure] = [
            .apiKeyRejected(statusCode: nil), .rateLimited, .contextWindowExceeded,
            .serverUnavailable(statusCode: 500), .unreachable, .requestRejected(statusCode: 404),
        ]
        for reason in reasons {
            let expected = reason.userFacingMessage(provider: "Fournisseur")
            #expect(ChatViewModel.userFacingMessage(for: OpenAICompatibleProviderError.providerFailure(provider: "Fournisseur", reason: reason)) == expected)
            #expect(ChatViewModel.userFacingMessage(for: CloudBYOKError.providerFailure(provider: "Fournisseur", reason: reason)) == expected)
        }
    }

    @Test("Une ressource du modèle absente de l'appareil : « se prépare encore », pas un échec opaque")
    func missingAssetsReadAsModelNotReady() {
        let mapped = AppleIntelligenceProvider.mapGenerationError(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "assets")))
        #expect(ChatViewModel.userFacingMessage(for: mapped) == "Apple Intelligence se prépare encore sur cet appareil. Réessaie dans quelques minutes.")
    }

    @Test("Aucun texte de serveur ni clé n'atteint le message, quel que soit le chemin")
    func secretsNeverReachTheMessage() {
        let secret = "sk-SECRET-42"
        let echoingErrors: [any Error] = [
            OpenAICompatibleProvider.mapClientError(OpenAICompatibleClientError.apiError(message: "Bearer \(secret)"), provider: "Mon LLM"),
            OpenAICompatibleProvider.mapClientError(SecretEchoError(secret: secret), provider: "Mon LLM"),
            CloudBYOKProvider.mapGenerationError(SecretEchoError(secret: secret)),
            CloudBYOKProvider.mapGenerationError(LanguageModelError.guardrailViolation(.init(debugDescription: "Bearer \(secret)"))),
            AppleIntelligenceProvider.mapGenerationError(LanguageModelError.guardrailViolation(.init(debugDescription: "Bearer \(secret)"))),
            AppleIntelligenceProvider.mapGenerationError(SecretEchoError(secret: secret)),
            MLXProvider.mapGenerationError(SecretEchoError(secret: secret)),
        ]
        for error in echoingErrors {
            let message = ChatViewModel.userFacingMessage(for: error)
            #expect(!message.contains(secret), "Écho du secret pour \(type(of: error))")
            #expect(!message.contains("Bearer"), "Écho du texte serveur pour \(type(of: error))")
        }
    }
}
