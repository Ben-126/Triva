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

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Largeur de contenu plafonnée en `regular` (iPad/Mac) — même principe
    /// que `ChatView.contentMaxWidth` / `AIEngineSelectionView.contentMaxWidth`,
    /// pour éviter que les lignes de fournisseurs ne s'étirent bord à bord.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    /// Plus de valeurs par défaut : chacune créait un store de plus, invisible
    /// du reste de l'app (le bug ci-dessus en est la forme exacte). Les deux
    /// viennent de `TrivaSharedStores`, via `SettingsView`.
    init(customStore: CustomProviderStore, selectionStore: CloudProviderSelectionStore) {
        _customStore = State(initialValue: customStore)
        self.selectionStore = selectionStore
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header

                    GlassEffectContainer(spacing: 12) {
                        VStack(alignment: .leading, spacing: 12) {
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

                            addCustomProviderButton
                        }
                    }
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .navigationTitle("Clés API")
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
        APIKeysViewModel(keyStore: keyStore, selectionStore: selectionStore)
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
            validator: OpenAICompatibleAPIKeyValidator(baseURL: preset.baseURL, model: preset.defaultModel),
            account: preset.id,
            selectionStore: selectionStore
        )
    }

    private var header: some View {
        Text("Chaque clé reste sur cet appareil, envoyée uniquement à son fournisseur.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var addCustomProviderButton: some View {
        Button {
            isAddingCustomProvider = true
        } label: {
            Label("Fournisseur personnalisé", systemImage: "plus")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .buttonStyle(.glass)
    }

    private func row(displayName: String, viewModel: APIKeysViewModel) -> some View {
        NavigationLink {
            ProviderAPIKeyEntryView(providerDisplayName: displayName, viewModel: viewModel)
        } label: {
            HStack {
                Text(displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if viewModel.hasStoredKey {
                    Text("Configuré")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    // Stores des aperçus (domaine `UserDefaults` dédié), jamais ceux de l'app.
    let stores = TrivaSharedStores.preview()
    BYOKProvidersView(customStore: stores.customProviders, selectionStore: stores.cloudSelection)
}
