//
//  TrivaApp.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import SwiftUI
import SwiftData

/// Tous les stores qui ne doivent exister qu'en UN exemplaire pour toute
/// l'app, créés une fois par `TrivaApp` puis transmis tels quels : à chaque
/// fenêtre (`TrivaRootView`), à la fenêtre Réglages macOS et, via la coquille,
/// à `SearchSession`.
///
/// ## Pourquoi une seule instance de chacun
/// `WindowGroup` instancie une `TrivaRootView` distincte par fenêtre — sur Mac
/// (⌘N) comme sur iPad (Split View, Stage Manager, plusieurs fenêtres de l'app
/// côte à côte). Un store créé PAR fenêtre ne voit jamais ce qu'écrit celui
/// d'une autre, parce que ces stores ne lisent `UserDefaults` qu'à leur
/// construction :
/// - moteur IA (`AIEngineSettingsStore`) : c'était le bug 10 — une fenêtre
///   affichait le badge d'un moteur pendant qu'une autre en avait choisi un
///   autre (règle n° 1 de DESIGN.md : le badge dit la vérité) ;
/// - sélections MLX / cloud et fournisseurs personnalisés : un modèle changé ou
///   un fournisseur supprimé dans une fenêtre restait actif dans l'autre ;
/// - historique et favoris : `revision` est un compteur PAR INSTANCE — deux
///   instances, et la Bibliothèque ne voit plus les écritures du chat ;
/// - instances SearXNG : une liste modifiée dans les Réglages n'atteindrait
///   jamais la recherche des autres fenêtres ;
/// - fiabilité et annuaire SearXNG (R3) : une mémoire par fenêtre ferait
///   réapprendre à chacune quelles instances sont mortes, en payant leurs
///   délais une fois de plus.
///
/// Un `struct` de références immuables plutôt qu'une classe observable : rien
/// ici ne change après la construction. Ce sont les stores qui changent, et ils
/// sont observables eux-mêmes — il n'y a rien à observer à ce niveau.
///
/// Pas d'initialiseur memberwise, volontairement : le seul moyen d'en obtenir
/// un est `init(userDefaults:container:…)`, qui garantit les deux couplages
/// décrits ci-dessous. Un appelant ne peut donc pas assembler par mégarde un
/// `CustomProviderStore` branché sur une autre sélection cloud que celle de
/// l'app.
struct TrivaSharedStores {
    let engineSettings: AIEngineSettingsStore
    let mlxSelection: MLXModelSelectionStore
    let cloudSelection: CloudProviderSelectionStore
    let customProviders: CustomProviderStore
    let searchInstances: CustomInstanceStore
    /// Mémoire de fiabilité des instances SearXNG (R3) : ce que chaque recherche
    /// a appris de chaque instance (latence, motif du dernier échec, mise de
    /// côté). La lisent et la nourrissent tous les `FailoverManager` de l'app
    /// (une session par fenêtre, Découvrir, l'entretien de fond) ; celle de
    /// `live()` est persistée, ce savoir survit donc au redémarrage.
    let searchReliability: InstanceReliabilityStore
    /// Instances vérifiées de l'annuaire searx.space (R3), rafraîchies en
    /// tâche de fond au plus une fois par jour (`SearXNGMaintenance`). Elles
    /// complètent la liste du bundle, ne la remplacent jamais : voir
    /// `searXNGInstances`.
    let searchDirectory: SearXNGDirectoryStore
    /// Articles de la dernière visite de Découvrir, partagés par les fenêtres.
    let discoverCache: any DiscoverContentCaching
    let chatHistory: ChatHistoryStore
    let favorites: FavoritesStore
    /// Trousseau des clés BYOK : le même pour les fournisseurs personnalisés
    /// (suppression de clé) et pour la résolution du provider cloud à l'envoi
    /// (`SearchSession`) — les tests y substituent un faux trousseau d'un bout
    /// à l'autre.
    let keyStore: any APIKeyStoring
    /// `true` quand la base SwiftData a dû se rabattre sur un stockage en
    /// mémoire (`TrivaModelContainer.isUsingVolatileFallback`) : la
    /// Bibliothèque et les Favoris doivent le dire, plutôt que d'afficher une
    /// liste vide qui ferait croire à un historique vide.
    let isHistoryStorageVolatile: Bool

