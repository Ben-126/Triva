//
//  OpensExternalSearchWindows.swift
//  Triva
//
//  Chantier 2.2 (M7) : ouvre les fenêtres demandées par le Service, le Dock ou la barre des menus.
//

import SwiftUI

/// Observe `ExternalSearchLauncher` et ouvre les fenêtres de recherche demandées.
///
/// Posé à DEUX endroits, par prudence : dans chaque fenêtre de recherche (`active`, le cas courant : leur
/// environnement `openWindow` est garanti) et sur la scène de l'app (`TrivaApp`, seul observateur vivant quand
/// toutes les fenêtres sont fermées). `ExternalSearchLauncher.drain()` ne rend chaque cible qu'une fois : jamais
/// deux fenêtres pour une demande. La scène de l'app s'efface tant qu'une fenêtre est affichée.
@MainActor
struct ExternalSearchWindowOpener {
    let launcher: ExternalSearchLauncher
    let openWindow: OpenWindowAction
    /// `true` pour l'observateur de scène : n'agit que si aucune fenêtre n'est affichée.
    let onlyWhenNoWindow: Bool

    func openPending() {
        if onlyWhenNoWindow, launcher.visibleWindowCount > 0 { return }
        let targets = launcher.drain()
        guard !targets.isEmpty else { return }
        for target in targets {
            openWindow(id: TrivaWindowTarget.sceneID, value: target)
        }
        #if os(macOS)
        NSApp.activate()
        #endif
    }
}

#if os(macOS)
private struct OpensExternalSearchWindows: ViewModifier {
    let launcher: ExternalSearchLauncher
    @Environment(\.openWindow) private var openWindow
    /// Identité de CETTE fenêtre pour le décompte (voir `ExternalSearchLauncher.visibleWindowCount`).
    @State private var windowID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { launcher.windowDidAppear(id: windowID) }
            .onDisappear { launcher.windowDidDisappear(id: windowID) }
            .onChange(of: launcher.revision, initial: true) {
                ExternalSearchWindowOpener(launcher: launcher, openWindow: openWindow, onlyWhenNoWindow: false)
                    .openPending()
            }
    }
}
#endif

extension View {
    /// Mac : cette fenêtre ouvre les recherches demandées de l'extérieur. Sans effet ailleurs.
    @ViewBuilder
    func opensExternalSearchWindows(_ launcher: ExternalSearchLauncher = .shared) -> some View {
        #if os(macOS)
        modifier(OpensExternalSearchWindows(launcher: launcher))
        #else
        self
        #endif
    }
}
