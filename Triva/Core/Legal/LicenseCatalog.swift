//
//  LicenseCatalog.swift
//  Triva
//
//  Mission C3 (audit légal, constats 25 et 26 ; M5).
//

import Foundation

/// Données de l'écran « Licences et attributions », lues dans `Resources/licences-app.json`.
///
/// POURQUOI un JSON embarqué plutôt qu'un fichier Swift généré : les textes de licence pèsent
/// ~50 Ko ; le même fichier alimente la page web `docs/licences.md`, donc une seule source à
/// relire et à corriger ; et il se décode comme `mlx-models.json` (même mécanisme que le reste de
/// l'app). Le texte d'une licence est écrit UNE fois (`licenseTexts`) et référencé par `@apache-2.0`.
///
/// Les paquets marqués `embedded: false` (outils de build : swift-syntax, swift-argument-parser,
/// swift-asn1…) ne sont PAS dans l'app livrée : ils ne figurent pas à l'écran.
nonisolated struct LicenseCatalog: Sendable, Equatable {
    /// Familles affichées, dans cet ordre.
    enum Kind: String, CaseIterable, Sendable {
        case app
        case dependency
        case model
        case dataSource
        case discoverFeed

        // Validé par Ben le 2026-11-18 (texte légal)
        var title: String {
            switch self {
            case .app: "Triva"
            case .dependency: "Logiciels libres utilisés"
            case .model: "Modèles d'IA"
            case .dataSource: "Sources de données"
            case .discoverFeed: "Flux de Découvrir"
            }
        }

        /// Phrase sous la liste (facultative).
        var footer: String? {
            switch self {
            case .model: "Téléchargés à la demande, jamais livrés avec l'app."
            case .discoverFeed: "Les articles appartiennent à leurs auteurs."
            default: nil
            }
        }
    }

    /// Un lien lisible dans le détail (« Site », « Licence », « Conditions »…).
    struct Link: Hashable, Sendable {
        let label: String
        let url: URL
    }

    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let kind: Kind
        let name: String
        /// Une ligne sous le nom : licence, éventuellement version.
        let summary: String
        let copyright: String?
        /// Texte de la licence (intégral) : `nil` pour une licence qui n'est pas reproduite ici
        /// (Creative Commons : lien).
        let licenseText: String?
        /// Fichier NOTICE du paquet, quand il en a un (Apache 2.0 § 4(d)).
        let notice: String?
        /// Explications libres (origine d'un modèle, règle d'un flux, remerciement).
        let notes: [String]
        let links: [Link]
    }

    struct Section: Identifiable, Hashable, Sendable {
        let kind: Kind
        let entries: [Entry]
        var id: String { kind.rawValue }
    }

    let sections: [Section]

    var allEntries: [Entry] { sections.flatMap(\.entries) }

    /// Recherche par nom ou licence, sans tenir compte des accents ni de la casse. Vide : tout.
    func filtered(by query: String) -> [Section] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sections }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return sections.compactMap { section in
            let kept = section.entries.filter {
                $0.name.range(of: needle, options: options) != nil
                    || $0.summary.range(of: needle, options: options) != nil
            }
            return kept.isEmpty ? nil : Section(kind: section.kind, entries: kept)
        }
    }
}

// MARK: - Chargement

nonisolated extension LicenseCatalog {
    enum LoadError: Error, Equatable {
        case resourceMissing
        case invalidData
    }

    static func load(bundle: Bundle = .main, resourceName: String = "licences-app") throws -> LicenseCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw LoadError.resourceMissing
        }
        return try parse(data: Data(contentsOf: url))
    }

    static func parse(data: Data) throws -> LicenseCatalog {
        let raw: RawCatalog
        do {
            raw = try JSONDecoder().decode(RawCatalog.self, from: data)
        } catch {
            throw LoadError.invalidData
        }
        return raw.makeCatalog()
    }
}

// MARK: - Format du fichier

