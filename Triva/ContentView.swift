import SwiftUI

struct ContentView: View {
    @State private var engineSettings = AIEngineSettingsStore()

    var body: some View {
        if let selected = engineSettings.selectedOption {
            EngineStatusView(
                selectedEngine: selected,
                onChangeEngine: { engineSettings.selectedOption = nil }
            )
        } else {
            AIEngineSelectionView { chosen in
                engineSettings.selectedOption = chosen
            }
        }
    }
}

/// Écran temporaire de V0 : affiche le moteur choisi et permet de tester une
/// vraie génération Apple Intelligence sur l'appareil, pour valider 0.4 en
/// conditions réelles (l'outil de snippet Xcode n'y arrive pas de façon fiable).
/// Sera remplacé par le vrai chat (0.8).
private struct EngineStatusView: View {
    let selectedEngine: AIEngineOption
    let onChangeEngine: () -> Void

    @State private var appleIntelligenceResult: Result<String, AppleIntelligenceError>?
    @State private var isTesting = false
    @State private var showingMLXSelection = false
    @State private var validatedMLXModel: MLXModelCatalogEntry?

    var body: some View {
        VStack(spacing: 16) {
            Text("Moteur sélectionné")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(label(for: selectedEngine))
                .font(.title2.bold())

            if selectedEngine == .appleIntelligence {
                appleIntelligenceTestSection
            }

            if selectedEngine == .mlxLocal {
                mlxTestSection
            }

            Button("Changer de moteur", action: onChangeEngine)
                .buttonStyle(.bordered)
        }
        .padding()
        .sheet(isPresented: $showingMLXSelection) {
            MLXModelSelectionView { chosen in
                validatedMLXModel = chosen
                showingMLXSelection = false
            }
        }
    }

    @ViewBuilder
    private var mlxTestSection: some View {
        if let validatedMLXModel {
            Text("Modèle actif : \(validatedMLXModel.displayName)")
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            Button("Changer de modèle MLX") {
                showingMLXSelection = true
            }
            .buttonStyle(.bordered)
        } else {
            Button("Choisir un modèle MLX") {
                showingMLXSelection = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var appleIntelligenceTestSection: some View {
        if let error = AppleIntelligenceProvider().availabilityError {
            Label("Indisponible : \(String(describing: error))", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            VStack(spacing: 8) {
                Button {
                    Task { await testGeneration() }
                } label: {
                    if isTesting {
                        ProgressView()
                    } else {
                        Text("Tester une génération")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting)

                if let appleIntelligenceResult {
                    switch appleIntelligenceResult {
                    case .success(let text):
                        Text(text)
                            .padding()
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    case .failure(let error):
                        Text("Erreur : \(String(describing: error))")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func testGeneration() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let text = try await AppleIntelligenceProvider().generate(prompt: "Dis bonjour en une phrase courte.")
            appleIntelligenceResult = .success(text)
        } catch let error as AppleIntelligenceError {
            appleIntelligenceResult = .failure(error)
        } catch {
            appleIntelligenceResult = .failure(.generationFailed(description: String(describing: error)))
        }
    }

    private func label(for option: AIEngineOption) -> String {
        switch option {
        case .appleIntelligence: "Apple Intelligence"
        case .mlxLocal: "Modèle local (MLX)"
        case .cloudBYOK: "Clé API personnelle"
        }
    }
}

#Preview {
    ContentView()
}
