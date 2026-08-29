import SwiftUI

/// Implémentation de référence de la DA de Triva (validée le 2026-08-30 — voir `DESIGN.md`
/// à la racine du repo pour la description complète : couleurs, typographie, espacement,
/// règles Liquid Glass). Toute nouvelle vue doit s'aligner sur ce fichier et sur `DESIGN.md`.
///
/// Le badge s'adapte au moteur IA réellement sélectionné (`AIEngineOption`) : la promesse
/// "sur l'appareil" n'est vraie que pour Apple Intelligence et MLX local — avec une clé API
/// perso (BYOK cloud), les données partent bien vers le fournisseur choisi.
struct TrivaHomeReferenceView: View {
    var engine: AIEngineOption = .appleIntelligence

    @State private var query = ""

    private let suggestions = [
        "Résume l'actualité tech",
        "Explique-moi un concept",
        "Compare deux produits",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    searchSection
                    suggestionsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bonjour")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Que veux-tu explorer ?")
                .font(.system(size: 28, weight: .semibold))
        }
    }

    private var searchSection: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tint)
                    TextField("Pose ta question…", text: $query)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 6) {
                    Label(engine.privacyBadge.text, systemImage: engine.privacyBadge.icon)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .capsule)

                    Text(engine.privacyBadge.caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
            }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ESSAIE")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.tertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {}
                                .font(.subheadline)
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
        }
    }

}

#Preview("Apple Intelligence — clair") {
    TrivaHomeReferenceView(engine: .appleIntelligence)
}

#Preview("Apple Intelligence — sombre") {
    TrivaHomeReferenceView(engine: .appleIntelligence)
        .preferredColorScheme(.dark)
}

#Preview("MLX local") {
    TrivaHomeReferenceView(engine: .mlxLocal)
}

#Preview("Clé API perso (BYOK)") {
    TrivaHomeReferenceView(engine: .cloudBYOK)
}
