//
//  SearchOrchestrator.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import Foundation

/// Tout ce que le pipeline produit À CÔTÉ du texte de réponse (I1b). Connu en
/// entier AVANT que l'appelant itère `StreamingAnswer.textStream` : contrat
/// de 0.8, étendu des sources aux widgets, médias et indicateurs de
/// validation — la vue peut tout afficher avant le premier token.
///
/// `sources` est dans l'ORDRE DES CITATIONS et cet ordre fait foi :
/// `sources[i]` est le document `[i + 1]` du prompt de rédaction
/// (`PromptTemplates.numberedContext` numérote dans l'ordre reçu). Les
/// fichiers joints viennent EN TÊTE (`attachmentSourceCount` premiers
/// éléments, URL `triva-attachment:<UUID>`, voir `UploadsSearchResultBuilder`),
/// puis les résultats web dans l'ordre du classement. Réordonner ce tableau
/// côté interface casserait la correspondance citation -> source affichée.
///
/// `nonisolated` (comme les types suivants) : construit par les points
/// d'entrée `@concurrent`, hors du main actor.
nonisolated struct SearchArtifacts: Sendable {
    let sources: [SearXNGSearchResult]
    /// Nombre de sources de tête qui sont des fichiers joints (1.11).
    let attachmentSourceCount: Int
    /// Widgets aboutis (1.5), dans l'ordre d'injection (météo puis calcul).
    /// Leur `llmContext` est déjà dans le prompt ; à afficher AU-DESSUS de la
    /// réponse (`SearchWidgetOutput.weatherData`, `.calculationData`).
    let widgets: [SearchWidgetOutput]
    /// Recherches média (1.6), `.notRequested` sauf demande de l'appelant.
    let images: MediaSearchOutcome<ImageSearchResult>
    let videos: MediaSearchOutcome<VideoSearchResult>
    /// Mode de réponse appliqué (1.13).
    let mode: ResponseMode
    /// Verbosité des consignes envoyées : à passer à
    /// `ResponseStructureValidator.validate(_:mode:complexity:citableSourceCount:)`.
    let promptComplexity: WriterPromptComplexity
    /// Plus grand numéro `[n]` citable du prompt (`PromptTemplates.citableDocumentCount`),
    /// 0 sans recherche ou sans document lisible : le `citableSourceCount` du
    /// validateur. Depuis la mission A1, ce n'est plus un compte dès que la
    /// numérotation a un trou ([1] et [3] montrés : 3) ; les numéros sautés
    /// sont dans `uncitableSourceNumbers`.
    let citableSourceCount: Int
    /// Vrai si une recherche (web ou fichiers joints) a eu lieu ; faux sur le
    /// chemin sans recherche (salutation, calcul pur, météo répondue par son
    /// widget), où aucune source n'est attendue.
    let searchPerformed: Bool
    /// Sujet de recherche effectif : la reformulation autonome du classifieur
    /// (`SearchOrchestrator.effectiveQuery`, bug 1), ou la question.
    let searchQuery: String
    /// Source web qui a fourni les sources web (RI1b) : `.searxng` sans chaîne
    /// de repli, la source retenue par `WebSearchChain` sinon. `nil` sans
    /// recherche web (route sans recherche, fichiers joints seuls). `var` avec
    /// défaut, seule forme qui garde l'init memberwise compatible avec les
    /// appels existants (dont les tests) : un ajout, pas une rupture.
    var webSourceKind: WebSearchSourceKind? = nil
    /// Numéros `[n]` des sources affichées mais NON CITABLES (mission A1) :
    /// sans extrait et dont la page n'a pas pu être lue, elles ne sont pas
    /// montrées au modèle (`PromptTemplates.uncitableDocumentNumbers`). Elles
    /// restent dans `sources` à leur rang : les retirer décalerait tous les
    /// numéros suivants.
    /// Une citation vers l'une d'elles ne compte jamais comme sourcée
    /// (`citesReadSource(in:)`). Vide par défaut, même raison que
    /// `webSourceKind`.
    var uncitableSourceNumbers: Set<Int> = []
    /// Constat de la chaîne de repli (mission A2) : sources laissées de côté,
    /// réponse probablement hors sujet. Vide hors recherche web ou sans chaîne.
    var webSearchReport = WebSearchChainReport()
    /// Réponse rédigée SANS AUCUNE recherche, ni widget, à autre chose qu'une
    /// salutation : la bulle le dit (« Réponse sans recherche », décision 3 de
    /// Ben, `SearchArtifacts.answersWithoutSearch`). Décidé ICI, où la question
    /// brute est connue : la reformulation d'un « Bonjour » n'en est plus un.
    var answeredWithoutSearch = false
}

/// Résultat du pipeline (0.7) : le texte généré et ses `artifacts`.
///
/// Plus `Equatable` depuis I1b : `SearchWidgetOutput` ne l'est pas (charge
/// utile existentielle), et l'`Equatable` des résultats média est isolé au
/// main actor. Aucun appelant ne comparait deux résultats entiers.
nonisolated struct SearchOrchestratorResult: Sendable {
    let answer: String
    let artifacts: SearchArtifacts

    /// Raccourci historique (0.7) : `artifacts.sources`.
    var sources: [SearXNGSearchResult] { artifacts.sources }
}

/// Résultat du pipeline en streaming (0.8) : `artifacts` est déjà complet
/// (classification, recherche, planner, widgets et médias sont terminés et
/// awaited) au moment où l'appelant le reçoit ; seul le texte arrive
/// progressivement via `textStream`. `Equatable` non conformé : un
/// `AsyncThrowingStream` ne l'est pas.
///
/// ## Suggestions (1.7)
/// Jamais générées ici : elles demandent la réponse COMPLÈTE, et les
/// attendre retarderait le premier token. Une fois `textStream` terminé sans
/// erreur ni annulation et le texte non vide, l'appelant lance
/// `SuggestionsService.generateSuggestions(chatHistory:)` avec l'historique
/// que rend `suggestionsHistory(previousTurns:query:answer:)` (méthode de
/// l'orchestrateur qui a répondu : mêmes bornes), dans une tâche à annuler
/// si l'utilisateur envoie autre chose. Le service ne lève jamais : un échec
/// rend `[]`, aucune erreur à afficher.
nonisolated struct StreamingAnswer: Sendable {
    let artifacts: SearchArtifacts
    let textStream: AsyncThrowingStream<String, Error>

    /// Raccourci historique (0.8) : `artifacts.sources`.
    var sources: [SearXNGSearchResult] { artifacts.sources }
}

