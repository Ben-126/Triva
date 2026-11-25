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
