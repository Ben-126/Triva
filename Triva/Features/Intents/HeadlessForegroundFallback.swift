//
//  HeadlessForegroundFallback.swift
//  Triva
//
//  Chantier 2.1 (mission B2) : quand le système refuse de faire tourner le modèle local en arrière-plan (le GPU
//  n'y est pas accordé), « Poser une question à Triva » continue au PREMIER PLAN si le système l'autorise, plutôt
//  que d'échouer. Logique pure.
//

import Foundation

nonisolated enum HeadlessForegroundFallback {
    /// Dit au moment de passer au premier plan (à valider par Ben).
    static let dialog = "Triva s'ouvre pour utiliser le modèle de ton appareil."
    /// Quand le modèle local ne peut tourner ni en arrière-plan ni au premier plan (à valider par Ben).
    static let refusedMessage = "Le modèle de ton appareil ne peut pas tourner en arrière-plan. Ouvre Triva et réessaie."

    /// Le message quand le modèle local ne peut pas démarrer : appareil verrouillé, c'est l'invitation à le déverrouiller
    /// (le premier plan est inaccessible tant qu'il l'est) ; sinon le refus habituel. Logique pure.
    static func refusal(isDeviceLocked: Bool, deviceName: String) -> String {
        isDeviceLocked ? DeviceLock.message(deviceName: deviceName) : refusedMessage
    }

    /// Même chose, d'après l'état de l'appareil à cet instant.
    @MainActor
    static var currentRefusalMessage: String {
        refusal(isDeviceLocked: DeviceLock.isLocked, deviceName: DeviceLock.deviceName)
    }

    /// Faut-il passer au premier plan SANS même essayer en arrière-plan ? Oui pour le modèle local sur iPhone et iPad tant
    /// que l'app n'est pas active : le système refuse alors le GPU (Triva n'a pas l'autorisation « Background GPU
    /// Access », absente d'un compte gratuit et de bien des appareils), et MLX, loin d'échouer, ferait planter l'app
    /// (mission M, plantage du 25/11).
    static func mustStartInForeground(execution: HeadlessExecution, gpuPhase: LocalGPUPhase) -> Bool {
        execution == .backgroundWithGPU && gpuPhase != .active
    }

    /// Faut-il continuer au premier plan après l'échec de `performBackgroundTask` ?
    ///
    /// - Seulement si le GPU était demandé (modèle local sur iPhone/iPad) : c'est la seule raison de ce repli.
    /// - Seulement si le travail n'a PAS commencé : sinon la question est déjà partie (et rangée dans l'historique),
    ///   la relancer ferait un doublon.
    /// - Jamais après une annulation (l'utilisateur ou le système a voulu arrêter).
    static func shouldContinueInForeground(
        execution: HeadlessExecution,
        operationStarted: Bool,
        wasCancelled: Bool,
        canContinueInForeground: Bool
    ) -> Bool {
        execution == .backgroundWithGPU && !operationStarted && !wasCancelled && canContinueInForeground
    }
}
