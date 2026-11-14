//
//  APIKeysViewModelTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 03/09/2026.
//

import Testing
import Foundation
@testable import Triva

/// Faux magasin de clés, pour tester `APIKeysViewModel` sans toucher au vrai
/// Keychain. `@unchecked Sendable` : mutable côté test uniquement, appelé
/// séquentiellement dans chaque `@Test`.
private final class MockAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    var storedKey: String?
    private(set) var saveCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var lastSavedKey: String?
    /// Pannes du Trousseau à la demande, `nil` = tout va bien.
    var saveError: (any Error)?
    var deleteError: (any Error)?

    func apiKey(account: String) throws -> String? { storedKey }

    func save(apiKey: String, account: String) throws {
        if let saveError { throw saveError }
        saveCallCount += 1
        lastSavedKey = apiKey
        storedKey = apiKey
    }

    func deleteAPIKey(account: String) throws {
        if let deleteError { throw deleteError }
        deleteCallCount += 1
        storedKey = nil
    }
}

/// Faux validateur, pour tester `APIKeysViewModel` sans vrai appel réseau
/// vers Claude.
private final class MockAPIKeyValidator: APIKeyValidating, @unchecked Sendable {
    var shouldThrow: Bool
    private(set) var callCount = 0

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func validate(apiKey: String) async throws {
        callCount += 1
        if shouldThrow {
            throw APIKeyValidationError.invalidKey(description: "stub")
        }
    }
}

@MainActor
@Suite("APIKeysViewModel")
struct APIKeysViewModelTests {
    /// `UserDefaults` isolé par test — jamais `.standard`, pour ne pas
    /// toucher une vraie sélection persistée sur la machine qui exécute les
    /// tests (`deleteStoredKey()` peut l'effacer, voir tests dédiés plus bas).
    private func uniqueSelectionStore() -> CloudProviderSelectionStore {
        CloudProviderSelectionStore(userDefaults: TestDefaults.suite(named: "test.apiKeysVM.\(UUID().uuidString)")!)
    }

    @Test("Sauvegarde une clé valide et met à jour l'état")
    func saveValidKeySucceeds() async {
        let keyStore = MockAPIKeyStore()
        let validator = MockAPIKeyValidator()
        let viewModel = APIKeysViewModel(keyStore: keyStore, validator: validator, selectionStore: uniqueSelectionStore())

        await viewModel.save(rawKey: "sk-ant-test")

        #expect(viewModel.state == .saved)
        #expect(viewModel.hasStoredKey)
        #expect(keyStore.saveCallCount == 1)
        #expect(keyStore.lastSavedKey == "sk-ant-test")
    }

    @Test("N'enregistre pas une clé rejetée par le validateur")
    func saveInvalidKeyDoesNotStore() async {
        let keyStore = MockAPIKeyStore()
        let validator = MockAPIKeyValidator(shouldThrow: true)
        let viewModel = APIKeysViewModel(keyStore: keyStore, validator: validator, selectionStore: uniqueSelectionStore())

        await viewModel.save(rawKey: "sk-ant-bad")

        guard case .failed = viewModel.state else {
            Issue.record("État attendu : .failed, obtenu \(viewModel.state)")
            return
        }
        #expect(keyStore.saveCallCount == 0)
        #expect(!viewModel.hasStoredKey)
    }

    @Test("Refuse un champ vide sans appeler le validateur ni le Keychain")
    func saveEmptyKeyFailsLocally() async {
        let keyStore = MockAPIKeyStore()
        let validator = MockAPIKeyValidator()
        let viewModel = APIKeysViewModel(keyStore: keyStore, validator: validator, selectionStore: uniqueSelectionStore())

        await viewModel.save(rawKey: "   ")

        guard case .failed = viewModel.state else {
            Issue.record("État attendu : .failed, obtenu \(viewModel.state)")
            return
        }
        #expect(validator.callCount == 0)
        #expect(keyStore.saveCallCount == 0)
    }

