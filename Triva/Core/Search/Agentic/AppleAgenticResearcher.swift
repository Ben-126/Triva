//
//  AppleAgenticResearcher.swift
//  Triva
//
//  Created by ben podrojsky on 26/11/2026.
//

import Foundation
import FoundationModels

/// Enquêteur Apple Intelligence (spec 2.4 §2.5) : une session `LanguageModelSession` sur
/// `ResearchInvestigatorProfile`, sous le délai du mode (`AgenticResearchRunner`). Ne reçoit à la
/// construction que le modèle : tout ce qui dépend de l'envoi arrive dans `AgenticResearchRequest`.
nonisolated struct AppleAgenticResearcher: AgenticResearching {
    /// Échec du cloud privé pendant l'enquête : prévient le coordinateur (badge, mise de côté du cloud),
    /// comme `AppleIntelligenceFallbackProvider`. `nil` pour le modèle de l'appareil.
    typealias PrivateCloudFailureHandler = @MainActor @Sendable (PrivateCloudFailure) -> Void

    let model: any LanguageModel
    let sampling: GenerationOptions.SamplingMode?
    let onPrivateCloudFailure: PrivateCloudFailureHandler?

    /// `sampling` : `.greedy` par défaut (décision M3, réversible) : une enquête reproductible, ce que
    /// demande aussi le banc de comparaison (M4). Le rédacteur garde ses propres réglages.
    init(
        model: any LanguageModel = SystemLanguageModel.default,
        sampling: GenerationOptions.SamplingMode? = .greedy,
        onPrivateCloudFailure: PrivateCloudFailureHandler? = nil
    ) {
        self.model = model
        self.sampling = sampling
        self.onPrivateCloudFailure = onPrivateCloudFailure
    }

    @concurrent
    func investigate(_ request: AgenticResearchRequest) async throws -> AgenticResearchOutcome {
        let ledger = ResearchLedger(budget: request.budget, trustedDomainsOnly: request.trustedDomainsOnly, seeded: request.seeded)
        let prompt = ResearchInvestigatorPrompt.prompt(
            question: request.question,
            searchQuery: request.searchQuery,
            seeded: ledger.snapshot.seededEntries,
            today: request.today
        )
        let (model, sampling) = (self.model, self.sampling)
        let usage = AgenticUsageRecorder()
        do {
            return try await AgenticResearchRunner.run(ledger: ledger, timeout: request.budget.timeout, clock: ContinuousClock(), usage: usage) {
                let profile = ResearchInvestigatorProfile(
                    ledger: ledger,
                    model: model,
                    sampling: sampling,
                    search: request.search,
                    scrape: request.scrape,
                    focusQuery: request.searchQuery
                )
                let session = LanguageModelSession(profile: profile)
                // Aussi quand `respond` lève (sentinelle de fin, plafond) ou est annulé (délai) : l'usage de la session
                // est cumulatif, on garde ce qui a été consommé jusque-là (F3).
                defer { usage.record(Self.tokenUsage(of: session.usage)) }
                _ = try await session.respond(to: prompt)
            }
        } catch let failure as AgenticResearchFailure {
            if let onPrivateCloudFailure, let cloudFailure = Self.privateCloudFailure(for: failure.reason) {
                await onPrivateCloudFailure(cloudFailure)
            }
            throw failure
        }
    }

    /// Les quatre compteurs de `LanguageModelSession.Usage` (doc Apple : `input.totalTokenCount`, `input.cachedTokenCount`,
    /// `output.totalTokenCount`, `output.reasoningTokenCount`).
    static func tokenUsage(of usage: LanguageModelSession.Usage) -> AgenticTokenUsage {
        AgenticTokenUsage(
            inputTokens: usage.input.totalTokenCount,
            cachedInputTokens: usage.input.cachedTokenCount,
            outputTokens: usage.output.totalTokenCount,
            reasoningTokens: usage.output.reasoningTokenCount
        )
    }

    /// Échec à signaler au coordinateur quand le modèle est le cloud privé. `rateLimited` : le cloud le lève
    /// en `LanguageModelError` (lu comme tel par le runner), `PrivateCloudFailure.classify` en fait un échec du cloud.
    static func privateCloudFailure(for reason: AgenticFallbackReason) -> PrivateCloudFailure? {
        switch reason {
        case .privateCloud(let failure): failure
        case .rateLimited: .rateLimited
        default: nil
        }
    }
}

/// Choix du modèle de l'enquêteur pour UN envoi (spec 2.4 §2.5) : la route du MÊME envoi
/// (`AppleIntelligenceModelCoordinator.lastSendingRoute`, posée par `providerForSending`).
///
/// Le cloud privé n'est construit QUE si l'entitlement est accordé : `PrivateCloudComputeLanguageModel`
/// fait planter l'app sans lui (mesure de la mission A4). Piège : `-debug.simulatePrivateCloud YES` donne une
/// route `.privateCloud` SANS entitlement. Dans ce cas, l'enquêteur reste sur l'appareil (décision M3,
/// réversible : le rédacteur, lui, suit son propre repli simulé).
nonisolated enum AgenticResearcherFactory {
    nonisolated enum ModelChoice: Sendable, Equatable {
        case onDevice
        case privateCloud
    }

    static func modelChoice(route: AppleModelRoute, isEntitlementGranted: Bool) -> ModelChoice {
        route.kind == .privateCloud && isEntitlementGranted ? .privateCloud : .onDevice
    }

    /// `makePrivateCloudModel` : injecté pour que les tests prouvent qu'il n'est jamais appelé sans entitlement.
    static func researcher(
        route: AppleModelRoute,
        isEntitlementGranted: Bool = PrivateCloudComputeEntitlement.isGranted,
        makePrivateCloudModel: () -> any LanguageModel = { PrivateCloudComputeLanguageModel() },
        onPrivateCloudFailure: AppleAgenticResearcher.PrivateCloudFailureHandler?
    ) -> AppleAgenticResearcher {
        switch modelChoice(route: route, isEntitlementGranted: isEntitlementGranted) {
        case .onDevice:
            AppleAgenticResearcher(model: SystemLanguageModel.default)
        case .privateCloud:
            AppleAgenticResearcher(model: makePrivateCloudModel(), onPrivateCloudFailure: onPrivateCloudFailure)
        }
    }
}
