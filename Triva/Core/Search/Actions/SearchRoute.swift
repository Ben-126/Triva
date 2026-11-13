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
    /// Aucune recherche : salutation, écriture, calcul pur (bug 15, le widget
    /// calcul répond hors ligne), ou demande sur la conversation elle-même.
    /// PAS la culture générale : le classifieur ne saute la recherche que pour sa
    /// liste fermée (`QueryClassifier`), une question de fait ou d'explication
    /// cherche toujours, même si le modèle en connaît la réponse. Prompt sans recherche (`conversationPrompt`).
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
    ///
    /// ## Mode Fiable (mission E2a, décision de Ben du 2026-11-12)
    /// « En Fiable, TOUJOURS chercher, sauf salutation et calcul. » Le classifieur
    /// juge `skipSearch` d'après sa liste fermée (salutation, écriture, calcul,
    /// météo) ; il peut aussi se tromper sur une vraie question, que le modèle
    /// traiterait alors de mémoire, sans source, alors que le mode promet des
    /// réponses sourcées. En Fiable, `skipSearch` ne tient donc que pour :
    /// - un calcul (`showCalculationWidget`) : le widget est la source ;
    /// - une salutation ou politesse (`SmallTalk.isGreeting(query)` : le classifieur
    ///   n'a pas de champ « salutation », c'est la même détection que la mention
    ///   « Réponse sans recherche » et que le repli de `classifyWithFallback`) ;
    /// Toute autre question classée « sans recherche » cherche (écriture, traduction,
    /// résumé de la conversation et météo compris, au sens littéral de la décision) :
    /// route décidée par la suite des règles (3 est sautée). La météo y cherche donc
    /// sur le web EN PLUS de son widget, qui tourne en parallèle de toute route et,
    /// abouti, suspend les contrôles Fiable (`SearchArtifacts+ReliableMode`). Rapide et Approfondie : inchangés.
    /// Hors connexion, `SearchOrchestrator.routeAvailable` réduit ensuite toute
    /// route web à `.none` : le comportement hors ligne reste prioritaire.
    ///
    /// - Parameters:
    ///   - mode: mode de réponse du tour (`.quick` par défaut : comportement historique).
    ///   - query: question BRUTE de l'utilisateur, pour reconnaître une salutation
    ///     (jamais la reformulation autonome, qui n'en est plus une).
    static func resolve(
        for classification: QueryClassification,
        hasAttachments: Bool,
        mode: ResponseMode = .quick,
        query: String = ""
    ) -> SearchRoute {
        if classification.personalSearch, hasAttachments {
            return .attachments
        }
        if classification.showStockWidget {
            return .web(.general)
        }
        if classification.skipSearch, honorsSkipSearch(classification, mode: mode, query: query) {
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

    /// `skipSearch` est-il respecté ? Toujours hors Fiable ; en Fiable, seulement pour les cas
    /// que la décision de Ben exempte (voir `resolve`). `case .reliable = mode` plutôt qu'une
    /// propriété de `ResponseMode` : même raison que `SearchArtifacts+ReliableMode.swift`.
    private static func honorsSkipSearch(_ classification: QueryClassification, mode: ResponseMode, query: String) -> Bool {
        guard case .reliable = mode else { return true }
        return classification.showCalculationWidget || SmallTalk.isGreeting(query)
    }
}
