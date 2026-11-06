//
//  PromptTemplates.swift
//  Triva
//
//  Created by ben podrojsky on 18/09/2026.
//

import Foundation

/// Deux niveaux de verbosité pour les instructions de rédaction. Même
/// convention de nommage et même intention que `ClassifierPromptComplexity`
/// (`Triva/Core/Search/QueryClassifier.swift`), mais type DISTINCT et non
/// partagé : les deux axes peuvent légitimement diverger (un modèle peut
/// mériter un classifieur `.full` — sortie JSON courte — tout en ayant besoin
/// d'un writer `.concise`, le prompt de rédaction étant dix fois plus long).
/// Les coupler dès maintenant interdirait ce réglage sans rien simplifier.
///
/// - `.full` : port complet de `writer.ts` (web), pour un modèle cloud BYOK
///   ou Apple Intelligence.
/// - `.concise` : version courte, pour un MLX local ultra-léger (Qwen3 0.6B /
///   1.7B du catalogue). Ce n'est pas une préférence esthétique : un modèle de
///   cette taille noie la question dans plusieurs centaines de mots de
///   consignes et répond à côté. La version concise ne garde que les trois
///   règles dont la violation se voit immédiatement à l'écran — citations
///   `[n]`, interdiction d'inventer, longueur.
nonisolated enum WriterPromptComplexity: Sendable, Equatable {
    case full
    case concise
}

/// Port natif de `src/lib/prompts/search/writer.ts` (web) : construit le
/// prompt de RÉDACTION, celui qui transforme un contexte de recherche en
/// réponse rédigée avec citations. C'est le prompt qui détermine la qualité
/// perçue de toute l'app — d'où le niveau de détail assumé ici.
///
/// Écarts volontaires par rapport à la référence web, et pourquoi :
///
/// 1. **Consignes en français.** Le web écrit ses consignes en anglais et
///    demande au modèle de répondre dans la langue de la question. Ici tout
///    est en français (cohérence projet) ; la règle de langue, elle, ne
///    change pas.
/// 2. **L'axe `mode: 'speed' | 'balanced' | 'quality'` du web n'existe pas.**
///    Triva n'a qu'un seul axe, `ResponseMode` (1.13 : `quick` / `deep` /
///    `reliable`). Côté web, `reliableModePrompt` interpole
///    `modeInstructions[mode]` pour récupérer sa structure : en supprimant
///    cet axe, `reliable` se retrouverait SANS aucune consigne de forme. La
///    section de forme du mode `reliable` est donc écrite ici — c'est la
///    seule partie du prompt qui n'est pas un portage.
/// 3. **Le mode `debate` n'est pas porté** : hors périmètre V1, décision de
///    Ben (voir `ResponseMode`).
/// 4. **Aucun emoji dans les consignes.** Le web fait produire au modèle des
///    marqueurs `⚠️` (« Sources disagree », « No verified sources »). Ce
///    texte finit tel quel dans la bulle de réponse : demander un emoji au
///    modèle viole DESIGN.md aussi sûrement qu'en coder un dans un `Text`.
///    Les marqueurs équivalents sont en texte simple.
/// 5. **Les formulations bannies sont des données Swift**
///    (`bannedSpeculationPhrases` / `bannedFillerPhrases`), interpolées dans
///    le prompt plutôt qu'écrites en dur dedans. C'est ce qui garantit que
///    `ResponseStructureValidator` contrôle EXACTEMENT ce que le prompt a
///    interdit : deux listes recopiées auraient divergé au premier ajout.
/// 6. **Pas de section « User instructions ».** Le web laisse l'utilisateur
///    injecter ses propres consignes système ; cette fonctionnalité n'existe
///    pas dans Triva, et un bloc vide ne ferait qu'occuper du contexte.
///
/// Tous les membres sont explicitement `nonisolated`, et
/// `WriterPromptComplexity` l'est aussi : sous
/// `-default-isolation=MainActor`, un type non annoté est isolé au main
/// actor, ET SES CONFORMANCES AVEC LUI. Une `WriterPromptComplexity`
/// simplement `Equatable` ne serait donc pas comparable depuis un contexte
/// nonisolated (`complexity == .full` refusé à la compilation), ce qui
/// interdirait d'appeler ce prompt hors du main actor — exactement ce dont
/// le pipeline de recherche a besoin.
enum PromptTemplates {

    // MARK: - Formulations bannies (source de vérité unique)