    /// Assemble les stores sur UNE source de persistance.
    ///
    /// - `customProviders` reçoit le MÊME `cloudSelection` que celui exposé ici,
    ///   et non son `CloudProviderSelectionStore()` par défaut : c'est ce qui
    ///   permet à `CustomProviderStore.remove(id:)` d'effacer la sélection
    ///   active vue par toutes les fenêtres, pas seulement la sienne.
    /// - historique et favoris travaillent sur le MÊME `container` : deux
    ///   conteneurs sur le même fichier seraient deux stores concurrents qui
    ///   s'ignorent (voir `TrivaModelContainer`), et un favori ne pourrait plus
    ///   retrouver la conversation qu'il marque.
    ///
    /// Un seul `userDefaults` pour tous les réglages : chaque store y a sa
    /// propre clé, sans recouvrement possible. Les tests passent un domaine
    /// jetable, un conteneur en mémoire et un faux trousseau ; l'app passe par
    /// `live()`.
    ///
    /// - `discoverCache` : aucun par défaut, seul `live()` écrit sur le disque.
    /// - `searchReliability` et `searchDirectory` sont EN MÉMOIRE par défaut :
    ///   tests et aperçus ne lisent ni n'écrivent les mesures réelles de
    ///   l'appareil (une mesure persistée ferait dépendre un test de la machine
    ///   qui le lance). Seul `live()` passe les stores persistés `.shared` — et
    ///   surtout pas un second store construit sur `UserDefaults.standard` : deux
    ///   stores sur la même clé, chacun avec sa copie en mémoire, écraseraient
    ///   mutuellement leurs écritures.
    init(
        userDefaults: UserDefaults,
        container: ModelContainer,
        isHistoryStorageVolatile: Bool,
        searchInstances: CustomInstanceStore,
        keyStore: any APIKeyStoring,
        searchReliability: InstanceReliabilityStore = InstanceReliabilityStore(),
        searchDirectory: SearXNGDirectoryStore = SearXNGDirectoryStore(),
        discoverCache: any DiscoverContentCaching = DiscoverNoCache()
    ) {
        let cloudSelection = CloudProviderSelectionStore(userDefaults: userDefaults)
        self.engineSettings = AIEngineSettingsStore(userDefaults: userDefaults)
        self.mlxSelection = MLXModelSelectionStore(userDefaults: userDefaults)
        self.cloudSelection = cloudSelection
        self.customProviders = CustomProviderStore(
            userDefaults: userDefaults,
            selectionStore: cloudSelection,
            keyStore: keyStore
        )
        self.searchInstances = searchInstances
        self.searchReliability = searchReliability
        self.searchDirectory = searchDirectory
        self.discoverCache = discoverCache
        self.chatHistory = ChatHistoryStore(container: container)
        self.favorites = FavoritesStore(container: container)
        self.keyStore = keyStore
        self.isHistoryStorageVolatile = isHistoryStorageVolatile
    }

    /// Les stores réels : `UserDefaults.standard`, base SwiftData sur disque
    /// (`TrivaModelContainer.shared`, avec son repli en mémoire si le fichier
    /// est illisible), trousseau réel, liste SearXNG du bundle plus les
    /// modifications de l'utilisateur, mémoire de fiabilité et annuaire SearXNG
    /// persistés (les instances `.shared`, uniques dans l'app).
    ///
    /// La base est donc ouverte dès le lancement, et non plus à la première
    /// visite de la Bibliothèque : quelques millisecondes, et le chat en a de
    /// toute façon besoin dès le premier envoi pour sauvegarder la conversation.
    static func live() -> TrivaSharedStores {
        TrivaSharedStores(
            userDefaults: .standard,
            container: TrivaModelContainer.shared,
            isHistoryStorageVolatile: TrivaModelContainer.isUsingVolatileFallback,
            searchInstances: CustomInstanceStore(),
            keyStore: KeychainAPIKeyStore(),
            searchReliability: .shared,
            searchDirectory: .shared,
            discoverCache: DiscoverDiskCache(language: .device())
        )
    }

