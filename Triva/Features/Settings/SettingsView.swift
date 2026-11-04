//
//  SettingsView.swift
//  Triva
//
//  Created by ben podrojsky on 16/09/2026.
//

import SwiftUI

/// Écran Réglages (1.15) : le moteur IA actif et son changement, les clés API
/// BYOK et le choix fournisseur/modèle, les clés de recherche personnelles et
/// — repliée par défaut, groupe « Avancé » — la liste d'instances SearXNG,
/// l'espace occupé par les modèles MLX.
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

    @State private var mlxSelectionStore: MLXModelSelectionStore
    @State private var cloudSelectionStore: CloudProviderSelectionStore
    @State private var customProviderStore: CustomProviderStore
    @State private var instanceStore: CustomInstanceStore

    @State private var presentedSheet: SettingsSheet?
    /// Moteur confirmé dans la feuille, appliqué à sa fermeture seulement :
    /// l'appliquer pendant que la feuille est encore à l'écran reconstruirait
    /// la coquille sous elle, en pleine animation.
    @State private var pendingEngine: AIEngineOption?
    @State private var isAdvancedExpanded = false
    /// Pile injectée, `nil` : `localNavigationPath`. Voir le commentaire de tête.
    private let injectedNavigationPath: Binding<[SettingsRoute]>?
    @State private var localNavigationPath: [SettingsRoute] = []

    init(
        selectedEngine: AIEngineOption? = nil,
        onSelectEngine: ((AIEngineOption) -> Void)? = nil,
        mlxSelectionStore: MLXModelSelectionStore = MLXModelSelectionStore(),
        cloudSelectionStore: CloudProviderSelectionStore = CloudProviderSelectionStore(),
        customProviderStore: CustomProviderStore = CustomProviderStore(),
        instanceStore: CustomInstanceStore = CustomInstanceStore(),
        navigationPath: Binding<[SettingsRoute]>? = nil
    ) {
        self.selectedEngine = selectedEngine
        self.onSelectEngine = onSelectEngine
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
    }

    // MARK: Sections

    private func engineSection(for engine: AIEngineOption) -> some View {
        Section("Moteur IA") {
            EngineBadge(engine: engine)
            if onSelectEngine != nil {
                Button("Changer de moteur") {
                    presentedSheet = .engineSelection
                }
            }
        }
    }

    /// Toujours visible, quel que soit le moteur actif : on peut préparer sa
    /// clé avant de basculer sur le moteur cloud. Le pied de section dit à
    /// quoi servent ces réglages quand le moteur actif est local.
    private var apiKeySection: some View {
        Section {
            Button("Gérer les clés API") {
                presentedSheet = .apiKeys
            }
            NavigationLink("Fournisseur et modèle", value: SettingsRoute.cloudModelPicker)
        } header: {
            Text("Clé API personnelle")
        } footer: {
            Text("Ces réglages ne servent qu'avec le moteur «\u{00A0}Clé API personnelle\u{00A0}».")
        }
    }

    /// Tout ce qui décide où partent les recherches, quel que soit le moteur IA.
    ///
    /// Les clés de recherche en premier : c'est le réglage qui change quelque
    /// chose pour la plupart des gens, et l'invitation du chat y mène. La liste
    /// d'instances reste repliée par défaut : elle ne concerne que ceux qui
    /// hébergent leur propre instance. La valeur affichée dit d'un coup d'œil
    /// si elle a été modifiée.
    ///
    /// Pas d'état des clés sur la ligne : il faudrait lire le trousseau à
    /// chaque rendu (le piège décrit dans `BYOKProvidersView`). L'écran poussé
    /// le dit, source par source.
    private var searchSection: some View {
        Section("Recherche") {
            NavigationLink("Clés de recherche", value: SettingsRoute.searchKeys)
            DisclosureGroup("Avancé", isExpanded: $isAdvancedExpanded) {
                NavigationLink(value: SettingsRoute.searxngInstances) {
                    LabeledContent(
                        "Instances SearXNG",
                        value: instanceStore.isCustomized ? "Personnalisées" : "Par défaut"
                    )
                }
            }
        }
    }

    private var storageSection: some View {
        Section("Stockage") {
            NavigationLink("Modèles MLX", value: SettingsRoute.mlxStorage)
        }
    }

    // MARK: Navigation

    @ViewBuilder
    private func destination(for route: SettingsRoute) -> some View {
        switch route {
        case .cloudModelPicker:
            CloudModelPickerScreen(
                customPresets: customProviderStore.customPresets,
                selectionStore: cloudSelectionStore
            )
        case .mlxStorage:
            MLXStorageView(mlxSelectionStore: mlxSelectionStore, activeEngine: selectedEngine)
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
        BYOKProvidersView(customStore: customProviderStore, selectionStore: cloudSelectionStore)
            #if os(iOS)
            .presentationDragIndicator(.visible)
            #elseif os(macOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sheetCloseBar
            }
            #endif
            .settingsSheetFrame()
    }

    #if os(macOS)
    /// Fond opaque et séparateur : la liste défile derrière la barre, elle ne
    /// doit pas transparaître (DESIGN.md : pas de calque semi-transparent).
    /// Échap ferme la feuille ; pas Entrée, qui validerait sinon la saisie
    /// d'une clé dans l'écran poussé à l'intérieur.
    private var sheetCloseBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Spacer()
                Button("Fermer") {
                    presentedSheet = nil
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.background)
    }
    #endif

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

/// Badge moteur IA + légende de confidentialité, exactement comme
/// `TrivaHomeReferenceView` et `EngineStatusView` : même contenu
/// (`AIEngineOption.privacyBadge`, source unique de vérité — jamais « Sur
/// l'appareil » pour `.cloudBYOK`), mêmes tailles, même verre teinté.
private struct EngineBadge: View {
    let engine: AIEngineOption

    var body: some View {
        let badge = engine.privacyBadge
        VStack(alignment: .leading, spacing: 6) {
            Label(badge.text, systemImage: badge.icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .capsule)

            Text(badge.caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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

    @State private var viewModel: CloudProviderModelPickerViewModel?

    var body: some View {
        Group {
            if let viewModel {
                CloudProviderModelPickerView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        // Pas de titre de barre : l'écran porte déjà son propre titre
        // (« Fournisseur & modèle ») dans son contenu.
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
