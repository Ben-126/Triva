//
//  ImageRecognizerCancellationTests.swift
//  TrivaTests
//
//  W4-V : une lecture d'image annulée n'est PAS une image illisible, et l'image de préparation se lit vraiment.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import Vision
@testable import Triva

@Suite("Lecture d'image — annulation")
struct ImageRecognizerCancellationTests {
    @Test("Les erreurs d'annulation (Swift ou Vision) restent des annulations")
    func cancellationsStayCancellations() {
        #expect(VisionImageTextRecognizer.failure(for: CancellationError(), isTaskCancelled: false) is CancellationError)
        #expect(VisionImageTextRecognizer.failure(for: VisionError.requestCancelled("annulée"), isTaskCancelled: false) is CancellationError)
        #expect(VisionImageTextRecognizer.failure(for: URLError(.badURL), isTaskCancelled: true) is CancellationError)
    }

    @Test("Toute autre erreur reste « image illisible », sans détail du système")
    func otherErrorsAreInvalidImage() {
        let error = VisionImageTextRecognizer.failure(for: URLError(.badURL), isTaskCancelled: false)
        #expect((error as? AttachmentExtractionError) == .invalidImage)
    }

    @Test("Tâche déjà annulée : la vraie lecture lève CancellationError, pas « image illisible »")
    func cancelledTaskThrowsCancellation() async {
        let png = ImageRecognitionPreparationImage.pngData() ?? Data()
        let task = Task { try await VisionImageTextRecognizer().recognizeText(inImageData: png) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

@Suite("Préparation de la lecture d'image — image fabriquée")
struct ImageRecognitionPreparationImageTests {
    @Test("Le PNG fabriqué se décode à la taille annoncée")
    func pngDecodes() throws {
        let data = try #require(ImageRecognitionPreparationImage.pngData())
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == ImageRecognitionPreparationImage.width)
        #expect(image.height == ImageRecognitionPreparationImage.height)
        #expect(ImageRecognitionPreparationImage.lines.first?.contains(ImageRecognitionPreparationImage.expectedWord) == true)
    }

    @Test("Le vrai Vision lit l'image de préparation : la préparation réelle réussit")
    func realPreparationSucceeds() async throws {
        try await VisionImageTextRecognizer().prepareRecognition()
    }
}
