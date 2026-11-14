//
//  SearchOrchestrator.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import Foundation

/// Orchestration multi-actions (1.2), avec le classement des sources (1.3),
/// le prompt de rédaction (1.4), le mode de réponse (1.13), les widgets
/// (1.5), les médias (1.6) et les fichiers joints (1.11) branchés.
///
/// Pipeline :
/// 1. `QueryClassifier` (1.1, un seul appel) classe la question et fournit
///    sa reformulation autonome (`standaloneFollowUp`) ; `SearchRoute.resolve`
///    en tire la route : aucune recherche, fichiers joints seuls, recherche
///    web (générale, académique, forums), ou météo répondue par son widget ;
/// 2. EN PARALLÈLE de la route, `WidgetExecutor` lance les widgets que la
///    classification demande (météo, calcul ; aucun sinon) ;
/// 3. recherche web : l'action seedée interroge SearXNG avec la
///    REFORMULATION (`effectiveQuery`, bug 1) — ou, quand l'envoi fournit la
///    chaîne de repli (RI1b, `webSearchChain`), ses sources dans l'ordre :
///    clé personnelle, SearXNG, recherche du fournisseur cloud, sources
///    ouvertes ; une recherche à moteurs forcés (Reddit, académique) restée
///    vide retombe sur la recherche web (bug 5) ; les médias demandés par
///    l'appelant partent en même temps, sur SearXNG seul ;
/// 4. `SourceRanker.rank` classe ces résultats (similarité + position +
///    domaine, une langue à la fois — décision 3 de Ben), les restreint aux
///    domaines fiables en mode Fiable, déduplique et borne au nombre de
///    sources du mode ;
/// 5. boucle planner bornée (`scrapeURL`/`done`), qui ne voit et ne peut
///    scraper QUE ces sources classées — les sources affichées (bug 8) —,
///    chacune au plus une fois (bug 11), et ne tourne pas en mode Rapide ;
///    les fichiers joints, eux, sont consultés dès le tour seedé (décision
///    (b) de Ben, `routeConsultingAttachments`) ;
/// 6. `PromptTemplates.writerPrompt` (citations `[n]`, anti-remplissage,
///    forme propre au mode, historique borné) — ou, sans recherche,
///    `PromptTemplates.conversationPrompt` —, données des widgets insérées
///    juste avant la question, puis génération simple ou en streaming.
///
/// ## Appels LLM par requête (coût et latence)
/// Le classement et la recherche dans les fichiers joints (embeddings
/// `NaturalLanguage`, sur l'appareil), le scraping et les médias (réseau
/// seul) ne coûtent AUCUN appel LLM. Restent :
/// - 1 classification (`QueryClassifier.classify`), toujours ;
/// - 1 par widget DEMANDÉ par la classification (extraction du lieu ou de
///   l'expression), aucun sinon ;
/// - 0 à `maxIterations - 1` tours planner, arrêtés au premier "done" (ou
///   sortie imparsable, action inconnue, échec du planner), ou quand plus
///   rien n'est à faire (toutes les sources affichées tentées, fichiers
///   joints déjà consultés) — aucun sans recherche web ;
/// - 1 génération finale (`generate` ou `streamGenerate`).
/// Avec les valeurs de `ResponseMode`, hors widgets : Rapide 2 appels ;
/// Fiable 3 au plus ; Approfondie 4 au plus ; sans recherche 2 dans tous les
/// modes.
///
/// ## Annulation (bug 3)
/// Le bouton Stop annule la tâche englobante. Aucune étape auxiliaire ne
/// l'avale (`bestEffort`), et la tâche est vérifiée au début de chaque tour
/// planner, après chaque série de scrapes (`ScrapeService.scrape` rend une
/// page en échec plutôt que de lever) et juste avant la génération finale :
/// une annulation lève `CancellationError` au lieu de relancer un appel LLM.
/// Un tour de scrape est en plus borné dans le temps (`scrapeRoundTimeout`).
///
/// ## Concurrence
/// `nonisolated` (service sans état d'interface) ET `@concurrent` sur
/// `answer`/`streamAnswer` : sous `NonisolatedNonsendingByDefault`, une
/// méthode `nonisolated async` tourne sur l'acteur de son APPELANT — appelée
/// par `ChatViewModel`, tout le pipeline (fusion, filtrage d'URLs, prompt de
/// rédaction, parsing du planner) tournait sur le thread d'interface. Les
/// étapes isolées au main actor (`QueryClassifier`, providers `AIGenerating`,
/// actions `SearchAction` : types non annotés hors de ce fichier) y sautent le
/// temps de leur appel. Prouvé par `SearchOrchestratorStreamingTests`.
nonisolated struct SearchOrchestrator: Sendable {
    // Propriétés SANS `private` : lues par `SearchOrchestrator+WebResearch.swift` (recherche web, médias,
    // boucle planner). Les autres restent privées à ce fichier.
    let failoverManager: FailoverManager
    let aiProvider: any AIGenerating
    private let queryClassifier: QueryClassifier
    let scrapeService: any ScrapeServing
    let sourceRanker: SourceRanker
    let responseMode: ResponseMode
    private let writerComplexity: WriterPromptComplexity
    let maxResultsUsedForContext: Int
    let maxIterations: Int
    let restrictsToTrustedDomains: Bool
    let maxScrapedURLsPerIteration: Int
    private let maxScrapedContextCharacters: Int
    private let maxHistoryMessages: Int
    private let maxHistoryMessageCharacters: Int
    let scrapeRoundTimeout: Duration
    let clock: any Clock<Duration>
    /// Voir `scrapeAll(onPageCollected:)` : sonde de test, `nil` en production.
    let onScrapedPageCollected: (@Sendable (ScrapedPage) -> Void)?
    private let widgetExecutor: WidgetExecutor
    let mediaSearcher: any MediaSearching
    let mediaGracePeriod: Duration
    private let maxAttachmentContextCharacters: Int
    /// Chaîne de repli de la recherche web (RI1b), `nil` = SearXNG seul.
    let webSearchChain: WebSearchChain?
    /// Appareil hors connexion (tâche 1.16, `ConnectivityMonitor`) : aucune recherche web, aucun
    /// widget météo ; fichiers joints et calcul restent disponibles. Voir `SearchOrchestrator+Offline.swift`.
    private let isOffline: Bool

    /// Attente maximale des médias (1.6) une fois la recherche texte finie :
    /// au-delà, ils valent `.failed` et la réponse part sans eux. Les médias
    /// ne nourrissent pas le prompt, ils ne doivent pas retarder le premier
    /// token de plus que ça (une instance qui bascule de panne en panne peut
    /// prendre bien plus). Les widgets, eux, nourrissent le prompt : ils sont
    /// attendus, sous leur propre borne (`WidgetExecutor.defaultTotalTimeout`).
    static let defaultMediaGracePeriod: Duration = .seconds(2)

    /// Borne d'un tour de scrape : `ScrapeService.maxPageLoadDuration` (12 s
    /// par page, réseau compris) plus 3 s de marge pour l'extraction. Filet de
    /// sécurité au-dessus des bornes de chaque page : un tour ne dépasse pas
    /// 15 s pour toute implémentation de `ScrapeServing` qui honore
    /// l'annulation — `ScrapeService` le fait (`URLSession` async). Une
    /// implémentation qui l'ignore retarde la fin du tour : voir la limite
    /// assumée de `scrapeAll`.
    static let defaultScrapeRoundTimeout: Duration = .seconds(15)

    /// Init principal (bug 6) : `configuration` porte les budgets du moteur
    /// actif (`SearchPipelineConfiguration.preset(for:mlxModel:)`). Sans
    /// valeur par défaut exprès : un appel sans elle reste résolu sans
    /// ambiguïté vers l'init historique ci-dessous.
    ///
    /// `@MainActor` sur un type `nonisolated` : lire les propriétés de
    /// `ResponseMode` et construire le `QueryClassifier` par défaut touchent
    /// deux types non annotés, donc isolés au main actor. Les trois valeurs
    /// tirées du mode sont copiées ICI dans des champs simples, lisibles
    /// ensuite depuis les points d'entrée `@concurrent`. `queryClassifier`
    /// par défaut est résolu dans le corps : un paramètre par défaut ne peut
    /// pas référencer `aiProvider`.
    ///
    /// - Parameters:
    ///   - responseMode: `.quick` par défaut, la valeur de
    ///     `ResponseModeSettingsStore.defaultMode` (décision 6 de Ben), écrite
    ///     en littéral : ce `static` est isolé au main actor, une valeur par
    ///     défaut isolée serait refusée si l'init cessait de l'être. Un test
    ///     vérifie que les deux valeurs restent alignées.
    ///   - configuration: complexité des prompts (classification ET
    ///     rédaction), bornes d'historique (prompt final ET classifieur, qui
    ///     n'en bornait que le nombre), budget scrapé, pages par tour. Les
    ///     constantes de la version web d'origine (3 000 tokens/chunk × 4 chunks × 3 URLs ≈ 36k tokens)
    ///     supposent une compression LLM par chunk absente ici : elles
    ///     feraient échouer tout modèle sur l'appareil.
    ///   - queryClassifier: injecté tel quel (ses réglages priment) ; sinon
    ///     construit avec la complexité et le nombre de messages du budget.
    ///   - sourceRanker: classement 1.3, injecté entier pour que les tests
    ///     maîtrisent aussi les doublons et la détection de langue.
    ///   - maxIterations, et `configuration.maxResultsUsedForContext` :
    ///     PLAFONDS, pas des cibles — valeur effective `min(plafond, valeur du
    ///     mode)` (`effectiveLimit`). Un plafond qui l'emporterait sur le mode
    ///     désactiverait en silence le mode Rapide (3 sources, aucun planner).
    ///     Les défauts (5 et 3) égalent le maximum des modes : ils ne
    ///     contraignent rien.
    ///   - scrapeRoundTimeout, clock: échéance d'un tour de scrape et horloge
    ///     qui la mesure, injectables pour les tests. L'horloge ne sert QU'À
    ///     cette échéance (un test compte ses lectures).
    ///   - widgets: `nil` (défaut) -> la liste de production
    ///     (`defaultWidgets(aiProvider:)` : météo, calcul) ; `[]` désactive
    ///     les widgets. Chaque widget ne tourne que si la classification le
    ///     demande.
    ///   - mediaSearcher: `nil` (défaut) -> `SearXNGMediaSearcher` sur le
    ///     même `failoverManager`. Ne sert que si l'appelant demande des médias.
    ///   - mediaGracePeriod: voir `defaultMediaGracePeriod`.
    ///   - webSearchChain: chaîne de repli de la recherche web (RI1b) : clé
    ///     personnelle, SearXNG, recherche du fournisseur cloud, sources
    ///     ouvertes (`WebSearchChain`). Sert aux seules actions web du tour
    ///     seedé ; les médias restent sur SearXNG (`mediaSearcher`). `nil`
    ///     (défaut) : SearXNG seul, comportement d'avant la chaîne.
    ///   - isOffline: `false` (défaut) = comportement d'avant la tâche 1.16. `true` : l'appareil est hors
    ///     connexion, le pipeline répond sans recherche web ni météo (voir `SearchOrchestrator+Offline.swift`).
    ///
    /// Budget des fichiers joints : `min(UploadsSearchResultBuilder.defaultMaxTotalCharacters,
    /// configuration.maxScrapedContextCharacters)` — 3 000 caractères sous
    /// Apple Intelligence plutôt que 6 000 —, divisé par deux quand ils
    /// s'ajoutent à une recherche web (planner). Dans ce second cas, ce
    /// qu'ils occupent est retranché du budget des pages scrapées
    /// (`scrapedContextBudget`) : `maxScrapedContextCharacters` borne tout le
    /// contenu long du prompt. Nombre d'extraits : `attachmentFragmentLimit(forBudget:)`.
    @MainActor
    init(
        failoverManager: FailoverManager,
        aiProvider: any AIGenerating,
        responseMode: ResponseMode = .quick,
        configuration: SearchPipelineConfiguration,
        queryClassifier: QueryClassifier? = nil,
        scrapeService: any ScrapeServing = ScrapeService(),
        sourceRanker: SourceRanker = SourceRanker(),
        maxIterations: Int = 3,
        scrapeRoundTimeout: Duration = SearchOrchestrator.defaultScrapeRoundTimeout,
        clock: any Clock<Duration> = ContinuousClock(),
        widgets: [any SearchWidget]? = nil,
        mediaSearcher: (any MediaSearching)? = nil,
        mediaGracePeriod: Duration = SearchOrchestrator.defaultMediaGracePeriod,
        webSearchChain: WebSearchChain? = nil,
        isOffline: Bool = false,
        onScrapedPageCollected: (@Sendable (ScrapedPage) -> Void)? = nil
    ) {
        self.onScrapedPageCollected = onScrapedPageCollected
        self.failoverManager = failoverManager
        self.aiProvider = aiProvider
        self.webSearchChain = webSearchChain
        self.isOffline = isOffline
        self.queryClassifier = queryClassifier ?? QueryClassifier(
            aiProvider: aiProvider,
            maxHistoryMessages: configuration.maxHistoryMessages,
            promptComplexity: configuration.classifierPromptComplexity
        )
        self.scrapeService = scrapeService
        self.sourceRanker = sourceRanker
        self.responseMode = responseMode
        self.writerComplexity = configuration.promptComplexity
        self.maxResultsUsedForContext = Self.effectiveLimit(cap: configuration.maxResultsUsedForContext, modeValue: responseMode.targetSourceCount)
        self.maxIterations = Self.effectiveLimit(cap: maxIterations, modeValue: responseMode.maxSearchIterations)
        self.restrictsToTrustedDomains = responseMode.restrictsToTrustedDomains
        self.maxScrapedURLsPerIteration = configuration.maxScrapedURLsPerIteration
        self.maxScrapedContextCharacters = configuration.maxScrapedContextCharacters
        self.maxHistoryMessages = configuration.maxHistoryMessages
        self.maxHistoryMessageCharacters = configuration.maxHistoryMessageCharacters
        self.scrapeRoundTimeout = scrapeRoundTimeout
        self.clock = clock
        self.widgetExecutor = WidgetExecutor(widgets: Self.widgetsAvailable(
            widgets ?? Self.defaultWidgets(aiProvider: aiProvider), isOffline: isOffline
        ))
        self.mediaSearcher = mediaSearcher ?? SearXNGMediaSearcher(failoverManager: failoverManager)
        self.mediaGracePeriod = mediaGracePeriod
        self.maxAttachmentContextCharacters = max(
            0,
            min(UploadsSearchResultBuilder.defaultMaxTotalCharacters, configuration.maxScrapedContextCharacters)
        )
    }

    /// `min(plafond, valeur du mode)`, jamais négatif : un plafond négatif
    /// passé par erreur vaut 0 (aucune source, aucun tour planner) plutôt
    /// que de faire trapper un `prefix` ou une plage plus loin.
    static func effectiveLimit(cap: Int, modeValue: Int) -> Int {
        max(0, min(cap, modeValue))
    }

    /// - Parameters:
    ///   - chatHistory: les échanges PRÉCÉDENTS, sans le message courant (qui
    ///     est `query`) — il alimente la classification (reformulation), les
    ///     widgets ET le prompt final, borné par
    ///     `maxHistoryMessages`/`maxHistoryMessageCharacters`.
    ///   - attachments: instantané des fichiers joints à la conversation
    ///     (`AttachmentStore.searchIndex`), lu au moment de l'envoi ; `nil` ou
    ///     vide : aucune recherche dans les fichiers (1.11).
    ///   - media: médias à chercher EN PARALLÈLE de la recherche web (1.6) ;
    ///     aucun par défaut. Sans recherche web pour ce message (calcul,
    ///     salutation, fichiers joints seuls), ils restent `.notRequested`.
    ///
    /// `@concurrent` : voir « Concurrence » dans la documentation du type.
    @concurrent
    func answer(
        query: String,
        chatHistory: [ClassifierChatMessage] = [],
        attachments: AttachmentSearchIndex? = nil,
        media: MediaSearchKinds = []
    ) async throws -> SearchOrchestratorResult {
        let request = SearchRequest(query: query, chatHistory: chatHistory, attachments: attachments, media: media)
        let prepared = try await prepareFinalPrompt(request)
        guard !prepared.artifacts.lacksReliableSources, !prepared.artifacts.withholdsAnswerOffline else {
            return SearchOrchestratorResult(answer: "", artifacts: prepared.artifacts)
        }
        let answerText = try await aiProvider.generate(prompt: prepared.prompt)
        // Mission A1 : même contrôle de fin de réponse que `ChatViewModel` en
        // streaming. Une réponse vide signifie ici « rien de fiable à montrer »,
        // avant génération (ci-dessus) comme après (refus exact, aucune page lue
        // citée) ; `artifacts` reste complet dans les deux cas.
        guard !prepared.artifacts.rejectsReliableAnswer(answerText) else {
            return SearchOrchestratorResult(answer: "", artifacts: prepared.artifacts)
        }
        return SearchOrchestratorResult(answer: answerText, artifacts: prepared.artifacts)
    }

    /// Même pipeline que `answer(query:chatHistory:attachments:media:)`
    /// jusqu'à la construction du prompt (classification, recherche, planner,
    /// scrapes, widgets et médias sont tous awaited ICI, pas dans le flux
    /// renvoyé — contrat de 0.8 : `ChatViewModel` attache les `artifacts`
    /// AVANT d'itérer `textStream`) ; seule la génération finale est déléguée
    /// à `aiProvider.streamGenerate(prompt:)` — exigence isolée au main actor
    /// (protocole non annoté), d'où le `await` depuis ce point `@concurrent`.
    ///
    /// `onSearchStarted` : appelé UNE fois, quand la classification est finie ET
    /// que la question va réellement chercher des sources (web ou fichiers
    /// joints) — jamais pour une salutation ou un calcul pur. Sert au libellé
    /// d'attente de l'écran (« Réflexion… » puis « Recherche des sources… »).
    @concurrent
    func streamAnswer(
        query: String,
        chatHistory: [ClassifierChatMessage] = [],
        attachments: AttachmentSearchIndex? = nil,
        media: MediaSearchKinds = [],
        onSearchStarted: (@MainActor @Sendable () -> Void)? = nil
    ) async throws -> StreamingAnswer {
        let request = SearchRequest(
            query: query, chatHistory: chatHistory, attachments: attachments, media: media,
            onSearchStarted: onSearchStarted
        )
        let prepared = try await prepareFinalPrompt(request)
        // Décision (c) de Ben : rien de citable en mode Fiable -> on ne génère
        // RIEN (pas de requête cloud lancée puis annulée). Critère partagé avec
        // `ChatViewModel` : `SearchArtifacts+ReliableMode.swift`. Le contrôle
        // de fin de flux (`rejectsReliableAnswer`) revient à l'appelant, seul à
        // lire le texte.
        // Même garde hors connexion (tâche 1.16) : météo sans réseau, ou mode Fiable sans aucune source.
        guard !prepared.artifacts.lacksReliableSources, !prepared.artifacts.withholdsAnswerOffline else {
            // Aucune requête au moteur : flux vide déjà terminé.
            return StreamingAnswer(artifacts: prepared.artifacts, textStream: AsyncThrowingStream { $0.finish() })
        }
        let textStream = await aiProvider.streamGenerate(prompt: prepared.prompt)
        return StreamingAnswer(artifacts: prepared.artifacts, textStream: textStream)
    }

    /// Historique à passer à `SuggestionsService.generateSuggestions(chatHistory:)`
    /// APRÈS le streaming (1.7) : les tours précédents, la question, puis la
    /// réponse telle que l'utilisateur la lit — corps sans `<think>` ni
    /// `<tldr>` (`ReasoningSegmenter`, TL;DR seul si le corps est vide) —,
    /// bornés comme l'historique du classifieur (`boundedHistory`, mêmes
    /// réglages que cette instance). Sans cette borne, quelques réponses
    /// Approfondies feraient déborder Apple Intelligence et le service
    /// rendrait `[]` en silence à chaque tour.
    ///
    /// À n'appeler que sur une réponse terminée, non vide, ni en erreur ni
    /// annulée : voir « Suggestions » sur `StreamingAnswer`.
    func suggestionsHistory(
        previousTurns: [ClassifierChatMessage],
        query: String,
        answer: String
    ) -> [ClassifierChatMessage] {
        let segments = ReasoningSegmenter.segment(answer, isStreaming: false)
        let visibleAnswer = segments.body.isEmpty ? (segments.tldr ?? "") : segments.body
        let turns = previousTurns + [
            ClassifierChatMessage(role: .user, content: query),
            ClassifierChatMessage(role: .assistant, content: visibleAnswer),
        ]
        return Self.boundedHistory(turns, maxMessages: maxHistoryMessages, maxCharacters: maxHistoryMessageCharacters)
    }

    /// Paramètres d'un envoi, regroupés pour garder des signatures courtes.
    private nonisolated struct SearchRequest: Sendable {
        let query: String
        let chatHistory: [ClassifierChatMessage]
        let attachments: AttachmentSearchIndex?
        let media: MediaSearchKinds
        var onSearchStarted: (@MainActor @Sendable () -> Void)?

        var hasAttachments: Bool {
            attachments.map { !$0.attachments.isEmpty } ?? false
        }
    }

    /// Prompt final et tout ce qui l'accompagne.
    private nonisolated struct PreparedAnswer: Sendable {
        let prompt: String
        let artifacts: SearchArtifacts
    }

    /// Ce que la recherche transmet au prompt final. `searchPerformed`
    /// sépare le chemin sans recherche (prompt sans recherche) de la
    /// recherche qui n'a rien trouvé (prompt de rédaction, « Aucune source
    /// disponible. ») : des `sources` vides ne départagent pas les deux.
    private nonisolated struct ResearchOutcome: Sendable {
        /// Fichiers joints d'abord, puis sources web classées.
        let sources: [SearXNGSearchResult]
        let attachmentSourceCount: Int
        let scrapedPages: [ScrapedPage]
        let searchQuery: String
        let searchPerformed: Bool
        let widgets: WidgetExecutionReport
        let media: MediaSearchResults
        /// `SearchArtifacts.webSourceKind`.
        let webSourceKind: WebSearchSourceKind?
        /// `SearchArtifacts.webSearchReport` (mission A2).
        var webSearchReport = WebSearchChainReport()
        /// `SearchArtifacts.offlineWeatherSkipped` (tâche 1.16).
        var offlineWeatherSkipped = false
    }

    /// Recherche complète puis prompt final, partagés par `answer` et
    /// `streamAnswer`. Le MÊME tableau `sources` sert au prompt et au
    /// résultat : c'est ce qui garantit qu'une citation `[n]` désigne bien la
    /// n-ième source affichée sous la réponse.
    ///
    /// `Task.checkCancellation()` avant de rendre le prompt (bug 3) : le
    /// classement ne lève jamais, une annulation survenue pendant lui (ou
    /// pendant un mode sans planner) n'arrêterait sinon rien avant l'appel
    /// LLM final — payant, et dont plus personne ne veut.
    private func prepareFinalPrompt(_ request: SearchRequest) async throws -> PreparedAnswer {
        let research = try await runResearch(request)
        try Task.checkCancellation()
        let scrapedBudget = Self.scrapedContextBudget(
            total: maxScrapedContextCharacters,
            attachmentSources: Array(research.sources.prefix(research.attachmentSourceCount))
        )
        // Salutation pure : ni historique ni reformulation pour le rédacteur (mission A2, le haïku
        // recopié en réponse à « Bonjour ! », voir `SmallTalk.isBareSalutation`).
        let bareSalutation = SmallTalk.isBareSalutation(request.query)
        let prompt = Self.buildPrompt(
            query: request.query,
            standaloneQuery: bareSalutation ? nil : research.searchQuery,
            sources: research.sources,
            scrapedPages: research.scrapedPages,
            chatHistory: bareSalutation ? [] : request.chatHistory,
            mode: responseMode,
            complexity: writerComplexity,
            searchPerformed: research.searchPerformed,
            maxHistoryMessages: maxHistoryMessages,
            maxHistoryMessageCharacters: maxHistoryMessageCharacters,
            maxScrapedContextCharacters: scrapedBudget,
            widgetContext: research.widgets.combinedLLMContext,
            sourcesMatchQuestion: research.webSearchReport.matchesQuestion
        )
        let citableCount = research.searchPerformed
            ? PromptTemplates.citableDocumentCount(sources: research.sources, scrapedPages: research.scrapedPages)
            : 0
        // Sur la liste FINALE (fichiers joints en tête, puis le web) : c'est
        // elle que `numberedContext` vient de numéroter.
        let uncitableNumbers = research.searchPerformed
            ? PromptTemplates.uncitableDocumentNumbers(sources: research.sources, scrapedPages: research.scrapedPages)
            : []
        let artifacts = SearchArtifacts(
            sources: research.sources,
            attachmentSourceCount: research.attachmentSourceCount,
            widgets: research.widgets.outputs,
            images: research.media.images,
            videos: research.media.videos,
            mode: responseMode,
            promptComplexity: writerComplexity,
            citableSourceCount: citableCount,
            searchPerformed: research.searchPerformed,
            searchQuery: research.searchQuery,
            webSourceKind: research.webSourceKind,
            uncitableSourceNumbers: uncitableNumbers,
            webSearchReport: research.webSearchReport,
            answeredWithoutSearch: SearchArtifacts.answersWithoutSearch(
                question: request.query,
                searchPerformed: research.searchPerformed,
                widgetCount: research.widgets.outputs.count
            )
        )
        return PreparedAnswer(
            prompt: prompt,
            artifacts: artifacts.markedOffline(isOffline, weatherSkipped: research.offlineWeatherSkipped)
        )
    }

    /// Coeur de l'orchestration, partagé par `answer` et `streamAnswer` (seule
    /// la génération finale diffère entre les deux) :
    /// 1. Classification (1 seul appel, comme dans la version web d'origine où le classifieur
    ///    tourne une fois en amont du chercheur), puis `effectiveQuery` : la
    ///    reformulation devient le SUJET de toute la recherche (action seedée,
    ///    classement, planner, médias) — bug 1 —, et `SearchRoute.resolve`.
    /// 2. Widgets lancés tout de suite, EN PARALLÈLE de la recherche (comme
    ///    le `Promise.all` de la version web d'origine), puis attendus avant le
    ///    prompt qu'ils enrichissent. Seule exception, la météo sans recherche
    ///    demandée : son widget est attendu D'ABORD, la recherche web n'étant
    ///    qu'un repli s'il ne produit rien (`SearchRoute.webUnlessWeatherAnswered`).
    /// 3. `gather` mène la recherche de la route. Chaque `async let` est
    ///    attendu une seule fois sur chaque chemin ; une erreur de recherche
    ///    l'annule à la sortie (`WidgetExecutor` ne lève jamais).
    private func runResearch(_ request: SearchRequest) async throws -> ResearchOutcome {
        let history = Self.boundedHistory(request.chatHistory, maxMessages: maxHistoryMessages, maxCharacters: maxHistoryMessageCharacters)
        let classification = try await classifyWithFallback(query: request.query, boundedHistory: history)
        let searchQuery = Self.effectiveQuery(for: request.query, standaloneFollowUp: classification.standaloneFollowUp)
        let route = Self.routeConsultingAttachments(
            Self.routeAvailable(
                SearchRoute.resolve(
                    for: classification,
                    hasAttachments: request.hasAttachments,
                    mode: responseMode,
                    query: request.query
                ),
                isOffline: isOffline,
                hasAttachments: request.hasAttachments
            ),
            hasAttachments: request.hasAttachments
        )

        let widgetInput = SearchWidgetInput(query: request.query, chatHistory: history, classification: classification, aiProvider: aiProvider)
        let executor = widgetExecutor
        async let pendingWidgets = executor.execute(widgetInput)

        let widgets: WidgetExecutionReport
        let gathered: GatheredSearch
        if let awaitedKind = Self.widgetAwaitedBeforeSearching(route) {
            widgets = await pendingWidgets
            let answered = widgets.outputs.contains { $0.kind == awaitedKind }
            let fallbackRoute = Self.routeConsultingAttachments(answered ? .none : .web(.general), hasAttachments: request.hasAttachments)
            await Self.announceSearch(of: fallbackRoute, for: request)
            gathered = try await gather(route: fallbackRoute, request: request, searchQuery: searchQuery)
        } else {
            await Self.announceSearch(of: route, for: request)
            gathered = try await gather(route: route, request: request, searchQuery: searchQuery)
            widgets = await pendingWidgets
        }

        return ResearchOutcome(
            sources: gathered.documents + gathered.webSources,
            attachmentSourceCount: gathered.documents.count,
            scrapedPages: gathered.scrapedPages,
            searchQuery: searchQuery,
            searchPerformed: gathered.searchPerformed,
            widgets: widgets,
            media: gathered.media,
            webSourceKind: gathered.webSourceKind,
            webSearchReport: gathered.webSearchReport,
            offlineWeatherSkipped: isOffline && classification.showWeatherWidget
        )
    }

    /// Dit à l'écran que Triva cherche vraiment (route autre que `.none`), une
    /// fois la classification terminée.
    private static func announceSearch(of route: SearchRoute, for request: SearchRequest) async {
        // `case .none = route` et non `route == .none` : voir `routeConsultingAttachments`.
        if case .none = route { return }
        await request.onSearchStarted?()
    }

    /// Ce qu'une route a rassemblé. Les fichiers joints (`documents`) restent
    /// À PART des sources web : ils ne passent ni par `SourceRanker` (dont le
    /// filtre « domaines fiables » du mode Fiable les retirerait, faute
    /// d'hôte), ni par le planner (rien à scraper), et précèdent les sources
    /// web dans la numérotation des citations.
    private nonisolated struct GatheredSearch: Sendable {
        let documents: [SearXNGSearchResult]
        let webSources: [SearXNGSearchResult]
        let scrapedPages: [ScrapedPage]
        let media: MediaSearchResults
        let searchPerformed: Bool
        /// Source web des `webSources`, `nil` hors recherche web.
        let webSourceKind: WebSearchSourceKind?
        /// Constat de la chaîne (mission A2), vide hors recherche web.
        var webSearchReport = WebSearchChainReport()

        static let noSearch = GatheredSearch(
            documents: [], webSources: [], scrapedPages: [], media: .notRequested, searchPerformed: false, webSourceKind: nil
        )
    }

    /// Mène la recherche d'une route. Aucune ne fait d'appel réseau hors
    /// `.web` : le calcul pur et la salutation répondent hors ligne (bug 15),
    /// les fichiers joints restent sur l'appareil.
    private func gather(route: SearchRoute, request: SearchRequest, searchQuery: String) async throws -> GatheredSearch {
        switch route {
        case .none, .webUnlessWeatherAnswered, .webUnlessCalculationAnswered:
            // Les routes « web sauf widget abouti » sont résolues par `runResearch` avant
            // d'arriver ici ; les traiter comme « aucune recherche » est le repli sûr.
            return .noSearch
        case .attachments:
            let uploads = await Self.uploadsAction(for: request.attachments, maxTotalCharacters: maxAttachmentContextCharacters)
            let documents = try await uploads?.search(queries: [searchQuery]) ?? []
            return GatheredSearch(
                documents: documents, webSources: [], scrapedPages: [], media: .notRequested, searchPerformed: true, webSourceKind: nil
            )
        case .web(let flavor):
            // Décision (b) de Ben : les fichiers joints sont consultés à CHAQUE
            // question, dès le tour seedé — le mode Rapide n'a pas de planner —,
            // EN PARALLÈLE du web (recherche locale, plusieurs secondes quand
            // le budget est plein), avec la moitié du budget : le contexte web
            // occupe déjà le prompt. Le planner ne les reconsulte pas
            // (`uploads: nil`) : une seconde lecture remplacerait la première
            // sans rien apporter de plus que ses propres requêtes.
            let uploads = await Self.uploadsAction(for: request.attachments, maxTotalCharacters: maxAttachmentContextCharacters / 2)
            async let pendingDocuments = Self.consultedDocuments(uploads, query: searchQuery)
            let (research, media) = try await webResearchAlongsideMedia(
                flavor: flavor,
                uploads: nil,
                searchQuery: searchQuery,
                mediaKinds: request.media
            )
            return GatheredSearch(
                documents: await Self.documentsCountingAsSources(try await pendingDocuments, query: searchQuery, mode: responseMode),
                webSources: research.sources,
                scrapedPages: research.scrapedPages,
                media: media,
                searchPerformed: true,
                webSourceKind: research.webSourceKind,
                webSearchReport: research.webSearchReport
            )
        }
    }

    /// Extraits des fichiers joints pour la question (vide sans fichier ou
    /// sans budget). Une erreur remonte, comme sur la route `.attachments`.
    private static func consultedDocuments(_ uploads: UploadsSearchAction?, query: String) async throws -> [SearXNGSearchResult] {
        guard let uploads else { return [] }
        return try await uploads.search(queries: [query])
    }

    /// Action « fichiers joints » de cette requête, `nil` sans fichier ou sans
    /// budget. Construite à chaque envoi, sur l'instantané reçu (contrat de
    /// `UploadsSearchAction`), avec au plus `attachmentFragmentLimit(forBudget:)`
    /// extraits. `@MainActor` : type non annoté (`Actions/`).
    @MainActor
    private static func uploadsAction(for attachments: AttachmentSearchIndex?, maxTotalCharacters: Int) -> UploadsSearchAction? {
        guard let attachments, !attachments.attachments.isEmpty, maxTotalCharacters > 0 else { return nil }
        return UploadsSearchAction(
            searchIndex: attachments,
            maxFragments: attachmentFragmentLimit(forBudget: maxTotalCharacters),
            maxTotalCharacters: maxTotalCharacters
        )
    }

    /// Classification en « meilleur effort » : un échec (aléa réseau ou
    /// provider) retombe sur la même classification « sûre » que
    /// `QueryClassifier.parse` pour une sortie imparsable (tous les booléens
    /// à `false` -> `.webSearch`, reformulation = la question), plutôt que de
    /// faire échouer toute la réponse. Le planner suit la même règle
    /// (`nextPlannerDecision`) — ce que cette doc affirmait déjà à tort avant
    /// le bug 3, alors que son erreur remontait jusqu'à `streamAnswer`.
    ///
    /// L'historique y arrive BORNÉ (`boundedHistory`, bug 6, calculé une fois
    /// par `runResearch` et partagé avec les widgets) : un débordement de
    /// contexte du classifieur n'est pas une erreur visible mais un repli
    /// silencieux à chaque tour.
    private func classifyWithFallback(
        query: String,
        boundedHistory history: [ClassifierChatMessage]
    ) async throws -> QueryClassification {
        let classifier = queryClassifier
        // Salutation et classification en échec : pas de recherche web (mission C1, décision de Ben).
        let safeFallback = QueryClassification(
            skipSearch: SmallTalk.isGreeting(query),
            personalSearch: false,
            academicSearch: false,
            discussionSearch: false,
            showWeatherWidget: false,
            showStockWidget: false,
            showCalculationWidget: false,
            standaloneFollowUp: query
        )
        return try await Self.bestEffort(fallback: safeFallback) {
            try await classifier.classify(query: query, chatHistory: history)
        }
    }
}
