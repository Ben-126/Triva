//
//  CloudAIConsentRequest.swift
//  Triva
//
//  Created by ben podrojsky on 14/11/2026.
//

import Foundation

/// Lignes ajoutées à l'écran selon le fournisseur (textes `consent.cloud.extra.*`).
nonisolated enum CloudAIConsentExtra: Sendable, Equatable {
    case webSearch, media, openRouter, deepSeek, gemini, custom
}

/// Tout ce que l'écran de consentement doit afficher pour UN fournisseur. Valeur pure.
nonisolated struct CloudAIConsentRequest: Identifiable, Sendable, Equatable {
    let providerID: String
    /// `displayName` exact (tableau A.4 de `ecrans.md`).
    let displayName: String
    /// Nom d'hôte, pour un fournisseur personnalisé seulement.
    let host: String?
    let privacyURL: URL?
    let termsURL: URL?
    let extras: [CloudAIConsentExtra]

    var id: String { providerID }

    /// Titre : pour un fournisseur personnalisé, « Nom (hôte) ».
    var titleName: String {
        guard let host else { return displayName }
        return "\(displayName) (\(host))"
    }
}

/// Fabrique des demandes : table du tableau A.4 (vérifié le 2026-11-14).
nonisolated enum CloudAIConsentCatalog {
    static let claudeProviderID = "claude"

    private struct Links {
        let privacy: String
        let terms: String?
    }

    private static let links: [String: Links] = [
        "openai": Links(privacy: "https://openai.com/policies/eu-privacy-policy/", terms: "https://openai.com/policies/"),
        claudeProviderID: Links(privacy: "https://www.anthropic.com/legal/privacy", terms: nil),
        "gemini": Links(privacy: "https://policies.google.com/privacy", terms: "https://ai.google.dev/gemini-api/terms"),
        "perplexity": Links(privacy: "https://www.perplexity.ai/hub/legal/privacy-notice", terms: nil),
        "groq": Links(privacy: "https://groq.com/privacy-policy", terms: nil),
        "openrouter": Links(privacy: "https://openrouter.ai/privacy", terms: nil),
        "mistral": Links(privacy: "https://legal.mistral.ai/terms/privacy-policy", terms: nil),
        "deepseek": Links(privacy: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html", terms: nil),
        "xai": Links(privacy: "https://x.ai/legal/privacy-policy", terms: nil),
        "together": Links(privacy: "https://www.together.ai/privacy", terms: nil),
        "fireworks": Links(privacy: "https://fireworks.ai/privacy-policy", terms: nil),
        "cerebras": Links(privacy: "https://www.cerebras.ai/privacy-policy", terms: nil)
    ]

    /// `nil` si `providerID` est inconnu (ni Claude, ni catalogue, ni personnalisé fourni).
    /// `@MainActor` : `CloudProviderCatalog` est isolé au main actor (défaut du projet).
    @MainActor
    static func request(providerID: String, customPresets: [CloudProviderPreset]) -> CloudAIConsentRequest? {
        var extras: [CloudAIConsentExtra] = []
        if CloudWebSearchService(providerID: providerID) != nil { extras.append(.webSearch) }
        extras.append(.media)

        if providerID == claudeProviderID {
            return make(providerID, "Claude", host: nil, extras: extras)
        }
        if let preset = CloudProviderCatalog.presets.first(where: { $0.id == providerID }) {
            switch providerID {
            case "openrouter": extras.append(.openRouter)
            case "deepseek": extras.append(.deepSeek)
            case "gemini": extras.append(.gemini)
            default: break
            }
            return make(providerID, preset.displayName, host: nil, extras: extras)
        }
        if let custom = customPresets.first(where: { $0.id == providerID }) {
            extras.append(.custom)
            return make(providerID, custom.displayName, host: custom.baseURL.host(), extras: extras)
        }
        return nil
    }

    private static func make(
        _ providerID: String, _ name: String, host: String?, extras: [CloudAIConsentExtra]
    ) -> CloudAIConsentRequest {
        let known = links[providerID]
        return CloudAIConsentRequest(
            providerID: providerID,
            displayName: name,
            host: host,
            privacyURL: known.flatMap { URL(string: $0.privacy) },
            termsURL: known?.terms.flatMap { URL(string: $0) },
            extras: extras
        )
    }
}

/// Textes de `textes/ecrans.md` section A (FR). Le projet n'a pas de String Catalog : tout le
/// texte de l'app est en français littéral, la traduction anglaise n'est donc pas ajoutée ici
/// (à faire avec la localisation de l'app).
// À VALIDER (texte légal) — tout ce qui suit.
nonisolated enum CloudAIConsentText {
    static func title(_ r: CloudAIConsentRequest) -> String { "Envoyer tes questions à \(r.titleName)\u{00A0}?" }
    static func intro(_ r: CloudAIConsentRequest) -> String {
        "Avec ce moteur, c'est \(r.displayName) qui écrit les réponses. Pour ça, Triva lui envoie\u{00A0}:"
    }
    static let items = [
        "ta question\u{00A0};",
        "les messages précédents de la conversation en cours\u{00A0};",
        "des extraits des pages trouvées sur le web\u{00A0};",
        // La mention des PDF protégés dépend de la mission M10 ; texte A.1 repris tel quel.
        "le texte des fichiers que tu joins (sauf les PDF protégés contre la copie, qui restent sur ton appareil)."
    ]
    static func extra(_ extra: CloudAIConsentExtra, _ r: CloudAIConsentRequest) -> String {
        switch extra {
        case .webSearch:
            "\(r.displayName) peut aussi utiliser ta question pour chercher sur le web. Ces recherches sont facturées sur ton compte \(r.displayName)."
        case .media:
            "Pour les recherches d'images et de vidéos, ta question lui est aussi envoyée pour être reformulée."
        case .openRouter:
            "OpenRouter transmet ensuite tes données à l'entreprise qui fait tourner le modèle choisi. Chacune a ses propres règles."
        case .deepSeek:
            "Selon sa politique, DeepSeek conserve les données en Chine."
        case .gemini:
            "Avec une clé gratuite, Google peut utiliser ce que tu envoies pour améliorer ses produits, et des personnes peuvent le relire. N'envoie pas d'informations personnelles."
        case .custom:
            "Ce fournisseur a été ajouté par toi. Triva ne le connaît pas : vérifie ses conditions avant d'accepter."
        }
    }
    static func direct(_ r: CloudAIConsentRequest) -> String {
        "L'envoi part directement de ton appareil vers \(r.displayName), avec ta clé. Triva n'a pas de serveur : ces données ne passent jamais par Triva et Triva ne les voit pas."
    }
    static func terms(_ r: CloudAIConsentRequest) -> String {
        "\(r.displayName) les traite selon ses propres conditions et sa politique de confidentialité, qui fixent notamment combien de temps elles sont gardées et dans quel pays."
    }
    static let minor = "Si tu as moins de 15 ans, accepte avec un de tes parents."
    static let revoke = "Tu peux retirer cet accord quand tu veux dans Réglages > Clés API."
    static func privacyLink(_ r: CloudAIConsentRequest) -> String { "Politique de confidentialité de \(r.displayName)" }
    static let termsLink = "Conditions d'utilisation de l'API"
    static func noLink(_ r: CloudAIConsentRequest) -> String {
        "Triva ne connaît pas la politique de confidentialité de ce service. Cherche-la sur le site de \(r.host ?? r.displayName)."
    }
    static let allow = "Autoriser"
    static let cancel = "Annuler"
    static let cancelled = "Rien n'a été envoyé. Tu peux choisir un autre moteur dans les Réglages."
    /// Un envoi bloqué par la porte sans passer par l'écran (accord retiré entre-temps).
    static let blocked = "Rien n'a été envoyé : tu n'as pas autorisé l'envoi à ce fournisseur. Relance ta question pour être invité à le faire."

    // Révocation (A.2)
    static let revokeStatus = "Envoi autorisé"
    static let revokeButton = "Retirer l'accord"
    static func revokeConfirmTitle(_ name: String) -> String { "Retirer l'accord pour \(name)\u{00A0}?" }
    static func revokeConfirmBody(_ name: String) -> String {
        "Triva n'enverra plus rien à \(name) sans te redemander. Ta clé reste enregistrée. Ce que \(name) a déjà reçu dépend de sa politique : Triva ne peut pas l'effacer chez lui."
    }
    static let revokeConfirmAction = "Retirer"
    static let revokeFooter = "Avant le premier envoi à un fournisseur, Triva te demande ton accord. Tu peux le retirer ici."
}