    /// Formulations de SPÉCULATION : elles habillent une affirmation non
    /// sourcée en information. Port de la liste `Banned speculation phrases`
    /// de `writer.ts`, complétée de ses équivalents français — le web ne
    /// listait que l'anglais parce qu'il ne rédige pas en français par
    /// défaut, ce qui n'est pas le cas ici.
    ///
    /// Tout en minuscules et sans souci d'accent : la comparaison côté
    /// validateur replie casse ET diacritiques (« En Résumé » et « en resume »
    /// sont attrapés par la même entrée).
    nonisolated static let bannedSpeculationPhrases: [String] = [
        // Français
        "on peut en déduire",
        "on peut supposer",
        "on pourrait supposer",
        "il est probable que",
        "il est possible que",
        "on peut s'attendre à",
        "on pourrait s'attendre à",
        "il semblerait que",
        "cela suggère que",
        "cela laisse penser que",
        "vraisemblablement",
        // Anglais : un modèle bascule facilement en anglais sur une question
        // anglaise, les garde-fous doivent tenir des deux côtés.
        "it can be inferred",
        "it could be assumed",
        "users might",
        "it is likely that",
        "it is possible that",
        "one might expect",
        "we can expect",
        "we might expect",
        "presumably",
        "it appears that",
        "this suggests that",
        "arguably",
    ]

    /// Formulations de REMPLISSAGE : elles occupent de la place sans apporter
    /// d'information. Port de la liste `Banned phrases` de `writer.ts`, qui
    /// donnait déjà ses deux moitiés française et anglaise.
    ///
    /// Choix volontaire : « en conclusion » et « pour conclure » sont listés
    /// SANS virgule finale, là où le web écrivait `"in conclusion,"`. Une
    /// virgule en dur laisserait passer « En conclusion. » et « En
    /// conclusion : ». Aucun risque de faux positif sur un titre
    /// `## Conclusion`, qui ne contient pas la préposition.
    nonisolated static let bannedFillerPhrases: [String] = [
        // Français
        "il convient de noter que",
        "il est important de noter que",
        "il est essentiel de noter que",
        "il faut noter que",
        "comme nous l'avons vu",
        "comme mentionné précédemment",
        "en résumé",
        "pour résumer",
        "en conclusion",
        "pour conclure",
        "en somme",
        "dans cet article",
        "sans plus attendre",
        "il va sans dire",
        "au bout du compte",
        "de nos jours",
        // Anglais
        "it is worth noting that",
        "it's worth noting that",
        "it should be noted that",
        "it is important to note that",
        "it's important to note that",
        "it is essential to note that",
        "as we have seen",
        "in conclusion",
        "in summary",
        "to summarize",
        "this article will explore",
        "without further ado",
        "needless to say",
        "it goes without saying",
        "at the end of the day",
        "in today's world",
    ]

    /// Union des deux catégories, consommée par défaut par
    /// `ResponseStructureValidator`. Elles restent séparées au-dessus parce
    /// que le prompt les présente comme deux règles distinctes, pour deux
    /// raisons différentes ; le validateur, lui, n'a aucune raison de les
    /// distinguer — il constate une occurrence, point.
    nonisolated static let allBannedPhrases: [String] = bannedSpeculationPhrases + bannedFillerPhrases

    // MARK: - Marqueurs de texte imposés au modèle

    /// Marqueur à coller après une affirmation que les sources ne soutiennent
    /// pas (mode `reliable`). Équivalent de `(not confirmed in available
    /// sources)` du web.
    nonisolated static let unsupportedClaimMarker = "(non confirmé par les sources disponibles)"

    /// Avertissement d'ouverture imposé en mode `reliable` quand le contexte
    /// ne contient AUCUNE source. Équivalent du `⚠️ No verified sources…` du
    /// web, sans emoji (écart 4 en tête de fichier).
    nonisolated static let unverifiedSourcesWarning =
        "Attention : aucune source vérifiée n'a été trouvée pour cette question. La réponse ci-dessous s'appuie sur des connaissances générales et n'a pas été vérifiée :"

    /// Phrase exacte à produire quand le contexte ne permet pas de répondre.
    /// Équivalent de `I could not find reliable information…` du web.
    /// `ResponseStructureValidator` la connaît et l'exempte de l'exigence de
    /// citation : c'est une réponse CONFORME, qui par construction ne cite
    /// rien.
    nonisolated static let noRelevantInformationAnswer =
        "Je n'ai pas trouvé d'information fiable sur ce sujet dans les sources disponibles. Essaie de reformuler ta question ou de relancer la recherche."

    /// Contexte d'une recherche sans aucun document citable (`numberedContext`).
    nonisolated static let noSourcesContext = "Aucune source disponible."

    /// Préfixe imposé pour signaler deux sources qui se contredisent.
    /// Équivalent de `⚠️ **Sources disagree**` du web, sans emoji.
    nonisolated static let contradictorySourcesMarker = "**Les sources divergent**"

    // MARK: - Valeurs par défaut

    /// Aligné sur `QueryClassifier` (8), pour la même raison : ne pas saturer
    /// le contexte d'un modèle on-device avec une conversation longue.
    nonisolated static let defaultMaxHistoryMessages = 8

