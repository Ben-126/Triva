//
//  PresentationDismissal.swift
//  Triva
//
//  Mission X2 (R2-11) : une route du système (widget, Siri, Spotlight, partage) ferme ce que la fenêtre montre par-dessus
//  son contenu, au lieu de s'appliquer dessous.
//

import Foundation
import Observation
import SwiftUI

/// Signal de fermeture des présentations LOCALES à un écran (Coup d'œil sur une pièce jointe ou une source…), que le
/// coordinateur ne détient pas. Détenu par `TrivaRootCoordinator` (une instance par fenêtre) et transmis par
/// l'environnement : chaque présentation locale s'abonne par `dismissesOnSystemRoute` et se referme quand le compteur avance.
@Observable
final class PresentationDismissal {
    /// Avance à chaque fermeture demandée (jamais à la lecture) : déclencheur des `onChange`.
    private(set) var epoch = 0

    func dismissAll() {
        epoch += 1
    }
}

extension EnvironmentValues {
    /// `nil` : aperçus et tests, aucune route ne vient fermer quoi que ce soit.
    @Entry var presentationDismissal: PresentationDismissal? = nil
}

extension View {
    /// Appelle `dismiss` quand une route du système demande de fermer les présentations de la fenêtre. À poser sur la vue
    /// qui porte l'état de la présentation locale (`quickLookPreview`, feuille, bulle).
    func dismissesOnSystemRoute(_ dismiss: @escaping () -> Void) -> some View {
        modifier(DismissesOnSystemRoute(dismiss: dismiss))
    }
}

private struct DismissesOnSystemRoute: ViewModifier {
    let dismiss: () -> Void
    @Environment(\.presentationDismissal) private var signal

    func body(content: Content) -> some View {
        content.onChange(of: signal?.epoch) { dismiss() }
    }
}

/// Quand arrêter une génération locale pour ne pas toucher au GPU en arrière-plan (mission X2, R2-01).
///
/// iOS et iPadOS interdisent au GPU de travailler pour une app en arrière-plan : un modèle MLX qui continue de lui soumettre du
/// travail fait lever une erreur dans un rappel de MLX, hors de la pile Swift, donc sans aucun `catch` possible, et l'app
/// plante. Apple le dit : à la désactivation, l'app doit cesser d'envoyer du travail à Metal. Le Mac n'a pas cette restriction.
/// Seul le passage en arrière-plan arrête la réponse : « inactif » (Centre de contrôle, notification, autre fenêtre en
/// Split View) laisse le GPU disponible.
nonisolated enum BackgroundGPUPolicy {
    /// Vrai là où le système coupe le GPU des apps en arrière-plan.
    static var platformRestrictsGPU: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    static func shouldStopGeneration(phase: ScenePhase, engine: AIEngineOption, restrictsGPU: Bool) -> Bool {
        restrictsGPU && phase == .background && engine == .mlxLocal
    }
}
