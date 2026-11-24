//
//  VoiceQuestionControl.swift
//  TrivaWidgets
//
//  Chantier 2.1 (mission C) : la commande « Question à la voix », écrite d'avance pour le chantier 2.7 et
//  VOLONTAIREMENT ABSENTE de `TrivaWidgetsBundle` : tant qu'elle n'y est pas, personne ne peut l'ajouter au Centre
//  de contrôle. Ce qui reste à faire en 2.7, dans cet ordre :
//    1. ajouter le cas `.voice` à `ComposerEntryAppEnum` (TrivaShared/OpenComposerIntent.swift) ;
//    2. remplacer `entry` ci-dessous par `.voice` ;
//    3. passer `TrivaFeatureFlags.voiceInput` à `true` et brancher le micro dans la barre de saisie ;
//    4. ajouter `VoiceQuestionControl()` au `TrivaWidgetsBundle`.
//

import AppIntents
import SwiftUI
import WidgetKit

struct VoiceQuestionControl: ControlWidget {
    /// Mode de saisie demandé. `.keyboard` en attendant le cas `.voice` (étape 1 de la liste ci-dessus).
    private static let entry: ComposerEntryAppEnum = .keyboard

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: TrivaWidgetKind.voiceQuestionControl) {
            ControlWidgetButton(action: OpenComposerIntent(target: Self.entry)) {
                Label("Question à la voix", systemImage: "mic")
            }
        }
        .displayName("Question à la voix Triva")
        .description("Ouvre Triva, prêt à écouter ta question.")
    }
}