    /// Longueur maximale d'UN message d'historique (bug 1) : une réponse
    /// Approfondie dépasse à elle seule 3 000 caractères. 2 000 (~500 tokens)
    /// est la valeur « cloud » de la revue ; Apple Intelligence (~4k tokens)
    /// doit passer ~600 (réglage par moteur du bug 6, via l'orchestrateur).
    nonisolated static let defaultMaxHistoryMessageCharacters = 2000

    /// Aligné sur `SearchOrchestrator.init(maxScrapedContextCharacters:)`
    /// (8000 ≈ 2000 tokens avec le proxy caractères/4). Porter les constantes
    /// du web telles quelles ferait dépasser la fenêtre de contexte d'Apple
    /// Intelligence (~4k tokens) ou d'un MLX 0.6B, ce qui est un échec dur
    /// (refus ou troncature), pas une dégradation de qualité.
    nonisolated static let defaultMaxScrapedContextCharacters = 8000

    /// Seuil de mots à partir duquel une réponse en mode approfondi est
    /// considérée comme « assez longue pour mériter des titres » (voir
    /// `ResponseStructureValidator`). La constante vit ICI parce que c'est le
    /// prompt qui fixe l'attente (3 à 5 sections, ~500 mots) : le validateur
    /// ne fait que constater. 150 mots ≈ deux paragraphes pleins — en
    /// dessous, les sources étaient trop minces pour structurer, et exiger
    /// des titres produirait un faux positif systématique.
    nonisolated static let deepModeHeadingWordThreshold = 150

    // MARK: - Construction du prompt

    /// Construit le prompt de rédaction complet.
    ///
    /// `currentDate` est injectable (et non un `Date()` capturé à
    /// l'intérieur) pour une seule raison, mais décisive : sans lui, aucun
    /// test ne peut vérifier que la date est bien injectée, puisque la valeur
    /// changerait à chaque exécution. Le web fait `new Date().toISOString()`
    /// directement dans le template, ce qui est intestable.
    ///
    /// Appelé par `SearchOrchestrator.buildPrompt`. Un appelant qui valide
    /// la réponse doit passer `citableDocumentCount(sources:scrapedPages:)`
    /// — et pas `sources.count` — au validateur : la fusion par URL peut
    /// faire diverger les deux (voir `numberedContext`).
    ///
    /// `standaloneQuery` (bug 1) : la reformulation autonome du classifieur,
    /// celle qui a servi de sujet de recherche. Elle est donnée EN PLUS de la
    /// question, jamais à sa place (voir `reformulationLine`).
    nonisolated static func writerPrompt(
        query: String,
        standaloneQuery: String? = nil,
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = [],
        chatHistory: [ClassifierChatMessage] = [],
        mode: ResponseMode,
        complexity: WriterPromptComplexity = .full,
        currentDate: Date = Date(),
        maxHistoryMessages: Int = defaultMaxHistoryMessages,
        maxHistoryMessageCharacters: Int = defaultMaxHistoryMessageCharacters,
        maxScrapedContextCharacters: Int = defaultMaxScrapedContextCharacters
    ) -> String {
        let prompt = PromptParts(
            query: query,
            reformulation: reformulationLine(query: query, standaloneQuery: standaloneQuery),
            history: formattedHistory(
                chatHistory,
                maxHistoryMessages: maxHistoryMessages,
                maxHistoryMessageCharacters: maxHistoryMessageCharacters
            ),
            mode: mode,
            currentDate: currentDate
        )
        let context = numberedContext(
            sources: sources,
            scrapedPages: scrapedPages,
            maxScrapedContextCharacters: maxScrapedContextCharacters
        )

        switch complexity {
        case .full:
            return fullPrompt(prompt, context: context)
        case .concise:
            return concisePrompt(prompt, context: context)
        }
    }

    /// Parties communes déjà mises en forme : des signatures courtes.
    private nonisolated struct PromptParts {
        let query: String
        let reformulation: String
        let history: String
        let mode: ResponseMode
        let currentDate: Date
    }

    private nonisolated static func fullPrompt(_ parts: PromptParts, context: String) -> String {
        """
        Tu es Triva, un assistant de recherche précis et direct. Ta tâche : répondre à la question de l'utilisateur en t'appuyant sur les sources numérotées fournies plus bas.

        \(coreRulesSection)

        \(citationSection)

        \(formattingSection)

        \(modeSection(for: parts.mode, complexity: .full))

        \(specialCasesSection)

        \(checklistSection(for: parts.mode, complexity: .full))

        <historique_conversation>
        \(parts.history)
        </historique_conversation>

        <contexte>
        \(context)
        </contexte>\(contextReminder(for: parts.mode, context: context))

        Date et heure actuelles (UTC, format ISO 8601) : \(formattedDate(parts.currentDate)).

        \(parts.reformulation)Question de l'utilisateur : \(parts.query)
        """
    }

