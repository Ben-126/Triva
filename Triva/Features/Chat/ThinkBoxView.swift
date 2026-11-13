//
//  ThinkBoxView.swift
//  Triva
//
//  Created by ben podrojsky on 02/10/2026.
//

import Foundation
import SwiftUI

// MARK: - Chronométrage (logique pure, testable)

/// Début et fin du raisonnement d'UN message, pour afficher « Réflexion…
/// 12 s » puis « A réfléchi pendant 12 s ».
///
/// Ni `ReasoningSegments` ni `ChatViewModel.Message` ne portent cette
/// information : le segmenteur est sans état et ne connaît pas l'heure.
/// Deux façons de la fournir à `ThinkBoxView` :
/// - l'appelant la tient (par exemple `ChatViewModel`, à chaque instantané
///   reçu : `timing = timing.updated(for: phase, at: .now)`) et la passe —
///   seule façon de la conserver dans l'historique ;
/// - il ne passe rien, et la vue la mesure elle-même pendant la session
///   (voir `ThinkBoxView.timing`).
///
/// Valeur immuable : `updated(for:at:)` renvoie une nouvelle valeur. Chaque
/// borne n'est écrite qu'UNE fois, au premier instantané qui la justifie :
/// rejouer le même instantané (ou réafficher la vue) ne la décale jamais.
nonisolated struct ReasoningTiming: Sendable, Equatable {
    let startedAt: Date?
    let endedAt: Date?

    init(startedAt: Date? = nil, endedAt: Date? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// Durée du raisonnement, ou `nil` si une borne manque. Une fin
    /// antérieure au début (horloge système recalée entre les deux) donne 0
    /// plutôt qu'une durée négative.
    var duration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        let interval = endedAt.timeIntervalSince(startedAt)
        guard interval.isFinite else { return nil }
        return max(0, interval)
    }

    /// Prend en compte la phase observée à `date`.
    ///
    /// - `.inProgress` fixe le début, s'il ne l'est pas encore.
    /// - `.completed` / `.interrupted` fixent la fin, et JAMAIS le début : un
    ///   message qui passe directement d'`.absent` à `.completed` (bloc
    ///   arrivé d'un coup, `</think>` orphelin des modèles « Thinking-2507 »,
    ///   message relu depuis l'historique) a une durée INCONNUE. Fixer le
    ///   début au même instant afficherait « 0 s », un chiffre faux.
    /// - `.absent` ne change rien.
    func updated(for phase: ReasoningPhase, at date: Date) -> ReasoningTiming {
        switch phase {
        case .absent:
            return self
        case .inProgress:
            guard startedAt == nil else { return self }
            return ReasoningTiming(startedAt: date, endedAt: nil)
        case .completed, .interrupted:
            guard endedAt == nil else { return self }
            return ReasoningTiming(startedAt: startedAt, endedAt: date)
        }
    }
}

// MARK: - Présentation (logique pure, testable)

