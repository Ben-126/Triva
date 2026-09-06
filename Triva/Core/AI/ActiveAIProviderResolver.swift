//
//  ActiveAIProviderResolver.swift
//  Triva
//
//  Created by ben podrojsky on 06/09/2026.
//

import Foundation

/// Erreurs de résolution du moteur IA actif (0.7) — un cas distinct par
/// situation d'échec possible, pour que l'appelant puisse afficher un message
/// précis (et, la plupart du temps, renvoyer vers l'écran de sélection
/// correspondant : moteur en 0.3, modèle MLX en 0.5, fournisseur/modèle cloud
/// en 0.6).
enum ActiveAIProviderResolverError: Error, Sendable, Equatable {
    /// Aucun `AIEngineOption` n'a jamais été choisi (`AIEngineSettingsStore.selectedOption == nil`).
    case noEngineSelected
    /// Apple Intelligence choisi, mais indisponible pour la raison portée par `AppleIntelligenceError`.
    case appleIntelligenceUnavailable(AppleIntelligenceError)
    /// MLX local choisi, mais aucun modèle n'a jamais été validé (`MLXModelSelectionStore.selectedModelID == nil`).
    case noMLXModelSelected
    /// MLX local choisi, un `modelID` est stocké mais ne correspond plus à aucune entrée du catalogue fourni.
    case mlxModelNotInCatalog(modelID: String)
    /// Cloud BYOK choisi, mais aucune sélection fournisseur/modèle n'a jamais été stockée (`CloudProviderSelectionStore.selection == nil`).
    case noCloudSelectionStored
    /// Cloud BYOK choisi, une sélection est stockée mais `CloudProviderSelectionResolver.makeProvider` ne peut pas la résoudre
    /// (fournisseur supprimé du catalogue/des presets personnalisés, ou modèle Claude inconnu).
    case cloudSelectionUnresolvable(CloudProviderSelection)
}

/// Pont entre la sélection de moteur IA persistée (0.3/0.4/0.5/0.6, chacune
/// avec sa propre persistance déjà indépendante) et un `AIGenerating`
/// concret, prêt à être branché sur le pipeline recherche -> génération
/// (0.7).
///
/// Volontairement **pur et synchrone** : pas de `async`, aucun appel réseau ou
/// disque ici. En particulier, pour le cas `.mlxLocal`, ce résolveur ne
/// PRÉPARE jamais le `MLXProvider` retourné (pas d'appel à `prepare()`) —
/// préparer un modèle MLX déclenche potentiellement un téléchargement réseau
/// et un chargement disque lourds (voir `MLXProvider.prepare()`), ce qui
/// n'est pas le rôle d'un résolveur pur : ça rendrait ce type impossible à
/// tester unitairement sans réseau réel, et ça imposerait un point de
/// synchronisation arbitraire (attendre un téléchargement) à un simple aiguillage
/// de sélection. C'est à l'appelant du pipeline (0.7) d'appeler `prepare()`
/// lui-même sur le `MLXProvider` renvoyé avant de s'en servir — exactement
/// comme le reste du code le documente déjà pour `MLXProvider`.
enum ActiveAIProviderResolver {
    static func resolve(
        engineSettings: AIEngineSettingsStore,
        mlxSelection: MLXModelSelectionStore,
        mlxCatalog: [MLXModelCatalogEntry],
        cloudSelection: CloudProviderSelectionStore,
        customCloudPresets: [CloudProviderPreset],
        keyStore: any APIKeyStoring = KeychainAPIKeyStore()
    ) throws -> any AIGenerating {
        guard let option = engineSettings.selectedOption else {
            throw ActiveAIProviderResolverError.noEngineSelected
        }

        switch option {
        case .appleIntelligence:
            let provider = AppleIntelligenceProvider()
            if let availabilityError = provider.availabilityError {
                throw ActiveAIProviderResolverError.appleIntelligenceUnavailable(availabilityError)
            }
            return provider

        case .mlxLocal:
            guard let modelID = mlxSelection.selectedModelID else {
                throw ActiveAIProviderResolverError.noMLXModelSelected
            }
            guard let provider = MLXModelSelectionResolver.makeProvider(modelID: modelID, catalog: mlxCatalog) else {
                throw ActiveAIProviderResolverError.mlxModelNotInCatalog(modelID: modelID)
            }
            // Pas de `prepare()` ici : voir la documentation de tête de ce type.
            return provider

        case .cloudBYOK:
            guard let selection = cloudSelection.selection else {
                throw ActiveAIProviderResolverError.noCloudSelectionStored
            }
            guard let provider = CloudProviderSelectionResolver.makeProvider(
                for: selection,
                customPresets: customCloudPresets,
                keyStore: keyStore
            ) else {
                throw ActiveAIProviderResolverError.cloudSelectionUnresolvable(selection)
            }
            return provider
        }
    }
}