    /// Rappel du mode Fiable, juste après le contexte, donc au plus près de la question : c'est la
    /// seule consigne que le modèle lit APRÈS avoir vu ce que les documents contiennent. Mesuré le
    /// 2026-11-05 avec gpt-4o-mini : sur « Quelles sont les différences entre JavaScript et
    /// TypeScript ? », avec un seul document hors sujet (« Syntaxe JavaScript »), il répondait de tête,
    /// sans citation ni marqueur, malgré `modeSection` et `specialCasesSection` plus haut. Le mode qui
    /// promet de ne rien affirmer sans source affirmait alors tout sans source.
    ///
    /// Conditionnel au seul cas hors sujet, exprès : avec des documents pertinents, `modeSection`
    /// garde son marqueur `unsupportedClaimMarker`, qu'un « jamais de connaissances générales » sans
    /// condition contredirait. Vide hors du mode Fiable : les autres gabarits restent identiques au
    /// caractère près. Vide aussi sans aucun document (widget seul, le seul cas où la rédaction tourne
    /// alors) : `modeSection` prévoit déjà `unverifiedSourcesWarning`.
    private nonisolated static func contextReminder(for mode: ResponseMode, context: String) -> String {
        guard case .reliable = mode, context != noSourcesContext else { return "" }
        return "\n\nRappel du mode Fiable : si les documents ci-dessus ne traitent pas du sujet de la question, n'utilise pas tes connaissances générales, même si tu connais la réponse : réponds exactement « \(noRelevantInformationAnswer) »"
    }

