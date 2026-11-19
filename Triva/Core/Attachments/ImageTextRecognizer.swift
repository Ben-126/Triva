//
//  ImageTextRecognizer.swift
//  Triva
//
//  Chantier 2.2 (M6) : lecture du texte d'une image (capture d'écran, photo de page, tableau blanc), EN LOCAL.
//  Vision tourne sur l'appareil : l'image ne part nulle part, seul le texte reconnu devient une pièce jointe
//  (comme le texte d'un PDF).
//

import Foundation
import Vision

/// Point d'injection de la reconnaissance de texte (tests sans Vision, comme `AttachmentPreparing`).
nonisolated protocol ImageTextRecognizing: Sendable {
    /// Texte lu dans l'image, une ligne par ligne reconnue, dans l'ordre rendu par le système. Chaîne vide si rien
    /// de lisible. Lève `AttachmentExtractionError.invalidImage` si les octets ne sont pas une image lisible, ou
    /// `CancellationError`.
    func recognizeText(inImageData data: Data) async throws -> String
}

/// Implémentation réelle : `RecognizeTextRequest` (framework Vision, API Swift d'iOS/macOS 18+), voie « précise ».
///
/// `@concurrent` : la reconnaissance est un vrai calcul (réseau de neurones) ; sans lui, appelée depuis le main
/// actor, elle s'exécuterait sur le thread principal (`NonisolatedNonsendingByDefault`).
nonisolated struct VisionImageTextRecognizer: ImageTextRecognizing {
    /// Une ligne reconnue sous ce seuil de confiance est écartée : sur une photo sans texte, Vision invente
    /// volontiers des fragments (motifs, ombres) avec une confiance faible. Valeur de produit, à ajuster ici.
    static let minimumConfidence: Float = 0.3

    @concurrent
    func recognizeText(inImageData data: Data) async throws -> String {
        try Task.checkCancellation()
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Triva est en français mais on lit aussi bien des captures anglaises : la langue est devinée.
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Octets qui ne sont pas une image décodable (fichier tronqué, renommé…). Aucun détail du système
            // n'est repris : il pourrait citer le chemin du fichier.
            throw AttachmentExtractionError.invalidImage
        }
        try Task.checkCancellation()

        let lines = observations.compactMap { observation -> String? in
            guard let best = observation.topCandidates(1).first, best.confidence >= Self.minimumConfidence else { return nil }
            return best.string
        }
        return Self.assemble(lines: lines)
    }

    /// Lignes rognées, lignes vides retirées, jointes par un saut de ligne. Pure, testée.
    static func assemble(lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
