//
//  NewQuestionControl.swift
//  TrivaWidgets
//
//  Chantier 2.1 (mission C) : la commande « Nouvelle question » (Centre de contrôle sur iPhone, iPad et Mac ;
//  bouton Action des iPhone qui en ont un). Un toucher ouvre Triva sur une recherche vide, clavier ouvert, via
//  l'intent `OpenComposerIntent` (mission A, compilé dans l'app ET ici, exécuté dans l'app : cible `.main`).
//  La commande ne contient aucune donnée de l'utilisateur et n'envoie jamais rien.
//

import AppIntents
import SwiftUI
import WidgetKit

struct NewQuestionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: TrivaWidgetKind.newQuestionControl) {
            ControlWidgetButton(action: OpenComposerIntent(target: .keyboard)) {
                Label("Nouvelle question", systemImage: "square.and.pencil")
            }
        }
        .displayName("Nouvelle question Triva")
        .description("Ouvre Triva, prêt à écrire ta question.")
    }
}
