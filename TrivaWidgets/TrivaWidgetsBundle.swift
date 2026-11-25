//
//  TrivaWidgetsBundle.swift
//  TrivaWidgets
//
//  Chantier 2.1 : point d'entrée de l'extension Widgets (S1). Mission C : widget « Recherche rapide » et commande
//  « Nouvelle question ». `VoiceQuestionControl` est écrit mais ABSENT d'ici jusqu'au chantier 2.7. Mission D :
//  l'activité en direct d'une recherche (iPhone et iPad seulement).
//

import SwiftUI
import WidgetKit

@main
struct TrivaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuickSearchWidget()
        NewQuestionControl()
        #if os(iOS)
        SearchLiveActivity()
        #endif
    }
}