/// Libellés, durées et règles de dépliage de `ThinkBoxView`, testables sans
/// interface.
///
/// `nonisolated` : fonctions pures sur des `String`, des `TimeInterval` et
/// `ReasoningPhase` (lui-même non isolé). Même convention que
/// `WeatherWidgetPresentation`.
///
/// Les durées sont mises en forme à la main (« 12 s », « 1 min 5 s ») plutôt
/// qu'avec `Duration.formatted` : le rendu de ce dernier dépend de la locale
/// et de la version du système, les tests ne pourraient pas le figer.
nonisolated enum ThinkBoxPresentation {

    /// Ce que VoiceOver annonce en premier, quel que soit l'état : la valeur
    /// (`accessibilityValue`) dit ensuite « replié » ou « déplié ».
    static let accessibilityLabel = "Raisonnement"

    /// Libellé d'un raisonnement terminé dont on ne connaît pas la durée
    /// (historique, bloc arrivé d'un coup) : sobre, sans chiffre inventé.
    static let unknownDurationTitle = "Raisonnement"

    /// Nombre maximum de caractères examinés, en partant de la FIN, pour
    /// l'aperçu d'une ligne. Une phrase de raisonnement fait en général 100 à
    /// 200 caractères ; 240 trouve presque toujours le début de la dernière.
    /// Cette borne rend le coût par token CONSTANT, indépendant de la
    /// longueur du raisonnement, qui peut atteindre des milliers de mots
    /// avec Qwen3 en mode thinking.
    static let previewScanLimit = 240

    /// Espace insécable entre un nombre et son unité (typographie française,
    /// même choix que `WeatherWidgetPresentation`) : « 12 » et « s » ne se
    /// retrouvent jamais sur deux lignes.
    static let numberUnitSeparator = "\u{00A0}"

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

    // MARK: Durées

    /// Secondes entières écoulées (arrondi vers le bas, comme un
    /// chronomètre), ou `nil` pour une valeur non finie. `Int(exactly:)` au
    /// lieu d'`Int(_:)`, qui ferait planter l'app sur une valeur hors plage.
    static func wholeSeconds(_ interval: TimeInterval) -> Int? {
        guard interval.isFinite else { return nil }
        return Int(exactly: max(0, interval).rounded(.down))
    }

    /// Temps écoulé à un battement du chronomètre de l'en-tête.
    ///
    /// Les dates d'un `TimelineView(.periodic(from: startedAt, by: 1))`
    /// tombent sur `startedAt + k s`. On arrondit au plus proche pour
    /// retrouver `k` exactement : si la date reçue arrivait à `k − ε` (une
    /// conversion d'horloge interne au système suffit), l'arrondi vers le bas
    /// de `wholeSeconds` afficherait `k − 1`, et le compteur bégaierait
    /// (« 6 s, 6 s, 8 s »). Les battements étant alignés sur `startedAt`,
    /// l'arrondi au plus proche ne peut pas, lui, avancer d'une seconde.
    static func elapsedAtTick(_ tick: Date, since startedAt: Date) -> TimeInterval {
        tick.timeIntervalSince(startedAt).rounded()
    }

    /// « 12 s », « 2 min », « 1 min 5 s ».
    static func durationText(seconds: Int) -> String {
        let total = max(0, seconds)
        let minutes = total / 60
        let remainder = total % 60
        guard minutes > 0 else { return "\(remainder)\(numberUnitSeparator)s" }
        guard remainder > 0 else { return "\(minutes)\(numberUnitSeparator)min" }
        return "\(minutes)\(numberUnitSeparator)min \(remainder)\(numberUnitSeparator)s"
    }

    /// « 12 secondes », « 1 minute 5 secondes » : en toutes lettres pour
    /// VoiceOver, qui lirait « s » comme une lettre. Singulier sous 2
    /// (« 1 seconde »), règle française.
    static func spokenDuration(seconds: Int) -> String {
        let total = max(0, seconds)
        let minutes = total / 60
        let remainder = total % 60
        let secondsText = spokenQuantity(remainder, singular: "seconde", plural: "secondes")
        guard minutes > 0 else { return secondsText }
        let minutesText = spokenQuantity(minutes, singular: "minute", plural: "minutes")
        return remainder > 0 ? "\(minutesText) \(secondsText)" : minutesText
    }

    private static func spokenQuantity(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value < 2 ? singular : plural)"
    }

    // MARK: Libellés

    /// Libellé de la ligne d'en-tête.
    ///
    /// - en cours : « Réflexion… », puis « Réflexion… 12 s » dès la première
    ///   seconde pleine (« 0 s » n'apporterait rien) ;
    /// - terminé : « A réfléchi pendant 12 s » (au moins 1 s : une réflexion
    ///   éclair n'est pas « 0 s »), ou `unknownDurationTitle` sans durée ;
    /// - interrompu : « Réflexion interrompue ».
    static func headerTitle(phase: ReasoningPhase, elapsed: TimeInterval?, duration: TimeInterval?) -> String {
        switch phase {
        case .absent:
            return ""
        case .inProgress:
            guard let elapsed, let seconds = wholeSeconds(elapsed), seconds >= 1 else { return "Réflexion…" }
            return "Réflexion… \(durationText(seconds: seconds))"
        case .completed:
            guard let duration, let seconds = wholeSeconds(duration) else { return unknownDurationTitle }
            return "A réfléchi pendant \(durationText(seconds: max(1, seconds)))"
        case .interrupted:
            return "Réflexion interrompue"
        }
    }

    /// « replié » / « déplié », suivi de l'état du raisonnement. VoiceOver lit
    /// donc « Raisonnement, replié, a réfléchi pendant 12 secondes, bouton ».
    /// Pas de compteur qui défile ici : la valeur ne suit pas les secondes,
    /// sinon VoiceOver pourrait la relire en boucle.
    static func accessibilityValue(phase: ReasoningPhase, isExpanded: Bool, duration: TimeInterval?) -> String {
        let state = isExpanded ? "déplié" : "replié"
        switch phase {
        case .absent:
            return state
        case .inProgress:
            return "\(state), réflexion en cours"
        case .completed:
            guard let duration, let seconds = wholeSeconds(duration) else { return state }
            return "\(state), a réfléchi pendant \(spokenDuration(seconds: max(1, seconds)))"
        case .interrupted:
            return "\(state), réflexion interrompue"
        }
    }

    static func accessibilityHint(isExpanded: Bool) -> String {
        isExpanded ? "Masque le raisonnement" : "Affiche le raisonnement complet"
    }

    // MARK: Aperçu d'une ligne

    /// La dernière phrase du raisonnement, blancs ramenés à une espace, ou
    /// `nil` s'il n'y a rien à montrer.
    ///
    /// C'est la phrase EN COURS d'écriture pendant le streaming. La vue la
    /// tronque à la fin (une ligne) : l'aperçu ne change donc à l'œil qu'au
    /// début d'une nouvelle phrase, pas à chaque token — c'est ce qui le
    /// garde discret.
    ///
    /// Coût borné : seuls les `scanLimit` derniers caractères sont examinés
    /// (`suffix` part de la fin, sans parcourir le début). Une frontière de
    /// phrase est un saut de ligne, ou `.`, `!`, `?`, `…` SUIVI d'un blanc —
    /// « 3.5 » ou « e.g. » au milieu d'un mot ne coupent rien. Si la fenêtre
    /// ne contient aucune frontière alors que le texte a été coupé, l'aperçu
    /// commence au milieu d'une phrase et le signale par « … ».
    static func previewLine(of reasoning: String, scanLimit: Int = previewScanLimit) -> String? {
        guard scanLimit > 0 else { return nil }
        let window = reasoning.suffix(scanLimit)
        let isWindowCut = window.startIndex != reasoning.startIndex
        let trimmed = window.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sentenceStart = startOfLastSentence(in: trimmed)
        let sentence = trimmed[sentenceStart...]
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !sentence.isEmpty else { return nil }

        let startsMidSentence = isWindowCut && sentenceStart == trimmed.startIndex
        return startsMidSentence ? "…" + sentence : sentence
    }

    /// Parcourt le texte à rebours depuis son dernier caractère. Le dernier
    /// caractère lui-même n'est jamais une frontière : un point final clôt la
    /// phrase courante, il n'en ouvre pas une nouvelle (vide).
    private static func startOfLastSentence(in text: String) -> String.Index {
        guard !text.isEmpty else { return text.startIndex }
        var cursor = text.index(before: text.endIndex)
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let candidate = text[previous]
            if candidate.isNewline || (sentenceTerminators.contains(candidate) && text[cursor].isWhitespace) {
                return cursor
            }
            cursor = previous
        }
        return text.startIndex
    }

    // MARK: Dépliage

    /// État par défaut, tant que l'utilisateur n'a rien touché.
    ///
    /// Décision de Ben (« un peu comme dans Claude chat ») : REPLIÉ pendant
    /// la réflexion comme une fois terminée. Seul `.interrupted` est déplié :
    /// le flux s'est arrêté avant `</think>`, et ce bloc peut être le SEUL
    /// texte de la réponse (petit modèle qui n'écrit jamais `</think>`, voir
    /// `ResponseStructureViolation.Kind.unclosedReasoningBlock`). Le replier
    /// afficherait une réponse vide.
    static func defaultExpansion(for phase: ReasoningPhase) -> Bool {
        phase == .interrupted
    }

    /// Vrai si une transition doit effacer le choix de l'utilisateur pour
    /// revenir à l'état par défaut de la nouvelle phase. Deux cas, une seule
    /// fois chacun :
    /// - fin de la réflexion (`.completed`) : un bloc déplié pendant la
    ///   réflexion se replie, la réponse prend la place ;
    /// - interruption : le bloc se déplie, même replié à la main avant
    ///   (même raison que `defaultExpansion`).
    static func resetsUserExpansion(from oldPhase: ReasoningPhase, to newPhase: ReasoningPhase) -> Bool {
        oldPhase != newPhase && (newPhase == .completed || newPhase == .interrupted)
    }
}