    /// Domaine `UserDefaults` réservé aux aperçus SwiftUI.
    private static let previewSuiteName = "TrivaPreviews"

    /// Stores des aperçus SwiftUI : ni les vrais réglages ni la vraie base de
    /// l'utilisateur. Domaine `UserDefaults` dédié et base SwiftData en
    /// mémoire (même règle que les aperçus de la Bibliothèque : les valeurs par
    /// défaut des écrans ouvriraient la base sur disque). La liste SearXNG du
    /// bundle reste lue telle quelle — ressource en lecture seule, c'est elle
    /// qui donne un écran Réglages réaliste.
    ///
    /// `engine` est toujours écrit (même `nil`) : le domaine des aperçus
    /// persiste d'un rafraîchissement à l'autre, et un aperçu doit montrer le
    /// même état à chaque fois.
    static func preview(engine: AIEngineOption? = nil) -> TrivaSharedStores {
        guard let userDefaults = UserDefaults(suiteName: previewSuiteName) else {
            // `nil` n'arrive que pour un nom de domaine réservé (identifiant
            // du bundle, domaine global) : une erreur de développement, jamais
            // une donnée utilisateur.
            preconditionFailure("Domaine UserDefaults des aperçus refusé : \(previewSuiteName)")
        }
        let container: ModelContainer
        do {
            container = try TrivaModelContainer.makeInMemory()
        } catch {
            // Même politique que `TrivaModelContainer` : un conteneur en
            // mémoire qui échoue trahit un schéma invalide, donc un bug de
            // développement.
            preconditionFailure("Aperçu impossible, conteneur en mémoire refusé : \(error)")
        }
        let stores = TrivaSharedStores(
            userDefaults: userDefaults,
            container: container,
            isHistoryStorageVolatile: false,
            // Annuaire en mémoire, comme `searchDirectory` ci-dessous : un aperçu
            // ne lit jamais l'annuaire réel de l'appareil.
            searchInstances: CustomInstanceStore(userDefaults: userDefaults, directory: SearXNGDirectoryStore()),
            keyStore: KeychainAPIKeyStore()
        )
        stores.engineSettings.selectedOption = engine
        return stores
    }
}

// MARK: - Recherche SearXNG fiabilisée (R3)

extension TrivaSharedStores {
    /// Liste d'instances SearXNG réellement essayée par la Recherche, Découvrir
    /// et l'entretien de fond, dans l'ordre de priorité (que `FailoverManager`
    /// affine ensuite par fiabilité mesurée) :
    /// 1. les instances ajoutées par l'utilisateur (Réglages > Recherche > Avancé) ;
    /// 2. la liste du bundle, dans l'ordre du fichier — elle peut commencer par
    ///    une instance personnelle, qui doit rester devant toute instance
    ///    publique ;
    /// 3. les instances vérifiées de l'annuaire searx.space qui n'y figurent pas
    ///    déjà.
    ///
    /// C'est `PublicInstanceList.loadMerged()` (bundle puis annuaire) avec les
    /// personnalisations de l'utilisateur par-dessus, sans relire le fichier du
    /// bundle à chaque recherche (`CustomInstanceStore` l'a lu au lancement).
    /// Relue à chaque appel : un rafraîchissement de l'annuaire terminé en tâche
    /// de fond est pris en compte à la recherche suivante, sans relancer l'app.
    var searXNGInstances: [URL] {
        Self.searXNGInstances(
            bundled: searchInstances.defaultInstances,
            directory: searchDirectory.refreshedInstances,
            overrides: searchInstances.overrides
        )
    }

