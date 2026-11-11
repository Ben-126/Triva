//
//  PrivateCloudComputeProvider.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import FoundationModels

/// Échec du cloud privé d'Apple qui justifie de répondre sur l'appareil à la place (mission A4).
/// Ne porte AUCUN texte venu du serveur : les `debugDescription` du SDK sont lues côté Apple, et
/// `ChatViewModel.userFacingMessage` afficherait tel quel un type d'erreur qu'il ne connaît pas.
/// Ce type ne sort d'ailleurs jamais d'`AppleIntelligenceFallbackProvider` (voir
/// `AppleIntelligenceFallbackProvider.finalError`).
nonisolated enum PrivateCloudFailure: Error, Sendable, Equatable {
    /// `PrivateCloudComputeLanguageModel.Error.networkFailure` : la doc d'Apple dit de réessayer
    /// sur l'appareil.
    case networkFailure
    /// `quotaLimitReached` : quota quotidien du compte iCloud épuisé pendant l'envoi.
    case quotaReached
    /// `serviceUnavailable` : le service d'Apple ne répond pas.
    case serviceUnavailable
    /// `LanguageModelError.rateLimited` levé par le cloud. Signalé sur les forums développeurs
    /// alors que le quota est intact (non officiel) : sur l'appareil, la limite est autre.
    case rateLimited

    /// Raison de repli correspondante, pour le badge et la suspension du cloud.
    var fallbackReason: AppleModelFallbackReason {
        self == .quotaReached ? .quotaReached : .privateCloudFailed
    }

    /// Correspondance pure erreur du SDK → échec de repli, `nil` pour tout le reste (garde-fous,
    /// refus, contexte…) : ces causes-là tiennent à la DEMANDE, le modèle local les lèverait
    /// aussi, ou pire.
    static func classify(_ error: any Error) -> PrivateCloudFailure? {
        if let cloudError = error as? PrivateCloudComputeLanguageModel.Error {
            switch cloudError {
            case .networkFailure: return .networkFailure
            case .quotaLimitReached: return .quotaReached
            case .serviceUnavailable: return .serviceUnavailable
            // Cas ajouté par un futur SDK : pas de repli sur une cause inconnue.
            @unknown default: return nil
            }
        }
        if let modelError = error as? LanguageModelError, case .rateLimited = modelError {
            return .rateLimited
        }
        return nil
    }
}

/// Génération sur le cloud privé d'Apple (`PrivateCloudComputeLanguageModel`), même interface
/// qu'`AppleIntelligenceProvider` (sur l'appareil). N'est JAMAIS construit si
/// `PrivateCloudComputeEntitlement.isGranted` est faux : sans l'entitlement, le premier envoi
/// fait planter l'app (mesuré, voir ce verrou). Seul `AppleIntelligenceModelCoordinator` le crée,
/// toujours enveloppé dans `AppleIntelligenceFallbackProvider`.
///
/// Pas de `ContextOptions(reasoningLevel:)` : le niveau par défaut du système. Un raisonnement
/// plus poussé allonge l'attente avant le premier mot et consomme plus de quota, pour un gain
/// non mesuré sur une synthèse de sources. À essayer sur appareil réel quand l'entitlement sera là.
struct PrivateCloudComputeProvider: AIGenerating {
    private let model: PrivateCloudComputeLanguageModel

    init(model: PrivateCloudComputeLanguageModel = PrivateCloudComputeLanguageModel()) {
        self.model = model
    }

