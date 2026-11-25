//
//  SearchLiveActivity.swift
//  TrivaWidgets
//
//  Chantier 2.1 (missions D puis I) : la présentation de l'activité en direct d'une recherche, sur l'écran verrouillé et
//  dans la Dynamic Island (iPhone et iPad ; ActivityKit n'existe pas sur Mac). L'extension LIT seulement : l'état vient
//  de l'app (`SearchActivityState`). DA : `DESIGN.md` (police système, couleurs sémantiques, aucun dégradé).
//
//  Mission I (essai réel de Ben sur iPhone 17, 25/11) :
//  - le symbole est celui de Triva (`TrivaSymbol`, le même dessin que la barre des menus du Mac), plus la loupe SF ;
//    l'étape reste dite par le TEXTE et, à la fin, par la coche ou le point d'alerte ;
//  - Dynamic Island étendue : le symbole est plus grand et écarté du bord par les marges prévues par l'API
//    (`contentMargins`), et le texte est aligné à gauche dans une seule région (plus de région centrale, qui se place
//    SOUS la caméra et centre son contenu) ;
//  - la question vient de l'ÉTAT de l'activité (`state.question`) : absente quand le réglage « Afficher la question »
//    est éteint, et alors rien ne la remplace.
//
//  La question est marquée `privacySensitive` : elle n'est masquée sur un écran verrouillé QUE si la personne a choisi
//  de masquer les contenus sensibles (doc WidgetKit, « Hide sensitive content »). Le toucher ouvre la conversation
//  (`triva://conversation/<id>`), ou simplement l'app.
//

#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

struct SearchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SearchActivityAttributes.self) { context in
            SearchActivityLockScreenView(state: context.state.displayed(isStale: context.isStale))
                .widgetURL(context.attributes.tapURL)
        } dynamicIsland: { context in
            let state = context.state.displayed(isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TrivaActivitySymbol(size: SearchActivityMetrics.expandedSymbol)
                        .accessibilityHidden(true)
                }
                .contentMargins([.leading, .top], SearchActivityMetrics.expandedMargin)
                DynamicIslandExpandedRegion(.trailing) {
                    SearchActivityStatusGlyph(state: state)
                        .font(.title2)
                }
                .contentMargins([.trailing, .top], SearchActivityMetrics.expandedMargin)
                DynamicIslandExpandedRegion(.bottom) {
                    SearchActivityTextBlock(state: state, questionFont: .callout)
                }
                .contentMargins([.leading, .trailing, .bottom], SearchActivityMetrics.expandedMargin)
            } compactLeading: {
                TrivaActivitySymbol(size: SearchActivityMetrics.compactSymbol)
                    .accessibilityLabel(state.statusText)
            } compactTrailing: {
                SearchActivityCompactTrailing(state: state)
            } minimal: {
                SearchActivityMinimal(state: state)
            }
            .widgetURL(context.attributes.tapURL)
        }
    }
}

/// Tailles et marges (grille 4/8/12/16/20/24/32/40 de `DESIGN.md`).
private enum SearchActivityMetrics {
    /// Symbole de l'île étendue : à côté de la caméra, plus grand que la loupe d'avant (≈ 17 pt).
    static let expandedSymbol: CGFloat = 32
    static let compactSymbol: CGFloat = 24
    static let minimalSymbol: CGFloat = 24
    static let lockScreenSymbol: CGFloat = 24
    /// Marge égale entre le contenu et le bord arrondi de l'île (HIG : marges concentriques, rien ne touche l'arrondi).
    static let expandedMargin: CGFloat = 16
}

/// Le symbole de Triva (asset `TrivaSymbol`, rendu en modèle : il prend la teinte). Taille fixe, jamais rognée.
private struct TrivaActivitySymbol: View {
    let size: CGFloat

    var body: some View {
        Image("TrivaSymbol")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.tint)
    }
}

/// La coche ou le point d'alerte des étapes finales ; rien pendant la recherche (le texte dit l'étape).
private struct SearchActivityStatusGlyph: View {
    let state: SearchActivityState

    var body: some View {
        switch state.stage {
        case .ready:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        case .interrupted, .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .thinking, .searching, .reading, .writing:
            EmptyView()
        }
    }
}

/// L'étape puis, si elle est montrée, la question : alignées à gauche, sur la même colonne.
private struct SearchActivityTextBlock: View {
    let state: SearchActivityState
    let questionFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.statusText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            if let question = state.question {
                Text(question)
                    .font(questionFont.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Écran verrouillé et bannière : le symbole et l'étape, puis la question sur deux lignes au plus (si elle est montrée).
private struct SearchActivityLockScreenView: View {
    let state: SearchActivityState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TrivaActivitySymbol(size: SearchActivityMetrics.lockScreenSymbol)
                .accessibilityHidden(true)
            SearchActivityTextBlock(state: state, questionFont: .callout)
            SearchActivityStatusGlyph(state: state)
                .font(.title3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// Île minimale (plusieurs activités) : le symbole de Triva pendant la recherche, la coche ou l'alerte à la fin.
private struct SearchActivityMinimal: View {
    let state: SearchActivityState

    var body: some View {
        Group {
            switch state.stage {
            case .ready:
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            case .interrupted, .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            case .thinking, .searching, .reading, .writing:
                TrivaActivitySymbol(size: SearchActivityMetrics.minimalSymbol)
            }
        }
        .accessibilityLabel(state.statusText)
    }
}

/// Dynamic Island compacte, côté droit : le nombre de sources lues, ou une coche quand la réponse est prête.
/// Sur iPhone Duo, en paysage ou avec deux activités, la Dynamic Island compacte est plus étroite : la doc Apple demande
/// alors de laisser vide le côté droit (le système le masque), le symbole de gauche suffit.
private struct SearchActivityCompactTrailing: View {
    let state: SearchActivityState

    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        if !isLimitedInWidth {
            // VoiceOver lit l'étape (« Lecture de 3 sources… »), pas « 3 » ni le nom d'un symbole.
            content.accessibilityLabel(state.statusText)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.stage {
        case .ready:
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
        case .interrupted, .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        case .thinking, .searching, .reading, .writing:
            if state.sourceCount > 0 {
                Text("\(state.sourceCount)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