    @Test("Supprime la clé stockée et réinitialise l'état")
    func deleteRemovesStoredKey() {
        let keyStore = MockAPIKeyStore()
        keyStore.storedKey = "sk-ant-existing"
        let viewModel = APIKeysViewModel(keyStore: keyStore, validator: MockAPIKeyValidator(), selectionStore: uniqueSelectionStore())
        #expect(viewModel.hasStoredKey)

        viewModel.deleteStoredKey()

        #expect(keyStore.deleteCallCount == 1)
        #expect(!viewModel.hasStoredKey)
        #expect(viewModel.state == .idle)
    }

    @Test("Détecte une clé déjà stockée à l'initialisation")
    func initDetectsExistingKey() {
        let keyStore = MockAPIKeyStore()
        keyStore.storedKey = "sk-ant-existing"

        let viewModel = APIKeysViewModel(keyStore: keyStore, validator: MockAPIKeyValidator(), selectionStore: uniqueSelectionStore())

        #expect(viewModel.hasStoredKey)
    }

    @Test("Supprimer la clé du fournisseur actuellement sélectionné efface aussi la sélection")
    func deletingKeyOfSelectedProviderClearsSelection() {
        let keyStore = MockAPIKeyStore()
        keyStore.storedKey = "sk-ant-existing"
        let selectionStore = uniqueSelectionStore()
        selectionStore.selection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")
        let viewModel = APIKeysViewModel(
            keyStore: keyStore,
            validator: MockAPIKeyValidator(),
            account: "claude",
            selectionStore: selectionStore
        )

        viewModel.deleteStoredKey()

        #expect(selectionStore.selection == nil)
    }

    @Test("Supprimer la clé d'un fournisseur non sélectionné laisse la sélection intacte")
    func deletingKeyOfOtherProviderKeepsSelection() {
        let keyStore = MockAPIKeyStore()
        keyStore.storedKey = "sk-groq-existing"
        let selectionStore = uniqueSelectionStore()
        selectionStore.selection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")
        let viewModel = APIKeysViewModel(
            keyStore: keyStore,
            validator: MockAPIKeyValidator(),
            account: "groq",
            selectionStore: selectionStore
        )

        viewModel.deleteStoredKey()

        #expect(selectionStore.selection == CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5"))
    }

    // MARK: - Échec du Trousseau (K5)

    @Test("Le Trousseau refuse la suppression : la clé reste affichée comme enregistrée, la sélection est gardée, l'échec est dit")
    func failedDeletionIsReportedAndChangesNothing() {
        let keyStore = MockAPIKeyStore()
        keyStore.storedKey = "sk-ant-existing"
        keyStore.deleteError = KeychainAPIKeyStoreError.unexpectedStatus(-25293)
        let selectionStore = uniqueSelectionStore()
        let selection = CloudProviderSelection(providerID: "claude", model: "claude-sonnet-5")
        selectionStore.selection = selection
        let viewModel = APIKeysViewModel(
            keyStore: keyStore, validator: MockAPIKeyValidator(), account: "claude", selectionStore: selectionStore
        )

        viewModel.deleteStoredKey()

        #expect(viewModel.hasStoredKey)
        #expect(viewModel.state == .failed(APIKeysViewModel.keychainDeleteFailureMessage))
        #expect(selectionStore.selection == selection)
        #expect(keyStore.storedKey == "sk-ant-existing")
    }

    @Test("Une clé valide que le Trousseau refuse d'enregistrer n'est pas présentée comme « invalide »")
    func keychainSaveFailureIsNotReportedAsAnInvalidKey() async {
        let keyStore = MockAPIKeyStore()
        keyStore.saveError = KeychainAPIKeyStoreError.unexpectedStatus(-25293)
        let viewModel = APIKeysViewModel(keyStore: keyStore, validator: MockAPIKeyValidator(), selectionStore: uniqueSelectionStore())

        await viewModel.save(rawKey: "sk-ant-valid")

        #expect(viewModel.state == .failed(APIKeysViewModel.keychainSaveFailureMessage))
        #expect(!viewModel.hasStoredKey)
    }
}
