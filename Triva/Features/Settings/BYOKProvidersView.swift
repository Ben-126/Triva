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
    @State private var customStore: CustomProviderStore
    @State private var isAddingCustomProvider = false

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
                            row(displayName: "Claude", viewModel: APIKeysViewModel())

                            ForEach(CloudProviderCatalog.presets) { preset in
                                row(displayName: preset.displayName, viewModel: viewModel(for: preset))
                            }

                            ForEach(customStore.customPresets) { preset in
                                row(displayName: preset.displayName, viewModel: viewModel(for: preset))
                            }

                            addCustomProviderButton
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .navigationTitle("Clés API")
            .sheet(isPresented: $isAddingCustomProvider) {
                AddCustomProviderView(customStore: customStore)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Clés API personnelles")
                .font(.system(size: 28, weight: .semibold))
            Text("Chaque clé reste sur cet appareil, envoyée uniquement à son fournisseur.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
