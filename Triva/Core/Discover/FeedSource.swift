//
//  FeedSource.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Un flux RSS/Atom public qui alimente Découvrir.
///
/// ## Règle d'entrée dans le catalogue
/// Un flux n'entre ici que si les conditions d'usage de son éditeur AUTORISENT clairement
/// la reprise du flux (titre, extrait, lien) dans une application : autorisation écrite
/// explicite (« les flux RSS peuvent être reproduits librement », Numerama et Frandroid),
/// licence ouverte (The Conversation, CC BY-ND) ou règles de reprise acceptables (ESPN, PMC).
/// Un silence, un « usage personnel et non commercial » ou une interdiction de
/// rediffusion suffisent à exclure un flux. `termsURL` pointe vers la page qui a été lue ;
/// `Triva/Core/Discover/DiscoverFeedCatalog.swift` résume ce qu'elle dit.
///
/// ## Ce que chaque source impose à l'affichage
/// - ESPN et PMC : lien vers l'article chez l'éditeur, mention de la source, aucun
///   changement de titre, de résumé ni d'adresse (`FeedText` ne fait que retirer le balisage).
/// - The Conversation (CC BY-ND) : pas de modification de l'article, et seul le `summary` du
///   flux sert d'extrait (jamais le corps). Ses images sont soumises à des droits tiers
///   (agences) : `usesThumbnails == false`.
nonisolated struct FeedSource: Sendable, Equatable, Identifiable {
    /// Identifiant stable, en minuscules (« numerama-tech »).
    let id: String
    /// Nom d'éditeur affiché dans la ligne de l'article (« Numerama »).
    let name: String
    let url: URL
    /// Page des conditions d'usage lue au moment de l'ajout au catalogue.
    let termsURL: URL
    /// Faux si l'éditeur ne garantit pas les droits de ses images : pas de vignette.
    let usesThumbnails: Bool

    init(id: String, name: String, url: URL, termsURL: URL, usesThumbnails: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.termsURL = termsURL
        self.usesThumbnails = usesThumbnails
    }
}
