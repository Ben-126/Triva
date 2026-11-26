//
//  HandoffPayload.swift
//  Triva
//
//  Chantier 2.3 (missions H1 et H2) : l'EN-TÊTE de ce que Triva propose à un autre appareil par Handoff (Continuité d'Apple).
//
//  L'en-tête (`userInfo`) ne porte que : le TEXTE de la question en cours (barre de saisie, ou à défaut la dernière
//  question), son genre (`typed`), et l'identifiant de la conversation, qui ANNONCE que la discussion entière peut être
//  demandée par les flux de continuation (décision de Ben, 2026-11-26 : questions, réponses et sources). Les réponses et
//  les sources ne sont JAMAIS dans l'en-tête : elles ne voyagent que par les flux (`HandoffStreamTransfer`), sur demande
//  de l'autre appareil. Jamais les fichiers joints, une clé ni le moteur choisi.
//
//  La doc d'Apple demande de garder `userInfo` sous 3 Ko et de le versionner : `v` vaut 1, et la taille est bornée
//  à `maxEncodedBytes`.
//

import Foundation

nonisolated struct HandoffPayload: Sendable, Equatable {
    /// Type d'activité, déclaré dans `NSUserActivityTypes` (`Config/Triva-iOS-Info.plist` et `Triva-macOS-Info.plist`).
    static let activityType = "com.benpodrojsky.Triva.search"

    /// Version du contenu : une autre valeur reçue est refusée.
    static let currentVersion = 1

    /// Longueur maximale du texte, en caractères visibles (avant la borne en octets).
    static let maxDraftCharacters = 1_200

    /// Borne STRICTE de la taille de `userInfo` une fois sérialisé en liste de propriétés binaire (la doc dit « under 3KB » :
    /// marge de sécurité ; le format binaire compte les caractères non ASCII sur 2 octets, c'est donc une mesure prudente).
    static let maxEncodedBytes = 2_500

    enum Key {
        static let version = "v"
        static let draft = "draft"
        static let conversationID = "conversationID"
        /// Absente = texte tapé ; `false` = c'est la dernière question de la conversation (déjà dans la discussion).
        static let draftIsTyped = "typed"
    }

    /// Texte assaini (`ExternalQuerySanitizer`), non vide, coupé aux bornes ci-dessus.
    let draft: String
    let conversationID: UUID?
    let draftIsTyped: Bool

    /// - Returns: `nil` s'il ne reste aucun texte à proposer (vide, blanc ou seulement des caractères invisibles).
    init?(draft: String?, conversationID: UUID? = nil, draftIsTyped: Bool = true) {
        guard let sanitized = ExternalQuerySanitizer.sanitize(draft) else { return nil }
        guard let fitted = Self.fitted(sanitized, conversationID: conversationID, draftIsTyped: draftIsTyped) else { return nil }
        self.draft = fitted
        self.conversationID = conversationID
        self.draftIsTyped = draftIsTyped
    }

    /// Lit une activité reçue. ENTRÉE EXTERNE : version inconnue, texte absent ou mal typé sont refusés ; le texte est
    /// assaini et recoupé comme à l'envoi ; un identifiant illisible est ignoré (le texte reste utilisable).
    init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              userInfo[Key.version] as? Int == Self.currentVersion,
              let draft = userInfo[Key.draft] as? String else { return nil }
        let conversationID = (userInfo[Key.conversationID] as? String).flatMap { UUID(uuidString: $0) }
        let draftIsTyped = userInfo[Key.draftIsTyped] as? Bool ?? true
        self.init(draft: draft, conversationID: conversationID, draftIsTyped: draftIsTyped)
    }

    /// Ce qui est confié à `NSUserActivity.addUserInfoEntries(from:)` : des types de liste de propriétés seulement.
    var userInfo: [String: Any] {
        Self.userInfo(draft: draft, conversationID: conversationID, draftIsTyped: draftIsTyped)
    }

    /// Taille du contenu sérialisé (liste de propriétés binaire), pour les tests et la coupe.
    var encodedByteCount: Int {
        Self.encodedByteCount(of: userInfo)
    }

    // MARK: Privé

    private static func userInfo(draft: String, conversationID: UUID?, draftIsTyped: Bool) -> [String: Any] {
        var info: [String: Any] = [Key.version: currentVersion, Key.draft: draft]
        if let conversationID { info[Key.conversationID] = conversationID.uuidString }
        if !draftIsTyped { info[Key.draftIsTyped] = false }
        return info
    }

    private static func encodedByteCount(of info: [String: Any]) -> Int {
        (try? PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).count) ?? Int.max
    }

    /// Le texte coupé à `maxDraftCharacters` caractères PUIS aux octets permis : des caractères lourds (emoji
    /// composés, plus de 20 octets chacun) feraient dépasser la borne bien avant 1 200 caractères. Recherche dichotomique
    /// du plus long préfixe qui tient : coupe par caractère entier, jamais au milieu d'un emoji, sans rien retirer de plus
    /// que nécessaire. Les blancs de fin sont retirés. `nil` si même un seul caractère ne tient pas.
    private static func fitted(_ text: String, conversationID: UUID?, draftIsTyped: Bool) -> String? {
        let characters = Array(text.prefix(maxDraftCharacters))
        func prefix(_ count: Int) -> String {
            String(characters.prefix(count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func fits(_ count: Int) -> Bool {
            let candidate = prefix(count)
            guard !candidate.isEmpty else { return false }
            return encodedByteCount(of: userInfo(draft: candidate, conversationID: conversationID, draftIsTyped: draftIsTyped)) < maxEncodedBytes
        }
        if fits(characters.count) { return prefix(characters.count) }
        // Plus grand `count` dans [1, characters.count - 1] qui tient ; la taille croît avec `count`.
        var low = 0
        var high = characters.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low >= 1 ? prefix(low) : nil
    }
}
