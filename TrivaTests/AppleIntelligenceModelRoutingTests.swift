//
//  AppleIntelligenceModelRoutingTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import FoundationModels
import Testing
@testable import Triva

/// Aiguillage cloud privé d'Apple / appareil (mission A4) : logique pure, sans réseau ni
/// entitlement. Aucun test ne construit de vrai `PrivateCloudComputeLanguageModel` pour générer :
/// sans l'entitlement, le premier envoi fait planter l'app (mesuré le 2026-11-11).
@MainActor
@Suite("AppleIntelligenceModelRouter")
struct AppleIntelligenceModelRouterTests {
    @Test("Cloud non proposé : sur l'appareil, sans raison de repli, quels que soient préférence et réseau")
    func unavailableIsExactlyTheOldBehaviour() {
        for preference in [nil, AppleIntelligenceModelKind.privateCloud, .onDevice] {
            for isOffline in [false, true] {
                let route = AppleIntelligenceModelRouter.route(preference: preference, status: .unavailable, isOffline: isOffline)
                #expect(route == .onDevice)
            }
        }
    }

    @Test("Cloud disponible, aucun choix fait : le cloud privé (défaut voulu par Ben)")
    func defaultIsPrivateCloud() {
        #expect(AppleIntelligenceModelRouter.route(preference: nil, status: .available, isOffline: false) == .privateCloud)
        #expect(AppleIntelligenceModelKind.defaultPreference == .privateCloud)
    }

    @Test("Choix « sur l'appareil » : respecté, sans raison de repli")
    func userChoiceOnDevice() {
        #expect(AppleIntelligenceModelRouter.route(preference: .onDevice, status: .available, isOffline: false) == .onDevice)
    }

    @Test("Hors connexion : sur l'appareil, raison « hors connexion », même quota atteint")
    func offlineFallsBack() {
        let expected = AppleModelRoute(kind: .onDevice, fallback: .offline)
        #expect(AppleIntelligenceModelRouter.route(preference: .privateCloud, status: .available, isOffline: true) == expected)
        #expect(AppleIntelligenceModelRouter.route(preference: nil, status: .quotaReached, isOffline: true) == expected)
    }

    @Test("Quota atteint : sur l'appareil, raison « quota »")
    func quotaFallsBack() {
        #expect(
            AppleIntelligenceModelRouter.route(preference: .privateCloud, status: .quotaReached, isOffline: false)
                == AppleModelRoute(kind: .onDevice, fallback: .quotaReached)
        )
    }

    @Test("Cloud mis de côté après un échec : appareil, raison « échec du cloud »")
    func suspension() {
        #expect(
            AppleIntelligenceModelRouter.route(preference: nil, status: .available, isOffline: false, isPrivateCloudSuspended: true)
                == AppleModelRoute(kind: .onDevice, fallback: .privateCloudFailed)
        )
        #expect(
            AppleIntelligenceModelRouter.route(preference: nil, status: .available, isOffline: false, isPrivateCloudSuspended: false)
                == .privateCloud
        )
    }

    @Test("État du SDK → état applicatif")
    func statusMapping() {
        #expect(PrivateCloudStatus.from(availability: .available, isLimitReached: false) == .available)
        #expect(PrivateCloudStatus.from(availability: .available, isLimitReached: true) == .quotaReached)
        #expect(PrivateCloudStatus.from(availability: .unavailable(.deviceNotEligible), isLimitReached: false) == .unavailable)
        #expect(PrivateCloudStatus.from(availability: .unavailable(.systemNotReady), isLimitReached: true) == .unavailable)
        #expect(PrivateCloudStatus.quotaReached.isOffered)
        #expect(!PrivateCloudStatus.unavailable.isOffered)
    }

    @Test("Sans l'entitlement, la sonde réelle dit « non proposé » sans construire le modèle")
    func probeWithoutEntitlement() {
        #expect(SystemPrivateCloudProbe(isEntitlementGranted: false).currentStatus() == .unavailable)
    }
}

@MainActor
@Suite("Échecs du cloud privé : repli et messages sans texte de serveur")
struct PrivateCloudFailureTests {
    private struct ServerError: Error, CustomStringConvertible {
        var description: String { "Authorization: Bearer SECRET-SERVEUR" }
    }

