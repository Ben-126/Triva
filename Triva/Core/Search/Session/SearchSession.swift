//
//  SearchSession.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import SwiftUI

/// État lourd de la destination "Recherche", volontairement sorti de la vue.
///
/// Avant la coquille de navigation V1, tout ceci vivait en `@State` dans
/// `EngineStatusView`, qui était l'unique écran de l'app et n'était donc jamais
/// démontée. Ce n'est plus vrai : dans la présentation `NavigationSplitView`
/// (iPad en `regular`, Mac), aller sur "Découvrir" puis revenir sur "Recherche"
/// remplace le contenu du détail — le `@State` de la vue serait détruit à
/// chaque aller-retour, donc conversation en cours perdue, `MLXProvider`
/// re-préparé (chargement disque lourd, voir `MLXProvider.prepare()`) et cache
/// de dernière instance SearXNG du `FailoverManager` jeté. Ces caches
/// appartiennent donc à un objet de référence détenu plus haut (le shell de
/// `TrivaRootView`), qui survit aux changements de destination et n'est
/// reconstruit qu'au changement de moteur IA.
///
/// Corollaire important : les closures passées à `ChatViewModel` capturent
/// CETTE référence (`[weak self]`) et non plus une copie de la vue. Une copie
/// de struct capturée continuerait d'écrire dans un `@State` orphelin après
/// remontage : chaque recherche referait silencieusement toute la préparation
/// sans jamais réussir à la mettre en cache.
///
/// ## Un moteur par session, figé à la construction (bug 10)
/// `engine` ne change jamais : c'est l'UNIQUE valeur dont dérivent à la fois le
/// badge de confidentialité (`EngineStatusView`, Réglages) et la résolution du
/// provider à l'envoi (`resolveProviderForSending()`, qui passe ce moteur EN
/// VALEUR à `ActiveAIProviderResolver.resolve(engine:…)` et ne relit aucun
/// store de moteur). Le moteur utilisé ne peut donc pas différer du moteur
/// affiché, même si une autre fenêtre modifie le store partagé entre deux
/// rendus. Un changement de moteur produit une session NEUVE
/// (`.id(selected)` dans `TrivaRootView`).
///
/// ## Des caches qui se revalident seuls
/// Le provider MLX préparé et le `FailoverManager` sont rangés avec la
/// sélection pour laquelle ils ont été construits, et comparés à l'état
/// ACTUEL des stores partagés à chaque envoi. Les providers Apple Intelligence
/// et cloud ne sont pas mis en cache du tout : leur construction est triviale
/// et sans entrée/sortie (la clé BYOK n'est lue dans le trousseau qu'au moment
/// de la requête). Avant, l'invalidation reposait sur un `.onChange` posé sur
/// `EngineStatusView` : inactif dès que cette vue est démontée, c'est-à-dire
/// précisément quand on change de fournisseur dans les Réglages (sidebar
/// iPad/Mac, fenêtre Réglages macOS) — au retour sur la Recherche, l'envoi
/// partait encore vers l'ANCIEN fournisseur cloud.
@Observable
@MainActor
final class SearchSession {
    /// Moteur de cette session. Voir « Un moteur par session ».
    let engine: AIEngineOption

    /// Stores partagés par toute l'app (créés une seule fois par `TrivaApp`,
    /// voir `TrivaSharedStores`) — jamais recréés ici : la session est
    /// reconstruite à chaque changement de moteur IA, et des stores reconstruits
    /// avec elle rompraient le partage entre fenêtres. Exposés tels quels :
    /// `chatHistory` et `favorites` sont ceux à injecter dans `ChatViewModel`.
    let stores: TrivaSharedStores

    /// Brouillon de la barre de saisie (voir `SearchDraft`) : il vit aussi
    /// longtemps que la conversation, pas que la vue qui l'affiche.
    let draft: SearchDraft

    /// Position de lecture du fil (mission I1) : détenue ici, comme le brouillon, pour survivre au
    /// remontage de `ChatView` quand l'iPhone Duo se plie ou se déplie. Voir `TranscriptScrollState`.
    let transcriptScroll = TranscriptScrollState()

    /// La feuille de choix du modèle MLX est ouverte (mission I1) : détenue ici plutôt qu'en `@State`
    /// dans `EngineStatusView`, qui est remplacée au pliage ou au dépliage de l'iPhone Duo.
    var isChoosingMLXModel = false