// MARK: - Vue

/// Bloc repliable du raisonnement visible (tâche 1.14), placé au-dessus du
/// corps de la réponse.
///
/// Port du bloc de réflexion de la version web d'origine, refait selon la décision de
/// Ben : « un peu comme dans Claude chat », sans coûter de temps ni de
/// performance.
/// - Pendant la réflexion : une seule ligne discrète, « Réflexion… 12 s »,
///   bloc replié, avec au plus un aperçu d'une ligne de la phrase en cours.
/// - À la fin : « A réfléchi pendant 12 s », un toucher déplie le texte
///   complet, un second le replie. Chevron natif, animation courte.
///
/// ## Écarts assumés vis-à-vis de `ReasoningPhase`
/// La documentation de `ReasoningPhase` décrit `.inProgress` comme DÉPLIÉ
/// avec un libellé animé : c'était le comportement de la version web d'origine. La décision plus
/// récente de Ben (replié, sans animation continue) l'emporte. `.completed`
/// (repli automatique, une fois) et `.interrupted` (déplié, jamais replié
/// automatiquement) suivent ce contrat. Voir
/// `ThinkBoxPresentation.defaultExpansion`.
///
/// ## Performance (exigence explicite de Ben)
/// - Le texte complet n'est construit QUE si le bloc est déplié
///   (`if isExpanded`) : replié, seul l'aperçu d'une ligne est calculé, sur
///   une fenêtre bornée (`ThinkBoxPresentation.previewLine`).
/// - Le chronomètre est un `TimelineView(.periodic(from:by: 1))` qui
///   n'enveloppe QUE le libellé : une mise à jour par seconde au plus, jamais
///   par token, et il disparaît dès la fin de la réflexion.
/// - Aucune animation continue : pas de `ProgressView`, pas de pulsation,
///   pas de shimmer. Le compteur qui avance est le seul signe d'activité.
/// - Texte brut (`Text(verbatim:)`) : jamais d'analyse Markdown sur le
///   raisonnement. Aucune mesure de géométrie.
///
/// ## Apparence
/// Ni verre ni carte : le bloc vit dans la bulle assistant, qui est déjà en
/// verre (du verre sur du verre est exclu). Texte `.secondary` en
/// `.footnote`, plus petit que le corps de la réponse.
///
/// ## Intégration (étape suivante, pas ici)
/// `ThinkBoxView(segments: ReasoningSegmenter.segment(message.text,
/// isStreaming: message.isStreaming))`, au-dessus du corps rendu par
/// `CitationView`. La vue ne produit rien en phase `.absent`.
struct ThinkBoxView: View {
    let reasoning: String
    let phase: ReasoningPhase
    /// Chronométrage fourni par l'appelant, qui fait alors foi. `nil` : la
    /// vue le mesure elle-même (`localTiming`), du moment où le bloc apparaît
    /// en cours jusqu'à la fin de la réflexion. Cette mesure locale vit avec
    /// la vue : un message relu plus tard affiche `unknownDurationTitle`,
    /// jamais une durée fausse.
    let timing: ReasoningTiming?

