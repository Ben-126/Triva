//
//  APIKeysView.swift
//  Triva
//
//  Created by ben podrojsky on 03/09/2026.
//

import SwiftUI

/// Écran de saisie de la clé API BYOK (0.6) — un seul fournisseur pour
/// l'instant (Claude, voir `CloudBYOKProviderKind`). La clé est validée par
/// un vrai appel au fournisseur avant d'être enregistrée en Keychain, et
/// n'est jamais réaffichée en clair une fois stockée. Réutilisable de façon
/// autonome, comme `AIEngineSelectionView` (0.3) — l'écran Réglages qui
/// l'accueillera reste le scope de 1.15.
struct APIKeysView: View {
    @State private var viewModel: APIKeysViewModel
    @State private var rawKey: String = ""

    init(viewModel: APIKeysViewModel = APIKeysViewModel()) {
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Clé API personnelle")
                .font(.system(size: 28, weight: .semibold))
            Text("Envoyée directement à Claude — jamais à un serveur Triva.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var entryField: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Clé API Claude", text: $rawKey)
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
    APIKeysView()
}