    /// Clés de recherche personnelles (Brave, Tavily), lues à chaque envoi par
    /// `resolveWebSearchChain(failoverManager:)`. Service Keychain SÉPARÉ de
    /// `stores.keyStore` (clés IA, `SearchKeyStore.keychainService`).
    let searchKeyStore: SearchKeyStore

    /// État de la connexion (tâche 1.16), lu à chaque envoi et par l'interface. Voir `SearchSession+Offline.swift`.
    let connectivity: ConnectivityMonitor
    /// Le modèle MLX d'identifiant donné est-il entièrement sur le disque ? Injectable : un test ne
    /// doit pas dépendre des modèles de la machine qui le lance.
    let hasMLXWeights: @MainActor (String) -> Bool
    /// Cloud privé d'Apple ou appareil, pour le moteur Apple Intelligence (mission A4). Instance
    /// PARTAGÉE de l'app (voir `AppleIntelligenceModelCoordinator`), injectable pour les tests.
    let appleModel: AppleIntelligenceModelCoordinator

    /// Erreur de disponibilité d'Apple Intelligence (voir
    /// `refreshAppleIntelligenceAvailabilityIfNeeded`).
    private(set) var appleIntelligenceError: AppleIntelligenceError?
    /// Un seul `ChatViewModel` pour toute la durée de vie de la session : c'est
    /// lui qui porte le fil de conversation en cours.
    private(set) var chatViewModel: ChatViewModel?
    /// Catalogue MLX (fichier du bundle), lu une seule fois par session et
    /// seulement pour le moteur MLX. Observé : `validatedMLXModel` en dérive.
    private(set) var mlxCatalog: [MLXModelCatalogEntry]?

    /// Construire un `AppleIntelligenceProvider` et relire
    /// `SystemLanguageModel.availability` à chaque apparition de l'écran est un
    /// travail inutile : ce drapeau garantit une seule lecture par session
    /// (`appleIntelligenceError == nil` ne peut pas servir de drapeau, c'est
    /// justement la valeur du cas "disponible").
    @ObservationIgnored private var didCheckAppleIntelligenceAvailability = false
    /// Modèle MLX préparé pour le DERNIER envoi de cette session, avec son budget. Le modèle
    /// lui-même vit dans le pool partagé (`stores.mlxProviderPool`, mission M3) : un seul en
    /// mémoire pour toutes les fenêtres. Revalidé à chaque envoi contre `stores.mlxSelection`.
    @ObservationIgnored var preparedMLXProvider: PreparedMLXProvider?
    /// Identité de cette session auprès du pool MLX (file d'attente, fenêtres encore ouvertes).
    let mlxRequesterID = UUID()
    /// Mode de réponse imposé à CETTE session, sans toucher au mode mémorisé de l'utilisateur (chantier 2.1,
    /// mission B : « Poser une question à Triva » avec un mode choisi dans Raccourcis). `nil` = le mode mémorisé,
    /// relu à chaque envoi. Lu par `ensureChatViewModel()`.
    @ObservationIgnored var responseModeOverride: ResponseMode?
    /// `false` pour une session sans fenêtre (Siri, Raccourcis) : les pistes « À creuser » ne seraient lues par
    /// personne et coûteraient un second appel au modèle. À poser AVANT `ensureChatViewModel()`.
    @ObservationIgnored var generatesSuggestions = true
    /// Qui suit l'avancement des échanges de cette session (activité en direct). Une session sans fenêtre le met à
    /// `nil` : le système affiche déjà sa propre progression pour Siri et Raccourcis, jamais d'activité en doublon.
    @ObservationIgnored var progressObserver: (any SearchProgressObserving)? = SearchLiveActivityController.shared
    /// `FailoverManager` de la session, avec la liste d'instances qui l'a
    /// construit. En recréer un à chaque recherche jetterait son cache de
    /// dernière instance fonctionnelle ; le garder quand la liste a changé
    /// (Réglages > Recherche > Avancé, ou annuaire searx.space rafraîchi en tâche de fond)
    /// ferait ignorer la modification jusqu'au prochain lancement.
    @ObservationIgnored private var cachedFailoverManager: CachedFailoverManager?