    /// Choix explicite de l'utilisateur, `nil` tant qu'il n'a rien touché :
    /// l'état affiché suit alors le défaut de la phase courante. Le défaut
    /// étant RECALCULÉ depuis la phase (et non copié dans un état), il reste
    /// juste même pour une transition survenue pendant que le bloc était
    /// absent (`.absent` → `.interrupted`).
    @State private var userExpansion: Bool?
    @State private var localTiming = ReasoningTiming()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(iOS)
    /// Cible tactile minimale des HIG. La ligne centre son libellé, ce qui
    /// laisse déjà de l'air sous lui : pas d'espacement en plus.
    private static let headerMinimumHeight: CGFloat = 44
    private static let contentSpacing: CGFloat = 0
    #else
    /// Pointeur précis sur Mac : pas de hauteur minimale, 8 pt sous le libellé.
    private static let headerMinimumHeight: CGFloat = 0
    private static let contentSpacing: CGFloat = 8
    #endif

    private static let toggleAnimation: Animation = .snappy(duration: 0.25)

    init(reasoning: String, phase: ReasoningPhase, timing: ReasoningTiming? = nil) {
        self.reasoning = reasoning
        self.phase = phase
        self.timing = timing
    }

    /// Raccourci d'intégration : directement depuis le résultat du segmenteur.
    init(segments: ReasoningSegments, timing: ReasoningTiming? = nil) {
        self.init(reasoning: segments.reasoning, phase: segments.reasoningPhase, timing: timing)
    }

    private var isExpanded: Bool {
        userExpansion ?? ThinkBoxPresentation.defaultExpansion(for: phase)
    }

    private var effectiveTiming: ReasoningTiming {
        timing ?? localTiming
    }

