//
//  BYOKProvidersView.swift
//  Triva
//
//  Created by ben podrojsky on 05/09/2026.
//

import SwiftUI

/// Écran listant tous les fournisseurs BYOK disponibles (0.6 élargi) :
/// Claude (chemin dédié `ClaudeForFoundationModels`, voir `CloudBYOKProvider`),
/// le catalogue générique compatible OpenAI (`CloudProviderCatalog` — Groq,
/// OpenRouter, Mistral, DeepSeek, etc.) et les entrées "Personnalisé" de
/// l'utilisateur (`CustomProviderStore`). Chaque ligne pousse
/// `ProviderAPIKeyEntryView` pour le fournisseur choisi. Réutilisable de
/// façon autonome, comme `AIEngineSelectionView` (0.3) — l'écran Réglages
/// qui l'accueillera reste le scope de 1.15.
struct BYOKProvidersView: View {
    private static let claudeProviderID = CloudBYOKProviderKind.claude.rawValue

    @State private var customStore: CustomProviderStore
    /// Sélection fournisseur/modèle PARTAGÉE par toute l'app
    /// (`TrivaSharedStores.cloudSelection`), transmise à chaque
    /// `APIKeysViewModel`. Avant, chacun construisait son propre
    /// `CloudProviderSelectionStore()` : supprimer la clé du fournisseur actif
    /// effaçait la sélection de ce store jetable, pendant que celui de l'app —
    /// lu par la Recherche et par les autres fenêtres, qui ne relisent
    /// `UserDefaults` qu'à leur construction — gardait une sélection
    /// orpheline, sans clé pour la résoudre. Pas d'`@State` : la vue ne le
    /// possède pas, elle le transmet.
    private let selectionStore: CloudProviderSelectionStore
    @State private var isAddingCustomProvider = false
    /// Un seul `APIKeysViewModel` par fournisseur, construit paresseusement et
    /// réutilisé pour la ligne ET la destination du `NavigationLink` — sinon
    /// chaque évaluation de `body` reconstruit tous les view models (lecture
    /// Keychain + UserDefaults synchrones sur le main actor à chaque ligne).
    @State private var viewModels: [String: APIKeysViewModel] = [:]

    /// Plus de valeurs par défaut : chacune créait un store de plus, invisible
    /// du reste de l'app (le bug ci-dessus en est la forme exacte). Les deux
    /// viennent de `TrivaSharedStores`, via `SettingsView`.
    /// Fourni quand l'écran est présenté en feuille : un bouton « Fermer » apparaît alors dans la
    /// barre. Sans lui, seul un geste fermait la feuille sur iPhone et iPad, sans que rien ne
    /// l'indique (finding Q3 n°22 et Q2 point 16) ; sur Mac, il remplace la barre du bas.
    private let onClose: (() -> Void)?

