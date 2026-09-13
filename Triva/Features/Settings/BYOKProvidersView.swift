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

    init(customStore: CustomProviderStore = CustomProviderStore()) {
        _customStore = State(initialValue: customStore)
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
            viewModels[Self.claudeProviderID] = APIKeysViewModel()
        }
        for preset in CloudProviderCatalog.presets where viewModels[preset.id] == nil {
            viewModels[preset.id] = viewModel(for: preset)
        }
        for preset in customStore.customPresets where viewModels[preset.id] == nil {
            viewModels[preset.id] = viewModel(for: preset)
        }
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

    private func viewModel(for preset: CloudProviderPreset) -> APIKeysViewModel {
        APIKeysViewModel(
            validator: OpenAICompatibleAPIKeyValidator(baseURL: preset.baseURL, model: preset.defaultModel),
            account: preset.id
        )
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
    BYOKProvidersView()
}
