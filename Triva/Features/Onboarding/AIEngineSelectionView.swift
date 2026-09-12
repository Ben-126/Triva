//
//  AIEngineSelectionView.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import SwiftUI

/// Écran de choix du moteur IA (0.3) : 3 cartes (Apple Intelligence / MLX local /
/// clé API perso), avec présélection automatique de l'option recommandée pour
/// l'appareil détecté — le choix reste libre. Réutilisable depuis l'onboarding
/// initial ou depuis les Réglages (1.15) pour changer de moteur à tout moment.
struct AIEngineSelectionView: View {
    @State private var selection: AIEngineOption
    private let recommendation: AIEngineRecommendation
    private let onConfirm: (AIEngineOption) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Largeur de contenu plafonnée en `regular` (iPad/Mac) — même principe
    /// que `ChatView.contentMaxWidth`, pour éviter que les cartes et le
    /// bouton "Continuer" ne s'étirent bord à bord sur un grand écran.
    private var contentMaxWidth: CGFloat? {
        horizontalSizeClass == .regular ? 640 : nil
    }

    init(
        capabilityProvider: any DeviceCapabilityProviding = SystemDeviceCapabilityProvider(),
        currentSelection: AIEngineOption? = nil,
        onConfirm: @escaping (AIEngineOption) -> Void
    ) {
        let recommendation = AIProviderSelector.recommend(for: capabilityProvider)
        self.recommendation = recommendation
        _selection = State(initialValue: currentSelection ?? recommendation.option)
        self.onConfirm = onConfirm
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                GlassEffectContainer(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        engineCard(
                            option: .appleIntelligence,
                            title: "Apple Intelligence",
                            subtitle: "Gratuit, sur l'appareil. Nécessite un iPhone/Mac compatible avec Apple Intelligence activé."
                        )
                        engineCard(
                            option: .mlxLocal,
                            title: "Modèle local (MLX)",
                            subtitle: "Gratuit, sur l'appareil. Un modèle adapté à la puissance de ton appareil te sera proposé au choix (0.5)."
                        )
                        engineCard(
                            option: .cloudBYOK,
                            title: "Clé API personnelle",
                            subtitle: "Le plus puissant. Payant selon le fournisseur choisi, ta clé reste uniquement sur cet appareil."
                        )
                    }
                }

                Button("Continuer") {
                    onConfirm(selection)
                }
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image("TrivaLockup")
                .resizable()
                .scaledToFit()
                .frame(height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("Choisis ton moteur IA")
                    .font(.system(size: 28, weight: .semibold))
                Text("Tu pourras en changer à tout moment depuis les Réglages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func engineCard(option: AIEngineOption, title: String, subtitle: String) -> some View {
        let isSelected = selection == option
        let isRecommended = recommendation.option == option

        Button {
            selection = option
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if isRecommended {
                        Text("Recommandé")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .capsule)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                isSelected ? .regular.tint(.accentColor.opacity(0.12)).interactive() : .regular.interactive(),
                in: .rect(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AIEngineSelectionView { _ in }
}
