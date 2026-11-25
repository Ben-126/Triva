//
//  PhotoLibraryImport.swift
//  Triva
//
//  K2 (iPhone, iPad, iPhone Duo) : photos choisies dans la photothèque avec `PhotosPicker`. Le sélecteur tourne dans un
//  processus à part : l'utilisateur ne donne accès qu'aux photos qu'il choisit, sans demande d'autorisation de
//  toute la photothèque. Chaque photo prend le chemin d'un fichier déposé (`DroppedItem`), donc les mêmes plafonds
//  (200 Mo, 50 Mo pour une image) ; son texte est lu SUR L'APPAREIL par Vision, l'image n'est jamais envoyée.
//

#if os(iOS)
import PhotosUI
import SwiftUI

extension FileAttachmentController {
    /// Joint les photos choisies. Une photo illisible devient un refus expliqué sous les capsules.
    func receivePhotos(_ pickedItems: [PhotosPickerItem]) async {
        var loaded: [DroppedItem] = []
        for pickedItem in pickedItems {
            do {
                loaded.append(try await pickedItem.loadTransferable(type: DroppedItem.self) ?? .refused(.unreadable))
            } catch {
                loaded.append(.refused(.unreadable))
            }
        }
        receivePasted(PasteImport.uniquelyNamed(loaded, imagePrefix: "Photo"))
    }
}
#endif
