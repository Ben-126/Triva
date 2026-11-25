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
        let request = Self.makeRequest()

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: data)
        } catch {
            throw Self.failure(for: error, isTaskCancelled: Task.isCancelled)
        }
        try Task.checkCancellation()

        let lines = observations.compactMap { observation -> String? in
            guard let best = observation.topCandidates(1).first, best.confidence >= Self.minimumConfidence else { return nil }
            return best.string
        }
        return Self.assemble(lines: lines)
    }

    /// Réglages de la reconnaissance, communs aux vraies lectures et à la préparation (`prepareRecognition()`) : le
    /// système prépare le modèle pour ces réglages-là, une préparation avec d'autres ne servirait à rien.
    static func makeRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Triva est en français mais on lit aussi bien des captures anglaises : la langue est devinée.
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        return request
    }

    /// Erreur à remonter pour un échec de `perform`. Mesuré le 2026-11-25 : annulée, la requête de Vision lève
    /// `VisionError.requestCancelled` (PAS `CancellationError`) en moins d'une milliseconde, même en pleine préparation du
    /// modèle. Sans cette conversion, une pièce jointe retirée en cours de lecture serait prise pour une image illisible.
    static func failure(for error: any Error, isTaskCancelled: Bool) -> any Error {
        if error is CancellationError || isTaskCancelled { return CancellationError() }
        if case .requestCancelled = error as? VisionError { return CancellationError() }
        // Octets qui ne sont pas une image décodable (fichier tronqué, renommé…). Aucun détail du système
        // n'est repris : il pourrait citer le chemin du fichier.
        return AttachmentExtractionError.invalidImage
    }

    /// Lignes rognées, lignes vides retirées, jointes par un saut de ligne. Pure, testée.
    static func assemble(lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
