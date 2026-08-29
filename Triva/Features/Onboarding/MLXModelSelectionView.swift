//
//  MLXModelSelectionView.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import SwiftUI

/// Écran de choix d'un modèle MLX (0.5) : 3 cartes (recommandé / plus
/// performant-plus lent / plus rapide-moins performant) calculées à partir de
/// la capacité/vitesse détectée de l'appareil, + liste complète dépliable.
/// Le modèle choisi passe toujours par un téléchargement annulable avec
/// progression, puis un mode essai (1-2 questions) avant validation.
struct MLXModelSelectionView: View {
    private let catalog: [MLXModelCatalogEntry]
    private let recommendation: MLXModelRecommendation?
    @State private var coordinator: MLXModelSelectionCoordinator
    @State private var showingFullCatalog = false

    init(
        capabilityProvider: any MLXDeviceCapabilityProviding = SystemMLXDeviceCapabilityProvider(),
        onValidated: @escaping (MLXModelCatalogEntry) -> Void
    ) {
        let loadedCatalog = (try? MLXModelCatalog.load()) ?? []
        catalog = loadedCatalog
        recommendation = MLXModelRecommender.recommend(from: loadedCatalog, for: capabilityProvider)
        _coordinator = State(initialValue: MLXModelSelectionCoordinator(onValidated: onValidated))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                switch coordinator.phase {
                case .idle:
                    choosingContent
                case .downloading(let fractionCompleted):
                    downloadingContent(fractionCompleted: fractionCompleted)
                case .trial:
                    trialContent
                case .ready:
                    readyContent
                case .failed(let description):
                    failedContent(description: description)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showingFullCatalog) {
            fullCatalogSheet
        }
    }

    // MARK: - Choix initial

    @ViewBuilder
    private var choosingContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choisis ton modèle local")
                .font(.system(size: 28, weight: .semibold))
            Text("Basé sur la puissance de ton appareil. Tu pourras en changer à tout moment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        if let recommendation {
            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    if let fasterLessPerformant = recommendation.fasterLessPerformant {
                        modelCard(fasterLessPerformant, badge: "Plus rapide")
                    }
                    modelCard(recommendation.recommended, badge: "Recommandé")
                    if let morePerformantSlower = recommendation.morePerformantSlower {
                        modelCard(morePerformantSlower, badge: "Plus performant")
                    }
                }
            }
        } else {
            Text("Aucun modèle disponible pour le moment.")
                .foregroundStyle(.secondary)
        }

        Button("Voir tous les modèles") {
            showingFullCatalog = true
        }
        .buttonStyle(.glass)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func modelCard(_ entry: MLXModelCatalogEntry, badge: String) -> some View {
        Button {
            coordinator.select(entry)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.displayName).font(.headline)
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .capsule)
                    Spacer()
                    Text(Self.formattedSize(entry.downloadSizeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Téléchargement

    @ViewBuilder
    private func downloadingContent(fractionCompleted: Double) -> some View {
        if let entry = coordinator.selectedEntry {
            VStack(alignment: .leading, spacing: 4) {
                Text("Téléchargement de \(entry.displayName)")
                    .font(.system(size: 28, weight: .semibold))
                Text("\(Self.formattedSize(entry.downloadSizeBytes)) • Wi-Fi requis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fractionCompleted)
                    .tint(.accentColor)
                Text("\(Int(fractionCompleted * 100)) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Annuler", role: .destructive) {
                coordinator.cancelDownload()
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: - Mode essai

    @ViewBuilder
    private var trialContent: some View {
        if let entry = coordinator.selectedEntry {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mode essai — \(entry.displayName)")
                    .font(.system(size: 28, weight: .semibold))
                Text("Pose quelques questions de démo avant de valider ce modèle par défaut.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(coordinator.trialAnswers.enumerated()), id: \.offset) { index, answer in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MLXModelSelectionCoordinator.trialQuestions[index])
                                .font(.subheadline.weight(.semibold))
                            Text(answer)
                                .font(.body)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }
                }
            }

            if let nextQuestion = coordinator.nextTrialQuestion {
                Text(nextQuestion)
                    .font(.subheadline)
                Button {
                    Task { await coordinator.askNextTrialQuestion() }
                } label: {
                    if coordinator.isGeneratingTrialAnswer {
                        ProgressView()
                    } else {
                        Text("Poser cette question")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(coordinator.isGeneratingTrialAnswer)
            }

            if coordinator.hasCompletedTrial {
                Button("Valider comme modèle par défaut") {
                    coordinator.validateAsDefault()
                }
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
            }

            Button("Choisir un autre modèle") {
                coordinator.chooseAnotherModel()
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: - États finaux

    @ViewBuilder
    private var readyContent: some View {
        if let entry = coordinator.selectedEntry {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(entry.displayName) est prêt")
                    .font(.system(size: 28, weight: .semibold))
                Text("Ce modèle est maintenant ton choix par défaut.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func failedContent(description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Le téléchargement a échoué")
                .font(.system(size: 28, weight: .semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button("Choisir un autre modèle") {
            coordinator.chooseAnotherModel()
        }
        .buttonStyle(.glassProminent)
    }

    // MARK: - Liste complète

    private var fullCatalogSheet: some View {
        NavigationStack {
            List(catalog) { entry in
                Button {
                    showingFullCatalog = false
                    coordinator.select(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.displayName).font(.headline)
                            Spacer()
                            Text(Self.formattedSize(entry.downloadSizeBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(entry.strengths, id: \.self) { strength in
                            Label(strength, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        ForEach(entry.tradeoffs, id: \.self) { tradeoff in
                            Label(tradeoff, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Tous les modèles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { showingFullCatalog = false }
                }
            }
        }
    }

    private static func formattedSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

#Preview {
    MLXModelSelectionView { _ in }
}
