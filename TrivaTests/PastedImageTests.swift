//
//  PastedImageTests.swift
//  TrivaTests
//
//  K2 : une image collée (capture d'écran, « Copier l'image ») n'a pas de fichier d'origine. Elle reçoit un nom
//  UNIQUE (le dépôt refuse deux fichiers de même nom), garde son format (PNG, JPEG, HEIC, TIFF) et passe par les
//  dépôts du coffre comme un fichier glissé : mêmes plafonds, mêmes refus.
//

import Foundation
import Testing
@testable import Triva

@Suite("Image collée — nom, format, dépôt")
struct PastedImageTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PastedImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: Nom

    private var fixedDate: Date { Date(timeIntervalSince1970: 1_795_000_000) } // 2026-11-18 ~ UTC
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }

    @Test("Le nom contient l'horodatage à la seconde, l'extension du format et reste sur une ligne")
    func nameFormat() {
        let name = PastedImageNaming.fileName(date: fixedDate, index: 0, fileExtension: "png", timeZone: utc)
        #expect(name.hasPrefix("Image collée "))
        #expect(name.hasSuffix(".png"))
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("\n"))
        #expect(AttachmentKind(fileName: name) == .image)
    }

    @Test("Deux images d'un même collage, à la même seconde, ont des noms différents")
    func namesAreUniqueWithinOnePaste() {
        let names = (0..<4).map { PastedImageNaming.fileName(date: fixedDate, index: $0, fileExtension: "png", timeZone: utc) }
        #expect(Set(names.map { $0.lowercased() }).count == 4)
    }

    @Test("Le même collage deux secondes plus tard donne un autre nom")
    func namesDifferAcrossSeconds() {
        let first = PastedImageNaming.fileName(date: fixedDate, index: 0, fileExtension: "png", timeZone: utc)
        let second = PastedImageNaming.fileName(date: fixedDate.addingTimeInterval(2), index: 0, fileExtension: "png", timeZone: utc)
        #expect(first != second)
    }

    @Test("Le dédoublonnage du contrôleur ne refuse pas deux images collées successives")
    func uniqueNamesPassTheDuplicateRule() {
        let urls = (0..<2).map {
            URL(fileURLWithPath: "/dépôts/\(PastedImageNaming.fileName(date: fixedDate, index: $0, fileExtension: "png", timeZone: utc))")
        }
        let plan = FileAttachmentRules.plan(for: urls, existingFileNames: [], availableSlots: 5)
        #expect(plan.accepted.count == 2)
        #expect(plan.duplicateFileNames.isEmpty)
    }

    // MARK: Format

    @Test("Le meilleur format disponible : PNG avant JPEG avant HEIC avant TIFF")
    func formatPriority() {
        #expect(PastedImageFormat.best(among: ["public.tiff", "public.png"])?.fileExtension == "png")
        #expect(PastedImageFormat.best(among: ["public.tiff", "public.jpeg"])?.fileExtension == "jpg")
        #expect(PastedImageFormat.best(among: ["public.tiff", "public.heic"])?.fileExtension == "heic")
        #expect(PastedImageFormat.best(among: ["public.tiff"])?.fileExtension == "tiff")
    }

    @Test("Aucun format d'image lisible : nil")
    func noImageFormat() {
        #expect(PastedImageFormat.best(among: ["public.utf8-plain-text", "public.file-url"]) == nil)
        #expect(PastedImageFormat.best(among: []) == nil)
    }

    @Test("Chaque format retenu est une image que l'extracteur lit")
    func everyFormatIsReadable() {
        for format in PastedImageFormat.all {
            #expect(AttachmentKind(fileName: "x.\(format.fileExtension)") == .image, "« \(format.fileExtension) » doit être une image lisible")
        }
    }

    // MARK: Dépôt

    @Test("Des octets collés sont déposés sous leur nom, dans le dossier des dépôts")
    func stageDataCreatesDeposit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try AttachmentFileVault.stageDeposit(data: Data("octets".utf8), named: "Image collée test.png", rootDirectory: root)
        #expect(url.lastPathComponent == "Image collée test.png")
        #expect(url.path.contains("/\(AttachmentFileVault.depositsFolderName)/"))
        #expect(try Data(contentsOf: url) == Data("octets".utf8))
    }

    @Test("Le dépôt de données refuse au-delà du plafond de 200 Mo (même règle que les fichiers)")
    func stageDataRefusesOversize() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: AttachmentFileVaultError.tooLarge) {
            try AttachmentFileVault.stageDeposit(data: Data(count: 11), named: "gros.png", rootDirectory: root, maxByteCount: 10)
        }
        #expect(AttachmentFileVault.maxFileByteCount == 200 * 1024 * 1024)
    }

    @Test("Le nom d'un dépôt de données ne peut pas sortir du dossier du dépôt")
    func stageDataNameIsSafe() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try AttachmentFileVault.stageDeposit(data: Data("x".utf8), named: "../../evil.png", rootDirectory: root)
        #expect(url.lastPathComponent == "evil.png")
        #expect(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/\(AttachmentFileVault.depositsFolderName)/"))
    }

    @Test("Un dépôt de données est adopté puis lu comme un dépôt de fichier : image reconnue")
    func stagedImageIsClassifiedAsImage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try AttachmentFileVault.stageDeposit(data: Data("x".utf8), named: "Image collée a.png", rootDirectory: root)
        let item = DroppedItem.fromURL(url, depositRoot: root)
        // fromURL copie à nouveau (comme tout fichier reçu) ; le résultat reste une image.
        guard case .image = item else { Issue.record("attendu .image, reçu \(item)"); return }
    }
}

@Suite("Image collée — renommage d'un dépôt")
struct DepositRenameTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RenameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Un dépôt est renommé en place, contenu intact")
    func renamesInPlace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try AttachmentFileVault.stageDeposit(data: Data("img".utf8), named: "image.png", rootDirectory: root)
        let renamed = AttachmentFileVault.renameDeposit(url, to: "Photo 2026-11-25 05.55.12.png", rootDirectory: root)
        #expect(renamed.lastPathComponent == "Photo 2026-11-25 05.55.12.png")
        #expect(renamed.deletingLastPathComponent() == url.deletingLastPathComponent())
        #expect(try Data(contentsOf: renamed) == Data("img".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Un fichier qui n'est pas un dépôt n'est jamais renommé")
    func neverRenamesUserFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let userFile = root.appendingPathComponent("photo.png")
        try Data("x".utf8).write(to: userFile)
        #expect(AttachmentFileVault.renameDeposit(userFile, to: "autre.png", rootDirectory: root) == userFile)
        #expect(FileManager.default.fileExists(atPath: userFile.path))
    }

    @Test("Le nom du préfixe « Photo » donne un nom lisible comme image")
    func photoPrefix() {
        let name = PastedImageNaming.fileName(prefix: "Photo", date: Date(timeIntervalSince1970: 1_795_000_000), index: 1, fileExtension: "heic")
        #expect(name.hasPrefix("Photo "))
        #expect(name.hasSuffix("(2).heic"))
        #expect(AttachmentKind(fileName: name) == .image)
    }
}
