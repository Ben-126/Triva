//
//  AttachmentFileProtectionTests.swift
//  TrivaTests
//
//  K2 : protection de fichiers Apple des copies du coffre (iPhone, iPad). La classe est `completeUntilFirstUserAuthentication` :
//  une lecture en cours survit au verrouillage de l'écran (voir `AttachmentFileProtection`). Le Mac n'a pas cette
//  protection par classe : les vérifications d'attribut ne s'exécutent que sur iOS.
//

import Foundation
import Testing
@testable import Triva

@Suite("Coffre — protection de fichiers")
struct AttachmentFileProtectionTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("La classe retenue survit au verrouillage : ni `complete` ni `completeUnlessOpen`")
    func chosenLevel() {
        #expect(AttachmentFileProtection.level == .completeUntilFirstUserAuthentication)
        #expect(AttachmentFileProtection.level != .complete)
        #expect(AttachmentFileProtection.level != .completeUnlessOpen)
    }

    @Test("Sur Mac aucune classe n'est attendue ; sur iPhone et iPad, celle retenue")
    func expectedLevelPerPlatform() {
        #if os(iOS)
        #expect(AttachmentFileProtection.expectedLevel == .completeUntilFirstUserAuthentication)
        #else
        #expect(AttachmentFileProtection.expectedLevel == nil)
        #endif
    }

    @Test("Appliquer la protection à un fichier réussit, et le fichier reste lisible")
    func applyKeepsFileReadable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try Data("contenu".utf8).write(to: file)
        #expect(AttachmentFileProtection.apply(to: file))
        #expect(try String(contentsOf: file, encoding: .utf8) == "contenu")
    }

    /// Le simulateur n'applique ni ne relit la protection de fichiers (constaté le 25/11 sur iOS 27.0 : `setAttributes` réussit
    /// même sur un chemin absent, `attributesOfItem` ne rend aucune classe) : ces deux tests ne valent que sur un appareil.
    #if os(iOS) && !targetEnvironment(simulator)
    @Test("Appliquer la protection à un chemin absent échoue sans lever d'erreur, sur iOS")
    func applyToMissingPath() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)")
        #expect(!AttachmentFileProtection.apply(to: missing))
    }

    @Test("iOS : un dépôt de fichier, un dépôt d'octets et une copie du coffre portent la classe retenue")
    func vaultFilesCarryTheLevel() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("x".utf8).write(to: source)

        let depositFile = try AttachmentFileVault.stageDeposit(of: source, rootDirectory: root)
        let depositData = try AttachmentFileVault.stageDeposit(data: Data("y".utf8), named: "Image collée.png", rootDirectory: root)
        let vault = AttachmentFileVault(rootDirectory: root)
        let copy = try vault.copy(of: source)
        let adopted = try vault.adopt(deposit: depositFile)

        for url in [depositData, copy, adopted] {
            #expect(AttachmentFileProtection.level(of: url) == .completeUntilFirstUserAuthentication, "« \(url.lastPathComponent) »")
        }
        #expect(AttachmentFileProtection.level(of: vault.sessionDirectory) == .completeUntilFirstUserAuthentication)
    }
    #endif
}
