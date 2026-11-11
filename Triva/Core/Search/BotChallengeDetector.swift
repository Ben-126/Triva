//
//  BotChallengeDetector.swift
//  Triva
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation

/// Reconnaît une page de VÉRIFICATION anti-robot (Anubis, Cloudflare,
/// DDoS-Guard…) servie à la place de l'article demandé. Mission A5 (décision
/// de Ben, 2026-11-11), constat de l'éval A2 (Q12 : une page « Je m'assure que
/// vous n'êtes pas un robot » avait été lue comme du contenu, puis citée).
///
/// Pourquoi un détecteur : ces pages répondent en HTTP 200, en `text/html`, et
/// leur texte visible dépasse largement `ScrapeService.minimumContentCharacters`
/// (« Je m'assure que vous n'êtes pas un robot. Veuillez patienter… »). Rien
/// dans la chaîne de scraping ne les distinguait d'un vrai article, donc le
/// rédacteur recevait une « source » qui ne dit rien et la citait.
///
/// Trois familles d'indices, du plus au moins sûr :
/// 1. signatures du HTML brut qui n'existent QUE sur une page de défi
///    (`_cf_chl_opt`, balises `anubis_version` / `anubis_challenge`) ; contrairement
///    à `/cdn-cgi/challenge-platform/`, présent aussi sur des pages normales
///    protégées par Cloudflare, donc volontairement non retenu ;
/// 2. titres typiques (« Just a moment... », « Attention Required! »…) ;
/// 3. phrases du corps (« Checking your browser before accessing »…). Les familles
///    2 et 3 ne valent que quand le contenu est court (`maxChallengeContentCharacters`) :
///    un long article de Wikipédia sur Cloudflare ou sur Anubis, le dieu, cite
///    ces mots, et un article intitulé « DDoS-Guard » n'est pas un défi.
///
/// Pas de seuil de score : détection par présence d'un indice, comme le reste
/// du projet (aucun seuil absolu sur des scores). Écart assumé : une page qui
/// serait un vrai article ET contiendrait une signature de défi (le code
/// source d'une page de défi affiché dans un tutoriel, par exemple) serait
/// écartée ; un faux négatif est moins grave qu'une source vide citée.
nonisolated enum BotChallengeDetector {
    /// Au-delà, le texte n'est plus celui d'une page de défi (quelques lignes) :
    /// seules les signatures du HTML brut restent décisives.
    static let maxChallengeContentCharacters = 1200

    /// Vrai si la page est une vérification anti-robot. `html` est le HTML brut
    /// (signatures), `title` et `content` sortent de l'extraction du texte.
    static func isChallenge(html: String, title: String, content: String) -> Bool {
        if hasRawSignature(html) { return true }
        // Titres ET phrases du corps seulement sur contenu court : une page de défi tient en quelques
        // lignes, alors qu'un long article intitulé « DDoS-Guard » ou « Un instant » est un vrai article.
        guard content.count <= maxChallengeContentCharacters else { return false }
        if hasChallengeTitle(title) { return true }
        let text = normalized(title + " " + content)
        return bodyPhrases.contains { text.contains($0) }
    }

    // MARK: - Indices

    private static let rawSignatures = [
        "_cf_chl_opt", "id=\"anubis_version\"", "id=\"anubis_challenge\"", "id='anubis_version'", "id='anubis_challenge'",
    ]

    private static func hasRawSignature(_ html: String) -> Bool {
        // Les signatures sont dans le `<head>` ou en tête de `<body>` : inutile
        // de balayer 2 Mo de HTML pour une page légitime.
        let head = html.prefix(60_000).lowercased()
        return rawSignatures.contains { head.contains($0) }
    }

    /// Titres complets, comparés sans ponctuation finale : « Un instant… » est
    /// le titre français de Cloudflare, mais « Un instant de bonheur » est un
    /// vrai titre d'article, d'où l'égalité plutôt que `contains`.
    private static let exactTitles: Set<String> = [
        "just a moment", "un instant", "one moment please", "please wait", "attention required! | cloudflare", "attention required",
        "verifying you are human", "verification en cours", "security check", "ddos-guard",
    ]

    /// Titres qu'aucun vrai article ne porte tels quels, même suivis d'un nom de site.
    private static let titleFragments = [
        "making sure you're not a bot", "making sure you are not a bot", "je m'assure que vous n'etes pas un robot",
        "attention required! | cloudflare", "ddos-guard", "just a moment...",
    ]

    private static func hasChallengeTitle(_ title: String) -> Bool {
        let folded = normalized(title)
        let bare = folded.trimmingCharacters(in: CharacterSet(charactersIn: ".…!? ")).trimmingCharacters(in: .whitespaces)
        if exactTitles.contains(bare) || exactTitles.contains(folded) { return true }
        return titleFragments.contains { folded.contains($0) }
    }

    /// Phrases (minuscules, sans accents, apostrophe droite) des pages de défi
    /// connues. Anubis (Techaro) en français et en anglais, Cloudflare (y
    /// compris Turnstile), DDoS-Guard, Sucuri, et le blocage générique « trafic
    /// inhabituel ».
    private static let bodyPhrases = [
        "je m'assure que vous n'etes pas un robot", "making sure you're not a bot", "making sure you are not a bot",
        "protected by anubis", "protege par anubis", "techaro",
        "checking your browser before accessing", "checking if the site connection is secure",
        "enable javascript and cookies to continue", "veuillez activer javascript et les cookies pour continuer",
        "verify you are human", "verifying you are human", "performing security verification",
        "verification de securite en cours", "verifiez que vous etes un humain", "verification que vous etes un humain",
        "ddos-guard", "ddos protection by", "sorry, you have been blocked", "please complete the security check",
        "unusual traffic from your computer network",
    ]

    /// Minuscules, sans accents, apostrophe typographique ramenée à l'apostrophe
    /// droite : les pages françaises écrivent « n’êtes » avec ’ (U+2019).
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
            .lowercased()
    }
}
