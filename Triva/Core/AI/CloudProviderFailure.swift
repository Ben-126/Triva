//
//  CloudProviderFailure.swift
//  Triva
//
//  Created by ben podrojsky on 01/11/2026.
//

import Foundation

/// Cause TYPÉE d'un échec chez un fournisseur cloud BYOK (bug 6), commune au
/// chemin compatible OpenAI (`OpenAICompatibleProvider`) et à Claude
/// (`CloudBYOKProvider`). Avant, tout échec cloud devenait
/// `generationFailed(description:)` et l'utilisateur lisait le même message,
/// qu'il s'agisse d'une clé refusée, d'un 429 ou d'une panne.
///
/// Déduite d'un statut HTTP ou d'une erreur DÉJÀ typée, jamais du corps d'une
/// réponse : un serveur « Personnalisé » quelconque peut y renvoyer l'en-tête
/// `Authorization: Bearer <clé>`. Aucun cas ne porte donc de chaîne venue du
/// réseau, seulement des statuts, affichables sans risque. Même découpage que
/// `CloudModelListError` (liste des modèles) et `PerplexityAgentError`, pour
/// que l'utilisateur retrouve les mêmes causes partout.
///
/// `nonisolated` : donnée pure, construite par les mappers `nonisolated static`
/// des providers et comparée hors du main actor dans les tests.
nonisolated enum CloudProviderFailure: Sendable, Equatable {
    /// 401 / 403 : clé refusée, ou sans les droits nécessaires. `nil` quand
    /// l'erreur typée ne donne pas le statut (Claude : `ClaudeError.missingCredential`).
    case apiKeyRejected(statusCode: Int?)
    /// 429. Chez OpenAI, couvre aussi le crédit épuisé (`insufficient_quota`) ;
    /// chez Anthropic, la surcharge 529, que `ClaudeForFoundationModels` range
    /// sous `LanguageModelError.rateLimited`. D'où le message à deux pistes.
    case rateLimited
    /// 413 (requête trop volumineuse), ou contexte trop long signalé par une
    /// erreur typée (`LanguageModelError.contextSizeExceeded`).
    case contextWindowExceeded
    /// 5xx : panne ou surcharge côté fournisseur.
    case serverUnavailable(statusCode: Int)
    /// Aucune réponse HTTP exploitable : délai dépassé ou réseau.
    case unreachable
    /// Tout autre statut d'échec (400, 404, 422…), sans cause plus précise. Le
    /// statut est gardé : il se montre sans risque et aide à diagnostiquer.
    case requestRejected(statusCode: Int)

    /// Classement d'un statut HTTP d'échec. Total : l'appelant ne le donne
    /// qu'hors succès, et tout statut inattendu reste un refus qui garde son code.
    init(statusCode: Int) {
        switch statusCode {
        case 401, 403: self = .apiKeyRejected(statusCode: statusCode)
        case 413: self = .contextWindowExceeded
        case 429: self = .rateLimited
        case 500..<600: self = .serverUnavailable(statusCode: statusCode)
        default: self = .requestRejected(statusCode: statusCode)
        }
    }

    /// Message français fixe et actionnable, affiché par
    /// `ChatViewModel.userFacingMessage(for:)`. `provider` est le nom des
    /// Réglages (catalogue, ou nom saisi pour un fournisseur personnalisé),
    /// jamais un texte du serveur. Le contexte dépassé peut survenir dès le
    /// premier tour (sources longues, texte CJK) : « nouvelle conversation »
    /// n'y suffit pas toujours, d'où l'autre modèle proposé.
    func userFacingMessage(provider: String) -> String {
        switch self {
        case .apiKeyRejected:
            "Clé API refusée par \(provider). Vérifie-la dans les Réglages."
        case .rateLimited:
            "Limite de requêtes atteinte chez \(provider). Réessaie dans un instant, ou vérifie le crédit de ton compte \(provider)."
        case .contextWindowExceeded:
            "La conversation et ses sources sont trop longues pour \(provider). Commence une nouvelle conversation ou choisis un autre modèle dans les Réglages."
        case .serverUnavailable:
            "\(provider) est momentanément indisponible. Réessaie dans un instant."
        case .unreachable:
            "Impossible de joindre \(provider). Vérifie ta connexion et réessaie."
        case .requestRejected(let statusCode):
            "\(provider) a refusé la requête (erreur \(statusCode)). Vérifie le modèle choisi dans les Réglages."
        }
    }

    /// Annulation (tâche Swift, ou requête `URLSession` interrompue) : les
    /// mappers la laissent ressortir INTACTE. Emballée dans un échec, elle
    /// passerait pour une panne auprès de `SearchOrchestrator.isCancellation`,
    /// dont c'est le même critère (`Task.isCancelled` mis à part, que
    /// l'appelant vérifie lui-même).
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