    /// Règle de composition de `searXNGInstances`, sans store : partagée avec
    /// l'écran des instances (`CustomInstanceStore.automaticInstances`).
    ///
    /// Les masquages de l'utilisateur valent AUSSI pour l'annuaire : une
    /// instance retirée de la liste ne revient pas par lui. Et si l'utilisateur
    /// a masqué TOUTES les instances par défaut pour ne garder que les siennes,
    /// l'annuaire n'est pas ajouté du tout : il a dit ne vouloir aucune instance
    /// publique choisie pour lui, l'annuaire ne doit pas en réintroduire en
    /// douce (choix de confidentialité soumis à Ben, rapport RI1a).
    ///
    /// Liste du bundle illisible (`bundled` vide, défaut d'empaquetage déjà
    /// signalé par les Réglages) : l'annuaire est ajouté quand même, la
    /// recherche fonctionne plutôt que d'échouer faute d'instance.
    nonisolated static func searXNGInstances(
        bundled: [URL],
        directory: [URL],
        overrides: SearXNGInstanceOverrides
    ) -> [URL] {
        let extras = overrides.hidesEveryDefault(of: bundled) ? [] : directory
        return overrides.effectiveInstances(defaults: PublicInstanceList.merging(bundled, with: extras))
    }

    /// `FailoverManager` neuf sur `instances`, branché sur la mémoire de
    /// fiabilité de l'app. Point de construction des managers de l'app : un
    /// manager construit sans elle repartirait d'une mémoire vide, en mémoire
    /// seulement, et paierait à nouveau le délai de chaque instance morte.
    func makeFailoverManager(instances: [URL]) -> FailoverManager {
        FailoverManager(instances: instances, reliability: searchReliability)
    }

    /// Entretien de fond (`SearXNGMaintenance`) branché sur CES stores : le
    /// rafraîchisseur écrit dans `searchDirectory` (et non dans son défaut
    /// `.shared` : aperçus et tests ne touchent jamais l'annuaire réel), la
    /// re-sonde lit et nourrit `searchReliability`.
    ///
    /// Le rafraîchisseur ne reçoit PAS `searchReliability` (son paramètre
    /// `reliability` reste `nil`), volontairement : sinon, chaque instance de
    /// l'annuaire validée par la sonde serait enregistrée comme ayant répondu,
    /// donc « bonne », et passerait devant une instance personnelle encore
    /// « neutre » (jamais essayée : premier lancement, mesure effacée). Une
    /// instance qui répond étant gardée en cache par le `FailoverManager`,
    /// l'instance personnelle ne serait alors plus jamais essayée tant que
    /// l'instance publique répond. Sans ce lien, les instances de l'annuaire
    /// entrent « neutres », APRÈS la liste du bundle, et seule une vraie
    /// recherche (ou la re-sonde) les fait monter.
    ///
    /// - Parameters: `requester` et `prober` : réseau réel par défaut, faux
    ///   dans les tests (aucun appel réseau depuis un test).
    func makeSearXNGMaintenance(
        requester: any HTTPDataRequesting = URLSessionDataRequester(),
        prober: any InstanceProbing = SearXNGInstanceHealthProbe()
    ) -> SearXNGMaintenance {
        SearXNGMaintenance(
            refresher: SearXNGDirectoryRefresher(requester: requester, prober: prober, store: searchDirectory),
            prober: prober,
            makeFailoverManager: { [self] in makeFailoverManager(instances: searXNGInstances) }
        )
    }
}

/// Détecte que l'app sert d'hôte aux tests unitaires : xcodebuild y place
/// `XCTestConfigurationFilePath`, absente d'un lancement normal.
nonisolated enum TrivaTestHost {
    static func isHostingUnitTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}

@main
struct TrivaApp: App {
    /// Créés une seule fois pour toute la durée de vie de l'app et partagés par
    /// toutes les fenêtres (voir `TrivaSharedStores`). `@State` : SwiftUI en
    /// garde la propriété pour toute la vie de l'app.
    @State private var stores: TrivaSharedStores
    /// Entretien de fond de la liste SearXNG (annuaire, re-sonde), UN pour
    /// toute l'app : c'est lui qui garantit un seul passage à la fois, quel
    /// que soit le nombre de fenêtres.
    @State private var searXNGMaintenance: SearXNGMaintenance
    /// Lue au niveau de l'`App`, la phase est celle de l'ENSEMBLE des scènes :
    /// `.active` dès qu'une fenêtre de l'app est au premier plan.
    @Environment(\.scenePhase) private var scenePhase

