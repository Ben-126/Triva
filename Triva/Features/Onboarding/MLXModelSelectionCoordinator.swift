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
///
/// L'ESSAI passe par le pool partagé (`MLXProviderPool`, chantier 2.2, mission G1) : ses questions attendent
/// leur tour dans la même file que les réponses des fenêtres (une seule génération MLX à la fois), et
/// l'abandonner ne retire JAMAIS un modèle que le pool utilise (voir `MLXProviderPool.discardTrialModel`).
/// Le téléchargement, lui, reste hors de la file : il dure plusieurs minutes et ferait attendre toutes les
/// fenêtres pour rien.
@MainActor
@Observable
final class MLXModelSelectionCoordinator {
    enum Phase: Equatable {
        case idle
        case downloading(fractionCompleted: Double)
        case trial
        case ready
        /// `isEnvironmentLimitation` distingue un VRAI échec de téléchargement/
        /// génération (`false`, le cas courant) d'une limitation connue de
        /// l'environnement (`true` — ex. `MLXProviderError.simulatorUnsupported`,
        /// aucun GPU Metal complet sur le Simulateur) où rien n'a jamais été
        /// téléchargé : l'UI (voir `MLXModelSelectionView.failedContent`) ne
        /// doit pas afficher "Le téléchargement a échoué" dans ce cas, ce
        /// serait factuellement faux.
        case failed(description: String, isEnvironmentLimitation: Bool = false)
    }

    static let trialQuestions = [
        "Explique en une phrase simple ce qu'est la photosynthèse.",
        "Donne-moi 2 idées de sujets à approfondir sur l'espace.",
    ]

    private(set) var phase: Phase = .idle
    private(set) var selectedEntry: MLXModelCatalogEntry?
    private(set) var trialAnswers: [String] = []
    private(set) var isGeneratingTrialAnswer = false

    /// Modèle d'essai et identifiant du modèle qu'il porte (`nil` ensemble). Jamais déchargé directement :
    /// toujours par le pool, qui sait si la fenêtre d'une autre conversation s'en sert.
    private var provider: (any TrialLocalModel)?
    private var providerModelID: String?
    private var downloadTask: Task<Void, Never>?
    /// Incrémenté à chaque abandon (annulation, changement de modèle) pour
    /// invalider toute Task de téléchargement encore en vol : `prepare()`
    /// n'est pas cancellation-aware (le transfert réseau continue jusqu'à sa
    /// fin naturelle, voir le commentaire de `MLXProvider.cancel()`), donc
    /// `downloadTask?.cancel()` seul ne l'empêche pas de terminer et
    /// d'essayer d'écrire dans `phase` bien après coup.
    private var downloadGeneration = 0

    private let onValidated: (MLXModelCatalogEntry) -> Void
    private let pool: MLXProviderPool
    private let makeModel: (MLXModelCatalogEntry) -> any TrialLocalModel
    /// Identité de l'essai dans la file du pool (jamais confondue avec une fenêtre).
    private let requesterID = UUID()

    /// - Parameters:
    ///   - pool: le pool partagé de l'app (`TrivaSharedStores.mlxProviderPool`).
    ///   - makeModel: fabrique du modèle d'essai ; les tests y mettent un double.
    init(
        pool: MLXProviderPool,
        makeModel: @escaping (MLXModelCatalogEntry) -> any TrialLocalModel = { MLXProvider(entry: $0) },
        onValidated: @escaping (MLXModelCatalogEntry) -> Void
    ) {
        self.pool = pool
        self.makeModel = makeModel
        self.onValidated = onValidated
    }

    /// Fenêtre fermée sans avoir choisi (« Fermer », geste de la feuille) : le modèle d'essai ne reste pas en mémoire.
    isolated deinit {
        discardProvider()
    }

    var nextTrialQuestion: String? {
        guard trialAnswers.count < Self.trialQuestions.count else { return nil }
        return Self.trialQuestions[trialAnswers.count]
    }

    var hasCompletedTrial: Bool {
        trialAnswers.count >= Self.trialQuestions.count
    }

