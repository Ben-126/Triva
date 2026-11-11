//
//  SearchArtifacts+ReliableMode.swift
//  Triva
//
//  Created by ben podrojsky on 10/11/2026.
//

import Foundation

/// Mode Fiable, garde-fous PAR LE CODE (mission A1, décisions de Ben du
/// 2026-11-10). Une seule définition pour `SearchOrchestrator` et
/// `ChatViewModel` : avant A1, le critère « sans source fiable » existait en
/// deux copies au corps identique, l'une lue sur `mode`, l'autre sur une copie
/// de `restrictsToTrustedDomains` — deux règles qui finissent toujours par
/// diverger.
///
/// `case .reliable = mode` plutôt que `mode.restrictsToTrustedDomains` :
/// `ResponseMode` n'est pas annoté, donc isolé au main actor, et ses
/// propriétés sont inaccessibles depuis les points d'entrée `@concurrent` de
/// l'orchestrateur. Le filtrage d'un `case` ne touche à aucune d'elles.
/// Aujourd'hui `restrictsToTrustedDomains` vaut exactement `self == .reliable` :
/// un mode qui filtrerait un jour sans être Fiable devrait relire ce fichier.
///
/// Deux moments, deux critères :
/// 1. AVANT la génération, `lacksReliableSources` : rien de citable, donc aucune
///    requête au moteur (décision (c), pas de requête cloud lancée puis annulée).
/// 2. APRÈS le flux, `rejectsReliableAnswer(_:)` : le modèle a répondu, mais par
///    le refus exact que lui impose le rappel Fiable (`PromptTemplates`), ou sans
///    citer aucune page lue. Rapport T2, scénario t3 : des documents hors sujet
///    passaient le premier critère, la rédaction tournait, et le refus arrivait
///    en TEXTE, sans le bouton « Relancer en mode Rapide ». Le prompt ne peut pas
///    garantir l'état : seul ce code le peut.
///
/// Un widget abouti suspend les deux critères : sa donnée est une source, déjà
/// affichée au-dessus de la réponse (rapport T2, finding 4 : un calcul juste ne
/// doit jamais être refusé parce que les documents web sont hors sujet).
nonisolated extension SearchArtifacts {
    /// Décision (c) : mode Fiable, recherche faite, AUCUN document citable ni
    /// widget. Sans `searchPerformed`, un « Bonjour » déclencherait l'état ; sans
    /// le test des widgets, un calcul juste serait caché. Les fichiers joints
    /// comptent comme sources.
    ///
    /// Lu sur `citableSourceCount` et non plus sur `sources.isEmpty` (A1) : des
    /// sources toutes illisibles (repli cloud dont aucune page n'a pu être lue)
    /// ne donnent au modèle que `PromptTemplates.noSourcesContext`. Équivalent
    /// à l'ancien critère tant que chaque source porte un extrait.
    var lacksReliableSources: Bool {
        guard case .reliable = mode else { return false }
        return searchPerformed && citableSourceCount == 0 && widgets.isEmpty
    }

    /// Vrai quand la réponse doit être contrôlée à la fin du flux, et RETENUE
    /// pendant le flux (`ChatViewModel`) : mode Fiable, recherche faite, aucun
    /// widget. Hors de ce cas, rien ne change.
    var requiresCitedAnswer: Bool {
        guard case .reliable = mode else { return false }
        return searchPerformed && widgets.isEmpty
    }

    /// Vrai si le texte VISIBLE (TL;DR et corps, jamais le bloc `<think>`) cite
    /// au moins une source affichée qui a été LUE : un numéro dans
    /// `1...sources.count` (ce que `CitationParser` transforme en pastille),
    /// hors `uncitableSourceNumbers` (page jamais montrée au modèle, donc qu'il
    /// n'a pu citer qu'en inventant).
    ///
    /// `isStreaming` : à vrai sur un instantané du flux, comme
    /// `ReasoningSegmenter` le veut (un bloc encore ouvert n'est pas tranché).
    func citesReadSource(in text: String, isStreaming: Bool = false) -> Bool {
        let segments = ReasoningSegmenter.segment(text, isStreaming: isStreaming)
        let visible = [segments.tldr ?? "", segments.body].joined(separator: "\n")
        let cited = CitationParser.parse(visible, sourceCount: sources.count).citationIndices
        return cited.contains { !uncitableSourceNumbers.contains($0) }
    }

    /// Fin de flux en mode Fiable (voir `requiresCitedAnswer`) : vrai si la
    /// réponse est le refus exact (`PromptTemplates.noRelevantInformationAnswer`,
    /// numéros de citation retirés : un modèle en colle parfois un au refus) ou
    /// ne cite aucune source lue. L'appelant montre alors l'état
    /// `.noReliableSources`, jamais le texte.
    ///
    /// Ne lève jamais : une sortie de modèle illisible n'est qu'une réponse sans
    /// citation, donc refusée — le repli sûr de ce mode.
    func rejectsReliableAnswer(_ text: String) -> Bool {
        guard requiresCitedAnswer else { return false }
        return Self.isNoRelevantInformationAnswer(text) || !citesReadSource(in: text)
    }

    /// Refus exact, reconnu sur ce que l'utilisateur lirait (corps, ou TL;DR
    /// seul sans corps, règle de `ChatViewModel.visibleText(of:)`), une fois les
    /// marqueurs `[n]` retirés : `ResponseStructureValidator` compare la phrase
    /// au caractère près, casse et accents mis à part.
    static func isNoRelevantInformationAnswer(_ text: String) -> Bool {
        let segments = ReasoningSegmenter.segment(text, isStreaming: false)
        let visible = segments.body.isEmpty ? (segments.tldr ?? "") : segments.body
        let withoutCitations = visible.replacing(#/\[[0-9]{1,4}\]/#, with: "")
        return ResponseStructureValidator.isNoRelevantInformationAnswer(withoutCitations)
    }
}
