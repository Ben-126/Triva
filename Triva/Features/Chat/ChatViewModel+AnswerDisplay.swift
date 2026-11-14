//
//  ChatViewModel+AnswerDisplay.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Étape d'une génération en cours, dite par une ligne d'état discrète près de l'indicateur
/// (QA Q3, finding 31, décision de Ben du 2026-11-11 : « rien ne dit si l'app cherche ou
/// rédige, alors que c'est le moment où on attend le plus »).
///
/// Trois étapes, celles que le ViewModel CONNAÎT : l'analyse de la question (classification, avant
/// toute recherche : « Réflexion… »), la recherche (annoncée par `SearchOrchestrator.streamAnswer`
/// seulement quand Triva cherche vraiment : jamais pour une salutation), puis la rédaction. « Lecture des pages… », demandée aussi, supposerait un signal d'étape de
/// l'orchestrateur, qui n'en émet aucun : non fait, plutôt qu'un libellé deviné.
nonisolated enum GenerationStage: Sendable, Equatable {
    /// Question en cours d'analyse, rien n'est encore cherché. Même mot que l'en-tête de la boîte de
    /// raisonnement (`ThinkBoxPresentation`), décision de Ben du 2026-11-14.
    case analyzing
    case searching
    case writing

    var statusText: String {
        switch self {
        case .analyzing: "Réflexion…"
        case .searching: "Recherche des sources…"
        case .writing: "Rédaction…"
        }
    }
}

// Règles d'affichage d'une réponse décidées à partir des artefacts (mission C1). Pures et
// statiques, testées sans pipeline.
extension ChatViewModel {
    /// Un widget a-t-il donné LA réponse ? Oui pour un calcul (résultat exact, que des pages web
    /// ne peuvent qu'affaiblir), et pour une météo SANS recherche web à côté. Non pour une météo
    /// accompagnée d'une recherche : constaté au parcours UI 10 (mission C1), « Cherche la hauteur
    /// de la tour Eiffel » a reçu un widget météo de Paris par erreur du classifieur, et masquer
    /// les sources sur la seule présence d'un widget cachait les pages réellement citées
    /// (« [2] » restait sans source). La recherche web, elle, répondait à la question.
    nonisolated static func widgetAnswered(_ artifacts: SearchArtifacts) -> Bool {
        artifacts.widgets.contains { widget in
            switch widget.kind {
            case .calculation: true
            case .weather: artifacts.webSourceKind == nil
            }
        }
    }

    /// Sources montrées sous la réponse. Quand un widget a donné la réponse (`widgetAnswered`),
    /// les sources WEB ne sont pas montrées (décision de Ben, QA Q3, finding 50) : sous un calcul
    /// exact, « Méthodes de multiplication avec 37 - TikTok » desservait la crédibilité d'un
    /// moteur sourcé. Les fichiers joints, eux, restent : ce sont les documents de l'utilisateur,
    /// en tête de liste, donc la numérotation `[n]` de ceux qui restent ne bouge pas.
    nonisolated static func displayedSources(of artifacts: SearchArtifacts) -> [SearXNGSearchResult] {
        guard widgetAnswered(artifacts) else { return artifacts.sources }
        return Array(artifacts.sources.prefix(artifacts.attachmentSourceCount))
    }

    /// Suggestions « À creuser » après cette réponse ? Non sous une salutation (« Bonjour ! »
    /// recevait des pistes sur le sujet PRÉCÉDENT, vu sur iPad par A2), ni quand un widget a
    /// donné la réponse (elles répétaient la question : « Est-ce que 47508 est la bonne réponse ? »,
    /// finding 49).
    nonisolated static func offersSuggestions(question: String, artifacts: SearchArtifacts) -> Bool {
        !widgetAnswered(artifacts) && !SmallTalk.isGreeting(question)
    }

    /// SearXNG a-t-il échoué pour cette recherche ? Vrai seulement s'il a été interrogé et n'a
    /// pas répondu (`.searchFailed`) ; une instance qui a répondu sans rien d'utile
    /// (`.noUsableAnswer`) répondrait aussi à une recherche d'images. Les recherches d'images et
    /// de vidéos ne passent que par SearXNG : leurs boutons échoueraient à coup sûr.
    nonisolated static func searXNGUnreachable(_ report: WebSearchChainReport) -> Bool {
        report.passedOver.contains { failure in
            guard failure.source == .searxng, case .searchFailed = failure.reason else { return false }
            return true
        }
    }
}
