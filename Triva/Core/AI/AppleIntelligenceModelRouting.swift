//
//  AppleIntelligenceModelRouting.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import FoundationModels

/// Les deux modèles du moteur « Apple Intelligence » (mission A4, décision de Ben du
/// 2026-11-11) : le cloud privé d'Apple (Private Cloud Compute, `PrivateCloudComputeLanguageModel`,
/// contexte de 32K tokens, réseau obligatoire, quota quotidien par compte iCloud) et le modèle
/// sur l'appareil (`SystemLanguageModel.default`, contexte de 4K à 8K tokens, hors connexion,
/// illimité). Les deux suivent le protocole `LanguageModel` du SDK OS27 : une même
/// `LanguageModelSession` sait parler à l'un ou à l'autre.
///
/// `rawValue` : la valeur persistée dans `UserDefaults` (voir `AppleIntelligenceModelPreference`).
/// Ne jamais renommer un cas sans migrer la clé : une valeur illisible retomberait sur le défaut.
nonisolated enum AppleIntelligenceModelKind: String, Sendable, CaseIterable, Codable {
    case privateCloud
    case onDevice

    /// Défaut voulu par Ben : le cloud privé quand il est disponible. Le routeur retombe de
    /// lui-même sur l'appareil quand il ne l'est pas : ce défaut n'engage donc rien tant que
    /// l'entitlement n'est pas accordé.
    static let defaultPreference: AppleIntelligenceModelKind = .privateCloud
}

/// État du cloud privé tel que l'app peut le lire AVANT d'envoyer quoi que ce soit, sans réseau :
/// disponibilité et quota sont des propriétés synchrones du SDK.
nonisolated enum PrivateCloudStatus: Sendable, Equatable {
    /// Utilisable maintenant.
    case available
    /// Appareil et système prêts, mais le quota du jour est épuisé (`quotaUsage.isLimitReached`).
    /// Le cloud reste PROPOSÉ (le choix reste affiché) : il revient tout seul à la remise à zéro.
    case quotaReached
    /// Pas proposé du tout : entitlement absent, appareil non éligible, système pas prêt. Dans ce
    /// cas, AUCUNE mention du cloud n'apparaît dans l'app (contrainte de Ben du 2026-11-11).
    case unavailable

    /// Le choix « Cloud privé / Sur l'appareil » et toute mention du cloud ne s'affichent que si
    /// ce cas est vrai.
    var isOffered: Bool { self != .unavailable }

    /// Correspondance pure SDK → état applicatif, testable sans appareil. `systemNotReady` et un
    /// futur cas inconnu : non proposé, le repli le plus prudent (rien ne part, rien ne s'affiche).
    static func from(
        availability: PrivateCloudComputeLanguageModel.Availability,
        isLimitReached: Bool
    ) -> PrivateCloudStatus {
        switch availability {
        case .available:
            isLimitReached ? .quotaReached : .available
        case .unavailable:
            .unavailable
        }
    }
}

/// Le verrou de l'entitlement `com.apple.developer.private-cloud-compute`.
///
/// POURQUOI UNE CONSTANTE ET PAS `availability` : mesuré le 2026-11-11 sur le Mac de Ben (macOS
/// 27.2, hôte de tests, SANS l'entitlement), `PrivateCloudComputeLanguageModel().availability`
/// vaut `.available`, `quotaUsage` `.belowLimit` — et le premier `respond(to:)` FAIT PLANTER
/// l'app (`SIGTRAP`, `_assertionFailure` à l'intérieur de FoundationModels). La disponibilité
/// décrit l'appareil, pas le droit de l'app : elle ne protège de rien. L'API qui lit ses propres
/// entitlements (`SecTaskCopyValueForEntitlement`) n'existe pas dans le SDK iOS public. Reste un
/// verrou explicite, posé en même temps que l'entitlement.
///
/// À FAIRE LE JOUR OÙ APPLE ACCORDE L'ENTITLEMENT (et SEULEMENT ce jour-là, sinon plantage au
/// premier envoi) : ajouter l'entitlement au projet (voir le rapport de la mission A4), puis
/// passer cette constante à `true`. Tant qu'elle vaut `false`, l'app ne construit JAMAIS de
/// `PrivateCloudComputeLanguageModel` : Triva reste exactement comme avant A4.
nonisolated enum PrivateCloudComputeEntitlement {
    static let isGranted = false
}

/// Lecture de l'état du cloud privé, injectable : les tests et les aperçus décrivent les deux
/// cas (proposé ou non) sans dépendre de l'entitlement ni du compte iCloud de la machine.
nonisolated protocol PrivateCloudAvailabilityProbing: Sendable {
    func currentStatus() -> PrivateCloudStatus
}

