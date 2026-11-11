//
//  MLXProvider+Availability.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

extension MLXProvider {
    /// Le modèle `modelID` est-il ENTIÈREMENT sur le disque ? Sert au mode hors connexion (tâche 1.16) :
    /// savoir, sans réseau, si `prepare()` peut charger le modèle ou s'il lui faudrait le télécharger.
    ///
    /// Critère : au moins un fichier de poids `.safetensors` lisible dans le dossier du modèle
    /// (`modelStorageDirectory(for:)`). Le cache Hugging Face y range les poids dans `blobs/` et en
    /// expose des liens dans `snapshots/<révision>/` ; un téléchargement interrompu laisse un blob
    /// `.incomplete` SANS lien dans `snapshots/`, ou un lien cassé : `fileExists` suit le lien et
    /// répond non dans les deux cas. Un dossier vide ou seulement partiel n'est donc jamais compté.
    ///
    /// Écart assumé : on ne vérifie pas que TOUS les fichiers du modèle (tokenizer, config) sont là. Si
    /// l'un manque, `prepare()` échoue hors connexion et `ChatViewModel` ramène le même message
    /// (`OfflineBlockReason.localModelUnavailable`) : jamais une attente dans le vide.
    nonisolated static func hasDownloadedWeights(modelID: String, fileManager: FileManager = .default) -> Bool {
        hasDownloadedWeights(in: modelStorageDirectory(for: modelID), fileManager: fileManager)
    }

    /// Logique pure du critère, testable sur un dossier temporaire.
    nonisolated static func hasDownloadedWeights(in directory: URL, fileManager: FileManager = .default) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "safetensors" {
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return true }
        }
        return false
    }
}