    /// Initialiseur explicite plutôt que deux valeurs par défaut : l'entretien
    /// doit être branché sur les MÊMES stores que les fenêtres, et une valeur
    /// par défaut de propriété ne peut pas en lire une autre.
    init() {
        let stores = TrivaSharedStores.live()
        _stores = State(initialValue: stores)
        _searXNGMaintenance = State(initialValue: stores.makeSearXNGMaintenance())
    }

    var body: some Scene {
        // `TrivaRootView` est la racine depuis la coquille de navigation V1 :
        // elle arbitre entre l'écran de choix du moteur IA et les 5
        // destinations. Voir le commentaire de tête de `ContentView.swift`, qui
        // garde son nom mais n'héberge plus que la destination "Recherche".
        WindowGroup {
            TrivaRootView(stores: stores)
        }
        // SearXNG fiabilisé (R3) : à chaque passage au premier plan, lancement
        // compris (`initial: true`), rafraîchit l'annuaire s'il est dû puis
        // re-sonde les instances écartées dont le délai a expiré — en tâche de
        // fond, jamais bloquant (voir `SearXNGMaintenance`). Jamais sous les
        // tests unitaires, qui tournent DANS l'app (hôte de test) : ce serait du
        // réseau réel et des préférences réelles à chaque lancement de suite.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, !TrivaTestHost.isHostingUnitTests() else { return }
            searXNGMaintenance.sceneDidBecomeActive()
        }

        // Fenêtre Réglages macOS (⌘,) — DÉCISION I4a : OUI.
        // 1. Convention de la plateforme : sur Mac, « Triva > Réglages… » et ⌘,
        //    sont l'endroit où l'on cherche les réglages ; une app Mac sans eux
        //    paraît portée à la va-vite. La scène `Settings` fournit l'item de
        //    menu et le raccourci sans rien coder de plus (outil Apple natif).
        // 2. Sans risque UNIQUEMENT parce que le moteur IA est désormais un
        //    store d'app (bug 10) : cette fenêtre n'appartient à aucune fenêtre
        //    principale. Avec un `AIEngineSettingsStore` par fenêtre, elle
        //    n'aurait pas su quelle fenêtre modifier, ni quel moteur afficher.
        // 3. La destination « Réglages » de la sidebar est CONSERVÉE : l'iPad
        //    (sans scène `Settings`) et le Mac gardent ainsi une seule et même
        //    navigation, et les deux points d'entrée affichent la même
        //    `SettingsView` sur les mêmes instances — ils ne peuvent pas se
        //    contredire. La retirer de la sidebar Mac reste possible plus tard :
        //    c'est un choix produit, signalé à Ben dans le rapport I4a.
        // `#if` et non `#available` : `Settings` est une scène macOS
        // uniquement, sur toutes les versions.
        #if os(macOS)
        Settings {
            TrivaSettingsWindow(stores: stores)
        }
        #endif
    }
}

#if os(macOS)
/// Contenu de la fenêtre Réglages macOS. Une vue dédiée plutôt qu'un appel à
/// `SettingsView` écrit directement dans la scène : c'est dans le `body` d'une
/// vue que la lecture de `engineSettings.selectedOption` est observée à coup
/// sûr. La fenêtre suit ainsi un changement de moteur fait depuis n'importe
/// quelle fenêtre principale.
///
/// Changer de moteur ici écrit dans le store PARTAGÉ : chaque fenêtre
/// principale reconstruit alors sa coquille pour le nouveau moteur
/// (`.id(selected)` dans `TrivaRootView`), badge et envoi compris.
private struct TrivaSettingsWindow: View {
    let stores: TrivaSharedStores

    var body: some View {
        SettingsView(
            selectedEngine: stores.engineSettings.selectedOption,
            onSelectEngine: { stores.engineSettings.selectedOption = $0 },
            mlxSelectionStore: stores.mlxSelection,
            cloudSelectionStore: stores.cloudSelection,
            customProviderStore: stores.customProviders,
            instanceStore: stores.searchInstances
        )
        // Taille minimale : en dessous, les écrans poussés depuis les Réglages
        // (liste d'instances SearXNG, modèles MLX) deviennent illisibles.
        .frame(minWidth: 520, minHeight: 560)
    }
}
#endif
