//
//  ImageRecognitionPreparation.swift
//  Triva
//
//  W4-V : la première lecture d'image d'une app coûte ~40 s sur Mac (mesuré le 2026-11-25 : 42 s à froid, 0,4 s ensuite),
//  le temps que le système prépare le modèle de reconnaissance de Vision. Aucune API officielle ne permet de préparer ce
//  modèle : la seule voie est de faire UNE vraie reconnaissance, sur une image fabriquée, à un moment où personne n'attend.
//  Ici : les contrats et les règles pures (testés) ; `ImageRecognitionReadiness` conduit la préparation.
//

import Foundation

/// Point d'injection de la préparation (tests sans Vision, comme `ImageTextRecognizing`).
nonisolated protocol ImageRecognitionPreparing: Sendable {
    /// Lit une image fabriquée avec la MÊME voie que les vraies lectures (précise), pour que le système prépare le
    /// modèle. Lève `CancellationError` si la tâche est annulée (Vision s'arrête alors aussitôt).
    func prepareRecognition() async throws
}

/// Pourquoi la préparation est remise à plus tard.
nonisolated enum ImageRecognitionDeferralReason: Sendable, Equatable {
    case lowPowerMode
    case deviceHot
}

/// État de l'appareil qui décide d'une préparation de fond (injectable : les tests le pilotent).
nonisolated protocol DeviceConditionsProviding: Sendable {
    var isLowPowerModeEnabled: Bool { get }
    var thermalState: ProcessInfo.ThermalState { get }
}

nonisolated struct SystemDeviceConditions: DeviceConditionsProviding {
    var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

/// Règle : une préparation de fond ne tourne ni en mode économie d'énergie, ni sur un appareil qui n'est plus au frais.
nonisolated enum ImageRecognitionPreparationPolicy {
    /// `.fair` compris : une préparation de ~40 s de calcul n'a rien d'urgent, elle attend le retour au calme
    /// (valeur de produit, à ajuster ici).
    static func deferralReason(
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> ImageRecognitionDeferralReason? {
        if isLowPowerModeEnabled { return .lowPowerMode }
        switch thermalState {
        case .nominal: return nil
        case .fair, .serious, .critical: return .deviceHot
        @unknown default: return .deviceHot
        }
    }
}

/// Mémoire de la préparation réussie. Mesuré en ligne de commande (2026-11-25) : le coût se paie par NOM de programme (une
/// copie renommée est froide ; un programme recompilé ou déplacé sous le même nom reste chaud), pas par version ni par
/// contenu. Pour l'app, la clé exacte du cache (nom de processus ou identifiant de bundle : les deux valent « Triva » à
/// chaque version) n'est PAS vérifiée. La clé du registre comprend pourtant version, build et version du système : relancer
/// la préparation sur un cache déjà chaud coûte ~0,5 s, et cela rattrape un cache purgé par une mise à jour.
nonisolated protocol ImageRecognitionPreparationLedger: Sendable {
    var preparedKey: String? { get }
    func markPrepared(key: String)
}

/// `UserDefaults` est sûr entre threads (documenté par Apple), mais pas marqué `Sendable` dans le SDK.
nonisolated struct UserDefaultsPreparationLedger: ImageRecognitionPreparationLedger, @unchecked Sendable {
    static let defaultsKey = "imageRecognitionPreparedKey"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var preparedKey: String? { defaults.string(forKey: Self.defaultsKey) }
    func markPrepared(key: String) { defaults.set(key, forKey: Self.defaultsKey) }
}

nonisolated enum ImageRecognitionPreparationKey {
    static func make(appVersion: String, appBuild: String, systemBuild: String) -> String {
        "\(appVersion)(\(appBuild))-\(systemBuild)"
    }

    static func current(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        return make(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info["CFBundleVersion"] as? String ?? "?",
            systemBuild: systemBuild()
        )
    }

    /// Numéro de build du système (« 27A123 »), `?` si illisible.
    static func systemBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }
}