    init(
        customStore: CustomProviderStore,
        selectionStore: CloudProviderSelectionStore,
        onClose: (() -> Void)? = nil
    ) {
        _customStore = State(initialValue: customStore)
        self.selectionStore = selectionStore
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            // `Form` groupé et non des cartes de verre : treize lignes de verre côte à côte, alors
            // que Réglages, Clés de recherche et Instances SearXNG sont des formulaires, faisaient
            // deux langages dans la même rubrique (finding Q3 n°11, DESIGN.md : « Ne pas mettre du
            // verre partout »). Le verre reste pour les cartes qu'on choisit (moteur, modèle).
            Form {
                Section {
                    if let claudeViewModel = viewModels[Self.claudeProviderID] {
                        row(displayName: "Claude", viewModel: claudeViewModel)
                    }

                    ForEach(CloudProviderCatalog.presets) { preset in
                        if let viewModel = viewModels[preset.id] {
                            row(displayName: preset.displayName, viewModel: viewModel)
                        }
                    }

                    ForEach(customStore.customPresets) { preset in
                        if let viewModel = viewModels[preset.id] {
                            row(displayName: preset.displayName, viewModel: viewModel)
                        }
                    }
                } footer: {
                    header
                }

                Section {
                    addCustomProviderButton
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Clés API")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        // Explicite : le libellé du système sortirait en anglais. Échap ferme sur Mac.
                        Button("Fermer", action: onClose)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("apiKeys.close")
                    }
                }
            }
            .sheet(isPresented: $isAddingCustomProvider) {
                AddCustomProviderView(customStore: customStore)
            }
            .onAppear(perform: ensureViewModels)
            .onChange(of: customStore.customPresets) { _, _ in ensureViewModels() }
        }
    }

    /// Construit le `APIKeysViewModel` de chaque fournisseur pas encore en
    /// cache — jamais deux fois le même, y compris quand `customStore.customPresets`
    /// grandit après l'ajout d'un fournisseur personnalisé.
    private func ensureViewModels() {
        if viewModels[Self.claudeProviderID] == nil {
            viewModels[Self.claudeProviderID] = Self.makeClaudeViewModel(selectionStore: selectionStore)
        }
        for preset in CloudProviderCatalog.presets where viewModels[preset.id] == nil {
            viewModels[preset.id] = Self.makeViewModel(for: preset, selectionStore: selectionStore)
        }
        for preset in customStore.customPresets where viewModels[preset.id] == nil {
            viewModels[preset.id] = Self.makeViewModel(for: preset, selectionStore: selectionStore)
        }
    }

    /// `APIKeysViewModel` de Claude (validateur et compte par défaut), branché
    /// sur la sélection partagée. Statique et interne pour que les tests
    /// vérifient le branchement sans interface ni vrai trousseau.
    static func makeClaudeViewModel(
        selectionStore: CloudProviderSelectionStore,
        keyStore: any APIKeyStoring = KeychainAPIKeyStore()
    ) -> APIKeysViewModel {
        APIKeysViewModel(
            keyStore: keyStore,
            validator: ModelListAPIKeyValidator(
                providerID: CloudProviderSelectionResolver.claudeProviderID,
                source: .anthropic,
                fallback: ClaudeAPIKeyValidator()
            ),
            selectionStore: selectionStore
        )
    }

    /// `APIKeysViewModel` d'un fournisseur compatible OpenAI (catalogue ou
    /// personnalisé), branché sur la sélection partagée. Même raison d'être
    /// statique que `makeClaudeViewModel`.
    static func makeViewModel(
        for preset: CloudProviderPreset,
        selectionStore: CloudProviderSelectionStore,
        keyStore: any APIKeyStoring = KeychainAPIKeyStore()
    ) -> APIKeysViewModel {
        APIKeysViewModel(
            keyStore: keyStore,
            validator: makeValidator(for: preset),
            account: preset.id,
            selectionStore: selectionStore
        )
    }

    /// Validateur d'un fournisseur compatible OpenAI : la liste de ses modèles prouve que la clé est
    /// acceptée sans dépendre d'un nom de modèle (`ModelListAPIKeyValidator`) ; la génération avec
    /// `defaultModel` ne sert que de repli quand le fournisseur ne publie pas de liste.
    static func makeValidator(for preset: CloudProviderPreset) -> any APIKeyValidating {
        let fallback = OpenAICompatibleAPIKeyValidator(baseURL: preset.baseURL, model: preset.defaultModel)
        guard let source = CloudModelListService.source(forProviderID: preset.id, customPresets: [preset]) else {
            return fallback
        }
        return ModelListAPIKeyValidator(providerID: preset.id, source: source, fallback: fallback)
    }

    private var header: some View {
        Text("Chaque clé reste dans le Trousseau de cet appareil, envoyée uniquement à son fournisseur.")
    }

    private var addCustomProviderButton: some View {
        Button {
            isAddingCustomProvider = true
        } label: {
            Label("Fournisseur personnalisé", systemImage: "plus")
        }
        .accessibilityIdentifier("apiKeys.addCustomProvider")
    }

    private func row(displayName: String, viewModel: APIKeysViewModel) -> some View {
        NavigationLink {
            ProviderAPIKeyEntryView(providerDisplayName: displayName, viewModel: viewModel)
        } label: {
            LabeledContent(displayName, value: viewModel.hasStoredKey ? "Configuré" : "")
        }
    }
}

#Preview {
    // Stores des aperçus (domaine `UserDefaults` dédié), jamais ceux de l'app.
    let stores = TrivaSharedStores.preview()
    BYOKProvidersView(customStore: stores.customProviders, selectionStore: stores.cloudSelection)
}
