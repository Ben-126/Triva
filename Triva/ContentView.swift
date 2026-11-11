//
//  ContentView.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import SwiftUI

/// Ce fichier n'est plus la racine de l'app : depuis la coquille de navigation
/// V1, c'est `TrivaRootView` (`Features/Root/TrivaRootView.swift`) qui décide
/// de ce qu'une fenêtre affiche — l'écran de choix du moteur IA tant qu'aucun
/// n'est choisi, puis les 5 destinations (Recherche, Découvrir, Bibliothèque,
/// Favoris, Réglages).
///
/// Il garde son nom parce qu'il garde son rôle réel, celui que `ChatView`,
/// `ChatViewModel`, `MessageBubbleView` et `SourcesListView` citent déjà dans
/// leur documentation : c'est ici que vit la destination "Recherche" (badge
/// moteur IA + `ChatView`) et la résolution du provider IA et du
/// `FailoverManager` actifs — désormais portée par `SearchSession` plutôt que
/// par la vue elle-même (voir le commentaire de tête de `SearchSession` pour
/// le pourquoi).

/// Erreurs propres à `SearchSession`.
enum SearchSessionError: Error, Sendable, Equatable {
    /// La session de recherche a été libérée (fenêtre fermée, ou changement de
    /// moteur IA qui reconstruit toute la session) alors qu'une génération
    /// était encore en vol.
    ///
    /// Le cas courant est déjà couvert sans passer par ici : changer de
    /// destination fait disparaître `ChatView`, qui annule sa `Task`, et
    /// `ChatViewModel` traite une annulation comme un arrêt volontaire. Reste
    /// la course de la fermeture de fenêtre pendant une génération, où la
    /// session peut être libérée avant que l'annulation ne soit constatée :
    /// `ChatViewModel.userFacingMessage(for:)` lui donne un message français
    /// (I2). Levée aussi par le chargement de Découvrir si la session a
    /// disparu (`TrivaRootCoordinator`), qui s'affiche alors comme un échec
    /// de chargement ordinaire. On préfère une erreur explicite à un
    /// `unowned self`, qui ferait planter l'app au lieu de le signaler.
    case sessionEnded
}

/// Texte de la barre de saisie de la Recherche, détenu par la `SearchSession`
/// plutôt que par `ChatView` (mission I4b). Deux raisons :
/// 1. Découvrir > « Chercher dans Triva » doit pouvoir REMPLIR la barre depuis
///    un autre espace (`TrivaRootCoordinator.search(_:)`) ;
/// 2. `ChatView` est démontée à chaque changement de destination en
///    présentation sidebar (iPad, Mac), et à chaque bascule de classe de
///    taille (Split View, Stage Manager, iPhone Duo déplié) : un texte en
///    `@State` dans la vue serait perdu à chaque fois.
///
/// Transmis à `ChatView` par l'environnement (`EngineStatusView`). Contrat
/// côté `ChatView` : lecture OPTIONNELLE,
/// `@Environment(SearchDraft.self) private var draft: SearchDraft?` — ses
/// aperçus n'en injectent pas, une lecture non optionnelle les ferait planter —,
/// barre liée à `draft.text` quand il est présent, vidée après l'envoi.
@Observable
@MainActor
final class SearchDraft {
    var text = ""
}

/// Ce qui manque au moteur de la session pour répondre — au premier lancement
/// comme après un réglage effacé ailleurs. Sert à ne jamais montrer un écran
/// vide ou un chat qui échouera à coup sûr sans dire pourquoi ni quoi faire.
enum SearchSetupRequirement: Equatable {
    /// Apple Intelligence choisi mais indisponible, pour la raison portée.
    case appleIntelligenceUnavailable(AppleIntelligenceError)
    /// MLX local choisi, aucun modèle validé.
    case mlxModel
    /// Clé API personnelle choisie, aucun fournisseur ni modèle sélectionné.
    case cloudProvider

