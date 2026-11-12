//
//  SettingsView.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import SwiftUI

/// Écran Réglages (1.15) : le moteur IA actif et son changement, les clés API
/// BYOK et le choix fournisseur/modèle, les clés de recherche personnelles et
/// — page à part, ligne « Avancé » (`AdvancedSettingsView`) — la liste
/// d'instances SearXNG, l'espace occupé par les modèles MLX.
///
/// Composants système (`Form`, lignes de navigation) plutôt que du verre :
/// c'est l'écran où l'app doit ressembler au reste du système. Seule
/// exception, le badge moteur IA, identique à celui de l'écran de recherche
/// (DESIGN.md : un badge, c'est du verre teinté) — c'est le même élément, il
/// doit se reconnaître d'un écran à l'autre.
///
/// RÉUTILISATION, SANS RÉÉCRITURE, des écrans de 0.3 et 0.6 :
/// - `BYOKProvidersView` est présentée en FEUILLE et non poussée : elle
///   enveloppe son contenu dans son propre `NavigationStack`, et une pile
///   poussée dans une autre pile donne une double barre et des liens cassés.
///   Sur iPhone/iPad, la poignée signale le geste de fermeture ; sur Mac, où
///   une feuille sans bouton enfermerait l'utilisateur et où une barre
///   d'outils ajoutée de l'extérieur n'atteindrait pas sa pile interne, une
///   barre « Fermer » est ajoutée sous la feuille.
/// - `CloudProviderModelPickerView` est poussée, son view model construit
///   à l'affichage seulement (voir `CloudModelPickerScreen`).
/// - `AIEngineSelectionView` est présentée en feuille, enveloppée d'une pile
///   qui lui ajoute le bouton « Annuler » qu'elle n'a pas (écran conçu pour
///   l'accueil, où l'on ne peut pas renoncer).
///
/// La pile de navigation peut être INJECTÉE (`navigationPath`) : le chat ouvre
/// ainsi directement l'écran des clés de recherche
/// (`TrivaRootCoordinator.showSearchKeys()`). Sans injection, la pile est
/// locale : fenêtre Réglages macOS, qui n'appartient à aucune fenêtre
/// principale, et aperçus.
///
/// Les stores sont INJECTÉS : `TrivaApp` les crée une seule fois et les
/// partage entre fenêtres (macOS). Les valeurs par défaut ne servent qu'aux
/// previews et à l'appel autonome `SettingsView()` de `TrivaRootShell` tant
/// que l'intégration n'est pas faite.
struct SettingsView: View {
    /// Moteur IA réellement actif. `nil` tant que l'intégration ne le fournit
    /// pas : la section « Moteur IA » est alors masquée plutôt que remplie
    /// par une supposition — le badge doit dire la VÉRITÉ (DESIGN.md), et
    /// relire soi-même un `AIEngineSettingsStore` ne suffirait pas : la racine
    /// observe sa propre instance, un changement fait ici ne l'atteindrait pas.
    let selectedEngine: AIEngineOption?
    /// Applique un nouveau moteur (à brancher sur
    /// `AIEngineSettingsStore.selectedOption` de la racine). Appelé seulement
    /// pour un moteur DIFFÉRENT, après la fermeture de la feuille de choix :
    /// la racine reconstruit alors toute la coquille (`.id(selected)` dans
    /// `TrivaRootView`), Réglages compris. `nil` : bouton masqué.
    let onSelectEngine: ((AIEngineOption) -> Void)?
    /// Action « Tout effacer » (voir `LocalDataEraser`). `nil` : section masquée,
    /// comme `onSelectEngine` — aperçus et appel autonome n'ont ni historique
    /// ni favoris à effacer.
    let localDataEraser: LocalDataEraser?
    /// Cloud privé d'Apple ou appareil (mission A4) : instance PARTAGÉE, la Recherche lit la même.
    /// Son choix n'apparaît que si le cloud est proposé (contrainte de Ben du 2026-11-11).
    @Bindable private var appleModel: AppleIntelligenceModelCoordinator
    /// Pour le badge : hors connexion, le moteur Apple répond sur l'appareil (même calcul que l'envoi).
    private let connectivity: ConnectivityMonitor

    @State private var mlxSelectionStore: MLXModelSelectionStore
    @State private var cloudSelectionStore: CloudProviderSelectionStore
    @State private var customProviderStore: CustomProviderStore
    @State private var instanceStore: CustomInstanceStore

