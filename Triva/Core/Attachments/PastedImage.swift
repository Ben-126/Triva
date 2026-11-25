//
//  PastedImage.swift
//  Triva
//
//  K2 : une image collée (capture d'écran, « Copier l'image ») n'a pas de fichier d'origine. Elle reçoit un NOM
//  unique (le coffre dédoublonne par nom : deux « Image collée.png » se refuseraient l'une l'autre) et garde son
//  format d'origine, que Vision lit tel quel.
//

import Foundation
import Synchronization

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

/// Rang des images collées d'une MÊME seconde, pour toute l'app (X2). Le nom d'une image collée porte l'horodatage à la
/// seconde : deux collages dans la même seconde (⌘V deux fois de suite, deux fenêtres) donnaient le même nom, et le
/// dédoublonnage du contrôleur refusait le second (« Déjà joint »). Le compteur continue d'une demande à l'autre tant
/// que la seconde ne change pas, et repart à 0 à la seconde suivante : une image seule garde son nom court, sans suffixe.
nonisolated final class PastedImageNumbering: Sendable {
    /// Exemplaire de l'app : le compteur est commun aux fenêtres, aux collages du presse-papiers et à la photothèque.
    static let shared = PastedImageNumbering()

    private struct State {
        var second: Int64?
        var next = 0
    }

    private let state = Mutex(State())

    init() {}

    /// Réserve `count` rangs pour des images collées à `date` (au moins 1).
    /// - Returns: le rang de la première image (0 pour la première de la seconde), à passer à `PastedImageNaming.fileName`.
    func reserve(count: Int, at date: Date) -> Int {
        let second = Int64(date.timeIntervalSince1970.rounded(.down))
        return state.withLock { state in
            if state.second != second {
                state.second = second
                state.next = 0
            }
            let first = state.next
            state.next += max(count, 1)
            return first
        }
    }
}
