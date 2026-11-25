//
//  DeviceLockedMessagesTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission NC, décision de Ben du 25/11) : « Poser une question à Triva » reste permis appareil
//  verrouillé ; quand le moteur ne peut pas travailler à cause du verrou (clé cloud illisible, modèle local, Apple
//  Intelligence), l'utilisateur lit « Déverrouille ton … pour utiliser ce moteur. », jamais « pas de clé ».
//

import AppIntents
import Foundation
import Security
import Testing
@testable import Triva

@MainActor
@Suite("Appareil verrouillé : messages")
struct DeviceLockedMessagesTests {
    private let missingKey = "Aucune clé API n'est enregistrée pour ce fournisseur. Ajoute-la dans les Réglages."

    @Test("Le texte nomme l'appareil : iPhone, iPad ou Mac")
    func messageNamesTheDevice() {
        #expect(DeviceLock.message(deviceName: "iPhone") == "Déverrouille ton iPhone pour utiliser ce moteur.")
        #expect(DeviceLock.message(deviceName: "iPad") == "Déverrouille ton iPad pour utiliser ce moteur.")
        #expect(DeviceLock.message(deviceName: "Mac") == "Déverrouille ton Mac pour utiliser ce moteur.")
    }

    @Test("L'appareil de cette machine de test est nommé sans erreur, et jamais verrouillé sous test")
    func currentDevice() {
        #if os(macOS)
        #expect(DeviceLock.deviceName == "Mac")
        #else
        #expect(["iPhone", "iPad"].contains(DeviceLock.deviceName))
        #endif
        #expect(DeviceLock.invitation == DeviceLock.message(deviceName: DeviceLock.deviceName))
        #expect(!DeviceLock.isLocked)
    }

    @Test("Seul -25308 (errSecInteractionNotAllowed) est « verrouillé » : une autre erreur du trousseau ne l'est pas")
    func onlyInteractionNotAllowedIsLocked() {
        #expect(LockedDeviceError.isLockedKeychain(KeychainAPIKeyStoreError.unexpectedStatus(errSecInteractionNotAllowed)))
        #expect(LockedDeviceError.isLockedKeychain(KeychainAPIKeyStoreError.unexpectedStatus(-25308)))
        #expect(!LockedDeviceError.isLockedKeychain(KeychainAPIKeyStoreError.unexpectedStatus(errSecItemNotFound)))
        #expect(!LockedDeviceError.isLockedKeychain(KeychainAPIKeyStoreError.unexpectedStatus(-34018)))
        #expect(!LockedDeviceError.isLockedKeychain(CancellationError()))
    }

    @Test("Clé illisible parce que verrouillé : l'invitation, jamais « aucune clé » ni un nom d'erreur")
    func lockedKeyIsTheInvitation() {
        let message = ChatViewModel.userFacingMessage(for: LockedDeviceError.deviceLocked)
        #expect(message == DeviceLock.invitation)
        #expect(message != missingKey)
        #expect(!message.contains("deviceLocked"))
    }

    @Test("Apple Intelligence indisponible : appareil verrouillé -> l'invitation ; déverrouillé -> le message habituel")
    func appleIntelligenceUnavailableWhileLocked() {
        let unavailable = ActiveAIProviderResolverError.appleIntelligenceUnavailable(.deviceNotEligible)
        #expect(ChatViewModel.userFacingMessage(for: unavailable, isDeviceLocked: true) == DeviceLock.invitation)
        #expect(ChatViewModel.userFacingMessage(for: unavailable, isDeviceLocked: false)
                == "Apple Intelligence n'est pas disponible sur cet appareil.")
        for error: AppleIntelligenceError in [.deviceNotEligible, .appleIntelligenceNotEnabled, .unavailableForOtherReason, .generationFailed(description: "x")] {
            #expect(ChatViewModel.userFacingMessage(for: error, isDeviceLocked: true) == DeviceLock.invitation)
        }
        // « Se prépare encore » ne s'explique pas par le verrou.
        #expect(ChatViewModel.userFacingMessage(for: AppleIntelligenceError.modelNotReady, isDeviceLocked: true)
                == "Apple Intelligence se prépare encore sur cet appareil. Réessaie dans quelques minutes.")
    }

    @Test("Modèle local qui ne démarre pas : appareil verrouillé -> l'invitation ; déverrouillé -> le message habituel")
    func localModelFailureWhileLocked() {
        #expect(ChatViewModel.userFacingMessage(for: MLXProviderError.unavailableInBackground, isDeviceLocked: true) == DeviceLock.invitation)
        #expect(ChatViewModel.userFacingMessage(for: MLXProviderError.generationFailed(description: "x"), isDeviceLocked: true) == DeviceLock.invitation)
        #expect(ChatViewModel.userFacingMessage(for: MLXProviderError.unavailableInBackground, isDeviceLocked: false)
                == HeadlessForegroundFallback.refusedMessage)
        // Pas de modèle choisi / téléchargement raté : aucun rapport avec le verrou.
        #expect(ChatViewModel.userFacingMessage(for: MLXProviderError.downloadFailed(description: "x"), isDeviceLocked: true)
                == "Le téléchargement du modèle local a échoué. Vérifie ta connexion et réessaie.")
    }

    @Test("L'état verrouillé n'est lu que pour les pannes ambiguës (une clé absente reste « clé absente »)")
    func lockStateIsReadOnlyForAmbiguousFailures() {
        var reads = 0
        let message = ChatViewModel.userFacingMessage(for: CloudBYOKError.missingAPIKey, isDeviceLocked: { reads += 1; return true }())
        #expect(message == missingKey)
        #expect(reads == 0)
    }

    @Test("Refus du modèle local au premier plan : appareil verrouillé -> l'invitation, sinon le refus habituel")
    func foregroundRefusal() {
        #expect(HeadlessForegroundFallback.refusal(isDeviceLocked: true, deviceName: "iPhone") == "Déverrouille ton iPhone pour utiliser ce moteur.")
        #expect(HeadlessForegroundFallback.refusal(isDeviceLocked: true, deviceName: "iPad") == "Déverrouille ton iPad pour utiliser ce moteur.")
        #expect(HeadlessForegroundFallback.refusal(isDeviceLocked: false, deviceName: "iPhone") == HeadlessForegroundFallback.refusedMessage)
    }

    @Test("Garde-fou : « Poser une question » reste permise appareil verrouillé, les clés ne sont pas affaiblies")
    func askStaysAllowedWhileLocked() {
        #expect(AskTrivaIntent.authenticationPolicy == .alwaysAllowed)
        #expect(KeychainAccessibility.whenUnlocked.attribute == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
