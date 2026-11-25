//
//  DeviceLock.swift
//  Triva
//
//  Chantier 2.1 (mission NC, décision de Ben du 25/11) : « Poser une question à Triva » (Siri, Raccourcis) reste permis
//  appareil VERROUILLÉ (`IntentAuthenticationPolicy.alwaysAllowed`, la valeur par défaut). Or les clés d'IA cloud sont au
//  trousseau `WhenUnlocked` (lecture refusée, -25308), le modèle local exige parfois le premier plan et Apple Intelligence
//  peut être indisponible. Dans ces cas l'utilisateur doit lire une invitation claire, jamais « pas de clé » ni un message
//  technique. Rien n'est affaibli : l'accessibilité des clés ne change pas.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Une clé n'a pas pu être lue parce que le trousseau est verrouillé (appareil verrouillé) : ce n'est NI une clé absente
/// NI une clé refusée. Levée par les fournisseurs cloud, dite par `ChatViewModel.userFacingMessage(for:)`.
nonisolated enum LockedDeviceError: Error, Sendable, Equatable {
    case deviceLocked

    /// L'erreur du trousseau dit-elle « verrouillé » (`errSecInteractionNotAllowed`, -25308) ?
    static func isLockedKeychain(_ error: any Error) -> Bool {
        if case KeychainAPIKeyStoreError.unexpectedStatus(let status) = error {
            return status == errSecInteractionNotAllowed
        }
        return false
    }
}

enum DeviceLock {
    /// Texte « à valider par Ben ». `deviceName` : « iPhone », « iPad » ou « Mac ».
    nonisolated static func message(deviceName: String) -> String {
        "Déverrouille ton \(deviceName) pour utiliser ce moteur."
    }

    /// Le mot de l'appareil : iPad sur iPad, Mac sur Mac, iPhone ailleurs (le Duo compte comme un iPhone).
    static var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// L'appareil est-il verrouillé à cet instant ? Les données protégées ne sont plus lisibles
    /// (`isProtectedDataAvailable`, la même propriété sur iOS, iPadOS et macOS).
    static var isLocked: Bool {
        // Les tests ne dépendent pas de l'écran de la machine qui les lance : ils passent l'état voulu en paramètre.
        if TrivaTestHost.isHostingUnitTests() { return false }
        #if os(macOS)
        return !NSApplication.shared.isProtectedDataAvailable
        #else
        return !UIApplication.shared.isProtectedDataAvailable
        #endif
    }

    /// L'invitation pour CET appareil.
    static var invitation: String { message(deviceName: deviceName) }
}
