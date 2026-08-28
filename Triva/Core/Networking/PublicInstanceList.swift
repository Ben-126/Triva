//
//  PublicInstanceList.swift
//  Triva
//
//  Created by ben podrojsky on 27/08/2026.
//

import Foundation

enum PublicInstanceListError: Error, Sendable, Equatable {
    case resourceMissing
    case invalidFormat
}

/// Charge la liste statique d'instances SearXNG publiques depuis
/// `Resources/searxng-instances.json`, dans l'ordre de priorité à essayer.
enum PublicInstanceList {
    static func load(bundle: Bundle = .main, resourceName: String = "searxng-instances") throws -> [URL] {
        guard let fileURL = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw PublicInstanceListError.resourceMissing
        }

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(InstanceListFile.self, from: data)
        let urls = decoded.instances.compactMap { URL(string: $0) }

        guard !urls.isEmpty else {
            throw PublicInstanceListError.invalidFormat
        }

        return urls
    }

    private struct InstanceListFile: Decodable {
        let instances: [String]
    }
}
