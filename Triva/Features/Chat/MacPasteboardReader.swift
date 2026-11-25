//
//  MacPasteboardReader.swift
//  Triva
//
//  K2 (Mac) : Cmd+V avec un fichier ou une image dans le presse-papiers. La lecture d'`NSPasteboard` se fait sur le
//  main actor et ne garde que des valeurs `Sendable` ; la copie vers les dépôts (jusqu'à 200 Mo) se fait hors du
//  main actor. La décision est `PasteboardClassifier`.
//

#if os(macOS)
import AppKit
import Foundation

nonisolated struct MacPastePayload: Sendable {
    var fileURLs: [URL] = []
    var imageData: Data?
    var imageFormat: PastedImageFormat?
    var text: String?
    /// Des octets d'un fichier que Triva ne lit pas (ancien .doc d'un mail…), sans adresse de fichier (mission W).
    var hasUnsupportedFileItem = false

    var snapshot: PasteboardSnapshot {
        PasteboardSnapshot(fileURLs: fileURLs, hasImage: imageData != nil, text: text, hasUnsupportedFileItem: hasUnsupportedFileItem)
    }

    /// Lit le presse-papiers. L'image n'est lue que s'il n'y a pas de fichier (le Finder y met l'icône du fichier).
    @MainActor
    static func read(from pasteboard: NSPasteboard = .general) -> MacPastePayload {
        var payload = MacPastePayload()
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        payload.fileURLs = urls ?? []
        payload.text = pasteboard.string(forType: .string)
        if payload.fileURLs.isEmpty {
            let identifiers = pasteboard.types?.map(\.rawValue) ?? []
            payload.hasUnsupportedFileItem = PasteboardClassifier.kind(ofTypeIdentifiers: identifiers) == .unsupportedFile
            if let format = PastedImageFormat.best(among: identifiers),
               let data = pasteboard.data(forType: NSPasteboard.PasteboardType(format.typeIdentifier)) {
                payload.imageData = data
                payload.imageFormat = format
            }
        }
        return payload
    }

    /// Les éléments à joindre pour une décision `.files` ou `.image`, copiés dans les dépôts (comme un dépôt).
    @concurrent
    func attachableItems(date: Date = Date(), numbering: PastedImageNumbering = .shared) async -> [DroppedItem] {
        if !fileURLs.isEmpty {
            return fileURLs.map { DroppedItem.fromURL($0) }
        }
        guard let imageData, let imageFormat else { return [] }
        let name = PastedImageNaming.fileName(
            date: date, index: numbering.reserve(count: 1, at: date), fileExtension: imageFormat.fileExtension
        )
        do {
            return [.image(try AttachmentFileVault.stageDeposit(data: imageData, named: name))]
        } catch AttachmentFileVaultError.tooLarge {
            return [.refused(.tooLarge)]
        } catch {
            return [.refused(.unreadable)]
        }
    }
}
#endif
