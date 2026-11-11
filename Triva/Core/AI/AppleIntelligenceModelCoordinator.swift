//
//  AppleIntelligenceModelCoordinator.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Observation

/// État partagé du choix « cloud privé d'Apple / sur l'appareil » du moteur Apple Intelligence
/// (mission A4) : préférence de l'utilisateur, état du cloud lu sur le système, mise de côté
/// après un échec, et modèle retenu pour l'envoi en cours.
///
/// **Une seule instance pour toute l'app** (`shared`), comme `ConnectivityMonitor.shared` : la
/// préférence est relue de `UserDefaults` à la construction seulement, et deux instances
/// divergeraient dès que l'une écrit — exactement la cause du bug 10 (voir
/// `AIEngineSettingsStore`). L'écran de choix du moteur, les Réglages et chaque `SearchSession`
/// observent donc la même valeur : un changement dans les Réglages se voit aussitôt dans le
/// badge de la Recherche, dans toutes les fenêtres. Les échecs du cloud (réseau, quota) sont des
/// faits de l'appareil, pas d'une fenêtre : leur mise de côté est partagée aussi.
///
/// Sous les tests unitaires, `shared` est figé sur « cloud non proposé » : un test qui ne
/// l'injecte pas garde le comportement d'avant A4, même le jour où l'entitlement sera accordé.
///
/// `@MainActor` (isolation par défaut, implicite) : état observé par les vues. Tout le travail
/// lourd (la génération) se fait dans les providers ; ici, uniquement des lectures synchrones.
@Observable
final class AppleIntelligenceModelCoordinator {
    static let shared = makeShared()

    private static func makeShared() -> AppleIntelligenceModelCoordinator {
        if TrivaTestHost.isHostingUnitTests() {
            return AppleIntelligenceModelCoordinator(probe: FixedPrivateCloudProbe(status: .unavailable))
        }
        #if DEBUG
        // Argument de lancement `-debug.simulatePrivateCloud YES` (débogage seulement) : le cloud
        // est PROPOSÉ, pour voir le choix et le badge « Apple · Cloud privé » sans l'entitlement.
        // Le « cloud » simulé échoue à chaque envoi (`SimulatedPrivateCloudOutage`) : l'envoi
        // exerce le vrai repli sur l'appareil, sans jamais construire de
        // `PrivateCloudComputeLanguageModel` (plantage sans l'entitlement). Argument de lancement
        // = domaine volatil de `UserDefaults`, rien n'est persisté.
        if UserDefaults.standard.bool(forKey: "debug.simulatePrivateCloud") {
            return AppleIntelligenceModelCoordinator(
                probe: FixedPrivateCloudProbe(status: .available),
                makePrivateCloudProvider: { SimulatedPrivateCloudOutage() }
            )
        }
        #endif
        return AppleIntelligenceModelCoordinator(probe: SystemPrivateCloudProbe())
    }

    /// État du cloud au dernier relevé (`refreshStatus()`). Relevé à l'affichage des écrans qui en
    /// dépendent et à chaque envoi, jamais à chaque rendu.
    private(set) var status: PrivateCloudStatus

    /// Choix explicite de l'utilisateur, `nil` tant qu'il n'a rien choisi (défaut :
    /// `AppleIntelligenceModelKind.defaultPreference`). Écrit dans `UserDefaults` à chaque
    /// changement.
    var preference: AppleIntelligenceModelKind? {
        didSet {
            if let preference { preferenceStore.write(preference) }
        }
    }

    /// Préférence effective, pour un sélecteur qui doit toujours montrer une option cochée.
    var effectivePreference: AppleIntelligenceModelKind {
        get { preference ?? .defaultPreference }
        set { preference = newValue }
    }

    /// Fin de la mise de côté du cloud après un échec en cours d'envoi, `nil` sinon. Le badge lit
    /// sa PRÉSENCE, jamais l'heure : l'échéance passée ne change rien à l'écran tant qu'un relevé
    /// (`refreshStatus()`) ne l'a pas levée, et ce relevé ne profite qu'à l'envoi SUIVANT (voir
    /// `providerForSending`).
    private(set) var suspendedUntil: Date?
    /// Modèle retenu par le DERNIER `providerForSending` : le budget de prompt de cet envoi en
    /// dérive (`pipelineConfigurationForSending()`). `ChatViewModel` lit le budget juste après le
    /// provider, sans suspension entre les deux, sur le main actor : deux fenêtres ne peuvent pas
    /// s'intercaler entre ces deux lectures.
    private(set) var lastSendingRoute: AppleModelRoute = .onDevice

    @ObservationIgnored private let probe: any PrivateCloudAvailabilityProbing
    @ObservationIgnored private let preferenceStore: AppleIntelligenceModelPreference
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Construction du provider cloud, injectable : un test ne doit jamais construire un vrai
    /// `PrivateCloudComputeLanguageModel` (plantage sans l'entitlement).
    @ObservationIgnored private let makePrivateCloudProvider: () -> any AIGenerating