    /// Explication affichée sous l'en-tête, ou `nil` quand le bouton d'action
    /// de l'en-tête (« Choisir un modèle MLX ») se suffit à lui-même.
    ///
    /// Jamais `String(describing:)` d'une erreur : l'écran affichait avant
    /// « Indisponible : deviceNotEligible », un identifiant anglais qui ne dit
    /// ni ce qui se passe ni quoi faire. Chaque message nomme l'issue — le
    /// bouton « Changer de moteur » est toujours juste au-dessus.
    var message: String? {
        switch self {
        case .appleIntelligenceUnavailable(let error):
            return Self.message(for: error)
        case .mlxModel:
            return nil
        case .cloudProvider:
            return "Ajoute ta clé API, puis choisis un fournisseur et un modèle dans les Réglages."
        }
    }

    private static func message(for error: AppleIntelligenceError) -> String {
        switch error {
        case .deviceNotEligible:
            "Cet appareil ne prend pas en charge Apple Intelligence. Choisis un autre moteur."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence est désactivé. Active-le dans les réglages de l'appareil, ou choisis un autre moteur."
        case .modelNotReady:
            "Le modèle Apple Intelligence est en cours de téléchargement. Réessaie dans quelques minutes."
        case .unavailableForOtherReason:
            "Apple Intelligence n'est pas disponible pour le moment. Réessaie plus tard, ou choisis un autre moteur."
        case .generationFailed:
            // Jamais produit par la vérification de disponibilité ; le texte
            // porté vient du framework, il n'est pas repris.
            "Apple Intelligence n'a pas pu répondre. Réessaie."
        }
    }
}

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
    /// `MLXProvider` déjà préparé, avec l'id du modèle pour lequel il l'a été —
    /// évite de refaire un `prepare()` coûteux (chargement de plusieurs Go) à
    /// chaque échange du chat. Revalidé à chaque envoi contre
    /// `stores.mlxSelection` : un modèle changé ailleurs (autre fenêtre,
    /// Réglages) est donc pris en compte au prochain envoi.
    @ObservationIgnored var preparedMLXProvider: PreparedMLXProvider?
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
    }

    /// Modèle MLX validé (0.5) pour la sélection courante, `nil` tant qu'aucun
    /// n'a été choisi — le chat MLX est inutilisable dans ce cas.
    ///
    /// DÉRIVÉ du store partagé à chaque lecture, et non plus copié dans la
    /// session : un modèle choisi dans une autre fenêtre (ou effacé par les
    /// Réglages, voir `MLXStorageView`) s'affiche donc ici aussitôt — la carte
    /// « Modèle actif » montre toujours le modèle que le prochain envoi
    /// utilisera, même logique que le badge.
    var validatedMLXModel: MLXModelCatalogEntry? {
        guard let id = stores.mlxSelection.selectedModelID else { return nil }
        return mlxCatalog?.first { $0.id == id }
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

    /// Ce qui manque encore au moteur de la session pour répondre, `nil` si
    /// la Recherche est prête. Dérivé à chaque lecture des stores partagés :
    /// une clé configurée dans les Réglages (de cette fenêtre ou d'une autre)
    /// fait apparaître le chat dès le retour sur la Recherche.
    ///
    /// Cloud : seule la SÉLECTION est vérifiée, jamais la clé — la lire
    /// demanderait un accès au trousseau à chaque rendu. Une sélection sans
    /// clé reste possible (clé supprimée hors de l'app) ; l'envoi le dit
    /// alors avec un message actionnable.
    var setupRequirement: SearchSetupRequirement? {
        switch engine {
        case .appleIntelligence:
            guard let appleIntelligenceError else { return nil }
            return .appleIntelligenceUnavailable(appleIntelligenceError)
        case .mlxLocal:
            return validatedMLXModel == nil ? .mlxModel : nil
        case .cloudBYOK:
            return stores.cloudSelection.selection == nil ? .cloudProvider : nil
        }
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

    /// Enregistre le modèle MLX que l'utilisateur vient de valider, dans le
    /// store PARTAGÉ (toutes les fenêtres le voient). Le provider préparé pour
    /// l'ancien modèle est relâché tout de suite plutôt qu'au prochain envoi :
    /// c'est de la mémoire (plusieurs Go) rendue sans attendre.
    func selectMLXModel(_ chosen: MLXModelCatalogEntry) {
        stores.mlxSelection.selectedModelID = chosen.id
        preparedMLXProvider = nil
        loadMLXCatalogIfNeeded()
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
            // Session disparue : l'envoi a déjà échoué sur `resolveProvider`,
            // ce repli (le budget le plus serré) n'est jamais utilisé.
            resolvePipelineConfiguration: { [weak self] in
                self?.pipelineConfigurationForSending() ?? .appleIntelligence
            },
            historyStore: stores.chatHistory,
            favoritesStore: stores.favorites
        )
    }

    /// Budget de recherche et de contexte du moteur qui a produit le provider
    /// de l'envoi en cours (bug 6). `ChatViewModel` l'appelle juste après
    /// `resolveProvider`, sans suspension entre les deux. Interne pour les
    /// tests.
    ///
    /// Apple Intelligence et cloud : `engine` est figé, le budget aussi. MLX :
    /// le budget dépend du MODÈLE (compact ou non), donc il est rangé avec le
    /// provider préparé, calculé sur le même `modelID` que lui. Relire
    /// `stores.mlxSelection` ici serait faux : une autre fenêtre peut changer
    /// de modèle pendant le `prepare()` de cet envoi, qui garde pourtant le
    /// modèle qu'il a chargé. Sans provider préparé (jamais en pratique : la
    /// résolution a échoué avant), le budget compact, le plus prudent.
    func pipelineConfigurationForSending() -> SearchPipelineConfiguration {
        switch engine {
        case .appleIntelligence:
            // Cloud privé ou appareil : le modèle retenu par CE même envoi (mission A4).
            return appleModel.pipelineConfigurationForSending()
        case .cloudBYOK:
            return SearchPipelineConfiguration.preset(for: engine)
        case .mlxLocal:
            return preparedMLXProvider?.configuration ?? SearchPipelineConfiguration.preset(for: .mlxLocal)
        }
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
                keyStore: stores.keyStore
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

    /// Chaîne de repli de la recherche web pour un envoi (RI1b) : clés de
    /// recherche personnelles, SearXNG sur `failoverManager` (celui que
    /// `ChatViewModel` vient de résoudre), recherche du fournisseur cloud,
    /// sources ouvertes (`WebSearchChain.assemble`). Interne pour les tests.
    ///
    /// Reconstruite à chaque envoi, jamais mise en cache, comme les providers
    /// Apple Intelligence et cloud (voir « Des caches qui se revalident
    /// seuls ») : une clé ajoutée ou retirée, une sélection cloud changée
    /// ailleurs, vaut dès la question suivante. La recherche cloud dépend de
    /// `engine`, le moteur FIGÉ de cette session (bug 10), jamais d'un store
    /// relu : une session Apple Intelligence ne l'utilise jamais, même si une
    /// autre fenêtre a enregistré une sélection cloud avec sa clé.
    func resolveWebSearchChain(failoverManager: FailoverManager) -> WebSearchChain {
        WebSearchChain.assemble(
            engine: engine,
            cloudSelection: stores.cloudSelection.selection,
            cloudKeyStore: stores.keyStore,
            searchKeys: searchKeyStore,
            failoverManager: failoverManager,
            fallbackLanguage: Self.fallbackSearchLanguage()
        )
    }

    /// Langue de la recherche quand celle de la question n'est pas reconnue (noms propres, mots
    /// isolés, voir « LANGUE » de `WebSearchChain`) : la langue de l'appareil, avec la règle FR/EN de
    /// Découvrir (`DiscoverLanguage.preferred`). `Locale.preferredLanguages`, jamais
    /// `Locale.current` : sans localisation française dans le projet, cette dernière peut valoir
    /// l'anglais sur un appareil réglé en français (voir `AnswerExcerpt.swift`).
    static func fallbackSearchLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        DiscoverLanguage.preferred(for: Locale(identifier: preferredLanguages.first ?? "en")).rawValue
    }

    /// Provider MLX préparé pour le modèle ACTUELLEMENT sélectionné.
    ///
    /// L'id est lu juste avant la résolution, sans suspension entre les deux
    /// (main actor) : le cache est donc rangé sous l'id réellement préparé. Si
    /// une autre fenêtre change de modèle PENDANT un `prepare()`, l'envoi en
    /// cours utilise le modèle qu'il a commencé à charger, et le suivant
    /// détecte l'écart et prépare le nouveau. Écart transitoire assumé : les
    /// deux modèles sont locaux, la promesse « sur l'appareil » tient.
    private func preparedMLXProviderForCurrentSelection() async throws -> any AIGenerating {
        let modelID = stores.mlxSelection.selectedModelID
        if let preparedMLXProvider, preparedMLXProvider.modelID == modelID {
            return preparedMLXProvider.provider
        }
        // Relâché AVANT de charger le suivant : jamais deux modèles en mémoire
        // pour une même session.
        preparedMLXProvider = nil

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
        // le cas contraire n'a rien à préparer ni à mettre en cache.
        guard let mlxProvider = provider as? MLXProvider else { return provider }

        // Budget calculé AVANT la suspension de `prepare()`, sur le même
        // instantané (`modelID`, catalogue) que le provider : voir
        // `pipelineConfigurationForSending()`.
        let configuration = SearchPipelineConfiguration.preset(
            for: .mlxLocal,
            mlxModel: catalog.first { $0.id == modelID }
        )
        try await mlxProvider.prepare()
        if let modelID {
            preparedMLXProvider = PreparedMLXProvider(
                modelID: modelID,
                provider: mlxProvider,
                configuration: configuration
            )
        }
        return mlxProvider
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

/// Provider MLX préparé, l'id du modèle qu'il porte et le budget de ce modèle
/// (cache de `SearchSession`) : les trois viennent du même instantané.
struct PreparedMLXProvider {
    let modelID: String
    let provider: MLXProvider
    let configuration: SearchPipelineConfiguration
}

/// `FailoverManager` et la liste d'instances qui l'a construit (cache de
/// `SearchSession`).
private struct CachedFailoverManager {
    let instances: [URL]
    let manager: FailoverManager
}

/// Destination "Recherche" de la coquille de navigation : affiche le moteur IA
/// de la session (badge + légende de confidentialité, DESIGN.md) et l'écran de
/// chat réel (`ChatView`, 0.8) pour ce moteur. Gère aussi tout ce qui est
/// spécifique au moteur et qui l'empêcherait de répondre
/// (`SearchSetupRequirement`) : choix/changement de modèle MLX,
/// indisponibilité d'Apple Intelligence, fournisseur cloud pas encore choisi.
/// Au premier lancement, l'utilisateur ne voit donc jamais un écran vide ni un
/// chat voué à l'échec : l'en-tête propose l'action qui débloque, une phrase
/// dit pourquoi.
///
/// Ne détient plus aucun état lourd : tout ce qui doit survivre à un
/// aller-retour vers une autre destination vit dans `SearchSession` (voir son
/// commentaire de tête). Ce qui reste ici en `@State` est strictement local à
/// l'affichage (présentation d'une feuille modale) et peut disparaître avec la
/// vue sans conséquence.
///
/// Plus de paramètre `selectedEngine` séparé : le badge lit `session.engine`,
/// la valeur même que l'envoi utilise. Deux sources auraient pu diverger — c'est
/// exactement la forme du bug 10.
struct EngineStatusView: View {
    let onChangeEngine: () -> Void
    /// « Configurer une clé API » (moteur cloud sans fournisseur choisi) :
    /// la coquille bascule sur les Réglages de la même fenêtre
    /// (`TrivaRootCoordinator.showSettings()`).
    let onOpenSettings: () -> Void

    /// Session injectée par le shell de `TrivaRootView` — surtout PAS de
    /// `@State` ici : cette vue est démontée/remontée à chaque changement de
    /// destination en présentation `NavigationSplitView`.
    let session: SearchSession

    /// `session` n'a volontairement PAS de valeur par défaut : `SearchSession`
    /// est `@MainActor`, et une expression de valeur par défaut est évaluée
    /// dans un contexte synchrone *nonisolated* au point d'appel — écrire
    /// `session: SearchSession = SearchSession()` ne compile donc pas
    /// (`call to main actor-isolated initializer ... in a synchronous
    /// nonisolated context`). Les previews ci-dessous, elles, s'exécutent sur
    /// le main actor et construisent leur session explicitement.
    init(onChangeEngine: @escaping () -> Void, onOpenSettings: @escaping () -> Void, session: SearchSession) {
        self.onChangeEngine = onChangeEngine
        self.onOpenSettings = onOpenSettings
        self.session = session
    }

    @State private var showingMLXSelection = false
    /// Force une relecture du `body` une fois le chat préparé. Constaté sur Mac au lancement : la
    /// création de `chatViewModel` ne relançait pas toujours le `body`, et seul le badge restait,
    /// sans barre de saisie, jusqu'au moindre autre changement d'état.
    @State private var chatPrepared = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Le moteur affiché ET utilisé (voir `SearchSession.engine`).
    private var engine: AIEngineOption { session.engine }

    /// Badge du modèle que le prochain envoi utilisera (cloud privé d'Apple ou appareil, mission
    /// A4) : même calcul que l'envoi, il suit la connexion et la préférence partagée.
    private var badge: (icon: String, text: String, caption: String) {
        guard engine == .appleIntelligence else { return engine.privacyBadge }
        return engine.privacyBadge(appleRoute: session.appleModel.displayedRoute(isOffline: session.connectivity.isOffline))
    }

    /// Même plafond que `ChatView.contentMaxWidth` (640pt en `regular`,
    /// iPad/Mac) — sans lui, le badge moteur IA et le bouton "Changer de
    /// moteur" restaient collés au bord gauche pendant que `ChatView` juste en
    /// dessous centrait ses messages, sur le même écran.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    var body: some View {
        let _ = chatPrepared
        VStack(alignment: .leading, spacing: 12) {
            header

            if let message = session.setupRequirement?.message {
                // Même colonne que l'en-tête et que `ChatView` (640 pt en
                // `regular`, centrée), texte calé à gauche dans cette colonne.
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: contentMaxWidth ?? .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("search.setupRequirement")
            }

            if let plan = session.resolveOfflinePlan() {
                OfflineStatusLine(text: plan.statusText)
                    .frame(maxWidth: contentMaxWidth ?? .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
            }

            if let chatViewModel = session.chatViewModel,
               Self.showsChat(requirement: session.setupRequirement, hasMessages: !chatViewModel.messages.isEmpty) {
                ChatView(viewModel: chatViewModel)
                    // Brouillon de la session (voir `SearchDraft`) : survit au
                    // démontage de `ChatView` et reçoit le texte de
                    // Découvrir > « Chercher dans Triva ».
                    .environment(session.draft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 24)
        .sheet(isPresented: $showingMLXSelection) {
            MLXModelSelectionView { chosen in
                session.selectMLXModel(chosen)
                showingMLXSelection = false
            }
            #if os(macOS)
            // Une feuille Mac ne se ferme ni d'un geste ni d'un clic à côté : sans ce bouton, seul
            // Échap permettait d'en sortir sans choisir de modèle (constaté, mission Q2).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                mlxSelectionCloseBar
            }
            #endif
        }
        .task {
            session.refreshAppleIntelligenceAvailabilityIfNeeded()
            if engine == .appleIntelligence { session.appleModel.refreshStatus() }
            session.loadMLXCatalogIfNeeded()
            session.ensureChatViewModel()
            chatPrepared = true
        }
    }

    #if os(macOS)
    /// Même barre que les feuilles des Réglages (`SettingsView.sheetCloseBar`) : fond opaque et
    /// séparateur, car la liste défile derrière ; Échap ferme aussi.
    private var mlxSelectionCloseBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Spacer()
                Button("Fermer") {
                    showingMLXSelection = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.background)
    }
    #endif

    /// Le chat s'affiche quand le moteur est prêt — ou, même s'il ne l'est
    /// pas, dès que le fil contient des messages : une conversation rouverte
    /// depuis la Bibliothèque ou un favori reste lisible (la relire ne dépend
    /// pas du moteur), l'explication au-dessus dit pourquoi un nouvel envoi
    /// échouerait. Moteur pas prêt et fil vide : pas de chat, qui échouerait à
    /// coup sûr au premier envoi ; l'en-tête propose l'action qui débloque.
    /// Règle pure, testée sans interface.
    static func showsChat(requirement: SearchSetupRequirement?, hasMessages: Bool) -> Bool {
        requirement == nil || hasMessages
    }

    /// Badge moteur IA + légende de confidentialité, et pour MLX local le CTA
    /// de choix de modèle (ou le modèle actif + bouton pour en changer) — la
    /// seule partie de cet écran qui ne fait pas partie du chat lui-même.
    /// Tous les éléments de verre de ce bloc (badge, CTA "Choisir un modèle
    /// MLX" ou "Configurer une clé API", carte "Modèle actif", bouton "Changer
    /// de modèle MLX", bouton "Changer de moteur") partagent un seul
    /// `GlassEffectContainer` commun
    /// (DESIGN.md : "toujours envelopper des éléments de verre frères dans un
    /// `GlassEffectContainer`") — jamais de container imbriqué dans un autre.
    ///
    /// Ordre volontaire : le CTA "Choisir un modèle MLX" (`.glassProminent`,
    /// l'action OBLIGATOIRE sans laquelle le chat est inutilisable) est
    /// TOUJOURS rendu avant "Changer de moteur" (`.glass`, une simple
    /// échappatoire secondaire) — DESIGN.md réserve `.glassProminent` à
    /// l'action principale d'un écran, ce que contredirait le fait de la faire
    /// suivre visuellement une action secondaire en scannant l'écran de haut
    /// en bas.
    private var header: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(badge.text, systemImage: badge.icon)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .capsule)
                        .accessibilityIdentifier("search.engineBadge")

                    Text(badge.caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                        .accessibilityIdentifier("search.engineCaption")
                }

                if engine == .mlxLocal, session.validatedMLXModel == nil {
                    Button("Choisir un modèle MLX") {
                        showingMLXSelection = true
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("search.chooseMLXModel")
                }

                // Même rôle que « Choisir un modèle MLX » pour le moteur cloud
                // (l'action sans laquelle rien ne peut répondre), donc même
                // place et même style. Mène aux Réglages de cette fenêtre, où
                // vivent « Gérer les clés API » et « Fournisseur et modèle ».
                if session.setupRequirement == .cloudProvider {
                    Button("Configurer une clé API", action: onOpenSettings)
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("search.configureAPIKey")
                }

                if engine == .mlxLocal, let validatedMLXModel = session.validatedMLXModel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Modèle actif : \(validatedMLXModel.displayName)")
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        Button("Changer de modèle MLX") {
                            showingMLXSelection = true
                        }
                        .buttonStyle(.glass)
                    }
                }

                Button("Changer de moteur", action: onChangeEngine)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("search.changeEngine")
            }
        }
        // Calé à gauche dans la colonne, comme `TrivaHomeReferenceView` et le chat juste en dessous.
        // Sans `alignment`, le bloc épousait son contenu et se centrait : le badge flottait à 76 pt du
        // bord sur iPhone au lieu de 20, et sautait de place dès qu'une carte « Modèle actif » remplissait
        // la colonne (constaté sur les captures iPhone, iPad et Mac, mission Q2).
        .frame(maxWidth: contentMaxWidth ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

#Preview("Recherche — Apple Intelligence") {
    EngineStatusView(
        onChangeEngine: {},
        onOpenSettings: {},
        session: SearchSession(engine: .appleIntelligence, stores: .preview(engine: .appleIntelligence))
    )
}

#Preview("Recherche — MLX local") {
    EngineStatusView(
        onChangeEngine: {},
        onOpenSettings: {},
        session: SearchSession(engine: .mlxLocal, stores: .preview(engine: .mlxLocal))
    )
}

#Preview("Recherche — Cloud BYOK") {
    EngineStatusView(
        onChangeEngine: {},
        onOpenSettings: {},
        session: SearchSession(engine: .cloudBYOK, stores: .preview(engine: .cloudBYOK))
    )
}