private nonisolated struct RawCatalog: Decodable {
    struct App: Decodable {
        let name: String
        let license: String
        let copyright: String?
    }

    struct Dependency: Decodable {
        let id: String
        let name: String
        let version: String?
        let license: String
        let copyright: String?
        let url: String?
        let licenseText: String?
        let notice: String?
        let includedVia: String?
        let embedded: Bool?
        let note: String?
    }

    struct Model: Decodable {
        let id: String
        let name: String
        let license: String
        let copyright: String?
        let origin: String?
        let conversion: String?
        let licenseText: String?
        let note: String?
    }

    struct DataSource: Decodable {
        let id: String
        let name: String
        let use: String?
        let license: String
        let attribution: String?
        let url: String?
        let licenseUrl: String?
        let terms: String?
        let note: String?
    }

    struct Feed: Decodable {
        let id: String
        let name: String
        let terms: String?
        let license: String?
        let rule: String?
    }

    let app: App
    let dependencies: [Dependency]
    let models: [Model]
    let dataSources: [DataSource]
    let discoverFeeds: [Feed]
    let licenseTexts: [String: String]

    func makeCatalog() -> LicenseCatalog {
        var sections: [LicenseCatalog.Section] = []
        func add(_ kind: LicenseCatalog.Kind, _ entries: [LicenseCatalog.Entry]) {
            if !entries.isEmpty { sections.append(.init(kind: kind, entries: entries)) }
        }

        add(.app, [
            .init(
                id: "app", kind: .app, name: app.name,
                summary: "Licence \(app.license)", copyright: app.copyright, licenseText: nil, notice: nil,
                // Titulaire du droit d'auteur : le même que dans LICENSE (validé par Ben le 2026-11-18).
                notes: ["Triva est un logiciel libre, publié sous licence \(app.license)."],
                links: []
            ),
        ])

        add(.dependency, dependencies.filter { $0.embedded != false }.map { dependency in
            var notes: [String] = []
            if let via = dependency.includedVia { notes.append("Inclus par : \(via).") }
            if let note = dependency.note { notes.append(note) }
            return LicenseCatalog.Entry(
                id: dependency.id, kind: .dependency, name: dependency.name,
                summary: [dependency.license, dependency.version].compactMap { $0 }.joined(separator: " · "),
                copyright: dependency.copyright,
                licenseText: resolveText(dependency.licenseText, license: dependency.license),
                notice: dependency.notice, notes: notes,
                links: Self.links([("Dépôt", dependency.url)])
            )
        })

        add(.model, models.map { model in
            var notes: [String] = []
            if let note = model.note { notes.append(note) }
            return LicenseCatalog.Entry(
                id: model.id, kind: .model, name: model.name,
                summary: model.license, copyright: model.copyright,
                licenseText: resolveText(model.licenseText, license: model.license),
                notice: nil, notes: notes,
                links: Self.links([("Modèle d'origine", model.origin), ("Conversion MLX", model.conversion)])
            )
        })

        add(.dataSource, dataSources.map { source in
            var notes: [String] = []
            if let attribution = source.attribution { notes.append(attribution) }
            if let use = source.use { notes.append("Utilisé pour : \(use).") }
            if let note = source.note { notes.append(note) }
            return LicenseCatalog.Entry(
                id: source.id, kind: .dataSource, name: source.name,
                summary: source.license, copyright: nil, licenseText: nil, notice: nil, notes: notes,
                links: Self.links([("Site", source.url), ("Licence", source.licenseUrl), ("Conditions", source.terms)])
            )
        })

        add(.discoverFeed, discoverFeeds.map { feed in
            LicenseCatalog.Entry(
                id: feed.id, kind: .discoverFeed, name: feed.name,
                summary: feed.license ?? "Flux publics", copyright: nil, licenseText: nil, notice: nil,
                notes: [feed.rule].compactMap { $0 },
                links: Self.links([("Conditions", feed.terms)])
            )
        })

        return LicenseCatalog(sections: sections)
    }

    /// `@apache-2.0` renvoie au texte partagé ; une licence « WITH Swift-exception » ajoute
    /// l'exception. Un texte écrit en clair est repris tel quel.
    private func resolveText(_ value: String?, license: String) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.hasPrefix("@") else { return value }
        let key = String(value.dropFirst()).lowercased()
        guard let name = licenseTexts.keys.first(where: { $0.lowercased() == key }),
              var text = licenseTexts[name]
        else { return nil }
        if license.localizedCaseInsensitiveContains("Swift-exception"), let exception = licenseTexts["Swift-exception"] {
            text += "\n\n" + exception
        }
        return text
    }

    private static func links(_ pairs: [(String, String?)]) -> [LicenseCatalog.Link] {
        pairs.compactMap { label, value in
            guard let value, let url = URL(string: value) else { return nil }
            return LicenseCatalog.Link(label: label, url: url)
        }
    }
}