    @State private var presentedSheet: SettingsSheet?
    /// Moteur confirmé dans la feuille, appliqué à sa fermeture seulement :
    /// l'appliquer pendant que la feuille est encore à l'écran reconstruirait
    /// la coquille sous elle, en pleine animation.
    @State private var pendingEngine: AIEngineOption?
    /// Pile injectée, `nil` : `localNavigationPath`. Voir le commentaire de tête.
    private let injectedNavigationPath: Binding<NavigationPath>?
    @State private var localNavigationPath = NavigationPath()

    init(
        selectedEngine: AIEngineOption? = nil,
        onSelectEngine: ((AIEngineOption) -> Void)? = nil,
        mlxSelectionStore: MLXModelSelectionStore = MLXModelSelectionStore(),
        cloudSelectionStore: CloudProviderSelectionStore = CloudProviderSelectionStore(),
        customProviderStore: CustomProviderStore = CustomProviderStore(),
        instanceStore: CustomInstanceStore = CustomInstanceStore(),
        localDataEraser: LocalDataEraser? = nil,
        navigationPath: Binding<NavigationPath>? = nil,
        appleModel: AppleIntelligenceModelCoordinator = .shared,
        connectivity: ConnectivityMonitor = .shared
    ) {
        _appleModel = Bindable(appleModel)
        self.connectivity = connectivity
        self.selectedEngine = selectedEngine
        self.onSelectEngine = onSelectEngine
        self.localDataEraser = localDataEraser
        _mlxSelectionStore = State(initialValue: mlxSelectionStore)
        _cloudSelectionStore = State(initialValue: cloudSelectionStore)
        _customProviderStore = State(initialValue: customProviderStore)
        _instanceStore = State(initialValue: instanceStore)
        injectedNavigationPath = navigationPath
    }