    /// Version courte. Ce qui est gardé et pourquoi : les citations `[n]`
    /// (sans elles l'app perd sa raison d'être), l'interdiction d'inventer
    /// (un petit modèle hallucine d'autant plus qu'on le laisse faire), la
    /// longueur (un 0.6B part sinon en boucle de répétition). Ce qui saute :
    /// les listes exhaustives de formulations bannies, la checklist finale,
    /// les exemples MAUVAIS/BON, les cas particuliers.
    ///
    /// Le validateur continue de vérifier les formulations bannies dans ce
    /// mode : une violation y est une information utile sur le modèle, pas un
    /// reproche — le prompt ne les lui a pas listées.
    private nonisolated static func concisePrompt(_ parts: PromptParts, context: String) -> String {
        """
        Tu es Triva. Réponds à la question en t'appuyant uniquement sur les sources numérotées ci-dessous.

        Règles :
        - Termine chaque affirmation factuelle par le numéro de sa source entre crochets, par exemple : La tour Eiffel mesure 330 mètres[1].
        - Plusieurs sources pour un même fait : [1][2].
        - N'invente rien. Si les sources ne le disent pas, ne l'écris pas.
        - Pas de phrase de remplissage, pas de répétition, pas de titre principal.

        \(modeSection(for: parts.mode, complexity: .concise))

        <historique_conversation>
        \(parts.history)
        </historique_conversation>

        <contexte>
        \(context)
        </contexte>

        Date du jour (UTC, ISO 8601) : \(formattedDate(parts.currentDate)).

        \(parts.reformulation)Question : \(parts.query)
        """
    }

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
            currentDate: currentDate
        )
        switch complexity {
        case .full:
            return fullConversationPrompt(parts)
        case .concise:
            return conciseConversationPrompt(parts)
        }
    }

    /// Les deux verbosités du prompt sans recherche, séparées comme `fullPrompt`/`concisePrompt`.
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

    // MARK: - Sections du prompt détaillé

    /// Les listes de formulations bannies sont interpolées depuis les
    /// constantes Swift, jamais recopiées à la main : c'est ce qui garantit
    /// que le prompt et le validateur parlent de la même chose.
    private nonisolated static let coreRulesSection: String = """
    ### Principes fondamentaux
    - **Langue** : réponds dans la langue de la question, sauf si la question demande explicitement une autre langue. Ne mélange jamais deux langues dans une même réponse.
    - **Continuité de la conversation** : l'historique est fourni plus bas. Si la question est courte, ambiguë ou renvoie implicitement à un message précédent (« pourquoi ? », « et le deuxième ? », « développe », « et en France ? »), identifie le sujet dans l'historique et réponds dans ce contexte — ne la traite jamais comme une question isolée. Les numéros [n] de l'historique désignaient les sources d'échanges précédents : ne les recopie pas, cite uniquement le contexte ci-dessous.
    - **Précision d'abord** : chaque affirmation factuelle doit porter une citation [n] renvoyant au contexte. Une affirmation qui ne peut pas être sourcée doit être supprimée, pas nuancée.
    - **Aucune spéculation** : n'utilise jamais une tournure prudente pour faire passer un fait non sourcé. Formulations interdites : \(quotedList(bannedSpeculationPhrases)).
    - **Aucun remplissage** : formulations interdites, en français comme en anglais : \(quotedList(bannedFillerPhrases)).
    - **Aucune répétition** : ne redis jamais la même chose autrement. Chaque phrase doit apporter une information nouvelle.
    - **Pas de conclusion creuse** : une conclusion contient une implication, une limite ou une suite concrète — jamais un résumé de ce qui précède.
    - **Sources minces** : si les sources ne couvrent pas un point assez bien pour l'écrire factuellement, ne comble pas le vide. Écris 1 à 2 phrases qui l'admettent : « Les sources disponibles ne donnent pas d'information précise sur X. »
    - **Sources contradictoires** : si deux sources se contredisent sur un même point factuel, signale-le juste après les affirmations en cause : « \(contradictorySourcesMarker) — la source 1 indique X[1] alors que la source 2 indique Y[2]. » Ne tranche pas, ne réconcilie pas : rapporte la divergence telle quelle.
    """

    private nonisolated static let citationSection: String = """
    ### Citations
    - Cite chaque affirmation factuelle avec la notation [n], où n est le numéro du document dans le contexte.
    - Colle la citation à la fin de la proposition ou de la phrase : « La tour Eiffel mesure 330 mètres[1]. »
    - Plusieurs sources pour un même fait : « Paris est un pôle culturel majeur[1][2]. » Jamais [1,2].
    - N'invente jamais un numéro absent du contexte, et n'écris jamais [0] : la numérotation commence à 1.
    - Une affirmation impossible à rattacher à une source est soit supprimée, soit explicitement marquée \(unsupportedClaimMarker).
    """

    private nonisolated static let formattingSection: String = """
    ### Mise en forme
    - **Pas de titre principal** : commence directement par le contenu (ou par le bloc <think> en mode approfondi).
    - **Titres** : n'utilise des titres ## que si la réponse couvre 3 sujets distincts ou plus. Jamais de titre pour un seul paragraphe.
    - **Listes** : des puces uniquement pour des éléments réellement énumérables (étapes, options, caractéristiques) — jamais pour allonger artificiellement.
    - **Longueur** : proportionne la réponse à la complexité réelle de la question. Une question factuelle simple appelle 1 à 3 phrases, pas 5 paragraphes.
    """

    private nonisolated static let specialCasesSection: String = """
    ### Cas particuliers
    - Si le contexte ne contient aucune information pertinente, réponds exactement : « \(noRelevantInformationAnswer) »
    - Si la question est purement conversationnelle (salutation, demande d'avis), réponds naturellement, sans citation.
    """

    // MARK: - Sections par mode

    /// Consignes de forme propres au mode. `quick` et `deep` sont des ports
    /// de `writer.ts` ; `reliable` est écrit ici (écart 2 en tête de fichier).
    ///
    /// Divergence assumée entre les deux verbosités, indispensable à
    /// comprendre pour lire `ResponseStructureValidator` : en `deep` +
    /// `.full`, les blocs `<think>` et `<tldr>` sont EXIGÉS ; en `deep` +
    /// `.concise`, ils sont INTERDITS. Demander trois formats imbriqués
    /// (raisonnement, résumé, sections) à un modèle 0.6B produit en pratique
    /// des balises ouvertes jamais refermées, qui s'affichent brutes dans la
    /// bulle de réponse. Le validateur reçoit donc la verbosité, pour ne
    /// jamais reprocher au modèle une consigne qu'on ne lui a pas donnée.
    nonisolated static func modeSection(for mode: ResponseMode, complexity: WriterPromptComplexity) -> String {
        switch (mode, complexity) {
        case (.quick, .full):
            return """
            ### Format de réponse — mode Rapide
            - Écris EXACTEMENT 2 à 3 phrases, pas une de plus.
            - Aucun titre, aucune liste.
            - La première phrase répond directement à la question ; la suivante apporte un fait d'appui ou une nuance.
            - N'utilise NI bloc <think>, NI bloc <tldr> : donne la réponse directement.
            """
        case (.quick, .concise):
            return """
            Format : 2 à 3 phrases maximum, aucun titre, aucune liste, pas de balise <think> ni <tldr>.
            """
        case (.deep, .full):
            return """
            ### Format de réponse — mode Approfondi
            - **Raisonnement d'abord** : avant d'écrire, réfléchis dans un bloc <think>...</think> de 2 à 4 phrases MAXIMUM : (1) reformule la question centrale, (2) nomme la ou les sources les plus pertinentes et pourquoi, en une expression chacune, (3) nomme UNE tension, nuance ou limite précise des sources que la réponse devra traiter avec soin. Ne résume pas ce que la réponse va dire. Referme toujours par </think>.
            - **TL;DR** : juste après </think> et AVANT le premier titre ##, écris une seule phrase dans des balises <tldr>...</tldr>, qui répond directement à la question centrale. Exactement UNE phrase, et referme toujours par </tldr>.
            - **Questions à plusieurs volets** : si la question porte sur 2 sujets distincts ou plus, consacre une section ## à chacun. Ne fusionne jamais deux sujets sans rapport dans un même paragraphe.
            - **Structure** : les titres ## sont OBLIGATOIRES dans ce mode. Organise la réponse en 3 à 5 sections couvrant des aspects distincts (ce que c'est, comment ça marche, pourquoi c'est important, compromis, contexte).
            - **Attaque** : ouvre la première section par la réponse elle-même ou par le résultat le plus important. Ne commence pas par « X est un sujet qui... » ni par « C'est une question importante. »
            - **Longueur** : vise 500 mots minimum quand les sources sont assez riches. Si elles ne le permettent pas, écris aussi complet que le matériau l'autorise — ne comble jamais avec de la spéculation.
            - **Conclusion** : termine par EXACTEMENT UNE section ## Conclusion, jamais deux. 2 phrases MAXIMUM. Avant de l'écrire, vérifie : « ma conclusion dit-elle quelque chose qui n'apparaît dans aucune section du corps ? » Si non, réécris-la. Une conclusion valide contient soit (a) un compromis, une limite ou une conséquence non discutés dans le corps, soit (b) une suite concrète ou une question ouverte qui découle des résultats.
            - MAUVAIS (simple redite, à ne jamais faire) : « Le ramasse-miettes est un élément clé des langages modernes, il gère la mémoire automatiquement et réduit les fuites. Ces avantages le rendent précieux pour la plupart des applications. »
            - BON (implication nouvelle) : « Rust écarte volontairement le ramasse-miettes pour supprimer les pauses imprévisibles — pour un système sensible à la latence, ce compromis vaut la complexité de la gestion manuelle de la mémoire[1]. »
            """
        case (.deep, .concise):
            return """
            Format : réponse structurée en 3 à 5 sections avec des titres ##, puis une section ## Conclusion de 2 phrases maximum qui apporte une idée nouvelle. Pas de balise <think> ni <tldr>.
            """
        case (.reliable, .full):
            return """
            ### Format de réponse — mode Fiable
            - N'écris que des affirmations directement soutenues par une source du contexte. Pour tout ce qui ne l'est pas, ajoute \(unsupportedClaimMarker) juste après la phrase — ne supprime jamais ce marqueur pour fluidifier le texte.
            - Ne déduis rien au-delà de ce que les sources affirment explicitement.
            - Structure : paragraphes courts. Titres ## seulement si la réponse couvre 3 sujets distincts ou plus.
            - N'utilise NI bloc <think>, NI bloc <tldr> : donne la réponse directement.
            - Conclusion facultative ; si tu en écris une, 2 phrases MAXIMUM, et elle doit apporter une limite ou une suite concrète.
            - Si le contexte ne contient AUCUNE source, commence par exactement : « \(unverifiedSourcesWarning) » puis réponds en marquant chaque phrase par \(unsupportedClaimMarker).
            """
        case (.reliable, .concise):
            return """
            Format : n'écris que ce que les sources disent explicitement. Ajoute \(unsupportedClaimMarker) après toute phrase non soutenue par une source. Pas de balise <think> ni <tldr>.
            """
        }
    }

    /// Checklist finale, port de `Final checklist before writing` du web.
    /// Utile uniquement en `.full` : sur un petit modèle, elle doublerait la
    /// longueur du prompt pour rappeler des règles déjà énoncées — d'où la
    /// chaîne vide en `.concise`. `complexity` reste un paramètre (plutôt
    /// qu'un appel réservé à `.full`) pour que la fonction soit totale et
    /// testable des deux côtés.
    nonisolated static func checklistSection(for mode: ResponseMode, complexity: WriterPromptComplexity) -> String {
        guard complexity == .full else { return "" }

        let shared = """
        ### Vérification finale avant d'écrire
        - La réponse est dans la langue de la question.
        - Chaque phrase qui énonce un fait porte une citation [n].
        - Aucune des formulations interdites listées plus haut n'apparaît (relis mot à mot).
        - Aucune phrase ne répète un point déjà fait.
        - Aucun numéro de citation ne dépasse le nombre de documents du contexte, et aucun n'est [0].
        """

        switch mode {
        case .quick:
            return shared + """

            - Mode Rapide : 3 phrases MAXIMUM au total, puis tu t'arrêtes.
            - Mode Rapide : aucun bloc <think> ni <tldr>, la réponse commence directement.
            """
        case .deep:
            return shared + """

            - Mode Approfondi : des titres ## sont présents, et il y a EXACTEMENT une section ## Conclusion, tout à la fin.
            - Mode Approfondi : la réponse commence par un bloc <think>...</think> de 2 à 4 phrases, suivi immédiatement d'un bloc <tldr>...</tldr> d'une seule phrase, l'un et l'autre refermés.
            - Mode Approfondi : le bloc <tldr> est APRÈS </think> et AVANT le premier titre ##, jamais à l'intérieur d'une section.
            - Mode Approfondi : la conclusion fait 2 phrases maximum et dit quelque chose qui n'est dans aucune section du corps.
            """
        case .reliable:
            return shared + """

            - Mode Fiable : chaque affirmation non soutenue par une source porte le marqueur \(unsupportedClaimMarker).
            - Mode Fiable : aucun bloc <think> ni <tldr>, la réponse commence directement.
            """
        }
    }

    // MARK: - Contexte numéroté

    /// Construit le bloc de contexte que les citations `[n]` référencent.
    ///
    /// Décision structurante : **une page scrapée n'obtient PAS son propre
    /// numéro si son URL correspond déjà à une source de recherche.** Son
    /// contenu est fusionné dans le document de cette source. Sans cette
    /// fusion, la même page apparaîtrait deux fois sous deux numéros
    /// différents, et le modèle citerait indifféremment l'un ou l'autre : la
    /// liste de sources affichée sous la réponse (0.8) ne correspondrait plus
    /// aux numéros cités — c'est-à-dire exactement la promesse de l'app qui
    /// casse. Une page scrapée dont l'URL n'est dans aucune source est ajoutée
    /// à la suite, avec son propre numéro — cas que le pipeline ne produit
    /// plus (bug 8) : `SearchOrchestrator` ne scrape que des sources
    /// affichées et recopie l'URL exacte de la source sur chaque page. Ce
    /// repli ne sert plus qu'à un appelant direct.
    ///
    /// Format volontairement différent de l'ancien `<result index=… title=…>`
    /// du prompt minimal de 0.7/1.2 (remplacé par ce prompt depuis le
    /// branchement de 1.4) : le numéro est écrit
    /// `[1]`, exactement sous la forme qu'on demande au modèle de recopier.
    /// Un modèle reproduit ce qu'il voit ; lui montrer `index=1` et lui
    /// demander d'écrire `[1]` ajoute une transformation gratuite.
    ///
    /// Les pages scrapées en échec (`succeeded == false`) ou vides sont
    /// ignorées : elles n'ajouteraient qu'un document citable creux.
    nonisolated static func numberedContext(
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = [],
        maxScrapedContextCharacters: Int = defaultMaxScrapedContextCharacters
    ) -> String {
        let documents = citableDocuments(sources: sources, scrapedPages: scrapedPages)
        guard !documents.isEmpty else {
            return noSourcesContext
        }

        // Répartition équitable du budget de caractères entre les documents
        // qui portent du contenu scrapé — protection anti-overflow « NIVEAU 2 »
        // du pipeline (elle vivait dans `SearchOrchestrator.formatScrapedPages`
        // avant le branchement de 1.4) : un plafond consommé au fil de l'eau
        // laisserait le premier document manger tout le budget.
        let scrapedDocumentCount = documents.filter { !$0.scrapedContent.isEmpty }.count
        let budgetPerDocument = scrapedDocumentCount > 0
            ? max(1, maxScrapedContextCharacters / scrapedDocumentCount)
            : 0

        return documents.enumerated()
            .map { index, document in
                var block = "[\(index + 1)] \(document.title) — \(document.url)"
                if !document.snippet.isEmpty {
                    block += "\nExtrait : \(document.snippet)"
                }
                if !document.scrapedContent.isEmpty, budgetPerDocument > 0 {
                    block += "\nContenu de la page : \(document.scrapedContent.prefix(budgetPerDocument))"
                }
                return block
            }
            .joined(separator: "\n\n")
    }

    /// Nombre de documents citables — donc le plus grand `n` valide dans une
    /// citation `[n]`. Exposé pour que l'appelant qui branche ce prompt le
    /// passe tel quel à `ResponseStructureValidator` sans re-dériver la règle
    /// de fusion par URL et tomber sur un autre compte.
    nonisolated static func citableDocumentCount(
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = []
    ) -> Int {
        citableDocuments(sources: sources, scrapedPages: scrapedPages).count
    }

    /// Un document citable, dans l'ordre de numérotation final.
    /// `nonisolated` pour la même raison que `WriterPromptComplexity` : sa
    /// conformance `Equatable` doit rester utilisable hors du main actor.
    private nonisolated struct CitableDocument: Sendable, Equatable {
        let url: String
        let title: String
        let snippet: String
        let scrapedContent: String
    }

    private nonisolated static func citableDocuments(
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage]
    ) -> [CitableDocument] {
        let usablePages = scrapedPages.filter { $0.succeeded && !$0.content.isEmpty }

        // Première page gagne en cas de doublon d'URL : cohérent avec la
        // déduplication « premier arrivé » de `SearchOrchestrator.accumulate`.
        var pagesByNormalizedURL: [String: ScrapedPage] = [:]
        for page in usablePages {
            let key = normalizedURL(page.url)
            guard pagesByNormalizedURL[key] == nil else { continue }
            pagesByNormalizedURL[key] = page
        }

        var consumedURLs: Set<String> = []
        var documents: [CitableDocument] = sources.map { source in
            let key = normalizedURL(source.url)
            guard let matchingPage = pagesByNormalizedURL[key] else {
                return CitableDocument(
                    url: source.url,
                    title: source.title,
                    snippet: source.content ?? "",
                    scrapedContent: ""
                )
            }
            consumedURLs.insert(key)
            return CitableDocument(
                url: source.url,
                title: source.title,
                snippet: source.content ?? "",
                scrapedContent: matchingPage.content
            )
        }

        for page in usablePages {
            let key = normalizedURL(page.url)
            guard !consumedURLs.contains(key) else { continue }
            consumedURLs.insert(key)
            documents.append(
                CitableDocument(url: page.url, title: page.title, snippet: "", scrapedContent: page.content)
            )
        }

        return documents
    }

    /// Normalisation minimale et volontairement prudente pour comparer deux
    /// URLs : espaces retirés, casse ignorée, slash final ignoré. On ne
    /// touche PAS au schéma (http/https), ni au sous-domaine `www.`, ni aux
    /// paramètres de requête : deux URLs qui ne diffèrent que par ça peuvent
    /// pointer vers des contenus réellement différents, et fusionner à tort
    /// deux documents attribuerait au modèle une citation qui ne correspond
    /// pas à la source affichée — le bug précis que la fusion cherche à
    /// éviter.
    private nonisolated static func normalizedURL(_ url: String) -> String {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    // MARK: - Historique et utilitaires

    /// Même convention de troncature que `QueryClassifier.buildPrompt` :
    /// seuls les `maxHistoryMessages` derniers messages sont gardés, et
    /// `max(0, …)` protège d'une valeur négative — la fonction est appelable
    /// directement (non `private`), donc on ne fait pas confiance à
    /// l'appelant (`suffix(_:)` trappe sur un argument négatif).
    /// Bug 1 : chaque message est aussi borné en LONGUEUR. Un budget nul ou
    /// négatif vaut « aucun historique » (`splitIntoChunks` rendrait sinon le
    /// texte ENTIER).
    nonisolated static func formattedHistory(
        _ chatHistory: [ClassifierChatMessage],
        maxHistoryMessages: Int = defaultMaxHistoryMessages,
        maxHistoryMessageCharacters: Int = defaultMaxHistoryMessageCharacters
    ) -> String {
        let kept = chatHistory.suffix(max(0, maxHistoryMessages))
        guard !kept.isEmpty, maxHistoryMessageCharacters > 0 else { return "Aucun échange précédent." }

        return kept
            .map { message in
                let content = boundedHistoryContent(message.content, maxCharacters: maxHistoryMessageCharacters)
                switch message.role {
                case .user:
                    return "Utilisateur : \(content)"
                case .assistant:
                    return "Assistant : \(content)"
                }
            }
            .joined(separator: "\n")
    }

    /// Garde le DÉBUT d'un message trop long, coupé sur une frontière de
    /// phrase (pas de mot coupé en deux) : `ScrapeService.firstChunk`, soit
    /// le premier chunk de `splitIntoChunks` sans découper tout le message —
    /// une réponse Approfondie en compte plusieurs milliers de caractères.
    /// « […] » marque la coupe : sans lui, le modèle prendrait un début de
    /// réponse pour la réponse entière. Exige `maxCharacters > 0`. Aussi
    /// utilisée pour l'historique du classifieur (`SearchOrchestrator.boundedHistory`).
    nonisolated static func boundedHistoryContent(_ content: String, maxCharacters: Int) -> String {
        guard content.count > maxCharacters else { return content }
        let head = ScrapeService.firstChunk(of: content, maxCharacters: maxCharacters)
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + " […]"
    }

    /// Ligne « question reformulée » (bug 1) juste avant la question, ou rien.
    /// La question reste celle de l'utilisateur : la reformulation peut se
    /// tromper, et l'historique permet au modèle de s'en apercevoir. Omise si
    /// absente, vide ou identique à la question (casse et accents ignorés).
    nonisolated static func reformulationLine(query: String, standaloneQuery: String?) -> String {
        guard let standalone = standaloneQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !standalone.isEmpty else { return "" }
        let original = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard standalone.compare(original, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else { return "" }
        return "Question reformulée d'après la conversation : \(standalone)\n"
    }

    /// Format ISO 8601 UTC, comme le web, malgré un prompt en français : une
    /// date localisée dépendrait de la locale de l'appareil et rendrait le
    /// prompt non déterministe d'un utilisateur à l'autre, pour zéro gain de
    /// compréhension côté modèle.
    nonisolated static func formattedDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private nonisolated static func quotedList(_ phrases: [String]) -> String {
        phrases.map { "« \($0) »" }.joined(separator: ", ")
    }
}
