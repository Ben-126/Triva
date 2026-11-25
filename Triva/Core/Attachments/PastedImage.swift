//
//  PastedImage.swift
//  Triva
//
//  K2 : une image collée (capture d'écran, « Copier l'image ») n'a pas de fichier d'origine. Elle reçoit un NOM
//  unique (le coffre dédoublonne par nom : deux « Image collée.png » se refuseraient l'une l'autre) et garde son
//  format d'origine, que Vision lit tel quel.
//

import Foundation

/// Format d'une image collée : identifiant de type du presse-papiers et extension du fichier déposé.
nonisolated struct PastedImageFormat: Sendable, Equatable {
    let typeIdentifier: String
    let fileExtension: String

    /// Du plus économe au plus lourd : une capture sort en PNG (sans perte, petit), TIFF est le repli non compressé.
    /// Tous sont dans `AttachmentKind.imageTypes` (testé).
    static let all: [PastedImageFormat] = [
        PastedImageFormat(typeIdentifier: "public.png", fileExtension: "png"),
        PastedImageFormat(typeIdentifier: "public.jpeg", fileExtension: "jpg"),
        PastedImageFormat(typeIdentifier: "public.heic", fileExtension: "heic"),
        PastedImageFormat(typeIdentifier: "public.tiff", fileExtension: "tiff"),
    ]

    /// Le meilleur format parmi ceux que le presse-papiers propose, `nil` si aucune image lisible.
    static func best(among typeIdentifiers: [String]) -> PastedImageFormat? {
        let available = Set(typeIdentifiers)
        return all.first { available.contains($0.typeIdentifier) }
    }
}

nonisolated enum PastedImageNaming {
    /// « Image collée 2026-11-18 14.32.05.png », suffixe « (2) »… pour les suivantes d'un même collage. Pas de « : »
    /// ni de « / » (interdits ou trompeurs dans un nom de fichier).
    /// - Parameter index: rang de l'image dans le collage, à partir de 0.
    /// - Parameter prefix: « Image collée » (presse-papiers) ou « Photo » (photothèque).
    static func fileName(
        prefix: String = "Image collée",
        date: Date,
        index: Int,
        fileExtension: String,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d %02d.%02d.%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        let suffix = index > 0 ? " (\(index + 1))" : ""
        return "\(prefix) \(stamp)\(suffix).\(fileExtension)"
    }
}