/// Lecture réelle, verrouillée par `PrivateCloudComputeEntitlement` : sans lui, le modèle n'est
/// même pas construit (voir la mesure décrite sur le verrou).
nonisolated struct SystemPrivateCloudProbe: PrivateCloudAvailabilityProbing {
    let isEntitlementGranted: Bool

    init(isEntitlementGranted: Bool = PrivateCloudComputeEntitlement.isGranted) {
        self.isEntitlementGranted = isEntitlementGranted
    }

    func currentStatus() -> PrivateCloudStatus {
        guard isEntitlementGranted else { return .unavailable }
        let model = PrivateCloudComputeLanguageModel()
        return PrivateCloudStatus.from(
            availability: model.availability,
            isLimitReached: model.quotaUsage.isLimitReached
        )
    }
}

/// État figé, pour les aperçus et les tests (même rôle que `FixedConnectivitySource`).
nonisolated struct FixedPrivateCloudProbe: PrivateCloudAvailabilityProbing {
    let status: PrivateCloudStatus

    func currentStatus() -> PrivateCloudStatus { status }
}

/// Pourquoi le moteur répond sur l'appareil alors que le cloud privé est proposé et préféré.
/// Seul `.quotaReached` est montré à l'utilisateur (mention discrète sous le badge, voulue par
/// Ben) : les autres replis sont silencieux, le badge suffit à dire la vérité.
nonisolated enum AppleModelFallbackReason: Sendable, Equatable {
    /// Appareil hors connexion (`ConnectivityMonitor`, tâche 1.16).
    case offline
    /// Quota du jour atteint (lu avant l'envoi, ou `quotaLimitReached` levé pendant).
    case quotaReached
    /// Échec réseau ou service du cloud privé pendant un envoi : le cloud est mis de côté un
    /// moment (`AppleIntelligenceModelRouter.suspensionDuration`).
    case privateCloudFailed
}

/// Le modèle que le PROCHAIN envoi utilisera, et pourquoi. Source unique du badge et du budget
/// de prompt : les deux dérivent de la même valeur, ils ne peuvent pas se contredire.
nonisolated struct AppleModelRoute: Sendable, Equatable {
    let kind: AppleIntelligenceModelKind
    /// `nil` : modèle choisi, ou cloud non proposé (l'app est alors exactement comme avant A4).
    let fallback: AppleModelFallbackReason?

    static let onDevice = AppleModelRoute(kind: .onDevice, fallback: nil)
    static let privateCloud = AppleModelRoute(kind: .privateCloud, fallback: nil)
}

/// Aiguillage pur et déterministe cloud privé / appareil, testé sans réseau ni appareil.
///
/// Toutes les causes de repli connues AVANT l'envoi sont tranchées ici, au moment de résoudre le
/// provider, et non pendant la génération : le budget de prompt est choisi juste après la
/// résolution (`ChatViewModel` : `resolveProvider` puis `resolvePipelineConfiguration`, sans
/// suspension). Un repli décidé après coup enverrait au modèle de 4K tokens un prompt taillé
/// pour 32K, qui échouerait en « contexte dépassé ». Le repli pendant la génération
/// (`AppleIntelligenceFallbackProvider`) ne couvre que l'imprévisible.
nonisolated enum AppleIntelligenceModelRouter {
    /// Après un échec réseau ou service du cloud en cours d'envoi, les envois suivants restent sur
    /// l'appareil pendant ce délai. Sans lui, `availability` (qui ne suit pas le réseau, voir la
    /// mesure de `PrivateCloudComputeEntitlement`) renverrait chaque envoi vers un cloud qui
    /// échoue, et chacun paierait l'échec avant de retomber. Cinq minutes : assez pour qu'une
    /// coupure passagère soit passée, assez court pour ne pas priver longtemps du cloud.
    static let suspensionDuration: TimeInterval = 5 * 60

    static func route(
        preference: AppleIntelligenceModelKind?,
        status: PrivateCloudStatus,
        isOffline: Bool,
        isPrivateCloudSuspended: Bool = false
    ) -> AppleModelRoute {
        guard status.isOffered else { return .onDevice }
        guard (preference ?? .defaultPreference) == .privateCloud else { return .onDevice }
        if isOffline {
            return AppleModelRoute(kind: .onDevice, fallback: .offline)
        }
        if status == .quotaReached {
            return AppleModelRoute(kind: .onDevice, fallback: .quotaReached)
        }
        if isPrivateCloudSuspended {
            return AppleModelRoute(kind: .onDevice, fallback: .privateCloudFailed)
        }
        return .privateCloud
    }
}

/// Préférence persistée de l'utilisateur. `nil` = jamais choisie : le défaut
/// (`AppleIntelligenceModelKind.defaultPreference`) s'applique. Pas de donnée sensible :
/// `UserDefaults`, comme `AIEngineSettingsStore`. `UserDefaults` injectable : un test ne doit
/// JAMAIS écrire dans les préférences réelles du Mac (incident de la mission Q2).
nonisolated struct AppleIntelligenceModelPreference {
    static let storageKey = "ai.apple.preferredModel"

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func read() -> AppleIntelligenceModelKind? {
        userDefaults.string(forKey: Self.storageKey).flatMap(AppleIntelligenceModelKind.init(rawValue:))
    }

    func write(_ kind: AppleIntelligenceModelKind) {
        userDefaults.set(kind.rawValue, forKey: Self.storageKey)
    }
}
