//
//  MLXModelSelectionCoordinator.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

/// Pilote le flux de choix d'un modèle MLX (0.5) : téléchargement annulable
/// avec progression, puis mode essai (1-2 questions de démo) avant de valider
/// le modèle comme choix par défaut. S'applique à n'importe quel modèle du
/// catalogue, pas seulement au modèle recommandé — un utilisateur qui choisit
/// un autre modèle dans la liste complète passe par le même garde-fou.
@MainActor
@Observable
final class MLXModelSelectionCoordinator {
    enum Phase: Equatable {
        case idle
        case downloading(fractionCompleted: Double)
        case trial
        case ready
        case failed(description: String)
    }

    static let trialQuestions = [
        "Explique en une phrase simple ce qu'est la photosynthèse.",
        "Donne-moi 2 idées de sujets à approfondir sur l'espace.",
    ]

    private(set) var phase: Phase = .idle
    private(set) var selectedEntry: MLXModelCatalogEntry?
    private(set) var trialAnswers: [String] = []
    private(set) var isGeneratingTrialAnswer = false

    private var provider: MLXProvider?
    private var downloadTask: Task<Void, Never>?

    private let onValidated: (MLXModelCatalogEntry) -> Void

    init(onValidated: @escaping (MLXModelCatalogEntry) -> Void) {
        self.onValidated = onValidated
    }

    var nextTrialQuestion: String? {
        guard trialAnswers.count < Self.trialQuestions.count else { return nil }
        return Self.trialQuestions[trialAnswers.count]
    }

    var hasCompletedTrial: Bool {
        trialAnswers.count >= Self.trialQuestions.count
    }

    func select(_ entry: MLXModelCatalogEntry) {
        selectedEntry = entry
        trialAnswers = []
        phase = .downloading(fractionCompleted: 0)

        let provider = MLXProvider(entry: entry)
        self.provider = provider

        downloadTask = Task { [weak self] in
            do {
                try await provider.prepare { progress in
                    Task { @MainActor in
                        self?.phase = .downloading(fractionCompleted: progress.fractionCompleted)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                phase = .trial
            } catch is CancellationError {
                self?.reset()
            } catch {
                self?.phase = .failed(description: String(describing: error))
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        reset()
    }

    func askNextTrialQuestion() async {
        guard let provider, let question = nextTrialQuestion else { return }
        isGeneratingTrialAnswer = true
        defer { isGeneratingTrialAnswer = false }

        do {
            let answer = try await provider.generate(prompt: question)
            trialAnswers.append(answer)
        } catch {
            trialAnswers.append(String(describing: error))
        }
    }

    func validateAsDefault() {
        guard let selectedEntry else { return }
        phase = .ready
        onValidated(selectedEntry)
    }

    func chooseAnotherModel() {
        downloadTask?.cancel()
        reset()
    }

    private func reset() {
        downloadTask = nil
        provider = nil
        selectedEntry = nil
        trialAnswers = []
        phase = .idle
    }
}
