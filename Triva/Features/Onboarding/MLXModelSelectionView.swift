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
            VStack(alignment: .leading, spacing: 16) {
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
            .padding()
        }
        .sheet(isPresented: $showingFullCatalog) {
            fullCatalogSheet
        }
    }

    // MARK: - Choix initial

    @ViewBuilder
    private var choosingContent: some View {
        Text("Choisis ton modèle local")
            .font(.title2.bold())
        Text("Basé sur la puissance de ton appareil. Tu pourras en changer à tout moment.")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        if let recommendation {
            if let fasterLessPerformant = recommendation.fasterLessPerformant {
                modelCard(fasterLessPerformant, badge: "Plus rapide")
            }
            modelCard(recommendation.recommended, badge: "Recommandé")
            if let morePerformantSlower = recommendation.morePerformantSlower {
                modelCard(morePerformantSlower, badge: "Plus performant")
            }
        } else {
            Text("Aucun modèle disponible pour le moment.")
                .foregroundStyle(.secondary)
        }

        Button("Voir tous les modèles") {
            showingFullCatalog = true
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func modelCard(_ entry: MLXModelCatalogEntry, badge: String) -> some View {
        Button {
            coordinator.select(entry)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.displayName).font(.headline)
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
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
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Téléchargement

    @ViewBuilder
    private func downloadingContent(fractionCompleted: Double) -> some View {
        if let entry = coordinator.selectedEntry {
            Text("Téléchargement de \(entry.displayName)")
                .font(.title2.bold())
            Text("\(Self.formattedSize(entry.downloadSizeBytes)) • Wi-Fi requis")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ProgressView(value: fractionCompleted)
            Text("\(Int(fractionCompleted * 100)) %")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Annuler", role: .destructive) {
                coordinator.cancelDownload()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Mode essai

    @ViewBuilder
    private var trialContent: some View {
        if let entry = coordinator.selectedEntry {
            Text("Mode essai — \(entry.displayName)")
                .font(.title2.bold())
            Text("Pose quelques questions de démo avant de valider ce modèle par défaut.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(Array(coordinator.trialAnswers.enumerated()), id: \.offset) { index, answer in
                VStack(alignment: .leading, spacing: 4) {
                    Text(MLXModelSelectionCoordinator.trialQuestions[index])
                        .font(.subheadline.weight(.semibold))
                    Text(answer)
                        .font(.body)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.isGeneratingTrialAnswer)
            }

            if coordinator.hasCompletedTrial {
                Button("Valider comme modèle par défaut") {
                    coordinator.validateAsDefault()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }

            Button("Choisir un autre modèle") {
                coordinator.chooseAnotherModel()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - États finaux

    @ViewBuilder
    private var readyContent: some View {
        if let entry = coordinator.selectedEntry {
            Text("\(entry.displayName) est prêt")
                .font(.title2.bold())
            Text("Ce modèle est maintenant ton choix par défaut.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func failedContent(description: String) -> some View {
        Text("Le téléchargement a échoué")
            .font(.title2.bold())
        Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
        Button("Choisir un autre modèle") {
            coordinator.chooseAnotherModel()
        }
        .buttonStyle(.borderedProminent)
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
