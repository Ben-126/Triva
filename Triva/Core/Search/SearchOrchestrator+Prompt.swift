//
//  SearchOrchestrator+Prompt.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

/// Prompt final du pipeline (découpage E1b) : délégation à `PromptTemplates` et insertion des données
/// des widgets.
extension SearchOrchestrator {
    // MARK: - Prompts et parsing, fonctions pures testables (pas `private`)

    /// Prompt final, délégation pure à `PromptTemplates` (aucun texte de
    /// prompt écrit ici : une seule source de vérité, couverte par
    /// `PromptTemplatesTests`) :
    /// - recherche faite (`searchPerformed`, défaut) : `writerPrompt`, le
    ///   prompt de rédaction de 1.4 (citations `[n]`, formulations bannies,
    ///   forme propre au mode) — y compris avec 0 source, cas qu'il traite
    ///   explicitement (« Aucune source disponible. », phrase de refus en
    ///   Rapide/Approfondi, avertissement en Fiable) ;
    /// - chemin `.skip` (bug 1) : `conversationPrompt`, qui répond depuis la
    ///   conversation sans exiger de sources absentes.
    ///
    /// Ce point d'entrée reste sur l'orchestrateur parce qu'il fixe ce que
    /// le pipeline y injecte : les sources DANS L'ORDRE DU CLASSEMENT (leur
    /// rang devient leur numéro de citation), les pages scrapées (fusionnées
    /// par `numberedContext` dans la source de même URL), l'historique borné
    /// et la reformulation qui a servi de sujet de recherche — donnée en plus
    /// de la question de l'utilisateur, jamais à sa place.
    ///
    /// Protection anti-overflow : niveau 1 par page dans `ScrapeService`
    /// (`maxContentCharactersPerPage`), niveau 2 (budget global réparti
    /// équitablement entre les documents) dans `numberedContext`. Les
    /// fichiers joints arrivent déjà bornés (`UploadsSearchAction`, budget de
    /// l'init) : `numberedContext` recopie un extrait sans le tronquer.
    ///
    /// `widgetContext` (1.5) : `WidgetExecutionReport.combinedLLMContext`,
    /// inséré juste avant la question (`insertingWidgetContext`) ; vide, le
    /// prompt est inchangé. Non vide, il adapte aussi le rappel du mode
    /// Fiable (`writerPrompt(hasWidgetData:)`, mission A1) : le refus exact
    /// qu'il impose contredirait la donnée d'un widget insérée APRÈS lui.
    ///
    /// `sourcesMatchQuestion` (mission A2) : faux quand aucune source n'a
    /// passé le test lexical de la chaîne (`WebSearchChainReport`) ; le
    /// prompt de rédaction prévient alors le modèle (`writerPrompt`).
    nonisolated static func buildPrompt(
        query: String,
        standaloneQuery: String? = nil,
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = [],
        chatHistory: [ClassifierChatMessage] = [],
        mode: ResponseMode,
        complexity: WriterPromptComplexity = .full,
        currentDate: Date = Date(),
        searchPerformed: Bool = true,
        maxHistoryMessages: Int = PromptTemplates.defaultMaxHistoryMessages,
        maxHistoryMessageCharacters: Int = PromptTemplates.defaultMaxHistoryMessageCharacters,
        maxScrapedContextCharacters: Int = PromptTemplates.defaultMaxScrapedContextCharacters,
        widgetContext: String = "",
        sourcesMatchQuestion: Bool = true
    ) -> String {
        let prompt = searchPerformed
            ? PromptTemplates.writerPrompt(
                query: query,
                standaloneQuery: standaloneQuery,
                sources: sources,
                scrapedPages: scrapedPages,
                chatHistory: chatHistory,
                mode: mode,
                complexity: complexity,
                currentDate: currentDate,
                maxHistoryMessages: maxHistoryMessages,
                maxHistoryMessageCharacters: maxHistoryMessageCharacters,
                maxScrapedContextCharacters: maxScrapedContextCharacters,
                hasWidgetData: !widgetContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                sourcesMatchQuestion: sourcesMatchQuestion
            )
            : PromptTemplates.conversationPrompt(
                query: query,
                standaloneQuery: standaloneQuery,
                chatHistory: chatHistory,
                mode: mode,
                complexity: complexity,
                currentDate: currentDate,
                maxHistoryMessages: maxHistoryMessages,
                maxHistoryMessageCharacters: maxHistoryMessageCharacters
            )
        return insertingWidgetContext(widgetContext, into: prompt, query: query)
    }

    /// Consigne qui ouvre le bloc des widgets dans le prompt final : sur le
    /// modèle du `noteForAssistant` du web (« already showed to the user […]
    /// do not CITE this as a source »).
    nonisolated static let widgetContextInstruction = "Données des widgets de Triva, DÉJÀ affichées à l'utilisateur au-dessus de ta réponse : appuie-toi dessus pour répondre, sans les recopier en entier, et ne les cite jamais avec un numéro [n] (ce ne sont pas des sources numérotées)."

    /// Insère les données des widgets dans un prompt de `PromptTemplates`,
    /// JUSTE AVANT le bloc de la question (ligne de reformulation éventuelle
    /// comprise), après la date : la donnée la plus utile est la plus proche
    /// de la question, et la question reste la dernière ligne du prompt.
    ///
    /// Repère : les quatre gabarits (rédaction et sans recherche, complet et
    /// concis) se terminent par `\(query)`, précédé du dernier saut de ligne
    /// double du prompt. La question elle-même peut contenir des sauts de
    /// ligne : la recherche du séparateur commence AVANT elle. Si le gabarit
    /// change au point de ne plus finir par la question, le bloc est ajouté
    /// à la fin — dégradé mais jamais perdu (un test couvre les quatre
    /// gabarits). `PromptTemplates` devrait à terme porter ce paramètre.
    nonisolated static func insertingWidgetContext(_ widgetContext: String, into prompt: String, query: String) -> String {
        let context = widgetContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else { return prompt }
        let block = "<donnees_widgets>\n\(widgetContextInstruction)\n\(context)\n</donnees_widgets>"
        guard
            !query.isEmpty,
            let questionRange = prompt.range(of: query, options: [.backwards, .anchored]),
            let separator = prompt.range(of: "\n\n", options: .backwards, range: prompt.startIndex..<questionRange.lowerBound)
        else {
            return prompt + "\n\n" + block
        }
        return String(prompt[..<separator.upperBound]) + block + "\n\n" + String(prompt[separator.upperBound...])
    }
}
