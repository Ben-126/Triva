//
//  LegalLinks.swift
//  Triva
//
//  Mission C3 (audit légal, constats 1, 5, 9).
//

import Foundation

/// Adresses et libellés des pages légales de Triva : UN seul fichier, pour que changer l'hébergement
/// (activation de GitHub Pages, domaine propre) ne demande de toucher qu'ici.
nonisolated enum LegalLinks {
    /// Base des pages publiques.
    // À VALIDER : URL définitive après activation de GitHub Pages
    static let baseURL = URL(string: "https://ben-126.github.io/Triva/")!

    /// Adresse de contact pour « Signaler un problème » (choisie par Ben le 2026-11-17, la même que
    /// dans les pages légales publiques). Si elle était vidée, le signalement ouvrirait la page
    /// d'assistance, jamais un e-mail adressé à personne.
    static let supportEmail = "benpodro@gmail.com"

    /// Les quatre pages publiques ouvertes depuis les Réglages.
    enum Page: String, CaseIterable, Sendable {
        case privacy
        case terms
        case legalNotice
        case support

        /// Nom de fichier publié (`docs/*.md` du dépôt, rendus en `.html` par GitHub Pages).
        var path: String {
            switch self {
            case .privacy: "confidentialite.html"
            case .terms: "conditions.html"
            case .legalNotice: "mentions-legales.html"
            case .support: "assistance.html"
            }
        }
    }

    static func url(for page: Page, base: URL = baseURL) -> URL {
        base.appending(path: page.path)
    }

    /// Destination de « Signaler un problème » : un e-mail préparé si l'adresse de support est
    /// définie, sinon la page d'assistance. Rien de la conversation n'est joint (B.3) : le corps ne
    /// contient que la consigne, l'utilisateur colle lui-même ce qu'il veut.
    static func reportDestination(supportEmail: String = supportEmail, base: URL = baseURL) -> URL {
        let address = supportEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return url(for: .support, base: base) }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: AboutText.reportMailSubject),
            URLQueryItem(name: "body", value: AboutText.reportMailBody),
        ]
        return components.url ?? url(for: .support, base: base)
    }
}

/// Textes de la section « À propos et mentions légales » (`textes/ecrans.md`, section E, et B.3).
nonisolated enum AboutText {
    // Validé par Ben le 2026-11-18 (texte légal) — tous les libellés de cette énumération.
    static let header = "À propos et mentions légales"

    static let privacyTitle = "Confidentialité"
    static let privacySubtitle = "Ce qui reste sur ton appareil, ce qui part et vers qui"
    static let termsTitle = "Conditions d'utilisation"
    static let termsSubtitle = "Les règles pour utiliser Triva"
    static let legalNoticeTitle = "Mentions légales"
    static let legalNoticeSubtitle = "Qui publie Triva"
    static let licensesTitle = "Licences et attributions"
    static let licensesSubtitle = "Logiciels libres, modèles et sources de données"
    static let supportTitle = "Assistance"
    static let supportSubtitle = "Questions fréquentes et contact"
    static let reportTitle = "Signaler un problème"
    static let reportSubtitle = "Une réponse fausse, choquante ou dangereuse"
    static let footer = "Triva est publiée par [Nom de l'éditeur]. Triva n'a ni serveur, ni compte, ni publicité."

    static let reportMailSubject = "Triva : signaler une réponse"
    static let reportMailBody = "Décris le problème (réponse fausse, choquante, dangereuse…). Tu peux coller la question et la réponse si tu veux : rien n'est ajouté sans toi."

    /// « Version {version} ({build}) ».
    static func versionLine(version: String, build: String) -> String {
        "Version \(version) (\(build))"
    }

    /// Version lue dans le `Info.plist` ; « — » si une clé manque (jamais un texte inventé).
    static func versionLine(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return versionLine(version: version, build: build)
    }
}
