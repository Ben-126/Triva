//
//  ProviderAPIKeyEntryView.swift
//  Triva
//
//  Created by ben podrojsky on 03/09/2026.
//

import SwiftUI

/// Écran de saisie de la clé API d'**un** fournisseur BYOK (0.6, élargi à
/// tout preset de `CloudProviderCatalog` + Claude + "Personnalisé" — voir
/// `BYOKProvidersView`, qui liste tous les fournisseurs et pousse cette vue
/// pour celui choisi). La clé est validée par un vrai appel au fournisseur
/// avant d'être enregistrée en Keychain, et n'est jamais réaffichée en clair
/// une fois stockée.
struct ProviderAPIKeyEntryView: View {
    let providerDisplayName: String
    @State private var viewModel: APIKeysViewModel
    @State private var rawKey: String = ""

    init(providerDisplayName: String, viewModel: APIKeysViewModel) {
        self.providerDisplayName = providerDisplayName
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                GlassEffectContainer(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        if viewModel.hasStoredKey {
                            storedKeyCard
                        } else {
                            entryField
                        }
                    }
                }

                if case .failed(let message) = viewModel.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .navigationTitle(providerDisplayName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(providerDisplayName)
                .font(.system(size: 28, weight: .semibold))
            Text("Envoyée directement à \(providerDisplayName) — jamais à un serveur Triva.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var entryField: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Clé API \(providerDisplayName)", text: $rawKey)
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))

            Button {
                Task { await viewModel.save(rawKey: rawKey) }
            } label: {
                Group {
                    if viewModel.state == .validating {
                        ProgressView()
                    } else {
                        Text("Enregistrer")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(viewModel.state == .validating || rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var storedKeyCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clé enregistrée")
                    .font(.headline)
                Text("Stockée uniquement sur cet appareil (Keychain).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Supprimer", role: .destructive) {
                viewModel.deleteStoredKey()
                rawKey = ""
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

#Preview {
    NavigationStack {
        ProviderAPIKeyEntryView(providerDisplayName: "Claude", viewModel: APIKeysViewModel())
    }
}
