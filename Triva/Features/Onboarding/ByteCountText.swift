//
//  ByteCountText.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

/// Taille de fichier écrite en français (« 430 Mo », « 1,05 Go ») pour tous les écrans de modèles.
///
/// POURQUOI : `ByteCountFormatter` suit la langue de l'APP, pas celle de la phrase autour. Tant que
/// le projet se déclarait en anglais, il écrivait « 430 MB » et « 1,05 GB » (virgule française,
/// unités anglaises) à côté de « ~4,5 Go à télécharger » écrit à la main dans le catalogue (finding
/// Q3 n°41). Toute l'interface de Triva est en français : la langue du formateur est donc fixée ici,
/// au lieu de dépendre du réglage de langue de l'app ou du système.
nonisolated enum ByteCountText {
    private static let french = Locale(identifier: "fr_FR")

    static func string(forByteCount bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(french))
    }

    /// Variante pour les tailles non signées lues sur disque ou dans le catalogue.
    static func string(forByteCount bytes: UInt64) -> String {
        string(forByteCount: Int64(clamping: bytes))
    }
}
