//
//  UncachedRemoteImage.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import SwiftUI
import ImageIO

/// Erreurs de chargement d'une image distante. Aucun cas ne porte de texte venu du réseau.
nonisolated enum RemoteImageError: Error, Sendable, Equatable {
    /// Réponse HTTP hors 2xx.
    case badStatus(Int)
    /// Octets reçus qui ne forment pas une image lisible.
    case undecodable
}

/// Charge et décode une image distante SANS AUCUN cache, pour les vignettes et la visionneuse.
///
/// POURQUOI (décision de Ben du 2026-11-11) : `AsyncImage` passe par `URLSession.shared` et son
/// `URLCache`, qui écrit chaque image vue dans `Library/Caches/<bundle>/Cache.db`. Ces images
/// viennent de sites tiers choisis par la recherche : garder sur disque, après la session, la trace
/// de ce que la personne a regardé contredit la promesse de vie privée de Triva. `AsyncImage` ne
/// permet pas de choisir la session ; ce chargeur passe donc par `URLSessionDataRequester`, dont la
/// session est `.ephemeral` avec `urlCache = nil` (voir `URLSessionDataRequester.uncachedSession`),
/// et demande `.reloadIgnoringLocalCacheData` pour qu'aucune réponse ne soit relue.
///
/// DÉCODAGE par ImageIO, hors du fil principal (`@concurrent`), avec sous-échantillonnage à
/// `maxPixelSize` : `AsyncImage` décodait à la résolution d'origine (≈ 48 Mo pour 4 000 × 3 000
/// pixels), alors qu'une case de la grille n'a besoin que de quelques centaines de pixels. L'ancien
/// commentaire de `MediaThumbnail` appelait justement ce « chargeur ImageIO qui sous-échantillonne ».
nonisolated struct UncachedImageLoader: Sendable {
    /// Délai d'inactivité d'une image : au-delà, la case passe en échec plutôt que de tourner.
    static let requestTimeout: TimeInterval = 20

    /// Plafond de pixels (plus grand côté) d'une vignette de grille ou de ligne.
    static let thumbnailPixelSize = 800
    /// Plafond de pixels de la visionneuse plein écran (écran Retina d'iPad Pro).
    static let viewerPixelSize = 2_400

    private let requester: any HTTPDataRequesting

    init(requester: any HTTPDataRequesting = URLSessionDataRequester()) {
        self.requester = requester
    }

    /// Requête d'une image : jamais relue depuis un cache local.
    static func request(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
    }

    @concurrent
    func image(from url: URL, maxPixelSize: Int) async throws -> CGImage {
        let (data, response) = try await requester.data(for: Self.request(for: url))
        // Un `data:` (aperçus) répond sans statut HTTP : seule une vraie réponse HTTP est jugée.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteImageError.badStatus(http.statusCode)
        }
        return try Self.decode(data, maxPixelSize: maxPixelSize)
    }

    /// Décode `data` en réduisant le plus grand côté à `maxPixelSize` au plus (jamais d'agrandissement).
    static func decode(_ data: Data, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw RemoteImageError.undecodable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw RemoteImageError.undecodable
        }
        return image
    }
}

/// État d'une image en cours de chargement, même vocabulaire que `AsyncImagePhase`.
enum UncachedImagePhase {
    case loading
    case success(Image)
    case failure
}

/// Équivalent de `AsyncImage` sans cache disque ni mémoire du système (voir `UncachedImageLoader`).
/// Recharge quand l'URL change ; la tâche est annulée avec la vue.
struct UncachedRemoteImage<Content: View>: View {
    let url: URL
    let maxPixelSize: Int
    @ViewBuilder let content: (UncachedImagePhase) -> Content

    @State private var phase = UncachedImagePhase.loading

    var body: some View {
        content(phase)
            .task(id: url) {
                phase = .loading
                do {
                    let cgImage = try await UncachedImageLoader().image(from: url, maxPixelSize: maxPixelSize)
                    withAnimation(.easeOut(duration: 0.2)) {
                        phase = .success(Image(decorative: cgImage, scale: 1))
                    }
                } catch {
                    // Annulation (la vue disparaît) : rien à afficher. Toute autre erreur = échec.
                    if !Task.isCancelled { phase = .failure }
                }
            }
    }
}