/// Décision du planner (itérations 2+ de la boucle de recherche) : quelle
/// action lancer ensuite, avec quelles URLs ou requêtes le cas échéant. Port
/// de la boucle `for` de `researcher/index.ts` (web) — mais là où le TS
/// délègue le choix d'action à un vrai tool-calling LLM (schéma zod +
/// function-calling natif), ici la décision passe par un parsing JSON
/// tolérant, même principe que `QueryClassifier.parse` : aucun des 3
/// providers IA de Triva n'expose de function-calling fiable.
///
/// Plus de champ `reasoning` (bug 8 de la revue) : demandé au modèle mais lu
/// nulle part, il coûtait des tokens de sortie à chaque tour — et, écrit
/// APRÈS l'action dans le JSON, il ne pouvait même pas éclairer la décision.
/// Un modèle qui le renvoie quand même reste accepté (clé ignorée).
///
/// `queries` (1.11) : requêtes de l'action `uploadsSearch` (fichiers joints),
/// 3 au plus retenues par `UploadsSearchResultBuilder.effectiveQueries`.
nonisolated struct PlannerDecision: Sendable, Equatable {
    let actionName: String
    let urls: [String]
    let queries: [String]

    init(actionName: String, urls: [String], queries: [String] = []) {
        self.actionName = actionName
        self.urls = urls
        self.queries = queries
    }
}

