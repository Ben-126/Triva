//
//  SearchRoute.swift
//  Triva
//
//  Created by ben podrojsky on 28/10/2026.
//

import Foundation

/// Famille de recherche web d'une route qui en lance une : elle fixe l'action
/// du tour seedé (moteurs par défaut, académiques ou forums).
nonisolated enum WebSearchFlavor: Sendable, Equatable {
    /// Moteurs par défaut de l'instance SearXNG (`WebSearchAction`).
    case general
    /// Moteurs académiques forcés (`AcademicSearchAction`).
    case academic
    /// Forums et discussions (`SocialSearchAction`).
    case discussion

    /// Action du tour seedé, branchée sur la chaîne de repli de l'envoi
    /// (RI1b) ou, sans chaîne, sur SearXNG seul (`WebSearchingAction`).
    /// `@MainActor` : les actions sont des types non annotés (`Actions/`),
    /// leur init est isolé au main actor.
    @MainActor
    func action(webSearchChain: WebSearchChain?) -> any WebSearchingAction {
        switch self {
        case .general: WebSearchAction(webSearchChain: webSearchChain)
        case .academic: AcademicSearchAction(webSearchChain: webSearchChain)
        case .discussion: SocialSearchAction(webSearchChain: webSearchChain)
        }
    }

    /// Repli d'une recherche restée vide (bug 5) : la recherche web, pour les
    /// seules familles à moteurs FORCÉS (`reddit` ; `arxiv`, `google scholar`,
    /// `pubmed`), qui n'ont aucun autre moteur derrière elles. Jamais pour la
    /// recherche web elle-même : une vraie recherche sans résultat reste une
    /// réponse valide, la relancer doublerait la latence pour rien.
    /// Énumération exhaustive exprès : une future famille à moteurs forcés
    /// devra choisir son repli.
    ///
    /// SANS chaîne seulement. Avec elle, ce repli a lieu DANS l'étape SearXNG
    /// de la chaîne (`WebSearchChain`), avant la recherche cloud payante ;
    /// relancer ensuite toute la chaîne en général redemanderait les mêmes
    /// sources (clé personnelle, cloud payant, SearXNG général déjà essayé)
    /// pour ne gagner qu'une source ouverte.
    @MainActor
    func emptyResultFallback(webSearchChain: WebSearchChain?) -> (any WebSearchingAction)? {
        guard webSearchChain == nil else { return nil }
        switch self {
        case .academic, .discussion: return WebSearchAction()
        case .general: return nil
        }
    }
}

/// Chemin de recherche d'une requête (I1b), décidé à partir de la
/// classification COMPLÈTE (1.1) et de la présence de fichiers joints (1.11).
/// Les widgets (1.5) ne sont PAS une route : ils tournent en parallèle de
/// n'importe laquelle, selon leurs propres drapeaux (`SearchWidget.shouldExecute`).
///
/// ## Pourquoi pas `QueryClassification.primaryAction` (bug 15)
/// `primaryAction` résume la classification en UNE action, widgets en tête
/// (météo, bourse, calcul, puis `.skip`) : « Combien font 15 % de 240 ? »,
/// classé `showCalculationWidget` + `skipSearch` comme le prompt du
/// classifieur le demande, y devient `.calculationWidget` — que l'ancien
/// `action(for:)` envoyait sur `WebSearchAction` : recherche SearXNG, 1 à 2
/// tours planner, scrapes de calculatrices en ligne, et, hors ligne,
/// « Aucune instance de recherche n'a répondu » là où « Bonjour » répond.
/// Réordonner `primaryAction` (fichier hors périmètre, couvert par
/// `QueryClassifierTests`) ne suffirait pas : une seule action ne peut pas
/// dire à la fois « widget » ET « recherche ou pas ». La route lit donc les
/// drapeaux eux-mêmes, et `primaryAction` reste inchangé.
nonisolated enum SearchRoute: Sendable, Equatable {
    /// Aucune recherche : salutation, écriture, culture générale, calcul pur
    /// (bug 15, le widget calcul répond hors ligne), ou demande sur la
    /// conversation elle-même. Prompt sans recherche (`conversationPrompt`).
    case none
    /// Fichiers joints SEULEMENT (`personalSearch` avec au moins un fichier) :
    /// la question porte sur les documents de l'utilisateur, une recherche
    /// web n'y ajouterait que du bruit. Aucun appel réseau.
    case attachments
    /// Recherche web de la famille donnée, puis classement et planner.
    case web(WebSearchFlavor)
    /// Météo sans recherche demandée (`showWeatherWidget` + `skipSearch`) : le
    /// widget météo répond, aucune recherche. S'il ne produit rien (lieu
    /// introuvable, Open-Meteo injoignable), repli sur une recherche web
    /// générale : une question météo réclame une donnée EN DIRECT, que le
    /// modèle ne peut pas tirer de ses connaissances. Seule route qui attend
    /// les widgets AVANT de chercher.
    case webUnlessWeatherAnswered

    /// Règles, dans cet ordre :
    /// 1. `personalSearch` avec fichiers joints -> `.attachments`, même si
    ///    `skipSearch` est vrai (« Résume ce PDF » ne demande aucune recherche
    ///    WEB, mais bien les documents). Sans fichier joint, `personalSearch`
    ///    retombe sur la recherche web, comme avant : il n'y a rien d'autre à
    ///    chercher.
    /// 2. `showStockWidget` -> recherche web générale, même avec `skipSearch` :
    ///    aucun widget bourse n'existe (hors champ, faute d'API sans clé) et un
    ///    cours de bourse est une donnée en direct.
    /// 3. `skipSearch` -> `.webUnlessWeatherAnswered` si la météo est demandée,
    ///    `.none` sinon (dont le calcul pur du bug 15).
    /// 4. `academicSearch`, puis `discussionSearch`, sinon recherche générale
    ///    (widgets avec `skipSearch` faux compris : le classifieur a jugé
    ///    qu'une recherche s'ajoutait au widget).
    static func resolve(for classification: QueryClassification, hasAttachments: Bool) -> SearchRoute {
        if classification.personalSearch, hasAttachments {
            return .attachments
        }
        if classification.showStockWidget {
            return .web(.general)
        }
        if classification.skipSearch {
            return classification.showWeatherWidget ? .webUnlessWeatherAnswered : .none
        }
        if classification.academicSearch {
            return .web(.academic)
        }
        if classification.discussionSearch {
            return .web(.discussion)
        }
        return .web(.general)
    }
}