    var body: some View {
        NavigationStack(path: injectedNavigationPath ?? $localNavigationPath) {
            Form {
                if let selectedEngine {
                    engineSection(for: selectedEngine)
                }
                apiKeySection
                searchSection
                storageSection
                if let localDataEraser {
                    LocalDataEraseSection(eraser: localDataEraser)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Réglages")
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(for: route)
            }
        }
        // Une seule feuille, pilotée par un enum : deux modificateurs `.sheet`
        // sur la même vue sont une source connue de présentations ignorées.
        .sheet(item: $presentedSheet, onDismiss: { applyPendingEngine() }) { sheet in
            sheetContent(for: sheet)
        }
        .task {
            appleModel.refreshStatus()
        }
    }

    // MARK: Sections

    private func engineSection(for engine: AIEngineOption) -> some View {
        let showsAppleModelChoice = engine == .appleIntelligence && appleModel.isPrivateCloudOffered
        return Section {
            // Composant partagé avec la Recherche (`DesignSystem/EngineBadge.swift`, mission C1).
            EngineBadge(badge: badge(for: engine))
                // Même rendu que sur la Recherche : écart symbole/texte fixe, et filet de ligne qui
                // part du bord (finding Q3 n°39).
                .labelStyle(.inline)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.engineBadge")
            if showsAppleModelChoice {
                AppleIntelligenceModelPicker(selection: $appleModel.effectivePreference)
            }
            if onSelectEngine != nil {
                Button("Changer de moteur") {
                    presentedSheet = .engineSelection
                }
                .accessibilityIdentifier("settings.changeEngine")
            }
        } header: {
            Text("Moteur IA")
        } footer: {
            if showsAppleModelChoice {
                Text(AppleIntelligenceModelCopy.fallbackNote)
            }
        }
    }

    /// Badge du modèle que le prochain envoi utilisera, même calcul que la Recherche.
    private func badge(for engine: AIEngineOption) -> (icon: String, text: String, caption: String) {
        guard engine == .appleIntelligence else { return engine.privacyBadge }
        return engine.privacyBadge(appleRoute: appleModel.displayedRoute(isOffline: connectivity.isOffline))
    }

    /// Toujours visible, quel que soit le moteur actif : on peut préparer sa
    /// clé avant de basculer sur le moteur cloud. Le pied de section dit à
    /// quoi servent ces réglages quand le moteur actif est local.
    private var apiKeySection: some View {
        Section {
            Button("Gérer les clés API") {
                presentedSheet = .apiKeys
            }
            .accessibilityIdentifier("settings.apiKeys")
            NavigationLink("Fournisseur et modèle", value: SettingsRoute.cloudModelPicker)
                .accessibilityIdentifier("settings.cloudModel")
        } header: {
            Text("Clé API personnelle")
        } footer: {
            Text("Ces réglages ne servent qu'avec le moteur «\u{00A0}Clé API personnelle\u{00A0}».")
        }
    }

    /// Tout ce qui décide où partent les recherches, quel que soit le moteur IA.
    ///
    /// Les clés de recherche en premier : c'est le réglage qui change quelque
    /// chose pour la plupart des gens, et l'invitation du chat y mène. « Avancé »
    /// ouvre une page à part (décision de Ben, 2026-11-12), comme Général >
    /// Informations dans les Réglages d'Apple : la liste d'instances ne concerne
    /// que ceux qui hébergent leur propre instance, elle n'a pas à alourdir
    /// cet écran.
    ///
    /// Pas d'état des clés sur la ligne : il faudrait lire le trousseau à
    /// chaque rendu (le piège décrit dans `BYOKProvidersView`). L'écran poussé
    /// le dit, source par source.
    private var searchSection: some View {
        Section("Recherche") {
            NavigationLink("Clés de recherche", value: SettingsRoute.searchKeys)
                .accessibilityIdentifier("settings.searchKeys")
            NavigationLink("Avancé", value: SettingsRoute.advanced)
                .accessibilityIdentifier("settings.advanced")
        }
    }

    private var storageSection: some View {
        Section("Stockage") {
            NavigationLink("Modèles MLX", value: SettingsRoute.mlxStorage)
                .accessibilityIdentifier("settings.mlxStorage")
        }
    }

    // MARK: Navigation

    @ViewBuilder
    private func destination(for route: SettingsRoute) -> some View {
        switch route {
        case .cloudModelPicker:
            CloudModelPickerScreen(
                customPresets: customProviderStore.customPresets,
                selectionStore: cloudSelectionStore,
                onOpenAPIKeys: { presentedSheet = .apiKeys }
            )
        case .mlxStorage:
            MLXStorageView(mlxSelectionStore: mlxSelectionStore, activeEngine: selectedEngine)
        case .advanced:
            AdvancedSettingsView(instanceStore: instanceStore)
        case .searxngInstances:
            SearXNGInstancesView(store: instanceStore)
        case .searchKeys:
            SearchKeysView()
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: SettingsSheet) -> some View {
        switch sheet {
        case .engineSelection:
            engineSelectionSheet
        case .apiKeys:
            apiKeysSheet
        }
    }

    private var engineSelectionSheet: some View {
        NavigationStack {
            AIEngineSelectionView(currentSelection: selectedEngine) { chosen in
                pendingEngine = chosen
                presentedSheet = nil
            }
            // Un vrai titre de barre : sans lui, « Annuler » flottait sur le contenu, qui passait
            // dessous quand on défilait (AX3, Duo plié ; findings Q3 n°19 et 20).
            .navigationTitle("Changer de moteur")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Explicite : celui du système sortirait en anglais.
                    Button("Annuler") {
                        presentedSheet = nil
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .settingsSheetFrame()
    }

    private var apiKeysSheet: some View {
        // Sélection cloud PARTAGÉE : supprimer ici la clé du fournisseur actif
        // doit effacer la sélection que lisent la Recherche et les autres
        // fenêtres (voir `BYOKProvidersView.selectionStore`).
        BYOKProvidersView(
            customStore: customProviderStore,
            selectionStore: cloudSelectionStore,
            onClose: { presentedSheet = nil }
        )
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
        .settingsSheetFrame()
    }

    /// Appelée à la fermeture de toute feuille ; ne fait quelque chose que si
    /// un moteur a été confirmé, et s'il diffère du moteur actif — reconfirmer
    /// le même moteur ne doit pas reconstruire la coquille (conversation en
    /// cours perdue pour rien).
    private func applyPendingEngine() {
        guard let chosen = pendingEngine else { return }
        pendingEngine = nil
        guard chosen != selectedEngine else { return }
        onSelectEngine?(chosen)
    }
}

// MARK: - Destinations

/// Destinations poussées dans la pile des Réglages. `nonisolated` : sous
/// `-default-isolation=MainActor`, un `Hashable` hérité du main actor serait
/// une conformance isolée, qu'une API générique de navigation peut refuser.
/// Interne, et non plus privé : `TrivaRootCoordinator` en détient la pile.
nonisolated enum SettingsRoute: Hashable {
    case cloudModelPicker
    case mlxStorage
    case advanced
    case searxngInstances
    case searchKeys
}

// MARK: - Types internes à l'écran

/// Feuilles présentées par les Réglages (une à la fois).
private nonisolated enum SettingsSheet: String, Identifiable {
    case engineSelection
    case apiKeys

    var id: String { rawValue }
}

/// Choix cloud privé d'Apple / appareil (mission A4), en sélecteur système intégré à la liste :
/// une ligne par option, son titre et sa phrase. Chaque changement est appliqué tout de suite,
/// comme tout réglage système ; la Recherche le lit au prochain envoi et son badge suit aussitôt
/// (instance partagée).
private struct AppleIntelligenceModelPicker: View {
    @Binding var selection: AppleIntelligenceModelKind

    var body: some View {
        Picker("Modèle d'Apple Intelligence", selection: $selection) {
            ForEach(AppleIntelligenceModelKind.allCases, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppleIntelligenceModelCopy.title(for: kind))
                    Text(AppleIntelligenceModelCopy.detail(for: kind))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(kind)
            }
        }
        .pickerStyle(.inline)
        #if os(iOS)
        .labelsHidden()
        #endif
        .accessibilityIdentifier("settings.appleModelPicker")
    }
}

/// Construit le view model du sélecteur fournisseur/modèle UNE fois par
/// affichage, à l'apparition : construit dans la destination elle-même, il
/// serait refait à chaque évaluation de la pile, avec ses lectures Keychain
/// synchrones sur le main actor (le piège décrit dans `BYOKProvidersView`).
/// Une nouvelle poussée repart d'un view model neuf : une clé ajoutée entre
/// deux visites apparaît (sa liste de fournisseurs est figée à
/// l'initialisation). Les fournisseurs personnalisés sont passés
/// explicitement : la valeur par défaut `[]` du view model les cacherait.
private struct CloudModelPickerScreen: View {
    let customPresets: [CloudProviderPreset]
    let selectionStore: CloudProviderSelectionStore
    /// Ouvre la feuille « Clés API » : seule suite possible quand aucune clé n'est enregistrée.
    let onOpenAPIKeys: () -> Void

    @State private var viewModel: CloudProviderModelPickerViewModel?

    var body: some View {
        Group {
            if let viewModel {
                CloudProviderModelPickerView(viewModel: viewModel, onOpenAPIKeys: onOpenAPIKeys)
            } else {
                Color.clear
            }
        }
        // Vrai titre de barre, comme les autres écrans des Réglages : le titre posé dans le contenu
        // laissait la barre vide et ne s'alignait pas sur le bouton retour (finding Q3 n°21).
        .navigationTitle("Fournisseur et modèle")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            makeViewModelIfNeeded()
        }
    }

    private func makeViewModelIfNeeded() {
        guard viewModel == nil else { return }
        viewModel = CloudProviderModelPickerViewModel(customPresets: customPresets, selectionStore: selectionStore)
    }
}

private extension View {
    /// Sur Mac, une feuille prend la taille idéale de son contenu, ce qui
    /// donne une fenêtre minuscule autour d'une `ScrollView`. Taille plancher
    /// sur Mac uniquement ; sans effet sur iPhone et iPad.
    @ViewBuilder
    func settingsSheetFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #else
        self
        #endif
    }
}

// MARK: - Previews

#Preview("Apple Intelligence") {
    SettingsView(selectedEngine: .appleIntelligence, onSelectEngine: { _ in })
}

#Preview("Clé API personnelle") {
    SettingsView(selectedEngine: .cloudBYOK, onSelectEngine: { _ in })
        .preferredColorScheme(.dark)
}

#Preview("Avant intégration (moteur non fourni)") {
    SettingsView()
}

#Preview("Apple Intelligence, cloud privé proposé") {
    SettingsView(
        selectedEngine: .appleIntelligence,
        onSelectEngine: { _ in },
        appleModel: AppleIntelligenceModelCoordinator(
            probe: FixedPrivateCloudProbe(status: .available),
            preferenceStore: AppleIntelligenceModelPreference(userDefaults: UserDefaults(suiteName: "preview.appleModel") ?? .standard)
        )
    )
}
