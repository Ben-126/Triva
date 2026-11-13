//
//  TrivaRootView.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import SwiftUI

/// Les espaces de premier niveau de l'app (V1). L'ordre des `allCases` est
/// celui de la barre d'onglets et de la sidebar : "Recherche" d'abord parce
/// que c'est la raison d'être de l'app, "Réglages" en dernier parce que c'est
/// la seule destination qu'on visite ponctuellement.
///
/// Type volontairement pur (aucune dépendance SwiftUI) : c'est ce qui permet
/// de tester l'ordre et les libellés sans lancer d'UI.
enum TrivaRootDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case search
    case discover
    case library
    case favorites
    case settings

    var id: String { rawValue }

    /// Libellés courts en français (DESIGN.md : phrases courtes, zéro
    /// remplissage). "Découvrir" plutôt que "Discover" (le nom de la
    /// fonctionnalité dans la version web d'origine) : c'est un libellé visible par l'utilisateur,
    /// il suit donc la règle de langue du reste de l'app.
    var title: String {
        switch self {
        case .search: "Recherche"
        case .discover: "Découvrir"
        case .library: "Bibliothèque"
        case .favorites: "Favoris"
        case .settings: "Réglages"
        }
    }

    /// SF Symbols sobres et littéraux (DESIGN.md : jamais d'emoji, et pas de
    /// symbole "magique" type `sparkles` qui ferait immédiatement "app IA
    /// générée"). Chaque symbole décrit le contenu réel de la destination, pas
    /// une ambiance.
    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .discover: "newspaper"
        case .library: "clock"
        case .favorites: "star"
        case .settings: "gearshape"
        }
    }
}

/// Les deux présentations possibles de la coquille de navigation racine.
///
/// Extrait de la vue pour rester testable : c'est la seule règle d'adaptation
/// de l'app, et elle doit être vérifiable sans lancer d'interface.
enum TrivaRootNavigationStyle: Sendable, Equatable {
    /// Barre d'onglets en bas — iPhone, et iPad/Mac en fenêtre étroite.
    case tabs
    /// `NavigationSplitView` avec sidebar — iPad en `regular` et macOS.
    case sidebar

    /// Décision validée avec Ben : onglets uniquement en `compact`, sidebar
    /// partout ailleurs. Le cas `nil` (aucune classe de taille fournie par
    /// l'environnement, ce qui arrive sur macOS) est traité comme `regular` :
    /// une fenêtre Mac n'est jamais une barre d'onglets iPhone.
    static func preferred(for horizontalSizeClass: UserInterfaceSizeClass?) -> TrivaRootNavigationStyle {
        horizontalSizeClass == .compact ? .tabs : .sidebar
    }
}

/// Racine réelle de l'app : ce qu'une fenêtre affiche.
///
/// Deux états seulement, volontairement exclusifs :
/// 1. aucun moteur IA choisi -> `AIEngineSelectionView` en plein écran, sans
///    onglets ni sidebar. Choisir son moteur est un préalable, pas une
///    destination : montrer "Découvrir" ou "Favoris" avant ce choix
///    proposerait des espaces qui ne peuvent rien produire.
/// 2. moteur choisi -> `TrivaRootShell`, la coquille à 5 destinations.
///
/// « Changer de moteur » (depuis la Recherche) présente l'écran de choix PAR-
/// DESSUS la coquille — plein écran sur iPhone et iPad, feuille sur Mac — au
/// lieu de la remplacer. Remplacée, la coquille était démontée : « Annuler »
/// la reconstruisait à neuf, conversation en cours, onglet et contenu de
/// Découvrir perdus pour un choix abandonné. Seul un moteur DIFFÉRENT
/// confirmé la reconstruit désormais (`.id(selected)`).
///
/// Ne crée aucun store : `TrivaApp` les crée une seule fois
/// (`TrivaSharedStores`) et chaque fenêtre reçoit les mêmes instances. Le
/// moteur IA en fait partie depuis le bug 10 : quand il avait encore un
/// `AIEngineSettingsStore` par fenêtre (`@State` ici), deux fenêtres pouvaient
/// afficher et utiliser deux moteurs différents, et la fenêtre Réglages macOS
/// n'aurait pas su laquelle modifier.
struct TrivaRootView: View {
    /// Stores uniques de l'app, jamais recréés par une fenêtre.
    let stores: TrivaSharedStores

