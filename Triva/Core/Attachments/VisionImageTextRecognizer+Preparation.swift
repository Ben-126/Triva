//
//  VisionImageTextRecognizer+Preparation.swift
//  Triva
//
//  W4-V : préparation de la lecture d'image (voir `ImageRecognitionPreparation.swift`) par une vraie reconnaissance précise
//  sur une image fabriquée, passée par `recognizeText(inImageData:)` : même voie, mêmes réglages que les vraies lectures
//  (mesuré : une préparation faite avec une image fabriquée rend la lecture suivante, par octets, immédiate).
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension VisionImageTextRecognizer: ImageRecognitionPreparing {
    /// `@concurrent` : plusieurs dizaines de secondes de calcul à froid, jamais sur le main actor.
    @concurrent
    func prepareRecognition() async throws {
        guard let png = ImageRecognitionPreparationImage.pngData() else {
            throw AttachmentExtractionError.invalidImage
        }
        let text = try await recognizeText(inImageData: png)
        // Une image fabriquée qui ne se lit plus ne prépare rien de fiable : échec, donc pas de marque « préparée ».
        guard text.localizedCaseInsensitiveContains(ImageRecognitionPreparationImage.expectedWord) else {
            throw AttachmentExtractionError.noTextInImage
        }
    }
}

/// L'image de préparation : texte noir sur fond blanc, français et anglais (la langue est devinée à la lecture), taille
/// d'une capture moyenne. Fabriquée à la demande, aucun fichier dans l'app.
nonisolated enum ImageRecognitionPreparationImage {
    static let width = 1_280
    static let height = 800
    /// Mot que la lecture doit retrouver pour que la préparation soit jugée réussie.
    static let expectedWord = "Triva"
    static let lines = [
        "Triva prépare la lecture des images",
        "Bonjour, ceci est une capture d'écran de 2026.",
        "The quick brown fox jumps over the lazy dog.",
        "Rendez-vous demain à 14 h 30, salle B12.",
        "func recognizeText(inImageData data: Data) async throws -> String",
        "Le chat dort sur le canapé pendant que la pluie tombe.",
        "Total : 42,50 € — merci de votre visite.",
        "Reading text from a screenshot, a photo or a page.",
    ]

    static func pngData() -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        for (index, text) in lines.enumerated() {
            guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { continue }
            context.textPosition = CGPoint(x: 40, y: CGFloat(height - 90 - index * 85))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
