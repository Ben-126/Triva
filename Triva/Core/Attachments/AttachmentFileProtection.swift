//
//  AttachmentFileProtection.swift
//  Triva
//
//  K2 : protection de fichiers Apple (Data Protection) des copies du coffre sur iPhone et iPad. Ce sont des
//  documents de l'utilisateur.
//
//  Classe choisie : `completeUntilFirstUserAuthentication`, d'après la documentation « Encrypting Your App's Files » :
//  - `complete` : fichier inaccessible dès que l'écran se verrouille. Une lecture en cours, ou les fichiers encore
//    en file (lecture séquentielle de 15 fichiers au plus), échoueraient au verrouillage : exclu.
//  - `completeUnlessOpen` : seuls les fichiers DÉJÀ ouverts restent lisibles. L'extracteur rouvre les fichiers (PDFKit
//    relit des pages, la file en ouvre un nouveau à chaque tour) : exclu.
//  - `completeUntilFirstUserAuthentication` : chiffré tant que l'appareil n'a pas été déverrouillé une fois après le
//    démarrage, puis lisible même écran verrouillé : une lecture en cours survit au verrouillage.
//  C'est aussi la classe par défaut d'iOS, mais on l'applique EXPLICITEMENT : un futur entitlement
//  `default-data-protection` plus strict ne doit pas casser la lecture au verrouillage en silence.
//
//  Appliquée à chaque dossier et fichier créé ; un déplacement ou une copie ne garantit pas de garder la classe voulue.
//  Sans effet sur Mac (pas de Data Protection par classe, le disque est chiffré par FileVault).
//

import Foundation

nonisolated enum AttachmentFileProtection {
    static let level: FileProtectionType = .completeUntilFirstUserAuthentication

    /// Classe attendue sur la plateforme courante : `nil` quand elle n'a pas de sens (Mac).
    static var expectedLevel: FileProtectionType? {
        #if os(iOS)
        level
        #else
        nil
        #endif
    }

    /// Applique la classe. Renvoie `false` si le système refuse : la copie reste alors à la classe par défaut (la
    /// même, sauf entitlement plus lâche), l'ajout de la pièce jointe n'est pas bloqué pour autant.
    @discardableResult
    static func apply(to url: URL, fileManager: FileManager = .default) -> Bool {
        #if os(iOS)
        do {
            try fileManager.setAttributes([.protectionKey: level], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
        #else
        return true
        #endif
    }

    /// Classe lue sur le disque (tests).
    static func level(of url: URL, fileManager: FileManager = .default) -> FileProtectionType? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
    }
}