    /// Pas de valeurs par défaut pour le moteur et les stores : seule la
    /// coquille de `TrivaRootView` crée une session, avec les stores de l'app ;
    /// les aperçus et les tests passent leurs propres stores
    /// (`TrivaSharedStores.preview()`, ou un jeu jetable).
    ///
    /// `searchKeyStore` a un défaut, le vrai trousseau des clés de recherche :
    /// `TrivaSharedStores` n'en porte pas encore (RI1b n'avait pas
    /// `TrivaApp.swift` dans son périmètre). Il n'est lu qu'à l'ENVOI : les
    /// aperçus et les tests qui n'envoient rien n'y touchent jamais, ceux qui
    /// envoient injectent un faux trousseau.
    init(
        engine: AIEngineOption,
        stores: TrivaSharedStores,
        searchKeyStore: SearchKeyStore = SearchKeyStore(),
        connectivity: ConnectivityMonitor = .shared,
        hasMLXWeights: @escaping @MainActor (String) -> Bool = { MLXProvider.hasDownloadedWeights(modelID: $0) },
        appleModel: AppleIntelligenceModelCoordinator = .shared
    ) {
        self.engine = engine
        self.stores = stores
        self.draft = SearchDraft()
        self.searchKeyStore = searchKeyStore
        self.connectivity = connectivity
        self.hasMLXWeights = hasMLXWeights
        self.appleModel = appleModel
        // Fenêtre MLX : elle compte dès sa création pour garder le modèle partagé en mémoire (M3).
        if engine == .mlxLocal {
            stores.mlxProviderPool.register(mlxRequesterID)
            // iPhone, iPad : la réponse du modèle local s'arrête quand l'app passe en arrière-plan (mission M).
            LocalGPUAccessMonitor.shared.register(self)
        }
    }

    /// Fin de session (changement de moteur, fenêtre fermée) : la génération en cours appartient au
    /// `ChatViewModel`, qui la garde en vie même quand `ChatView` est démontée (revue R3-1) ; il faut
    /// donc l'arrêter ici, sinon elle tournerait pour personne. La `Task` du modèle retient le modèle,
    /// jamais la session (closures `[weak self]`), donc ce `deinit` s'exécute bien.
    isolated deinit {
        // Aussi les réponses laissées en arrière-plan : plus personne ne les attend.
        chatViewModel?.stopEverything()
        // Dernière fenêtre MLX fermée (ou moteur changé) : le pool libère le modèle (mission M3).
        stores.mlxProviderPool.unregister(mlxRequesterID)
    }

    /// Lit la disponibilité d'Apple Intelligence au premier affichage de la
    /// destination "Recherche" ; ensuite, seulement tant qu'elle est en échec.
    /// Sans objet pour un autre moteur : rien ne l'afficherait.
    ///
    /// Relire tant qu'il y a une erreur (et non plus une seule fois par
    /// session) : `modelNotReady` (modèle en téléchargement) et
    /// `appleIntelligenceNotEnabled` se règlent sans changer de moteur. Lue
    /// une fois pour toutes, l'erreur aurait bloqué la Recherche jusqu'au
    /// prochain changement de moteur ou lancement, alors qu'il suffit de
    /// revenir sur l'écran. Une disponibilité confirmée n'est plus relue : un
    /// échec ultérieur remonte de toute façon à l'envoi, avec son message.
    func refreshAppleIntelligenceAvailabilityIfNeeded() {
        guard engine == .appleIntelligence else { return }
        guard !didCheckAppleIntelligenceAvailability || appleIntelligenceError != nil else { return }
        didCheckAppleIntelligenceAvailability = true
        appleIntelligenceError = AppleIntelligenceProvider().availabilityError
    }

    /// Charge le catalogue MLX pour l'affichage du modèle actif (moteur MLX
    /// seulement). Un échec laisse `validatedMLXModel` à `nil`, donc le bouton
    /// « Choisir un modèle MLX » : l'écran de choix lit le même fichier et
    /// affiche lui-même l'erreur, et l'envoi la remonte telle quelle (voir
    /// `preparedMLXProviderForCurrentSelection`) — rien n'est avalé.
    func loadMLXCatalogIfNeeded() {
        guard engine == .mlxLocal else { return }
        _ = try? loadedMLXCatalog()
    }