    func generate(prompt: String) async throws -> String {
        let session = LanguageModelSession(model: model)
        do {
            return try await session.respond(to: prompt).content
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Même contrat que `AppleIntelligenceProvider.streamGenerate` : chaque yield est le texte
    /// CUMULÉ (`Snapshot.content`), pas un delta.
    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let session = LanguageModelSession(model: model)
            let task = Task {
                do {
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Annulation intacte (sinon elle passerait pour un échec, et déclencherait un repli) ;
    /// échec de repli → `PrivateCloudFailure` ; cause typée connue → le cas d'Apple Intelligence
    /// déjà traduit pour l'utilisateur ; le reste → `generationFailed` avec une description FIXE,
    /// jamais `String(describing:)` d'une erreur venue d'un serveur.
    nonisolated static func mapError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let failure = PrivateCloudFailure.classify(error) { return failure }
        if let modelError = error as? LanguageModelError,
           let cause = AppleIntelligenceProvider.generationError(for: modelError) {
            return cause
        }
        return AppleIntelligenceError.generationFailed(description: "privateCloud.unclassified")
    }
}

/// Cloud privé d'abord, appareil en secours, sans erreur visible (mission A4, point 3).
///
/// Ne couvre que l'IMPRÉVISIBLE : hors connexion, quota déjà atteint et cloud indisponible sont
/// tranchés avant l'envoi par `AppleIntelligenceModelRouter`, avec le budget de prompt qui va
/// avec. Ici, le cloud vient d'échouer pendant l'envoi (`PrivateCloudFailure`) : `onFallback`
/// prévient le coordinateur (badge, mise de côté du cloud pour les envois suivants), puis la même
/// demande part sur l'appareil.
///
/// LIMITE ASSUMÉE : le prompt a été construit pour le contexte du cloud (32K tokens). S'il
/// dépasse celui de l'appareil (4K à 8K), le modèle local refuse en « contexte dépassé » ; ce
/// refus ressort en échec générique (`finalError`), et l'envoi suivant, déjà routé sur
/// l'appareil, repart avec le budget de l'appareil. Les petites demandes (classifieur,
/// suggestions, widgets, conversations courtes) passent, elles, sans que rien ne se voie.
///
/// Flux : repli seulement si le cloud échoue AVANT le premier morceau. Après, une partie de la
/// réponse est déjà à l'écran ; la remplacer par une réponse locale différente serait déroutant.
/// L'envoi échoue alors avec un message générique, et le suivant part sur l'appareil.
struct AppleIntelligenceFallbackProvider: AIGenerating {
    let primary: any AIGenerating
    let fallback: any AIGenerating
    let onFallback: @Sendable (PrivateCloudFailure) -> Void

    func generate(prompt: String) async throws -> String {
        do {
            return try await primary.generate(prompt: prompt)
        } catch let failure as PrivateCloudFailure {
            onFallback(failure)
            do {
                return try await fallback.generate(prompt: prompt)
            } catch {
                throw Self.finalError(afterFallback: error)
            }
        }
    }

    func streamGenerate(prompt: String) -> AsyncThrowingStream<String, Error> {
        let primary = primary
        let fallback = fallback
        let onFallback = onFallback
        return AsyncThrowingStream { continuation in
            let task = Task {
                var hasYielded = false
                do {
                    for try await snapshot in primary.streamGenerate(prompt: prompt) {
                        hasYielded = true
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch let failure as PrivateCloudFailure {
                    onFallback(failure)
                    guard !hasYielded else {
                        continuation.finish(throwing: Self.interruptedError)
                        return
                    }
                    await Self.forward(fallback.streamGenerate(prompt: prompt), into: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func forward(
        _ stream: AsyncThrowingStream<String, Error>,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        do {
            for try await snapshot in stream {
                continuation.yield(snapshot)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: finalError(afterFallback: error))
        }
    }

    /// Réponse cloud coupée en plein flux : message générique d'Apple Intelligence (« n'a pas pu
    /// répondre »), description fixe.
    static let interruptedError = AppleIntelligenceError.generationFailed(description: "privateCloud.interrupted")

    /// Erreur du modèle LOCAL après un repli. « Contexte dépassé » vient alors du prompt taillé
    /// pour le cloud, pas de la conversation : son message dédié (« trop longues pour Apple
    /// Intelligence », « choisis un autre moteur ») pousserait à tort à changer de moteur, alors
    /// qu'un nouvel essai suffit (l'envoi suivant est déjà routé sur l'appareil, avec son budget).
    /// D'où l'échec générique d'Apple Intelligence, « n'a pas pu répondre » — dont la seconde
    /// phrase (« si la conversation est longue, commence-en une nouvelle ») reste un conseil
    /// valable mais ne dit pas la cause. Un message dédié demanderait de toucher
    /// `ChatViewModel+ErrorMessages.swift` (hors mission A4) : signalé à Ben. Le reste (garde-fous,
    /// refus, annulation…) ressort tel quel : c'est la vraie réponse du modèle interrogé.
    static func finalError(afterFallback error: any Error) -> any Error {
        if let cause = error as? AppleIntelligenceGenerationError, cause == .contextWindowExceeded {
            return AppleIntelligenceError.generationFailed(description: "privateCloud.fallbackContextExceeded")
        }
        return error
    }
}
