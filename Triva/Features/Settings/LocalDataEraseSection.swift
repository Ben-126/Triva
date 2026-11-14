//
//  LocalDataEraseSection.swift
//  Triva
//
//  Created by ben podrojsky on 10/11/2026.
//

import SwiftUI

/// Section « Données » des Réglages : l'action « Tout effacer », avec
/// confirmation. Isolée de `SettingsView` (déjà longue) ; composants système
/// seulement, comme le reste de l'écran (DESIGN.md : pas de verre dans un `Form`).
///
/// La confirmation dit exactement ce qui part ET ce qui reste (les clés et le
/// moteur), parce que c'est la crainte évidente devant un bouton « Tout » :
/// la liste est la même que celle de `LocalDataEraser`.
///
/// Le résultat s'affiche dans le pied de section plutôt qu'en alerte : il reste
/// lisible après coup et ne demande aucun geste de plus. Un échec partiel est
/// dit tel quel (« pas pu tout effacer »), jamais présenté comme un succès.
struct LocalDataEraseSection: View {
    let eraser: LocalDataEraser

    @State private var isConfirming = false
    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case erasing
        case done
        /// Les étapes en base qui n'ont pas pu être jouées (les caches, eux, l'ont été).
        case incomplete(failedSteps: [LocalDataEraseStep])
    }

    var body: some View {
        Section {
            Button("Tout effacer", role: .destructive) {
                isConfirming = true
            }
            .disabled(phase == .erasing)
            .accessibilityIdentifier("settings.eraseAll")
            .confirmationDialog(
                "Tout effacer ?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Tout effacer", role: .destructive) {
                    Task { await erase() }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text(Self.confirmationMessage)
            }
        } header: {
            Text("Données")
        } footer: {
            Text(footerText)
        }
    }

    /// Exposé pour les tests : la promesse faite avant l'effacement.
    static let confirmationMessage =
        "Tes conversations, tes favoris et les caches de recherche seront supprimés de cet appareil, "
        + "sans retour possible. Tes clés API et le choix de ton moteur IA ne changent pas."

    private var footerText: String {
        switch phase {
        case .idle:
            "Supprime les conversations, les favoris et les caches. Les clés API et le moteur choisi sont conservés."
        case .erasing:
            "Effacement en cours…"
        case .done:
            "Tout a été effacé."
        case .incomplete(let failedSteps):
            Self.incompleteMessage(failedSteps: failedSteps)
        }
    }

    /// Dit ce qui n'a PAS été effacé, et ce qui l'a été. Les caches sont
    /// toujours vidés, même quand la base échoue (`LocalDataEraser`). **Textes
    /// À VALIDER PAR BEN.**
    static func incompleteMessage(failedSteps: [LocalDataEraseStep]) -> String {
        let retry = " Réessaie ; si cela se reproduit, redémarre l'app."
        let failedFavorites = failedSteps.contains(.favorites)
        let failedHistory = failedSteps.contains(.history)
        switch (failedHistory, failedFavorites) {
        case (true, true):
            return "Tes conversations et tes favoris n'ont pas pu être effacés. Seuls les caches de recherche l'ont été." + retry
        case (true, false):
            return "Tes conversations n'ont pas pu être effacées ; tes favoris et les caches de recherche l'ont été." + retry
        case (false, true):
            return "Tes favoris n'ont pas pu être effacés ; tes conversations et les caches de recherche l'ont été." + retry
        case (false, false):
            return "Triva n'a pas pu tout effacer." + retry
        }
    }

    private func erase() async {
        phase = .erasing
        do {
            try await eraser.eraseAll()
            phase = .done
        } catch {
            phase = .incomplete(failedSteps: error.failedSteps)
        }
    }
}