    /// « Changer de moteur » demandé dans CETTE fenêtre. État local
    /// volontairement, et non `selectedOption = nil` : le store est partagé,
    /// le vider ferait basculer TOUTES les fenêtres sur l'écran de choix,
    /// conversations comprises (et, avant la coquille V1, quand l'envoi
    /// relisait un store neuf, faisait échouer celui des autres fenêtres avec
    /// « Aucun moteur IA sélectionné »). Ici, les autres fenêtres gardent le
    /// moteur en vigueur tant qu'un nouveau n'est pas confirmé, puis basculent
    /// toutes ensemble.
    @State private var isChoosingEngine = false

    /// Moteur choisi à la première étape du premier lancement, pas encore enregistré (voir
    /// `firstLaunch`). Local à la fenêtre : tant que l'étape de clé n'est pas passée, rien n'est
    /// écrit dans le store partagé.
    @State private var pendingEngine: AIEngineOption?

    /// Pas de valeur par défaut pour `stores` : seul `TrivaApp` crée les
    /// instances de l'app, les aperçus passent `TrivaSharedStores.preview()`.
    init(stores: TrivaSharedStores) {
        self.stores = stores
    }

    var body: some View {
        root
            // Posé AUTOUR de la coquille, hors de son `.id(selected)` : la
            // présentation survit à la reconstruction qu'un nouveau moteur
            // déclenche, au lieu d'être arrachée avec l'ancienne identité.
            .engineChangePresentation(isPresented: $isChoosingEngine) {
                engineChangeScreen
            }
            // Copie des clés de l'ancien trousseau Mac vers le trousseau protégé, hors du fil
            // principal et une seule fois par lancement (`KeychainMigration`).
            .task { await KeychainMigration.runOnce() }
    }

    @ViewBuilder
    private var root: some View {
        if let selected = stores.engineSettings.selectedOption {
            TrivaRootShell(
                engine: selected,
                onChangeEngine: { isChoosingEngine = true },
                stores: stores
            )
            // Identité liée au moteur : un changement de moteur — depuis
            // l'écran de choix, les Réglages de n'importe quelle fenêtre ou la
            // fenêtre Réglages macOS — reconstruit tout le shell, donc une
            // `SearchSession` neuve liée au nouveau moteur. INDISPENSABLE au
            // bug 10 : la session fige son moteur à la construction (badge et
            // envoi en dérivent), seule une nouvelle identité peut la remplacer.
            // Démonter l'ancien `ChatView` annule aussi une génération encore en
            // vol, qui ne continue donc pas sous le badge du nouveau moteur.
            // Conséquence validée par Ben le 2026-10-04 : la conversation
            // repart à zéro. Nouveau depuis le store partagé (signalé dans le
            // rapport I4a) : cela vaut pour TOUTES les fenêtres ouvertes, le
            // moteur étant désormais commun à l'app.
            .id(selected)
        } else {
            firstLaunch
        }
    }

    /// Premier lancement, en deux étapes sans « Annuler » (il n'y a rien vers quoi revenir) :
    /// choix du moteur, puis proposition facultative d'une clé de recherche. Le moteur choisi n'est
    /// ÉCRIT dans le store qu'à la fin de la seconde étape : l'écrire à « Continuer » ferait
    /// basculer tout de suite sur la coquille et couperait l'étape en deux.
    @ViewBuilder
    private var firstLaunch: some View {
        if let engine = pendingEngine {
            onboardingStack {
                SearchKeyOnboardingView {
                    stores.engineSettings.selectedOption = engine
                }
            }
        } else {
            onboardingStack {
                AIEngineSelectionView(currentSelection: nil, onCancel: nil) { chosen in
                    pendingEngine = chosen
                }
            }
        }
    }

    /// Pile de navigation sans titre autour des écrans plein écran de l'onboarding, sur iPhone et
    /// iPad : elle réserve la place des commandes de fenêtre de l'iPad en fenêtre, qui touchaient
    /// sinon le logo (finding Q3 n°27, HIG windows.md : « Make sure window controls don't overlap
    /// toolbar items »). Inutile sur Mac, dont la fenêtre a sa propre barre de titre.
    @ViewBuilder
    private func onboardingStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(iOS)
        NavigationStack {
            content()
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        content()
        #endif
    }