    /// Crée le `ChatViewModel` de la session au besoin. Appelée depuis
    /// `.onAppear` de la vue, jamais depuis son `body`, pour ne pas muter
    /// l'état observé pendant l'évaluation de la vue (SwiftUI l'interdit :
    /// "Modifying state during view update").
    ///
    /// Appelée aussi par `TrivaRootCoordinator.openConversation(id:)`, depuis
    /// une action : on peut ouvrir une conversation de la Bibliothèque avant
    /// d'avoir jamais affiché la Recherche.
    ///
    /// Les closures capturent `self` FAIBLEMENT : `chatViewModel` est retenu
    /// par la session, un capture fort refermerait le cycle et ferait fuir
    /// session + conversation + provider MLX préparé à chaque changement de
    /// moteur IA ou fermeture de fenêtre.
    ///
    /// Historique et favoris : les instances UNIQUES de l'app. Sans elles, rien
    /// n'était enregistré (Bibliothèque vide, étoile indisponible) ; avec des
    /// instances créées ici, le compteur `revision` de la Bibliothèque ne
    /// verrait jamais les écritures du chat. Le `ChatViewModel` n'en crée
    /// jamais lui-même.
    func ensureChatViewModel() {
        guard chatViewModel == nil else { return }
        chatViewModel = ChatViewModel(
            resolveProvider: { [weak self] in
                guard let self else { throw SearchSessionError.sessionEnded }
                return try await self.resolveProviderForSending()
            },
            resolveFailoverManager: { [weak self] in
                guard let self else { throw SearchSessionError.sessionEnded }
                return self.resolveFailoverManager()
            },
            resolveWebSearchChain: { [weak self] failoverManager in
                guard let self else { throw SearchSessionError.sessionEnded }
                return self.resolveWebSearchChain(failoverManager: failoverManager)
            },
            resolveOfflinePlan: { [weak self] in self?.resolveOfflinePlan() },
            // Tâche 2.4 : `nil` sauf Apple Intelligence avec le drapeau `AgenticResearchSetting` allumé.
            resolveAgenticResearcher: { [weak self] in self?.agenticResearcherForSending() },
            // Session disparue : l'envoi a déjà échoué sur `resolveProvider`,
            // ce repli (le budget le plus serré) n'est jamais utilisé.
            resolvePipelineConfiguration: { [weak self] in
                self?.pipelineConfigurationForSending() ?? .appleIntelligence
            },
            // Mode imposé à cette session (Raccourcis), sinon le mode mémorisé, relu à chaque envoi.
            readResponseMode: { [weak self] in self?.responseModeOverride ?? ChatViewModel.persistedResponseMode() },
            historyStore: stores.chatHistory,
            favoritesStore: stores.favorites,
            // Une session sans fenêtre (Siri) ne génère pas de pistes : personne ne les lirait.
            generateSuggestions: { [weak self] provider, history in
                guard self?.generatesSuggestions ?? true else { return [] }
                return await SuggestionsService(aiProvider: provider).generateSuggestions(chatHistory: history)
            },
            resolveConsentRequest: { [weak self] in self?.cloudConsentRequestForSending() },
            grantConsent: { [weak self] request in self?.stores.cloudConsent.grant(providerID: request.providerID) }
        )
        chatViewModel?.progressObserver = progressObserver
    }


    /// Provider IA à utiliser pour un envoi : TOUJOURS celui de `engine`, le
    /// moteur affiché par le badge de cette fenêtre (bug 10), jamais celui
    /// qu'un store relu indiquerait. Interne (et non privé) pour que les tests
    /// verrouillent cette garantie (`SearchSessionEngineBindingTests`).
    ///
    /// Pour MLX, le provider est préparé ici — `ActiveAIProviderResolver` ne
    /// le fait jamais lui-même (voir sa documentation) : c'est cette session
    /// qui sait qu'un chargement potentiellement long est acceptable à cet
    /// endroit.
    func resolveProviderForSending() async throws -> any AIGenerating {
        switch engine {
        case .mlxLocal:
            return try await preparedMLXProviderForCurrentSelection()
        case .appleIntelligence, .cloudBYOK:
            // Résolus à neuf à chaque envoi (voir « Des caches qui se
            // revalident seuls ») : toujours conformes à la sélection cloud et
            // aux fournisseurs personnalisés du moment. Catalogue MLX vide : il
            // n'a rien à faire ici, et un fichier de catalogue illisible ne
            // doit pas empêcher Apple Intelligence ou le cloud de répondre.
            let provider = try ActiveAIProviderResolver.resolve(
                engine: engine,
                mlxSelection: stores.mlxSelection,
                mlxCatalog: [],
                cloudSelection: stores.cloudSelection,
                customCloudPresets: stores.customProviders.customPresets,
                keyStore: stores.keyStore,
                cloudConsent: stores.cloudConsent.storage
            )
            // Apple Intelligence : le provider local, déjà vérifié disponible, devient le secours
            // du cloud privé quand celui-ci est proposé et choisi (mission A4) ; sinon, tel quel.
            guard engine == .appleIntelligence else { return provider }
            return appleModel.providerForSending(local: provider, isOffline: connectivity.isOffline)
        }
    }