    func select(_ entry: MLXModelCatalogEntry) {
        // Invalide toute génération précédente (abandonne son provider) AVANT
        // de préparer la nouvelle sélection : un premier téléchargement encore
        // en vol après une annulation, ou un double-tap rapide sur deux
        // modèles (cf. `MLXModelSelectionView`), ne doit plus jamais pouvoir
        // toucher `phase` une fois la génération suivante démarrée.
        invalidateCurrentDownload()
        let generation = downloadGeneration

        selectedEntry = entry
        trialAnswers = []
        phase = .downloading(fractionCompleted: 0)

        let provider = makeModel(entry)
        self.provider = provider
        providerModelID = entry.id

        downloadTask = Task { [weak self] in
            do {
                try await provider.loadIntoMemory { progress in
                    Task { @MainActor in
                        // Un `prepare()` annulé continue de télécharger en
                        // tâche de fond côté module mlx-swift-lm (voir le
                        // commentaire de `MLXProvider.cancel()`) et peut donc
                        // encore appeler ce callback après coup — sans cette
                        // garde, la barre de progression réapparaîtrait après
                        // que l'utilisateur l'a fermée.
                        guard let self, self.downloadGeneration == generation else { return }
                        self.phase = .downloading(fractionCompleted: progress.fractionCompleted)
                    }
                }
                guard let self, self.downloadGeneration == generation else { return }
                phase = .trial
            } catch is CancellationError {
                guard let self, self.downloadGeneration == generation else { return }
                self.reset()
            } catch let error as MLXProviderError where error == .simulatorUnsupported {
                guard let self, self.downloadGeneration == generation else { return }
                self.phase = .failed(
                    description: "Les modèles locaux (MLX) nécessitent un vrai appareil : le Simulateur n'a pas de vrai GPU Metal.",
                    isEnvironmentLimitation: true
                )
            } catch {
                guard let self, self.downloadGeneration == generation else { return }
                self.phase = .failed(description: String(describing: error))
            }
        }
    }

    func cancelDownload() {
        invalidateCurrentDownload()
        reset()
    }

    func askNextTrialQuestion() async {
        guard let provider, let question = nextTrialQuestion else { return }
        // Capture la génération courante : si `chooseAnotherModel()` (ou une
        // nouvelle `select()`) abandonne cette session pendant le `await`,
        // la réponse tardive de l'ancien modèle ne doit pas atterrir dans le
        // `trialAnswers` (vidé entretemps) de la nouvelle sélection.
        let generation = downloadGeneration
        isGeneratingTrialAnswer = true
        defer {
            if downloadGeneration == generation {
                isGeneratingTrialAnswer = false
            }
        }

        do {
            let generator = pool.trialGenerator(for: provider, requester: requesterID)
            let answer = try await generator.generate(prompt: question)
            guard downloadGeneration == generation else { return }
            trialAnswers.append(answer)
        } catch {
            guard downloadGeneration == generation else { return }
            trialAnswers.append(String(describing: error))
        }
    }

    /// Le modèle essayé devient le modèle de l'app. Le modèle d'essai, déjà chargé, est confié au pool APRÈS
    /// l'écriture de la sélection (`onValidated`) : il devient le modèle résident si une fenêtre l'utilise
    /// (aucun rechargement à la première question), sinon il est libéré. Il n'est jamais « annulé » ici :
    /// `MLXProvider.cancel()` évincerait du cache les poids que l'app va utiliser.
    func validateAsDefault() {
        guard let selectedEntry else { return }
        phase = .ready
        onValidated(selectedEntry)
        if let provider, let providerModelID {
            pool.adoptTrialModel(provider, id: providerModelID)
        }
        provider = nil
        providerModelID = nil
    }

    func chooseAnotherModel() {
        invalidateCurrentDownload()
        reset()
    }

    /// Invalide la génération de téléchargement/essai courante et abandonne
    /// son provider. N'interrompt PAS un transfert réseau déjà en vol —
    /// `MLXProvider.cancel()` ne fait qu'évincer le modèle du cache partagé,
    /// le téléchargement sous-jacent continue en tâche de fond jusqu'à sa fin
    /// naturelle — mais garantit qu'une fois revenu, ce flux abandonné ne
    /// pourra plus écrire dans `phase`/`trialAnswers` d'une session ultérieure.
    private func invalidateCurrentDownload() {
        downloadGeneration += 1
        downloadTask?.cancel()
        discardProvider()
    }

    /// Abandonne le modèle d'essai par le pool : il n'est déchargé que si le pool ne s'en sert pas (même
    /// identifiant que le modèle résident ou en cours de chargement).
    private func discardProvider() {
        if let provider, let providerModelID {
            pool.discardTrialModel(provider, id: providerModelID)
        }
        provider = nil
        providerModelID = nil
    }

    private func reset() {
        downloadTask = nil
        discardProvider()
        selectedEntry = nil
        trialAnswers = []
        isGeneratingTrialAnswer = false
        phase = .idle
    }
}