    var body: some View {
        if phase != .absent {
            VStack(alignment: .leading, spacing: Self.contentSpacing) {
                header
                if isExpanded {
                    fullText
                } else if phase == .inProgress, let preview = ThinkBoxPresentation.previewLine(of: reasoning) {
                    previewLine(preview)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                record(phase)
            }
            .onChange(of: phase) { oldPhase, newPhase in
                record(newPhase)
                if ThinkBoxPresentation.resetsUserExpansion(from: oldPhase, to: newPhase) {
                    userExpansion = nil
                }
            }
        }
    }

    // MARK: Sous-vues

    /// Toute la ligne est touchable (`Spacer` + `contentShape`), pas seulement
    /// le libellé. Un seul élément VoiceOver : « Raisonnement, replié, … ».
    private var header: some View {
        Button(action: toggleExpansion) {
            HStack(spacing: 4) {
                headerTitle
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .frame(minHeight: Self.headerMinimumHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ThinkBoxPresentation.accessibilityLabel)
        .accessibilityValue(ThinkBoxPresentation.accessibilityValue(
            phase: phase,
            isExpanded: isExpanded,
            duration: effectiveTiming.duration
        ))
        .accessibilityHint(ThinkBoxPresentation.accessibilityHint(isExpanded: isExpanded))
    }

    /// Le `TimelineView` n'existe que pendant la réflexion, et seulement une
    /// fois le début connu : il part de `startedAt` (`.periodic(from:)`), ses
    /// battements tombent donc pile sur les secondes écoulées.
    @ViewBuilder
    private var headerTitle: some View {
        if phase == .inProgress, let startedAt = effectiveTiming.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(ThinkBoxPresentation.headerTitle(
                    phase: .inProgress,
                    elapsed: ThinkBoxPresentation.elapsedAtTick(context.date, since: startedAt),
                    duration: nil
                ))
            }
        } else {
            Text(ThinkBoxPresentation.headerTitle(phase: phase, elapsed: nil, duration: effectiveTiming.duration))
        }
    }

    /// Masqué à VoiceOver : il répète un morceau du texte complet, accessible
    /// en dépliant, et changerait à chaque phrase.
    private func previewLine(_ preview: String) -> some View {
        Text(verbatim: preview)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityHidden(true)
    }

    /// Sélectionnable : copier un raisonnement est utile, surtout sur Mac.
    private var fullText: some View {
        Text(verbatim: reasoning)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func toggleExpansion() {
        let expanded = !isExpanded
        withAnimation(reduceMotion ? nil : Self.toggleAnimation) {
            userExpansion = expanded
        }
    }

    /// Mesure locale, seulement si l'appelant ne fournit pas de chronométrage.
    private func record(_ observedPhase: ReasoningPhase) {
        guard timing == nil else { return }
        localTiming = localTiming.updated(for: observedPhase, at: .now)
    }
}

// MARK: - Previews

private let previewReasoning = """
La question porte sur la hauteur réelle de la tour Eiffel, antennes comprises. \
La source 1 donne 330 mètres, la source 2 parle de 312 mètres sans les antennes. \
Je dois préciser ce qui est mesuré avant de donner un chiffre.
"""

#Preview("En cours — replié, chronomètre") {
    ThinkBoxView(
        reasoning: previewReasoning,
        phase: .inProgress,
        timing: ReasoningTiming(startedAt: .now.addingTimeInterval(-7))
    )
    .padding(20)
}

#Preview("Terminé — 12 s") {
    ThinkBoxView(
        reasoning: previewReasoning,
        phase: .completed,
        timing: ReasoningTiming(startedAt: .now.addingTimeInterval(-12), endedAt: .now)
    )
    .padding(20)
}

/// Message relu depuis l'historique : durée inconnue, aucun chiffre inventé.
#Preview("Terminé — durée inconnue, sombre") {
    ThinkBoxView(reasoning: previewReasoning, phase: .completed, timing: ReasoningTiming())
        .padding(20)
        .preferredColorScheme(.dark)
}

/// Flux arrêté avant `</think>` : déplié d'office, ce peut être le seul texte.
#Preview("Interrompu — déplié") {
    ThinkBoxView(reasoning: previewReasoning, phase: .interrupted, timing: ReasoningTiming())
        .padding(20)
}

/// Les quatre phases l'une sous l'autre (`ReasoningPhase` est
/// `CaseIterable` pour ce cas) : `.absent` ne produit rien.
#Preview("Toutes les phases — grand texte") {
    VStack(alignment: .leading, spacing: 24) {
        ForEach(ReasoningPhase.allCases, id: \.self) { phase in
            ThinkBoxView(
                reasoning: previewReasoning,
                phase: phase,
                timing: ReasoningTiming(startedAt: .now.addingTimeInterval(-75), endedAt: phase == .inProgress ? nil : .now)
            )
        }
    }
    .padding(20)
    .dynamicTypeSize(.xxxLarge)
}