    /// Écran de choix d'un changement de moteur. Reconfirmer le moteur en
    /// vigueur ne touche pas au store : rien n'est reconstruit, la
    /// conversation continue (même règle que `SettingsView.applyPendingEngine`).
    private var engineChangeScreen: some View {
        NavigationStack {
            AIEngineSelectionView(
                currentSelection: stores.engineSettings.selectedOption,
                onCancel: { isChoosingEngine = false }
            ) { chosen in
                isChoosingEngine = false
                guard chosen != stores.engineSettings.selectedOption else { return }
                stores.engineSettings.selectedOption = chosen
            }
            .navigationTitle("Changer de moteur")
            .macSheetTitleBar("Changer de moteur")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

private extension View {
    /// Plein écran sur iPhone et iPad, comme l'écran de choix du premier
    /// lancement ; feuille sur Mac, qui n'a pas de présentation plein écran.
    /// Taille plancher sur Mac : une feuille y prend sinon la taille idéale de
    /// son contenu, minuscule autour d'une `ScrollView` (même valeur que les
    /// feuilles des Réglages).
    @ViewBuilder
    func engineChangePresentation<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(macOS)
        sheet(isPresented: isPresented) {
            content()
                .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        }
        #else
        fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }
}

/// Coquille à 5 destinations, une fois le moteur IA choisi.
///
/// C'est ici que vit le `TrivaRootCoordinator` de la fenêtre, et avec lui la
/// `SearchSession` (conversation en cours, provider MLX préparé,
/// `FailoverManager`), le modèle de Découvrir et la destination affichée : au-
/// dessus du contenu de la destination, qui lui est démonté à chaque
/// changement d'onglet en présentation `sidebar`. Voir le commentaire de tête
/// de `SearchSession` et celui du coordinateur.
///
/// Le moteur n'est PAS stocké ici en plus de la session : toutes les
/// destinations lisent `session.engine`, l'unique valeur dont dérivent le badge
/// et l'envoi (bug 10). Une seconde copie pourrait un jour diverger de la
/// première.
private struct TrivaRootShell: View {
    let onChangeEngine: () -> Void
    let stores: TrivaSharedStores

    /// Un seul état pour toute la coquille : destination, session et
    /// Découvrir changent ENSEMBLE lors d'une action entre espaces (ouvrir
    /// une conversation, « Chercher dans Triva »), ils appartiennent donc au
    /// même objet. La destination n'y est pas optionnelle : il y a toujours
    /// quelque chose à l'écran, la sidebar ne doit jamais se retrouver sans
    /// détail (voir `sidebarSelection` pour le pont vers la sélection
    /// optionnelle qu'attend `List`). Elle est AU-DESSUS du choix onglets /
    /// sidebar : une bascule de classe de taille (Split View, Stage Manager,
    /// iPhone Duo déplié) garde la destination, la conversation et le
    /// brouillon.
    @State private var coordinator: TrivaRootCoordinator

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// `engine` ne sert qu'à construire le coordinateur (et sa session).
    /// `State(initialValue:)` ne retient que le PREMIER pour une identité
    /// donnée — les suivants, construits à chaque réévaluation du parent, ne
    /// coûtent rien (init sans effet de bord) : c'est le `.id(selected)` posé
    /// par `TrivaRootView` qui garantit qu'un autre moteur produit une autre
    /// identité, donc une autre session.
    init(engine: AIEngineOption, onChangeEngine: @escaping () -> Void, stores: TrivaSharedStores) {
        self.onChangeEngine = onChangeEngine
        self.stores = stores
        _coordinator = State(initialValue: TrivaRootCoordinator(engine: engine, stores: stores))
    }

    var body: some View {
        Group {
            switch TrivaRootNavigationStyle.preferred(for: horizontalSizeClass) {
            case .tabs:
                tabs
            case .sidebar:
                splitView
            }
        }
        // Posé AUTOUR du choix onglets / sidebar, pas dans une seule branche :
        // il doit continuer de jouer quand la classe de taille bascule. Une
        // conversation supprimée dans une AUTRE fenêtre (ou par « Tout
        // effacer ») vide ici le fil qui l'affichait.
        .onChange(of: stores.chatHistory.revision) {
            coordinator.historyDidChange()
        }
    }

    /// iPhone (et fenêtre étroite) : barre d'onglets. Les 5 destinations
    /// tiennent exactement dans les 5 emplacements d'une `TabView` iOS, donc
    /// "Réglages" y est un onglet plutôt qu'un bouton de barre d'outils : un
    /// bouton devrait être dupliqué sur chacun des 4 autres écrans (ou n'être
    /// accessible que depuis un seul, ce qui le rendrait introuvable), et le
    /// même modèle se traduit tel quel en item de sidebar sur iPad/Mac.
    private var tabs: some View {
        TabView(selection: $coordinator.selection) {
            ForEach(TrivaRootDestination.allCases) { destination in
                Tab(value: destination) {
                    content(for: destination)
                } label: {
                    Label(destination.title, systemImage: destination.systemImage)
                }
                // Identifiant stable : sur iPhone Duo plié, les onglets passent sur le côté SANS
                // libellé, et les tests UI ne peuvent plus les retrouver par leur titre.
                .accessibilityIdentifier("tab.\(destination.rawValue)")
            }
        }
    }

    /// iPad en `regular` et macOS : sidebar + détail.
    private var splitView: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(TrivaRootDestination.allCases) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
            .navigationTitle("Triva")
        } detail: {
            // Chaque espace a sa pile, mais toutes partagent cette colonne : leurs chemins doivent
            // être du même type, `NavigationPath`. Quitter un écran poussé compare l'ancien chemin au
            // nouveau, et deux types différents font planter SwiftUI sur un `try!`
            // (`AnyNavigationPath.Error.comparisonTypeMismatch`, constaté sur iPad, QA Q1 ; un
            // `.id` sur ce détail n'y change rien).
            content(for: coordinator.selection)
        }
    }

