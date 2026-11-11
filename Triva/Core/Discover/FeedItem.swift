//
//  FeedItem.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Un article tel que le publie un flux RSS 2.0 ou Atom, après lecture mais avant tout
/// choix d'affichage. `nonisolated` : donnée pure, produite hors du main actor par
/// `FeedParser` puis transformée en `DiscoverArticle` par `DiscoverService`.
///
/// Ce qui n'y figure PAS est volontaire :
/// - le corps de l'article (`content:encoded` en RSS, `content` en Atom). Il contient
///   l'article entier (jusqu'à 800 Ko pour un flux de The Conversation), parfois le texte
///   derrière un mur payant (`pmc-paywall` chez ARTnews). Triva cite un extrait fourni par
///   l'éditeur dans `description`/`summary` et renvoie vers l'article, jamais plus ;
/// - l'auteur et les catégories : Découvrir n'en a pas l'usage.
nonisolated struct FeedItem: Sendable, Equatable {
    /// Titre en texte brut (balises retirées, entités décodées).
    var title: String
    /// Adresse de l'article chez l'éditeur, telle que publiée.
    var link: String
    /// `description` (RSS) ou `summary` (Atom) en texte brut, `nil` s'il est vide.
    var summary: String?
    /// Vignette déclarée par l'éditeur (`media:content`, `media:thumbnail`, `enclosure`),
    /// jamais une image devinée dans le corps de l'article.
    var imageURL: String?
    /// Date de publication réelle, `nil` si le flux n'en donne pas ou si elle est illisible.
    var publishedAt: Date?
}