    @Test("Erreurs du SDK qui justifient un repli")
    func classifiesFallbackErrors() {
        typealias CloudError = PrivateCloudComputeLanguageModel.Error
        #expect(PrivateCloudFailure.classify(CloudError.networkFailure(.init(debugDescription: "x"))) == .networkFailure)
        #expect(PrivateCloudFailure.classify(CloudError.quotaLimitReached(.init(debugDescription: "x"))) == .quotaReached)
        #expect(PrivateCloudFailure.classify(CloudError.serviceUnavailable(.init(debugDescription: "x"))) == .serviceUnavailable)
        #expect(PrivateCloudFailure.classify(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "x"))) == .rateLimited)
        #expect(PrivateCloudFailure.classify(CancellationError()) == nil)
        #expect(PrivateCloudFailure.classify(ServerError()) == nil)
        #expect(PrivateCloudFailure.quotaReached.fallbackReason == .quotaReached)
        #expect(PrivateCloudFailure.networkFailure.fallbackReason == .privateCloudFailed)
    }

    @Test("Annulation intacte, erreur inconnue → description FIXE, jamais le texte reçu")
    func mapErrorNeverLeaksServerText() {
        #expect(PrivateCloudComputeProvider.mapError(CancellationError()) is CancellationError)
        let mapped = PrivateCloudComputeProvider.mapError(ServerError())
        #expect(mapped as? AppleIntelligenceError == .generationFailed(description: "privateCloud.unclassified"))
        #expect(!String(describing: mapped).contains("SECRET"))
        let quota = PrivateCloudComputeProvider.mapError(
            PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(debugDescription: "SECRET"))
        )
        #expect(quota as? PrivateCloudFailure == .quotaReached)
    }

    @Test("Contexte dépassé APRÈS un repli → échec générique ; autre erreur locale → telle quelle")
    func finalErrorAfterFallback() {
        let context = AppleIntelligenceFallbackProvider.finalError(afterFallback: AppleIntelligenceGenerationError.contextWindowExceeded)
        #expect(context as? AppleIntelligenceError == .generationFailed(description: "privateCloud.fallbackContextExceeded"))
        let guardrail = AppleIntelligenceFallbackProvider.finalError(afterFallback: AppleIntelligenceGenerationError.guardrailViolation)
        #expect(guardrail as? AppleIntelligenceGenerationError == .guardrailViolation)
    }
}

@MainActor
@Suite("Badge du moteur Apple selon le modèle retenu")
struct AppleIntelligenceBadgeTests {
    @Test("Sans route (cloud non proposé) ou route appareil : le badge d'avant A4, mot pour mot")
    func onDeviceBadgeUnchanged() {
        let legacy = AIEngineOption.appleIntelligence.privacyBadge
        #expect(legacy.text == "Apple Intelligence · Sur l'appareil")
        #expect(legacy.caption == "Aucune IA cloud utilisée")
        for route in [nil, AppleModelRoute.onDevice, AppleModelRoute(kind: .onDevice, fallback: .offline),
                      AppleModelRoute(kind: .onDevice, fallback: .privateCloudFailed)] {
            let badge = AIEngineOption.appleIntelligence.privacyBadge(appleRoute: route)
            #expect(badge.text == legacy.text && badge.caption == legacy.caption && badge.icon == legacy.icon)
        }
    }

    @Test("Cloud privé : jamais « Sur l'appareil » ni « Aucune IA cloud »")
    func privateCloudBadgeTellsTheTruth() {
        let badge = AIEngineOption.appleIntelligence.privacyBadge(appleRoute: .privateCloud)
        #expect(badge.text == "Apple · Cloud privé")
        #expect(badge.icon == "lock.icloud.fill")
        #expect(!badge.text.contains("Sur l'appareil"))
        #expect(!badge.caption.contains("Aucune IA cloud"))
        #expect(badge.caption.contains("Apple"))
    }

    @Test("Quota atteint : badge appareil, mention discrète du repli")
    func quotaMention() {
        let badge = AIEngineOption.appleIntelligence.privacyBadge(appleRoute: AppleModelRoute(kind: .onDevice, fallback: .quotaReached))
        #expect(badge.text == "Apple Intelligence · Sur l'appareil")
        #expect(badge.caption == "Limite du cloud privé atteinte : réponses sur l'appareil")
    }

    @Test("Autres moteurs : la route Apple est ignorée")
    func otherEnginesIgnoreRoute() {
        for engine in [AIEngineOption.mlxLocal, .cloudBYOK] {
            let badge = engine.privacyBadge(appleRoute: .privateCloud)
            #expect(badge.text == engine.privacyBadge.text && badge.caption == engine.privacyBadge.caption)
        }
    }

    @Test("Textes du choix : courts, sans « IA »")
    func choiceCopy() {
        let texts = AppleIntelligenceModelKind.allCases.flatMap {
            [AppleIntelligenceModelCopy.title(for: $0), AppleIntelligenceModelCopy.detail(for: $0)]
        } + [AppleIntelligenceModelCopy.comparison, AppleIntelligenceModelCopy.fallbackNote]
        for text in texts {
            #expect(!text.contains("IA"))
            #expect(text.count <= 140)
        }
    }
}
