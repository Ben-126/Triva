//
//  SearchSession+LocalGPU.swift
//  Triva
//
//  Mission M (25/11) : voir `LocalGPUAccessMonitor`.
//

import Foundation

extension SearchSession: LocalGenerationStopping {
    /// L'app est en arrière-plan et le GPU au repos : la réponse en cours (affichée ou d'une autre conversation) s'arrête,
    /// son début est gardé. Enregistré seulement par les sessions du modèle local.
    func stopLocalGenerationInBackground() async {
        await chatViewModel?.stopBecauseAppLeftForeground(timeout: .seconds(3))
    }

    /// Retour au premier plan, arrêt fini (F3) : la réponse coupée par l'arrière-plan reprend toute seule.
    func resumeLocalGenerationAfterBackground() {
        chatViewModel?.resumeAfterBackgroundInterruption()
    }
}