    /// `List` travaille avec une sélection optionnelle (elle peut être vidée,
    /// p. ex. en cliquant dans le vide de la sidebar sur macOS), alors que la
    /// coquille affiche toujours une destination. Ce pont ignore donc la
    /// désélection au lieu de laisser un détail vide apparaître.
    private var sidebarSelection: Binding<TrivaRootDestination?> {
        Binding(
            get: { self.coordinator.selection },
            set: { newValue in
                guard let newValue else { return }
                self.coordinator.selection = newValue
            }
        )
    }

    /// Les écrans reçoivent les INSTANCES UNIQUES de l'app (jamais leurs
    /// valeurs par défaut, qui créeraient un store de plus à chaque
    /// réévaluation de ce `body`), et leurs actions vers un autre espace
    /// passent toutes par le coordinateur (voir son commentaire de tête).
    @ViewBuilder
    private func content(for destination: TrivaRootDestination) -> some View {
        switch destination {
        case .search:
            // Pile de navigation propre à la Recherche, comme chaque autre
            // espace a la sienne (Découvrir, Réglages…) : sans elle, la barre
            // d'outils du chat (« Nouvelle conversation ») resterait invisible
            // dans la barre d'onglets iPhone, qui n'a pas de barre de
            // navigation. Titre en ligne, comme Découvrir : un grand titre
            // pousserait le badge et le fil vers le bas pour répéter le nom de
            // l'onglet.
            NavigationStack {
                EngineStatusView(
                    onChangeEngine: onChangeEngine,
                    onOpenSettings: { coordinator.showSettings() },
                    session: coordinator.session
                )
                .navigationTitle(destination.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                // Lue par `ChatView`, sous `EngineStatusView`, qui n'a pas à
                // la connaître (voir `EnvironmentValues.openSearchKeySettings`).
                .environment(\.openSearchKeySettings, OpenSearchKeySettingsAction(owner: coordinator) {
                    coordinator.showSearchKeys()
                })
            }
        case .discover:
            // UN modèle par fenêtre (celui du coordinateur), chargé à travers
            // la liste d'instances effective de l'app.
            DiscoverView(model: coordinator.discover, onSearch: { coordinator.search($0) })
        case .library:
            LibraryView(
                store: stores.chatHistory,
                isStorageVolatile: stores.isHistoryStorageVolatile,
                onOpenConversation: { coordinator.openConversation(id: $0) },
                onConversationDeleted: { coordinator.conversationWasDeleted(id: $0) }
            )
        case .favorites:
            FavoritesView(
                store: stores.favorites,
                historyStore: stores.chatHistory,
                isStorageVolatile: stores.isHistoryStorageVolatile,
                onOpenConversation: { coordinator.openConversation(id: $0) }
            )
        case .settings:
            // Moteur de la SESSION (celui du badge de la Recherche) et stores
            // partagés : sans eux, la section « Moteur IA » restait masquée et
            // chaque visite des Réglages travaillait sur des stores jetables,
            // invisibles du reste de l'app. Un nouveau moteur choisi ici est
            // écrit dans le store partagé : `TrivaRootView` reconstruit alors
            // la coquille de chaque fenêtre (voir son `.id(selected)`).
            SettingsView(
                selectedEngine: coordinator.session.engine,
                onSelectEngine: { stores.engineSettings.selectedOption = $0 },
                mlxSelectionStore: stores.mlxSelection,
                cloudSelectionStore: stores.cloudSelection,
                customProviderStore: stores.customProviders,
                instanceStore: stores.searchInstances,
                localDataEraser: stores.makeLocalDataEraser(),
                navigationPath: $coordinator.settingsPath
            )
        }
    }
}

#Preview("Premier lancement") {
    TrivaRootView(stores: .preview())
}

#Preview("Moteur choisi — Apple Intelligence") {
    TrivaRootView(stores: .preview(engine: .appleIntelligence))
}
