//
//  PasteImport.swift
//  Triva
//
//  K2 : du presse-papiers aux `DroppedItem`. Un collage prend EXACTEMENT le chemin d'un glisser-déposer
//  (`DroppedItem` → `DropPlan` → `FileAttachmentController.enqueue(areDeposits: true)`), donc les mêmes plafonds
//  (200 Mo, 50 Mo pour une image) et les mêmes refus.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated enum PasteImport {
    /// Les fournisseurs d'éléments du système, chargés comme le fait une zone de dépôt. Un élément illisible devient
    /// un refus, jamais un silence. Les images reçoivent un NOM UNIQUE (voir `uniquelyNamed`).
    ///
    /// Pas de `@concurrent` : le travail lourd (copie dans les dépôts) est fait par le système, dans la fermeture
    /// d'import de `DroppedItem`, hors du main actor ; ici on ne fait qu'attendre. Un `NSItemProvider` ne peut d'ailleurs
    /// pas changer d'acteur.
    static func items(from providers: [NSItemProvider], imagePrefix: String = "Image collée") async -> [DroppedItem] {
        var loaded: [DroppedItem] = []
        for provider in providers {
            loaded.append(await load(provider))
        }
        return uniquelyNamed(loaded, imagePrefix: imagePrefix)
    }

    private static func load(_ provider: NSItemProvider) async -> DroppedItem {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: DroppedItem.self) { result in
                switch result {
                case .success(let item): continuation.resume(returning: item)
                case .failure: continuation.resume(returning: .refused(.unreadable))
                }
            }
        }
    }

    /// Le système donne aux images collées ou choisies des noms génériques, identiques d'un collage au suivant : le
    /// dédoublonnage par nom du contrôleur refuserait le second (« Déjà joint »). Chaque image devient donc
    /// « <préfixe> <horodatage> (n).<extension> ». Les autres éléments sont rendus tels quels.
    static func uniquelyNamed(
        _ items: [DroppedItem],
        imagePrefix: String,
        date: Date = Date(),
        depositRoot: URL = AttachmentFileVault.defaultRootDirectory
    ) -> [DroppedItem] {
        var imageIndex = 0
        return items.map { item in
            guard case .image(let url) = item else { return item }
            let name = PastedImageNaming.fileName(
                prefix: imagePrefix, date: date, index: imageIndex, fileExtension: url.pathExtension.lowercased()
            )
            imageIndex += 1
            return .image(AttachmentFileVault.renameDeposit(url, to: name, rootDirectory: depositRoot))
        }
    }
}
