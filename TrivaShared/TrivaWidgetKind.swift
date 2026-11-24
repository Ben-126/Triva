//
//  TrivaWidgetKind.swift
//  TrivaShared
//
//  Chantier 2.1 (mission C) : identifiants des widgets et des commandes, partagés entre l'app (qui recharge le
//  widget) et l'extension (qui les déclare). Un identifiant qui changerait ferait disparaître le widget de
//  l'écran de l'utilisateur : ne jamais les renommer.
//

import Foundation

nonisolated enum TrivaWidgetKind {
    /// Widget d'accueil « Recherche rapide ».
    static let quickSearch = "com.benpodrojsky.Triva.QuickSearch"
    /// Commande « Nouvelle question » (Centre de contrôle, bouton Action).
    static let newQuestionControl = "com.benpodrojsky.Triva.NewQuestion"
    /// Commande « Question à la voix » : hors de l'extension jusqu'au chantier 2.7.
    static let voiceQuestionControl = "com.benpodrojsky.Triva.VoiceQuestion"
}