    /// `FailoverManager` construit sur la liste d'instances SearXNG EFFECTIVE
    /// (`stores.searXNGInstances` : ajouts de l'utilisateur, liste du bundle,
    /// puis instances vérifiées de l'annuaire searx.space, masquages appliqués)
    /// et branché sur la mémoire de fiabilité PARTAGÉE de l'app
    /// (`stores.searchReliability`, persistée) ; réutilisé tant que cette liste
    /// ne change pas. Reconstruire un manager ne perd plus que son cache de
    /// dernière instance : ce qu'il avait appris de chaque instance vit dans le
    /// store partagé, que la session suivante (ou une autre fenêtre) retrouve.
    /// Interne pour les tests. Une liste vide n'est pas une erreur ici :
    /// `FailoverManager.search` la signale (`noInstancesConfigured`), avec un
    /// message français déjà prévu par `ChatViewModel`.
    func resolveFailoverManager() -> FailoverManager {
        let instances = stores.searXNGInstances
        if let cachedFailoverManager, cachedFailoverManager.instances == instances {
            return cachedFailoverManager.manager
        }
        let manager = stores.makeFailoverManager(instances: instances)
        cachedFailoverManager = CachedFailoverManager(instances: instances, manager: manager)
        return manager
    }


    /// Générateur MLX pour le modèle ACTUELLEMENT sélectionné, tiré du pool PARTAGÉ de l'app
    /// (mission M3) : un seul modèle en mémoire pour toutes les fenêtres, chargé une seule fois,
    /// et chaque génération attend son tour dans la file commune.
    ///
    /// L'id est lu juste avant la résolution, sans suspension entre les deux (main actor). Si la
    /// sélection change PENDANT le chargement, le pool l'abandonne (`modelNotLoaded`) plutôt que de
    /// garder deux modèles : la question suivante part sur le nouveau.
    private func preparedMLXProviderForCurrentSelection() async throws -> any AIGenerating {
        let modelID = stores.mlxSelection.selectedModelID
        // Sans modèle choisi, le résolveur lève `noMLXModelSelected` (message
        // actionnable) sans consulter le catalogue : ne pas le lire évite
        // qu'un fichier de catalogue illisible masque cette erreur-là.
        let catalog: [MLXModelCatalogEntry]
        if modelID == nil {
            catalog = []
        } else {
            catalog = try loadedMLXCatalog()
        }
        let provider = try ActiveAIProviderResolver.resolve(
            engine: .mlxLocal,
            mlxSelection: stores.mlxSelection,
            mlxCatalog: catalog,
            cloudSelection: stores.cloudSelection,
            customCloudPresets: [],
            keyStore: stores.keyStore
        )
        // Le résolveur renvoie toujours un `MLXProvider` pour `.mlxLocal` ;
        // le cas contraire n'a rien à préparer ni à partager.
        guard let modelID, let mlxProvider = provider as? MLXProvider else { return provider }

        // Budget calculé AVANT la suspension du chargement, sur le même
        // instantané (`modelID`, catalogue) que le provider : voir
        // `pipelineConfigurationForSending()`.
        let configuration = SearchPipelineConfiguration.preset(
            for: .mlxLocal,
            mlxModel: catalog.first { $0.id == modelID }
        )
        preparedMLXProvider = nil
        let pool = stores.mlxProviderPool
        // `mlxProvider` ne sert que si le pool n'a pas déjà ce modèle (instance neuve, chargée une fois).
        let model = try await pool.preparedModel(id: modelID, requester: mlxRequesterID) { mlxProvider }
        preparedMLXProvider = PreparedMLXProvider(modelID: modelID, configuration: configuration)
        return pool.generator(for: model, requester: mlxRequesterID)
    }

    /// Catalogue MLX, lu dans le bundle au premier besoin puis gardé (le
    /// fichier ne change pas pendant la vie de l'app). Jamais appelé depuis un
    /// `body` : il écrit dans un état observé.
    private func loadedMLXCatalog() throws -> [MLXModelCatalogEntry] {
        if let mlxCatalog {
            return mlxCatalog
        }
        let catalog = try MLXModelCatalog.load()
        mlxCatalog = catalog
        return catalog
    }
}

/// Modèle MLX du dernier envoi de `SearchSession` et budget de ce modèle : les deux viennent du
/// même instantané. Le modèle lui-même vit dans `MLXProviderPool` (partagé entre fenêtres).
struct PreparedMLXProvider {
    let modelID: String
    let configuration: SearchPipelineConfiguration
}

/// `FailoverManager` et la liste d'instances qui l'a construit (cache de
/// `SearchSession`).
private struct CachedFailoverManager {
    let instances: [URL]
    let manager: FailoverManager
}