    init(
        probe: any PrivateCloudAvailabilityProbing,
        preferenceStore: AppleIntelligenceModelPreference = AppleIntelligenceModelPreference(),
        now: @escaping @Sendable () -> Date = { Date() },
        makePrivateCloudProvider: @escaping () -> any AIGenerating = { PrivateCloudComputeProvider() }
    ) {
        self.probe = probe
        self.preferenceStore = preferenceStore
        self.now = now
        self.makePrivateCloudProvider = makePrivateCloudProvider
        self.status = probe.currentStatus()
        self.preference = preferenceStore.read()
    }

    /// Le choix et toute mention du cloud ne s'affichent que si c'est vrai.
    var isPrivateCloudOffered: Bool { status.isOffered }

    /// Relève l'état du cloud et lève une mise de côté échue. Deux changements OBSERVÉS : le badge
    /// les montre aussitôt.
    func refreshStatus() {
        let current = probe.currentStatus()
        if current != status { status = current }
        if let suspendedUntil, now() >= suspendedUntil { self.suspendedUntil = nil }
    }

    /// Modèle que le prochain envoi utilisera, pour le badge. Calculé UNIQUEMENT sur un état
    /// observé (préférence, état du cloud, mise de côté, connexion) : sans horloge, une valeur
    /// affichée ne peut pas devenir fausse sans que l'écran se redessine.
    func displayedRoute(isOffline: Bool) -> AppleModelRoute {
        AppleIntelligenceModelRouter.route(
            preference: preference,
            status: status,
            isOffline: isOffline,
            isPrivateCloudSuspended: suspendedUntil != nil
        )
    }

    /// Provider d'un envoi Apple Intelligence. `local` : le provider sur l'appareil déjà résolu
    /// (et vérifié disponible) par `ActiveAIProviderResolver`. Sur l'appareil, il est rendu tel
    /// quel : sans cloud proposé, l'envoi est exactement celui d'avant A4.
    ///
    /// RÈGLE : un envoi ne part vers le cloud que si l'état que le badge affichait déjà disait
    /// « cloud ». Le relevé fait ici peut RESTREINDRE l'envoi en cours (cloud devenu indisponible,
    /// quota atteint : on passe sur l'appareil), jamais l'ÉLARGIR (quota revenu, mise de côté
    /// échue) : ce changement-là redessine le badge et ne vaut qu'à partir de l'envoi suivant.
    /// Sans cette règle, le badge dirait encore « Sur l'appareil · Aucune IA cloud utilisée » au
    /// moment où la question part chez Apple.
    func providerForSending(local: any AIGenerating, isOffline: Bool) -> any AIGenerating {
        let shown = displayedRoute(isOffline: isOffline)
        refreshStatus()
        let fresh = displayedRoute(isOffline: isOffline)
        let route = fresh.kind == .onDevice ? fresh : shown
        lastSendingRoute = route
        guard route.kind == .privateCloud else { return local }
        return AppleIntelligenceFallbackProvider(
            primary: makePrivateCloudProvider(),
            fallback: local,
            onFallback: { [weak self] failure in
                Task { @MainActor in self?.recordFailure(failure) }
            }
        )
    }

    /// Budget du modèle retenu pour l'envoi en cours (voir `lastSendingRoute`).
    func pipelineConfigurationForSending() -> SearchPipelineConfiguration {
        lastSendingRoute.kind == .privateCloud ? .applePrivateCloud : .appleIntelligence
    }

    /// Échec du cloud pendant un envoi : cloud mis de côté pendant
    /// `AppleIntelligenceModelRouter.suspensionDuration` ; quota, en plus, état « quota atteint »
    /// (mention sous le badge) jusqu'au prochain relevé qui dira si le quota est revenu.
    func recordFailure(_ failure: PrivateCloudFailure) {
        lastSendingRoute = AppleModelRoute(kind: .onDevice, fallback: failure.fallbackReason)
        // Mise de côté dans TOUS les cas, quota compris : le relevé suivant peut encore dire
        // « sous la limite » (valeur du système en retard sur le serveur), et sans elle chaque
        // envoi repasserait par un cloud qui refuse.
        suspendedUntil = now().addingTimeInterval(AppleIntelligenceModelRouter.suspensionDuration)
        if failure == .quotaReached {
            status = .quotaReached
        }
    }
}

#if DEBUG
/// « Cloud » de `-debug.simulatePrivateCloud` : le service d'Apple ne répond jamais.
private struct SimulatedPrivateCloudOutage: AIGenerating {
    func generate(prompt: String) async throws -> String {
        throw PrivateCloudFailure.serviceUnavailable
    }
}
#endif

extension SearchPipelineConfiguration {
    /// Cloud privé d'Apple : contexte de 32K tokens, contre 4K à 8K sur l'appareil. Les budgets du
    /// cloud BYOK (`.cloud` : consignes complètes, 8 messages × 2 000 caractères, 8 000 caractères
    /// de pages) tiennent largement dedans (~30 000 caractères au pire, ~8K tokens en français),
    /// avec de la marge pour le CJK et la réponse. Consignes complètes (`.full`) : le mode Fiable
    /// (A1) y a sa version longue, déjà éprouvée avec le cloud BYOK ; le rappel court de A3
    /// (`.concise`) reste celui du modèle sur l'appareil, inchangé.
    nonisolated static let applePrivateCloud = SearchPipelineConfiguration.cloud
}
