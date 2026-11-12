//
//  UncachedImageLoaderTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import Triva

/// Faux client HTTP : renvoie des octets fixés et garde les requêtes reçues.
private nonisolated final class ImageStubRequester: HTTPDataRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let statusCode: Int
    private let body: Data

    init(statusCode: Int = 200, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _requests.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// PNG uni de `width` × `height` pixels, fabriqué avec ImageIO (aucun fichier de test).
private func makePNG(width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private let imageURL = URL(string: "https://images.example/photo.png")!

@Suite("UncachedImageLoader — images sans cache")
struct UncachedImageLoaderTests {
    @Test("La requête ignore tout cache local")
    func requestIgnoresLocalCache() {
        let request = UncachedImageLoader.request(for: imageURL)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.url == imageURL)
    }

    @Test("La session par défaut est éphémère et sans URLCache : rien n'est écrit dans Cache.db")
    func defaultSessionHasNoCache() {
        let configuration = URLSessionDataRequester.uncachedSession.configuration
        #expect(configuration.urlCache == nil)
        // Éphémère : pas de stockage disque (un `URLSessionConfiguration.default` aurait un URLCache).
        #expect(configuration.urlCredentialStorage == nil || configuration.urlCache == nil)
    }

    @Test("Une image plus grande que le plafond est réduite, sans déformation")
    func downsamplesLargeImage() async throws {
        let requester = ImageStubRequester(body: makePNG(width: 2_000, height: 1_000))
        let image = try await UncachedImageLoader(requester: requester).image(from: imageURL, maxPixelSize: 500)
        #expect(max(image.width, image.height) == 500)
        #expect(image.width == 2 * image.height)
        #expect(requester.requests.first?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("Une image plus petite que le plafond n'est jamais agrandie")
    func smallImageStaysSmall() async throws {
        let requester = ImageStubRequester(body: makePNG(width: 40, height: 30))
        let image = try await UncachedImageLoader(requester: requester).image(from: imageURL, maxPixelSize: 800)
        #expect(image.width == 40)
        #expect(image.height == 30)
    }

    @Test("Des octets qui ne sont pas une image donnent une erreur, pas un plantage")
    func garbageIsUndecodable() async {
        let requester = ImageStubRequester(body: Data("pas une image".utf8))
        await #expect(throws: RemoteImageError.undecodable) {
            _ = try await UncachedImageLoader(requester: requester).image(from: imageURL, maxPixelSize: 800)
        }
    }

    @Test("Un statut HTTP hors 2xx est un échec, même avec un corps qui ressemble à une image")
    func badStatusFails() async {
        let requester = ImageStubRequester(statusCode: 404, body: makePNG(width: 10, height: 10))
        await #expect(throws: RemoteImageError.badStatus(404)) {
            _ = try await UncachedImageLoader(requester: requester).image(from: imageURL, maxPixelSize: 800)
        }
    }
}
