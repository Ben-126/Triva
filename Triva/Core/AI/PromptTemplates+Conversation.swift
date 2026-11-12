//
//  PromptTemplates+Conversation.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

// Sorti de `PromptTemplates.swift` (mission E1c) : déplacement pur, aucun
// changement de texte ni de comportement. Le prompt du chemin sans recherche.
extension PromptTemplates {
    // MARK: - Réponse sans recherche (chemin `.skip`, bug 1)

    /// Prompt quand le classifieur a jugé la recherche inutile (`.skip` :
    /// salutation, écriture, culture générale, ou demande sur la conversation
    /// elle-même — traduire, résumer). Bug 1 : ce chemin recevait le prompt de
    /// rédaction, qui exige « les sources numérotées » absentes puis impose un
    /// refus (`noRelevantInformationAnswer`) ou, en Fiable,
    /// `unverifiedSourcesWarning` — à un simple « Bonjour ». Le mode n'y règle
    /// que la longueur et l'avertissement Fiable (`conversationModeRule`).
    nonisolated static func conversationPrompt(
        query: String,
        standaloneQuery: String? = nil,
        chatHistory: [ClassifierChatMessage] = [],
        mode: ResponseMode,
        complexity: WriterPromptComplexity = .full,
        currentDate: Date = Date(),
        maxHistoryMessages: Int = defaultMaxHistoryMessages,
        maxHistoryMessageCharacters: Int = defaultMaxHistoryMessageCharacters
    ) -> String {
        let parts = PromptParts(
            query: query,
            reformulation: reformulationLine(query: query, standaloneQuery: standaloneQuery),
            history: formattedHistory(chatHistory, maxHistoryMessages: maxHistoryMessages, maxHistoryMessageCharacters: maxHistoryMessageCharacters),
            mode: mode,
            currentDate: currentDate,
            // Sans contexte, aucun rappel Fiable : le drapeau n'a rien à adapter.
            hasWidgetData: false
        )
        switch complexity {
        case .full:
            return fullConversationPrompt(parts)
        case .concise:
            return conciseConversationPrompt(parts)
        }
    }

    /// Les deux verbosités du prompt sans recherche, séparées comme `fullPrompt`/`concisePrompt`.
    ///
    /// Pas de règle « ne recopie pas une réponse précédente » ici, contrairement aux prompts de
    /// rédaction (mission A2, décision 5 de Ben) : mesurée contre-productive sur Apple Intelligence.
    /// « Bonjour ! » envoyé après un haïku (vu sur iPad et iPhone : le haïku recopié mot pour mot),
    /// 6 générations par version : sans règle, recopie 2 fois ; avec « …sauf si ce message demande
    /// de la reprendre ; à une salutation, réponds par une courte salutation », 0 fois, mais
    /// « Bonjour. » s'invitait devant une demande de traduction 3 fois sur 3 ; sans la clause
    /// salutation, 5 fois. Le cas mesuré est réglé en amont, sans prompt : une salutation pure part
    /// au rédacteur sans historique (`SmallTalk.isBareSalutation`). Jamais mesurée sur cloud ni MLX.
    private nonisolated static func fullConversationPrompt(_ parts: PromptParts) -> String {
        """
        Tu es Triva, un assistant de recherche précis et direct. Aucune recherche web n'a été lancée pour ce message : il ne demande ni information récente ni source (salutation, tâche d'écriture, culture générale, ou demande qui porte sur la conversation elle-même — traduire, résumer, reformuler, développer une réponse précédente).

        ### Consignes
        - Réponds à partir de l'historique de conversation ci-dessous et de tes connaissances générales.
        - **Langue** : réponds dans la langue de la question, sauf si elle demande explicitement une autre langue.
        - Aucune source n'accompagne cette réponse : n'écris aucune citation [n], et retire celles d'un passage de l'historique que tu reprends.
        - N'invente rien : si tu n'es pas sûr d'un fait, dis-le en une phrase plutôt que de l'affirmer.
        - Aucune phrase de remplissage, aucune répétition, pas de titre principal, ni bloc <think> ni bloc <tldr>.
        - \(conversationModeRule(for: parts.mode))

        <historique_conversation>
        \(parts.history)
        </historique_conversation>

        Date et heure actuelles (UTC, format ISO 8601) : \(formattedDate(parts.currentDate)).

        \(parts.reformulation)Question de l'utilisateur : \(parts.query)
        """
    }

    private nonisolated static func conciseConversationPrompt(_ parts: PromptParts) -> String {
        """
        Tu es Triva. Aucune recherche n'a été faite pour ce message : réponds à partir de l'historique ci-dessous et de tes connaissances générales.

        Règles :
        - Langue : réponds dans la langue de la question, sauf si elle demande explicitement une autre langue.
        - Pas de citation [n] : aucune source n'accompagne cette réponse.
        - N'invente rien. Si tu n'es pas sûr, dis-le.
        - Pas de phrase de remplissage, pas de balise <think> ni <tldr>.
        - \(conversationModeRule(for: parts.mode))

        <historique_conversation>
        \(parts.history)
        </historique_conversation>

        Date du jour (UTC, ISO 8601) : \(formattedDate(parts.currentDate)).

        \(parts.reformulation)Question : \(parts.query)
        """
    }

    /// `switch`, jamais `mode == …` : `Equatable` de `ResponseMode` est isolé
    /// au main actor, inutilisable ici (même raison que `modeSection`).
    private nonisolated static func conversationModeRule(for mode: ResponseMode) -> String {
        switch mode {
        case .quick:
            return "Mode Rapide : 2 à 3 phrases au plus — sauf pour reprendre un passage de la conversation (traduction, reformulation), qui le couvre en entier."
        case .deep:
            return "Mode Approfondi : développe autant que la question l'exige (titres ## seulement pour 3 sujets distincts ou plus) ; une salutation reste brève."
        case .reliable:
            return "Mode Fiable : aucune source ne vérifie cette réponse. Si elle énonce des faits qui ne viennent pas de l'historique, commence par exactement : « \(unverifiedSourcesWarning) » et ajoute \(unsupportedClaimMarker) après chacun ; une salutation ou une reprise de la conversation n'en a pas besoin."
        }
    }
}