/// Budgets du pipeline selon le moteur IA ACTIF (bug 6 de la revue). Avant,
/// tous les moteurs recevaient ceux d'un modèle cloud (128k tokens et plus) :
/// classifieur `.full` (~6 400 caractères), historique de longueur illimitée
/// côté classifieur, 8 000 caractères de pages scrapées. Apple Intelligence
/// (~4 096 tokens, prompt ET réponse) débordait dès la classification — échec
/// avalé par `bestEffort`, donc classification « tout à false » à chaque tour
/// (plus de `.skip`, plus de routage) — puis au prompt final.
///
/// Une seule complexité pour les DEUX prompts (classification, rédaction) :
/// ce qui noie un petit modèle, c'est la longueur des consignes, la même dans
/// les deux étapes. `maxResultsUsedForContext` reste un PLAFOND du mode (voir
/// l'init de `SearchOrchestrator`). Budgets en caractères, proxy des tokens
/// (~4 caractères par token en français, ~1 en chinois ou japonais) : ils ne
/// protègent pas entièrement un texte CJK, d'où des marges larges — le
/// débordement résiduel doit devenir un message clair côté `ChatViewModel`.
nonisolated struct SearchPipelineConfiguration: Sendable, Equatable {
    let promptComplexity: WriterPromptComplexity
    let maxHistoryMessages: Int
    let maxHistoryMessageCharacters: Int
    let maxScrapedContextCharacters: Int
    let maxResultsUsedForContext: Int
    let maxScrapedURLsPerIteration: Int

    /// Cloud BYOK : les valeurs historiques du pipeline, inchangées (défauts
    /// de `PromptTemplates`, 5 sources, 3 pages par tour).
    static let cloud = SearchPipelineConfiguration(
        promptComplexity: .full,
        maxHistoryMessages: PromptTemplates.defaultMaxHistoryMessages,
        maxHistoryMessageCharacters: PromptTemplates.defaultMaxHistoryMessageCharacters,
        maxScrapedContextCharacters: PromptTemplates.defaultMaxScrapedContextCharacters,
        maxResultsUsedForContext: 5,
        maxScrapedURLsPerIteration: 3
    )

    /// Apple Intelligence : prompts courts, 4 messages × 600 caractères,
    /// 3 000 caractères scrapés partagés entre 2 pages par tour (1 500 chacune
    /// plutôt que 1 000 sur 3). Les 5 extraits SearXNG restent : c'est le
    /// contexte le plus dense par caractère. Pire cas mesuré par
    /// `PromptTemplatesTests` : sous 10 000 caractères (~2 500 tokens en
    /// français), ce qui laisse ~1 500 tokens à la réponse. Même borne tenue
    /// avec des fichiers joints trouvés par le planner et deux widgets
    /// (`UploadsSearchPipelineTests`) : les fichiers partagent le budget des
    /// pages (`SearchOrchestrator.scrapedContextBudget`) et 5 extraits au plus
    /// y entrent (`SearchOrchestrator.attachmentFragmentLimit(forBudget:)`).
    static let appleIntelligence = SearchPipelineConfiguration(
        promptComplexity: .concise,
        maxHistoryMessages: 4,
        maxHistoryMessageCharacters: 600,
        maxScrapedContextCharacters: 3000,
        maxResultsUsedForContext: 5,
        maxScrapedURLsPerIteration: 2
    )

    /// MLX léger (Qwen3 0.6B, 1.7B) : fenêtre de 32k tokens, mais un modèle de
    /// cette taille se perd dans de longues consignes (raison d'être de
    /// `.concise`), et chaque token de prompt coûte du pré-remplissage et du
    /// cache KV en mémoire sur l'appareil.
    static let mlxCompact = SearchPipelineConfiguration(
        promptComplexity: .concise,
        maxHistoryMessages: 6,
        maxHistoryMessageCharacters: 1000,
        maxScrapedContextCharacters: 5000,
        maxResultsUsedForContext: 5,
        maxScrapedURLsPerIteration: 3
    )

    /// MLX 4B et plus : consignes complètes, budgets proches du cloud, un peu
    /// réduits pour la même raison de latence et de mémoire sur l'appareil.
    /// Valeurs de départ, à ajuster sur iPhone réel.
    static let mlx = SearchPipelineConfiguration(
        promptComplexity: .full,
        maxHistoryMessages: 6,
        maxHistoryMessageCharacters: 1500,
        maxScrapedContextCharacters: 6000,
        maxResultsUsedForContext: 5,
        maxScrapedURLsPerIteration: 3
    )

    /// `capabilityScore` (catalogue MLX) des Qwen3 0.6B (1) et 1.7B (2) : les
    /// modèles visés par `WriterPromptComplexity.concise`.
    static let maxCompactMLXCapabilityScore = 2

    /// Préréglage du moteur RÉELLEMENT résolu pour la requête, comme le
    /// provider lui-même (`ActiveAIProviderResolver`) : un budget lu ailleurs
    /// pourrait décrire un autre moteur que celui qui répond. `mlxModel` :
    /// l'entrée du catalogue sélectionnée ; inconnue, on suppose le plus petit
    /// modèle — un budget trop serré dégrade une réponse, un budget trop large
    /// la perd. `@MainActor` : `AIEngineOption` et `MLXModelCatalogEntry` sont
    /// des types non annotés, isolés au main actor (appelant : `ChatViewModel`).
    @MainActor
    static func preset(for engine: AIEngineOption, mlxModel: MLXModelCatalogEntry? = nil) -> SearchPipelineConfiguration {
        switch engine {
        case .appleIntelligence:
            return .appleIntelligence
        case .cloudBYOK:
            return .cloud
        case .mlxLocal:
            guard let mlxModel, mlxModel.capabilityScore > maxCompactMLXCapabilityScore else { return .mlxCompact }
            return .mlx
        }
    }

    /// Même choix pour le classifieur, dont l'enum est isolé au main actor
    /// (type non annoté de `QueryClassifier.swift`).
    @MainActor
    var classifierPromptComplexity: ClassifierPromptComplexity {
        switch promptComplexity {
        case .full: .full
        case .concise: .concise
        }
    }
}

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
    private let failoverManager: FailoverManager
    private let aiProvider: any AIGenerating
    private let queryClassifier: QueryClassifier
    private let scrapeService: any ScrapeServing
    private let sourceRanker: SourceRanker
    private let responseMode: ResponseMode
    private let writerComplexity: WriterPromptComplexity
    private let maxResultsUsedForContext: Int
    private let maxIterations: Int
    private let restrictsToTrustedDomains: Bool
    private let maxScrapedURLsPerIteration: Int
    private let maxScrapedContextCharacters: Int
    private let maxHistoryMessages: Int
    private let maxHistoryMessageCharacters: Int
    private let scrapeRoundTimeout: Duration
    private let clock: any Clock<Duration>
    private let widgetExecutor: WidgetExecutor
    private let mediaSearcher: any MediaSearching
    private let mediaGracePeriod: Duration
    private let maxAttachmentContextCharacters: Int
    /// Chaîne de repli de la recherche web (RI1b), `nil` = SearXNG seul.
    private let webSearchChain: WebSearchChain?

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
    ///     constantes TS (3 000 tokens/chunk × 4 chunks × 3 URLs ≈ 36k tokens)
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
        webSearchChain: WebSearchChain? = nil
    ) {
        self.failoverManager = failoverManager
        self.aiProvider = aiProvider
        self.webSearchChain = webSearchChain
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
        self.widgetExecutor = WidgetExecutor(widgets: widgets ?? Self.defaultWidgets(aiProvider: aiProvider))
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
        guard !prepared.artifacts.lacksReliableSources else {
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
    @concurrent
    func streamAnswer(
        query: String,
        chatHistory: [ClassifierChatMessage] = [],
        attachments: AttachmentSearchIndex? = nil,
        media: MediaSearchKinds = []
    ) async throws -> StreamingAnswer {
        let request = SearchRequest(query: query, chatHistory: chatHistory, attachments: attachments, media: media)
        let prepared = try await prepareFinalPrompt(request)
        // Décision (c) de Ben : rien de citable en mode Fiable -> on ne génère
        // RIEN (pas de requête cloud lancée puis annulée). Critère partagé avec
        // `ChatViewModel` : `SearchArtifacts+ReliableMode.swift`. Le contrôle
        // de fin de flux (`rejectsReliableAnswer`) revient à l'appelant, seul à
        // lire le texte.
        guard !prepared.artifacts.lacksReliableSources else {
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
        return PreparedAnswer(prompt: prompt, artifacts: artifacts)
    }

    /// Coeur de l'orchestration, partagé par `answer` et `streamAnswer` (seule
    /// la génération finale diffère entre les deux) :
    /// 1. Classification (1 seul appel, comme côté web où le classifieur
    ///    tourne une fois en amont du chercheur), puis `effectiveQuery` : la
    ///    reformulation devient le SUJET de toute la recherche (action seedée,
    ///    classement, planner, médias) — bug 1 —, et `SearchRoute.resolve`.
    /// 2. Widgets lancés tout de suite, EN PARALLÈLE de la recherche (comme
    ///    le `Promise.all` de `search/index.ts`), puis attendus avant le
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
            SearchRoute.resolve(for: classification, hasAttachments: request.hasAttachments),
            hasAttachments: request.hasAttachments
        )

        let widgetInput = SearchWidgetInput(query: request.query, chatHistory: history, classification: classification, aiProvider: aiProvider)
        let executor = widgetExecutor
        async let pendingWidgets = executor.execute(widgetInput)

        let widgets: WidgetExecutionReport
        let gathered: GatheredSearch
        if case .webUnlessWeatherAnswered = route {
            widgets = await pendingWidgets
            let weatherAnswered = widgets.outputs.contains { $0.kind == .weather }
            let fallbackRoute = Self.routeConsultingAttachments(weatherAnswered ? .none : .web(.general), hasAttachments: request.hasAttachments)
            gathered = try await gather(route: fallbackRoute, request: request, searchQuery: searchQuery)
        } else {
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
            webSearchReport: gathered.webSearchReport
        )
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

    /// Recherche web : sources classées, pages scrapées, et documents trouvés
    /// par le planner (`uploadsSearch`).
    private nonisolated struct WebResearch: Sendable {
        let documents: [SearXNGSearchResult]
        let sources: [SearXNGSearchResult]
        let scrapedPages: [ScrapedPage]
        /// Source qui a fourni le tour seedé (RI1b).
        let webSourceKind: WebSearchSourceKind
        /// Constat de la chaîne sur ce tour (mission A2).
        let webSearchReport: WebSearchChainReport
    }

    /// Mène la recherche d'une route. Aucune ne fait d'appel réseau hors
    /// `.web` : le calcul pur et la salutation répondent hors ligne (bug 15),
    /// les fichiers joints restent sur l'appareil.
    private func gather(route: SearchRoute, request: SearchRequest, searchQuery: String) async throws -> GatheredSearch {
        switch route {
        case .none, .webUnlessWeatherAnswered:
            // `.webUnlessWeatherAnswered` est résolue par `runResearch` avant
            // d'arriver ici ; la traiter comme « aucune recherche » est le repli sûr.
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
                documents: try await pendingDocuments,
                webSources: research.sources,
                scrapedPages: research.scrapedPages,
                media: media,
                searchPerformed: true,
                webSourceKind: research.webSourceKind,
                webSearchReport: research.webSearchReport
            )
        }
    }

    /// Décision (b) de Ben (2026-10-29) : des fichiers joints sont TOUJOURS
    /// consultés, quels que soient le mode et la classification (le
    /// classifieur ne sait pas qu'il y en a). La route « aucune recherche »
    /// devient donc « fichiers joints » ; les routes web les consultent dès le
    /// tour seedé (`gather`) ; `.attachments` et `.webUnlessWeatherAnswered`
    /// (résolue plus tard par `runResearch`) sont inchangées.
    ///
    /// Écart assumé avec la piste « forcer `personalSearch` » : la règle 1 de
    /// `SearchRoute.resolve` enverrait alors TOUTE question d'une conversation
    /// à fichier joint sur `.attachments` — recherche web coupée jusqu'au
    /// retrait du fichier, puisque les capsules restent d'une question à
    /// l'autre. Pour ce comportement-là, rendre `.attachments` dès que
    /// `hasAttachments` est vrai.
    /// `case .none = route` et non `route == .none` : comparé par `==`, `.none`
    /// serait pris pour `Optional<SearchRoute>.none`, toujours différent.
    nonisolated static func routeConsultingAttachments(_ route: SearchRoute, hasAttachments: Bool) -> SearchRoute {
        guard hasAttachments, case .none = route else { return route }
        return .attachments
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

    /// Longueur minimale UTILE d'un extrait de fichier joint : celle d'un
    /// extrait SearXNG (~300 caractères, l'ordre de grandeur que les tests de
    /// pire cas donnent aux résultats web). En dessous, un extrait n'est plus
    /// qu'une phrase tronquée.
    nonisolated static let minimumAttachmentExcerptCharacters = 300

    /// Nombre d'extraits de fichiers joints pour un budget donné (I1b) : les
    /// 10 du web (`UploadsSearchResultBuilder.defaultMaxFragments`), sauf si
    /// le budget ne leur laisse pas `minimumAttachmentExcerptCharacters`
    /// chacun. Chaque extrait coûte aussi ~90 caractères d'en-tête dans le
    /// prompt (`[n]`, nom du fichier, URL synthétique `triva-attachment:<UUID>`) :
    /// sous 1 500 caractères (Apple Intelligence, fichiers joints ajoutés à
    /// une recherche web), 10 extraits de 150 caractères coûtaient 900
    /// caractères d'en-têtes pour un contenu à peine lisible ; 5 extraits de
    /// 300 disent plus pour moins. Seuls changent Apple Intelligence (5
    /// extraits sur la route web) et MLX léger (8) ; le cloud et la route
    /// « fichiers joints seuls » gardent 10. Toujours au moins 1.
    nonisolated static func attachmentFragmentLimit(forBudget budget: Int) -> Int {
        min(UploadsSearchResultBuilder.defaultMaxFragments, max(1, budget / minimumAttachmentExcerptCharacters))
    }

    /// Budget des pages scrapées dans le prompt final, une fois servis les
    /// fichiers joints (I1b) : `maxScrapedContextCharacters` borne TOUT le
    /// contenu long du prompt, pages ET fichiers joints. Avant, les fichiers
    /// trouvés par le planner s'ajoutaient aux pages au lieu de partager leur
    /// budget : sous Apple Intelligence, 1 500 caractères de documents plus
    /// 3 000 de pages, et le pire cas mesuré montait à 11 269 caractères, au-
    /// delà des 10 000 que la fenêtre de ~4 096 tokens tolère
    /// (`UploadsSearchPipelineTests`).
    ///
    /// Jamais nul quand des pages sont scrapées : sur la route web, les
    /// fichiers joints ont au plus la MOITIÉ de ce budget (voir `gather`), il
    /// en reste donc au moins la moitié aux pages. Ce point compte :
    /// `PromptTemplates.numberedContext` ramènerait un budget nul à 1
    /// caractère par page. Sur la route « fichiers joints seuls », aucune page
    /// n'est scrapée, un reste nul n'y change rien. Seule la route web avec
    /// fichiers joints (consultés dès le tour seedé, décision (b)) est
    /// concernée : sans fichier joint, le budget des pages est inchangé.
    nonisolated static func scrapedContextBudget(total: Int, attachmentSources: [SearXNGSearchResult]) -> Int {
        let attachmentCharacters = attachmentSources.reduce(0) { $0 + ($1.content?.count ?? 0) }
        return max(0, total - attachmentCharacters)
    }

    /// Événement de la recherche web menée en parallèle des médias.
    private nonisolated enum ParallelSearchEvent: Sendable {
        case research(WebResearch)
        case media(MediaSearchResults)
        case mediaGraceExpired
    }

    /// Recherche web et médias EN PARALLÈLE (1.6), jamais en série : deux
    /// tâches d'un même groupe. Les médias ne nourrissent pas le prompt :
    /// une fois la recherche texte finie, ils ont encore `mediaGracePeriod`
    /// pour arriver, puis valent `.failed` et sont annulés. Une erreur de la
    /// recherche texte (ou une annulation) remonte et annule les médias ; un
    /// échec des médias ne lève jamais (`MediaSearchResults.search`).
    /// `Task.sleep` (temps réel) plutôt que `clock` : l'horloge injectée ne
    /// mesure que les tours de scrape.
    private func webResearchAlongsideMedia(
        flavor: WebSearchFlavor,
        uploads: UploadsSearchAction?,
        searchQuery: String,
        mediaKinds: MediaSearchKinds
    ) async throws -> (WebResearch, MediaSearchResults) {
        guard !mediaKinds.isEmpty else {
            return (try await webResearch(flavor: flavor, uploads: uploads, searchQuery: searchQuery), .notRequested)
        }
        let searcher = mediaSearcher
        let grace = mediaGracePeriod
        return try await withThrowingTaskGroup(of: ParallelSearchEvent.self) { group in
            group.addTask { .research(try await self.webResearch(flavor: flavor, uploads: uploads, searchQuery: searchQuery)) }
            group.addTask { .media(await MediaSearchResults.search(mediaKinds, query: searchQuery, using: searcher)) }
            var research: WebResearch?
            var media: MediaSearchResults?
            while let event = try await group.next() {
                switch event {
                case .research(let outcome):
                    research = outcome
                    if media == nil {
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return .mediaGraceExpired
                        }
                    }
                case .media(let results):
                    media = media ?? results
                case .mediaGraceExpired:
                    media = media ?? .failed(mediaKinds)
                }
                if let research, let media {
                    group.cancelAll()
                    return (research, media)
                }
            }
            // Inatteignable : la tâche de recherche rend un événement ou lève.
            throw CancellationError()
        }
    }

    /// Recherche web d'une route `.web` :
    /// 1. la classification SEEDE le 1er tour — pas d'appel planner pour ce
    ///    tour, on a déjà payé pour `classify()` (repli web du bug 5 compris,
    ///    voir `seededSearch`) ;
    /// 2. classement (1.3) des résultats du tour seedé, UNE fois : la boucle
    ///    planner ne fait que scraper (ou consulter les fichiers joints), elle
    ///    n'ajoute jamais de source web. Si un jour le planner peut relancer
    ///    une recherche web, il faudra reclasser après chaque tour ;
    /// 3. lecture sans LLM des sources classées SANS EXTRAIT, dans tous les
    ///    modes (mission A1, `SearchOrchestrator+PreRead.swift`) : le repli
    ///    cloud rend des URL nues, et le mode Rapide n'a pas de planner pour
    ///    les lire ;
    /// 4. boucle planner sur les seules sources classées, qui sait ces pages
    ///    déjà tentées, puis `pagesBackedBySources` : invariant des citations
    ///    garanti en un seul point, quelle que soit l'origine d'une page.
    private func webResearch(flavor: WebSearchFlavor, uploads: UploadsSearchAction?, searchQuery: String) async throws -> WebResearch {
        let seeded = try await seededSearch(flavor: flavor, query: searchQuery)
        var searchResults: [SearXNGSearchResult] = []
        var seededPages: [ScrapedPage] = []
        Self.accumulate(seeded.output, sources: &searchResults, scrapedPages: &seededPages)

        // `searchResults` est encore dans l'ordre rendu par le moteur
        // (`accumulate` conserve l'ordre d'arrivée) : c'est le contrat
        // d'entrée de `SourceRanker.rank`, dont 30 % du score dérive de la
        // position. Le filtre "sources fiables" s'y applique AVANT le
        // scoring, et peut légitimement tout retirer (mode Fiable sans
        // aucun domaine fiable) : on n'y retombe jamais sur des sources non
        // fiables, `PromptTemplates` gère alors l'avertissement dédié.
        let sources = await sourceRanker.rank(
            query: searchQuery,
            results: searchResults,
            limit: maxResultsUsedForContext,
            trustedDomainsOnly: restrictsToTrustedDomains
        ).map(\.result)

        // Copie locale : voir `runPlannerLoop` (SE-0352).
        let roundClock = clock
        let alreadyRead = try await Self.preRead(
            sources,
            using: scrapeService,
            timeout: Self.preReadTimeout(for: responseMode, scrapeRoundTimeout: scrapeRoundTimeout),
            clock: roundClock
        )
        let harvest = try await runPlannerLoop(query: searchQuery, sources: sources, uploads: uploads, alreadyRead: alreadyRead)
        let pages = Self.pagesBackedBySources(seededPages + harvest.pages, sources: sources)
        return WebResearch(
            documents: harvest.documents,
            sources: sources,
            scrapedPages: pages,
            webSourceKind: seeded.sourceKind,
            webSearchReport: seeded.report
        )
    }

    /// Tour seedé, avec le repli du bug 5 (sans chaîne) ou la chaîne de repli
    /// de la recherche web (RI1b) : logique et documentation dans
    /// `SearchOrchestrator+WebSearchChain.swift` (`seededWebSearch`).
    private func seededSearch(flavor: WebSearchFlavor, query: String) async throws -> SeededWebSearch {
        try await Self.seededWebSearch(
            flavor: flavor,
            query: query,
            webSearchChain: webSearchChain,
            trustedDomainsOnly: restrictsToTrustedDomains,
            failoverManager: failoverManager
        )
    }

    /// Boucle planner bornée `2...maxIterations` (donc `maxIterations - 1`
    /// tours au plus, aucun en mode Rapide où `maxIterations` vaut 1).
    ///
    /// - Aucun tour sans source (bug 8) : le planner ne peut scraper que des
    ///   sources affichées, il n'aurait rien à choisir.
    /// - Mémoire des URLs déjà tentées, succès comme échec (bug 11) : sans
    ///   elle, le prompt du tour 3 était identique à celui du tour 2 et le
    ///   modèle redemandait les mêmes pages, téléchargées deux fois. Elle
    ///   alimente `scrapableURLs` (filtre) ET `plannerPrompt` (le modèle sait
    ///   ce qui est déjà lu). Un tour qui ne propose rien de neuf, ou plus
    ///   rien à proposer, termine la boucle.
    /// - Annulation vérifiée à chaque tour et après chaque série de scrapes
    ///   (bug 3) : `scrapeAll` ne lève jamais.
    /// - Fichiers joints (1.11) : `uploadsSearch` est proposé tant qu'il n'a
    ///   pas servi, UNE fois au plus (un second passage reclasserait les
    ///   mêmes fragments, pour un coût d'embeddings de plusieurs secondes sur
    ///   l'appareil). Les documents trouvés s'ajoutent en tête des sources.
    /// - Pages déjà lues sans LLM (`alreadyRead`, mission A1) : elles ouvrent
    ///   la récolte et comptent comme tentées, succès comme échec — le
    ///   planner les voit déjà lues et ne les redemande pas ; toutes lues, il
    ///   ne reste rien à scraper et aucun tour (donc aucun appel LLM) n'a
    ///   lieu. Sans planner (mode Rapide), elles sont rendues telles quelles :
    ///   c'est tout l'intérêt de les lire avant.
    private func runPlannerLoop(
        query: String,
        sources: [SearXNGSearchResult],
        uploads: UploadsSearchAction?,
        alreadyRead: [ScrapedPage]
    ) async throws -> PlannerHarvest {
        let preRead = PlannerHarvest(pages: alreadyRead)
        guard maxIterations >= 2, !sources.isEmpty || uploads != nil else { return preRead }

        let sourceKeys = Set(sources.map { Self.urlKey($0.url) })
        // Copie locale indispensable : passée directement, la propriété
        // `any Clock` n'est pas ouverte vers le générique de `scrapeAll`
        // (SE-0352) dès que Foundation est importé — vérifié en Swift 6.4.
        let roundClock = clock
        var attemptedKeys = Set(alreadyRead.map { Self.urlKey($0.url) })
        var pendingUploads = uploads
        var harvest = preRead
        for iteration in 2...maxIterations {
            try Task.checkCancellation()
            let canScrape = !sourceKeys.isSubset(of: attemptedKeys)
            guard canScrape || pendingUploads != nil else { break }

            let actionNames = Self.plannerActionNames(canScrape: canScrape, canSearchUploads: pendingUploads != nil)
            let decision = try await nextPlannerDecision(
                query: query,
                sources: sources,
                scrapedPages: harvest.pages,
                actionNames: actionNames,
                iteration: iteration
            )
            if decision.actionName == Self.uploadsSearchActionName, let uploadsAction = pendingUploads {
                pendingUploads = nil
                harvest.documents = try await uploadsAction.search(queries: decision.queries.isEmpty ? [query] : decision.queries)
                continue
            }
            // "done", action inconnue ou indisponible, sortie imparsable ou
            // planner en échec : même repli sûr, jamais d'action supplémentaire.
            guard canScrape, decision.actionName == Self.scrapeActionName else { break }

            let urls = Self.scrapableURLs(
                decision.urls,
                displayedSources: sources,
                alreadyAttempted: attemptedKeys,
                limit: maxScrapedURLsPerIteration
            )
            guard !urls.isEmpty else { break }
            attemptedKeys.formUnion(urls.map { Self.urlKey($0) })

            let pages = await Self.scrapeAll(urls, using: scrapeService, timeout: scrapeRoundTimeout, clock: roundClock)
            try Task.checkCancellation()
            harvest.pages.append(contentsOf: pages)
        }
        return harvest
    }

    /// Récolte de la boucle planner.
    private nonisolated struct PlannerHarvest: Sendable {
        var pages: [ScrapedPage] = []
        var documents: [SearXNGSearchResult] = []
    }

    /// Noms d'actions du planner. `uploadsSearch` = `UploadsSearchAction.name`.
    nonisolated static let scrapeActionName = "scrapeURL"
    nonisolated static let uploadsSearchActionName = "uploadsSearch"
    nonisolated static let doneActionName = "done"

    /// Actions proposées à un tour : seulement celles qui ont encore un objet
    /// (une source à scraper, des fichiers joints pas encore consultés), plus
    /// `done`. Sans fichier joint, exactement `["scrapeURL", "done"]`, comme
    /// avant 1.11.
    static func plannerActionNames(canScrape: Bool, canSearchUploads: Bool) -> [String] {
        (canScrape ? [scrapeActionName] : []) + (canSearchUploads ? [uploadsSearchActionName] : []) + [doneActionName]
    }

    /// Un tour planner : étape AUXILIAIRE (bug 3). Son échec (429/529 ou
    /// timeout BYOK, garde-fou ou limite d'Apple Intelligence…) vaut "done" :
    /// on répond avec les sources déjà trouvées plutôt que de perdre toute la
    /// réponse pour une étape facultative. L'annulation, elle, remonte.
    private func nextPlannerDecision(
        query: String,
        sources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage],
        actionNames: [String],
        iteration: Int
    ) async throws -> PlannerDecision {
        let prompt = Self.plannerPrompt(
            query: query,
            displayedSources: sources,
            scrapedPages: scrapedPages,
            availableActionNames: actionNames,
            iteration: iteration,
            maxIterations: maxIterations,
            maxURLsPerIteration: maxScrapedURLsPerIteration
        )
        return try await Self.bestEffort(fallback: PlannerDecision(actionName: Self.doneActionName, urls: [])) {
            let rawOutput = try await aiProvider.generate(prompt: prompt)
            return Self.decideNextAction(rawOutput: rawOutput)
        }
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
        let safeFallback = QueryClassification(
            skipSearch: false,
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

    /// Historique tel que le classifieur le reçoit (bug 6) : `QueryClassifier`
    /// n'en bornait que le NOMBRE de messages (`suffix(8)`), jamais la
    /// longueur — quelques réponses Approfondies suffisaient à faire déborder
    /// Apple Intelligence dès la classification. Mêmes bornes et même coupe
    /// (fin de phrase, « […] ») que le prompt final ; un budget nul ou
    /// négatif vaut « aucun historique », comme `PromptTemplates.formattedHistory`.
    static func boundedHistory(
        _ history: [ClassifierChatMessage],
        maxMessages: Int,
        maxCharacters: Int
    ) -> [ClassifierChatMessage] {
        guard maxCharacters > 0 else { return [] }
        return history.suffix(max(0, maxMessages)).map { message in
            ClassifierChatMessage(
                role: message.role,
                content: PromptTemplates.boundedHistoryContent(message.content, maxCharacters: maxCharacters)
            )
        }
    }

    /// Étape LLM auxiliaire (classification, planner) : en cas d'échec,
    /// `fallback`. Seule exception, l'annulation (`isCancellation`), relancée
    /// TELLE QUELLE : l'avaler ferait enchaîner le tour planner suivant —
    /// voire la génération finale — dans une tâche que l'utilisateur vient
    /// d'arrêter. Même règle que `FailoverManager.search`, qui relance
    /// l'erreur d'une tâche annulée au lieu d'essayer l'instance suivante.
    private static func bestEffort<Value>(
        fallback: Value,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            if isCancellation(error) { throw error }
            return fallback
        }
    }

    /// Une erreur est une annulation si la tâche l'est (`Task.isCancelled`,
    /// le critère de `FailoverManager` et de `ChatViewModel`), ou si elle en
    /// porte la marque sans que la tâche le soit encore : `CancellationError`
    /// (Swift Concurrency) ou `URLError(.cancelled)` (requête `URLSession`
    /// interrompue, ce que lève un provider cloud coupé en plein vol).
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Un tour de scrape : un scrape par URL EN PARALLÈLE (`TaskGroup`), sous
    /// une échéance GLOBALE (`timeout`, proposée par A′) — sans elle, le tour
    /// durait autant que la page la plus lente, et la réponse l'attendait.
    /// À l'échéance, les pages finies sont gardées, les autres annulées puis
    /// rendues EN ÉCHEC, comme tout échec individuel (`scrape(url:)` ne lève
    /// jamais) : `plannerPrompt` les annonce « récupération échouée », le
    /// modèle ne les redemande pas. Une annulation de la tâche englobante
    /// (Stop) interrompt aussitôt l'attente ; `runPlannerLoop` la vérifie
    /// juste après. Pages rendues dans l'ordre de `urls`, plus d'arrivée.
    ///
    /// Limite assumée : sortir d'un `TaskGroup` attend ses tâches, une tâche
    /// annulée doit donc s'arrêter d'elle-même — `ScrapeService` le fait
    /// (`URLSession` async) ; une page arrivée après l'échéance est ignorée.
    /// `clock.now` est lu ICI, sur l'exécuteur de l'orchestrateur, et non
    /// dans la tâche minuteur : un test s'en sert comme sonde du `@concurrent`.
    /// Non `private` depuis la mission A1 : la lecture des sources sans
    /// extrait (`SearchOrchestrator+PreRead.swift`) réutilise ce même tour.
    static func scrapeAll<C: Clock<Duration>>(
        _ urls: [String],
        using scrapeService: any ScrapeServing,
        timeout: Duration,
        clock: C
    ) async -> [ScrapedPage] {
        guard !urls.isEmpty else { return [] }
        let deadline = clock.now.advanced(by: timeout)
        return await withTaskGroup(of: ScrapeRoundEvent.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { .page(index: index, page: await scrapeService.scrape(url: url)) }
            }
            group.addTask {
                try? await clock.sleep(until: deadline, tolerance: nil)
                return .deadlineReached
            }
            var finishedPages: [Int: ScrapedPage] = [:]
            while finishedPages.count < urls.count, case .page(let index, let page)? = await group.next() {
                finishedPages[index] = page
            }
            group.cancelAll()
            return urls.indices.map { finishedPages[$0] ?? ScrapedPage(url: urls[$0], title: urls[$0], content: "", succeeded: false) }
        }
    }

    /// Événement d'un tour de scrape : une page finie (avec son rang dans la
    /// demande), ou l'échéance.
    private nonisolated enum ScrapeRoundEvent: Sendable {
        case page(index: Int, page: ScrapedPage)
        case deadlineReached
    }

    // MARK: - Sujet de recherche, URLs et pages (fonctions pures testables)

    /// Au-delà, une « reformulation » plus longue que la question elle-même
    /// n'en est pas une : le classifieur demande une reformulation COURTE, et
    /// un petit modèle qui boucle peut en produire des milliers de caractères.
    /// Envoyée telle quelle à SearXNG (requête GET), elle ferait échouer les
    /// instances une à une (URL trop longue) jusqu'à `allInstancesUnavailable`
    /// — une réponse perdue sur un simple raté de génération.
    nonisolated static let maxStandaloneQueryCharacters = 300

    /// Sujet de recherche (bug 1) : la reformulation autonome du classifieur
    /// (« Et son salaire ? » -> « Salaire de Tim Cook, PDG d'Apple »), sans
    /// laquelle SearXNG, le classement et le planner travaillaient sur une
    /// question incompréhensible hors conversation. Repli sur la question
    /// d'origine si la reformulation est vide après nettoyage des blancs, ou
    /// anormalement longue (`maxStandaloneQueryCharacters`, sauf si la
    /// question l'est déjà autant). Le classifieur en échec reformule déjà
    /// par la question elle-même (`classifyWithFallback`).
    nonisolated static func effectiveQuery(for query: String, standaloneFollowUp: String) -> String {
        let reformulation = standaloneFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reformulation.isEmpty, reformulation.count <= max(maxStandaloneQueryCharacters, query.count) else {
            return query
        }
        return reformulation
    }

    /// Clé de comparaison d'URL de tout le pipeline : `SourceRanker.normalizedURLKey`,
    /// celle qui déduplique déjà les sources — fragment `#…` retiré (jamais
    /// envoyé au serveur : deux URLs qui ne diffèrent que par lui téléchargent
    /// le MÊME document), hôte sans `www.` ni casse, slash final et paramètres
    /// de suivi ignorés, chemin sensible à la casse. Une seule règle : un
    /// dédoublonnage et une liste blanche fondés sur deux normalisations
    /// différentes finiraient par se contredire.
    nonisolated static func urlKey(_ url: String) -> String {
        SourceRanker.normalizedURLKey(for: url)
    }

    /// URLs que le planner peut réellement faire télécharger, dans l'ordre où
    /// il les propose :
    /// - uniquement des SOURCES AFFICHÉES (bug 8) : une page hors du top N, ou
    ///   inventée par le modèle, serait téléchargée depuis l'IP de
    ///   l'utilisateur puis injectée dans le prompt sans qu'il puisse la voir
    ///   sous la réponse ;
    /// - jamais deux fois la même page (bug 11), ni au sein d'une même liste
    ///   ni d'un tour à l'autre (`alreadyAttempted`, clés `urlKey`) ;
    /// - au plus `limit`, compté APRÈS ce filtre : trois URLs invalides en
    ///   tête ne doivent pas priver le tour d'une quatrième valide.
    /// Chaque URL retenue est réécrite à l'identique de sa source (la
    /// variante proposée par le modèle est abandonnée) : la page scrapée
    /// porte alors exactement l'URL que `PromptTemplates.numberedContext`
    /// compare pour la fusionner dans le document de cette source.
    nonisolated static func scrapableURLs(
        _ requestedURLs: [String],
        displayedSources: [SearXNGSearchResult],
        alreadyAttempted attemptedKeys: Set<String>,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }
        let canonicalURLByKey = canonicalURLsByKey(displayedSources)
        var selectedKeys: Set<String> = []
        var selected: [String] = []
        for url in requestedURLs {
            let key = urlKey(url)
            guard let canonicalURL = canonicalURLByKey[key], !attemptedKeys.contains(key) else { continue }
            guard selectedKeys.insert(key).inserted else { continue }
            selected.append(canonicalURL)
            if selected.count == limit { break }
        }
        return selected
    }

    /// Invariant des citations (bug 8) garanti en UN point, juste avant le
    /// prompt : toute page scrapée injectée figure dans les sources affichées.
    /// Les autres sont écartées, et l'URL de chaque page gardée est recopiée
    /// de sa source — sans cela, une page à l'URL légèrement différente
    /// (fragment, slash final) recevrait de `numberedContext` son propre
    /// numéro, une citation `[n]` au-delà des sources affichées. Le
    /// dédoublonnage reste celui de `numberedContext` (première page
    /// exploitable gagnante), qui sait préférer une page réussie à un échec.
    nonisolated static func pagesBackedBySources(_ pages: [ScrapedPage], sources: [SearXNGSearchResult]) -> [ScrapedPage] {
        let canonicalURLByKey = canonicalURLsByKey(sources)
        return pages.compactMap { page in
            guard let canonicalURL = canonicalURLByKey[urlKey(page.url)] else { return nil }
            return ScrapedPage(url: canonicalURL, title: page.title, content: page.content, succeeded: page.succeeded)
        }
    }

    /// Clé normalisée -> URL exacte de la source ; la première source gagne
    /// si deux partagent une clé (cas évité en amont : `SourceRanker`
    /// déduplique avec la même clé).
    private nonisolated static func canonicalURLsByKey(_ sources: [SearXNGSearchResult]) -> [String: String] {
        Dictionary(sources.map { (urlKey($0.url), $0.url) }, uniquingKeysWith: { first, _ in first })
    }

    /// Dédoublonnage par URL normalisée (`urlKey`), comme côté web
    /// (`researcher/index.ts`) : conserve l'ordre d'arrivée, ignore les
    /// doublons ultérieurs. Bug 11 corrigé : l'ensemble des URLs vues était
    /// calculé AVANT la boucle et jamais mis à jour, si bien que deux
    /// résultats de même URL dans un même lot passaient tous les deux — et
    /// produisaient des identifiants en double dans le `ForEach` des sources.
    static func accumulate(
        _ output: SearchActionOutput,
        sources: inout [SearXNGSearchResult],
        scrapedPages: inout [ScrapedPage]
    ) {
        switch output {
        case .searchResults(let results):
            var seenKeys = Set(sources.map { urlKey($0.url) })
            for result in results where seenKeys.insert(urlKey(result.url)).inserted {
                sources.append(result)
            }
        case .scrapedPages(let pages):
            scrapedPages.append(contentsOf: pages)
        case .reasoning, .done:
            break
        }
    }

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
    static func buildPrompt(
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
    static func insertingWidgetContext(_ widgetContext: String, into prompt: String, query: String) -> String {
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

    /// Prompt du planner (itérations 2+) : contrairement au tool-calling
    /// natif de `researcher/index.ts` (web), demande explicitement un JSON
    /// `{ "action": ..., "urls": [...] }`, même approche tolérante que
    /// `QueryClassifier.buildPrompt`. Le marqueur `<planner_context>` (absent
    /// du prompt de classification ET du prompt final) permet de distinguer
    /// sans ambiguïté un prompt de planificateur des deux autres étapes —
    /// utile aux mocks de test comme au débogage.
    ///
    /// Ne liste que les sources AFFICHÉES (bug 8), seules scrapables, chacune
    /// annotée si sa page a déjà été récupérée ou a échoué (bug 11 : sans
    /// cette mémoire, le modèle redemandait les mêmes pages à chaque tour).
    /// Le plafond par tour est interpolé depuis `maxURLsPerIteration` plutôt
    /// qu'écrit en dur (« 1 à 3 ») : un réglage par moteur (bug 6) ne doit
    /// pas laisser le prompt promettre plus que ce que la boucle exécute.
    ///
    /// Chaque action n'est décrite que si elle figure dans
    /// `availableActionNames` (`done` toujours) : `uploadsSearch` (1.11) et
    /// son champ `queries` n'apparaissent qu'avec des fichiers joints pas
    /// encore consultés. Avec `["scrapeURL", "done"]`, le texte est celui
    /// d'avant 1.11.
    static func plannerPrompt(
        query: String,
        displayedSources: [SearXNGSearchResult],
        scrapedPages: [ScrapedPage] = [],
        availableActionNames: [String],
        iteration: Int,
        maxIterations: Int,
        maxURLsPerIteration: Int = 3
    ) -> String {
        let succeededByKey = scrapedPages.reduce(into: [String: Bool]()) { status, page in
            let key = urlKey(page.url)
            status[key] = (status[key] ?? false) || page.succeeded
        }
        let sourcesSummary = displayedSources.enumerated()
            .map { index, result in
                let marker: String
                switch succeededByKey[urlKey(result.url)] {
                case true?: marker = " (page déjà récupérée)"
                case false?: marker = " (récupération échouée, ne la redemande pas)"
                case nil: marker = ""
                }
                return "\(index + 1). \(result.title) — \(result.url)\(marker)"
            }
            .joined(separator: "\n")

        let jsonFields = plannerJSONFields(availableActionNames)

        return """
        Tu es un agent de recherche. Itération \(iteration)/\(maxIterations).

        <planner_context>
        Requête de l'utilisateur : \(query)

        Sources affichées à l'utilisateur (les seules que tu peux demander) :
        \(sourcesSummary)

        Actions disponibles : \(availableActionNames.joined(separator: ", "))
        \(plannerActionDescriptions(availableActionNames, maxURLsPerIteration: maxURLsPerIteration))
        </planner_context>

        Réponds STRICTEMENT avec ce JSON, sans aucun texte autour :
        {
          "action": \(actionChoice(availableActionNames)),
          \(jsonFields)
        }
        """
    }

    /// Une ligne par action proposée, `done` toujours en dernier.
    private static func plannerActionDescriptions(_ actionNames: [String], maxURLsPerIteration: Int) -> String {
        let scrape = actionNames.contains(scrapeActionName)
            ? ["- \"scrapeURL\" : récupère le contenu complet de sources de la liste ci-dessus dont la page n'a pas encore été récupérée (au plus \(max(1, maxURLsPerIteration)) à la fois), pour approfondir la réponse. Fournis \"urls\" avec leurs URLs exactes."]
            : []
        let uploads = actionNames.contains(uploadsSearchActionName)
            ? ["- \"uploadsSearch\" : cherche dans les fichiers joints par l'utilisateur, sur l'appareil (jamais sur le web), si la question peut porter sur leur contenu. Fournis \"queries\" : 1 à \(UploadsSearchResultBuilder.maxQueries) requêtes courtes."]
            : []
        let done = ["- \"done\" : arrête la recherche, les sources actuelles suffisent pour répondre."]
        return (scrape + uploads + done).joined(separator: "\n")
    }

    /// Champs du JSON attendu, ceux des actions proposées seulement : `urls`
    /// pour `scrapeURL`, `queries` pour `uploadsSearch` — un petit modèle
    /// remplit volontiers un champ qu'on lui montre, même inutile. Sans action
    /// à paramètre (la boucle n'appelle alors jamais le planner), `urls`
    /// reste, comme avant 1.11.
    private static func plannerJSONFields(_ actionNames: [String]) -> String {
        let urls = actionNames.contains(scrapeActionName) ? ["\"urls\": [\"url1\", \"url2\"]"] : []
        let queries = actionNames.contains(uploadsSearchActionName) ? ["\"queries\": [\"requête 1\"]"] : []
        let fields = urls + queries
        return fields.isEmpty ? "\"urls\": [\"url1\", \"url2\"]" : fields.joined(separator: ",\n  ")
    }

    /// `"a" ou "b"`, `"a", "b" ou "c"` : la valeur attendue du champ `action`.
    private static func actionChoice(_ actionNames: [String]) -> String {
        let quoted = actionNames.map { "\"\($0)\"" }
        guard let last = quoted.last else { return "\"\(doneActionName)\"" }
        let head = quoted.dropLast()
        return head.isEmpty ? last : head.joined(separator: ", ") + " ou " + last
    }

    /// Parsing tolérant, même principe que `QueryClassifier.parse` : jamais
    /// de `throw`, un JSON introuvable/invalide/mal typé retombe sur
    /// `fallbackActionName` ("done" par défaut) — garantit la terminaison de
    /// la boucle planner quelle que soit la sortie du LLM.
    static func decideNextAction(rawOutput: String, fallbackActionName: String = "done") -> PlannerDecision {
        let fallback = PlannerDecision(actionName: fallbackActionName, urls: [])

        for candidate in Self.jsonCandidates(from: rawOutput) {
            guard
                let data = candidate.data(using: .utf8),
                let decoded = try? JSONDecoder().decode(RawPlannerResponse.self, from: data),
                let actionName = decoded.action
            else { continue }

            return PlannerDecision(actionName: actionName, urls: decoded.urls ?? [], queries: decoded.queries ?? [])
        }

        return fallback
    }

    /// Extraction de candidats JSON dupliquée depuis `QueryClassifier`
    /// (blocs de code markdown, puis repli sur la sous-chaîne entre la
    /// première `{` et la dernière `}`) plutôt que partagée :
    /// `QueryClassifier.jsonCandidates` est `private`, et ce fichier reste
    /// hors du scope autorisé de modification de `QueryClassifier.swift`
    /// (voir consignes de la tâche 1.2).
    private static func jsonCandidates(from rawOutput: String) -> [String] {
        var candidates: [String] = []
        for fencedBlock in Self.extractFencedBlocks(from: rawOutput) {
            candidates.append(Self.extractBracesSubstring(from: fencedBlock) ?? fencedBlock)
        }
        if let braces = Self.extractBracesSubstring(from: rawOutput) {
            candidates.append(braces)
        }
        return candidates
    }

    private static func extractFencedBlocks(from rawOutput: String) -> [String] {
        let fenceComponents = rawOutput.components(separatedBy: "```")
        guard fenceComponents.count >= 3 else { return [] }
        var blocks: [String] = []
        var index = 1
        while index < fenceComponents.count {
            var block = fenceComponents[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if block.hasPrefix("json") {
                block.removeFirst("json".count)
            }
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            index += 2
        }
        return blocks
    }

    private static func extractBracesSubstring(from rawOutput: String) -> String? {
        guard
            let firstBrace = rawOutput.firstIndex(of: "{"),
            let lastBrace = rawOutput.lastIndex(of: "}"),
            firstBrace < lastBrace
        else { return nil }
        return String(rawOutput[firstBrace...lastBrace])
    }

    /// Sans `reasoning` : clé ignorée si un modèle la renvoie quand même
    /// (`JSONDecoder` tolère les clés inconnues). `queries` : action
    /// `uploadsSearch` (1.11). `nonisolated` : décodé hors du main actor.
    private nonisolated struct RawPlannerResponse: Decodable {
        let action: String?
        let urls: [String]?
        let queries: [String]?
    }
}
