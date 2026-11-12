//
//  CalculationExpressionEvaluator.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

// Sorti de `CalculationWidgetService.swift` (mission E1c) : déplacement pur,
// aucun changement de code ni de comportement. L'évaluateur arithmétique (normalisation, tokenisation, shunting-yard, évaluation).

/// Élément de la pile d'opérateurs. Type séparé de `CalculationRPNItem`
/// parce que la pile, elle, doit pouvoir contenir une parenthèse gauche que
/// la sortie ne doit jamais contenir : deux types rendent la confusion
/// impossible.
nonisolated private enum CalculationStackItem: Sendable, Equatable {
    case binaryOperator(CalculationBinaryOperator)
    case unaryMinus
    case function(CalculationFunction)
    case leftParenthesis
}

// MARK: - Évaluateur

/// Évaluateur arithmétique 100 % local : tokeniseur + shunting-yard
/// (Dijkstra) + évaluation en notation polonaise inverse.
///
/// ## Pourquoi PAS `NSExpression` (arbitrage demandé par la mission)
/// 1. **Ce n'est pas un évaluateur arithmétique, c'est un moteur de
///    prédicats.** Il accepte les key-paths (`a.b.c`) et
///    `FUNCTION(receveur, "sélecteur")`, qui envoie un vrai message
///    Objective-C. Lui donner une chaîne produite par un LLM — donc
///    indirectement influençable par une page web scrapée — n'est pas un
///    risque qu'un gain de concision justifie.
/// 2. **La liste blanche serait nécessaire de toute façon.** La seule parade
///    connue est de valider l'entrée caractère par caractère AVANT de la lui
///    passer : on paierait le coût de la liste blanche sans le bénéfice d'un
///    parseur dont on maîtrise les cas limites.
/// 3. **Sa notation n'est pas celle qu'un modèle produit** (`^` n'est pas la
///    puissance, pas de `sqrt(x)`), et une expression invalide lève une
///    exception Objective-C — donc un crash, pas une erreur rattrapable. Un
///    plantage sur une entrée externe est interdit par le projet.
///
/// Le parseur maison coûte plus de lignes, mais chaque cas limite (division
/// par zéro, dépassement, parenthèses, caractère hostile) est atteignable
/// par un test unitaire — ce que la mission demande explicitement.
///
/// ## Convention du pourcentage
/// `%` est un opérateur POSTFIXE qui vaut « divisé par 100 », rien d'autre.
/// `15% * 240` vaut donc 36, ce qui couvre le cas du plan (« 15% de 240 »).
/// Conséquence assumée : `240 + 10%` vaut `240,1` et NON `264` — la « hausse
/// en pourcentage » des calculatrices de poche est contextuelle (elle prend
/// implicitement 10 % de l'opérande de gauche), donc imprévisible dès que
/// l'expression se complique. Une règle unique et vérifiable vaut mieux
/// qu'une règle intuitive sur deux exemples et fausse sur le troisième ; le
/// prompt demande au modèle la forme multiplicative.
/// Corollaire : `%` n'est JAMAIS le modulo. `10 % 3` est une erreur de
/// syntaxe, jamais un « 1 » silencieusement faux.
///
/// ## Aucune récursion
/// Les trois étapes sont itératives (boucles + piles explicites) :
/// `((((…))))` ne peut pas faire déborder la pile d'appels, seul
/// `maximumExpressionLength` borne l'entrée.
nonisolated enum CalculationExpressionEvaluator {
    /// Longueur maximale de l'expression NORMALISÉE. 256 caractères : une
    /// expression tirée d'une question en langage naturel tient très
    /// largement en dessous (« 15% * 240 » en fait 10). La borne ne refuse
    /// pas des calculs légitimes, elle plafonne le coût quand un petit modèle
    /// on-device part en boucle et renvoie des milliers de caractères.
    static let maximumExpressionLength = 256

    /// Entre `* /` (2) et `^` (4) : voir le trou de numérotation documenté
    /// sur `CalculationBinaryOperator`.
    static let unaryMinusPrecedence = 3

    /// Symboles acceptés en plus des chiffres et lettres ASCII. La virgule en
    /// est ABSENTE volontairement : elle est ambiguë (décimale en français
    /// dans `1,5`, milliers en anglais dans `1,500`) et se tromper change le
    /// résultat d'un facteur 1000. Un widget absent vaut mieux qu'un widget
    /// faux ; le prompt exige donc le point décimal.
    static let allowedSymbols: Set<Character> = [".", "+", "-", "*", "/", "^", "(", ")", "%", " "]

    /// Point d'entrée unique. Les étapes restent visibles pour être testées
    /// séparément, mais leur ordre n'est décidé qu'ici.
    static func evaluate(_ rawExpression: String) throws -> Double {
        let normalized = normalize(rawExpression)
        guard !normalized.isEmpty else { throw CalculationExpressionError.emptyExpression }
        guard normalized.count <= maximumExpressionLength else {
            throw CalculationExpressionError.expressionTooLong(length: normalized.count)
        }
        if let offending = normalized.first(where: { !isAllowed($0) }) {
            throw CalculationExpressionError.invalidCharacter(offending)
        }
        return try evaluateRPN(shuntingYard(tokenize(normalized)))
    }

    static func isAllowed(_ character: Character) -> Bool {
        if character.isASCII && (character.isNumber || character.isLetter) { return true }
        return allowedSymbols.contains(character)
    }

    // MARK: Normalisation

    /// Ramène les graphies réellement écrites par un modèle ou un humain à la
    /// grammaire unique du tokeniseur. Aucune réparation risquée : chaque
    /// substitution est un synonyme strict, jamais une devinette.
    ///
    /// Le passage en minuscules autorise `SQRT(16)` et `1E3`. Les espaces
    /// insécables deviennent des espaces ordinaires, ce qui rend `2 + 3`
    /// lisible quel que soit l'espace employé — mais NE rend pas `1 000 000`
    /// valide pour autant : un espace entre deux nombres reste une erreur, au
    /// même titre que la virgule et pour la même raison d'ambiguïté.
    static func normalize(_ expression: String) -> String {
        var result = expression.lowercased()
        for replacement in replacements {
            result = result.replacingOccurrences(of: replacement.source, with: replacement.target)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Un `struct` nommé plutôt qu'un tuple : un tableau statique de tuples
    /// se relit mal (`$0.0` / `$0.1`) et n'apporte rien ici.
    private struct Replacement: Sendable {
        let source: String
        let target: String
    }

    /// **L'ordre compte** : `**` doit passer avant toute substitution qui
    /// touche `*`, sinon `2**10` resterait deux multiplications de suite.
    private static let replacements: [Replacement] = [
        Replacement(source: "**", target: "^"),          // notation Python/JavaScript
        Replacement(source: "\u{00D7}", target: "*"),    // ×
        Replacement(source: "\u{22C5}", target: "*"),    // ⋅
        Replacement(source: "\u{00B7}", target: "*"),    // ·
        Replacement(source: "\u{00F7}", target: "/"),    // ÷
        Replacement(source: "\u{2215}", target: "/"),    // ∕
        Replacement(source: "\u{2212}", target: "-"),    // − moins typographique
        Replacement(source: "\u{2013}", target: "-"),    // –
        Replacement(source: "\u{2014}", target: "-"),    // —
        Replacement(source: "\u{221A}", target: "sqrt"), // √ : impose donc √(16), voir scanFunction
        Replacement(source: "\u{00A0}", target: " "),    // espace insécable
        Replacement(source: "\u{202F}", target: " "),    // espace fine insécable
        Replacement(source: "\u{2009}", target: " "),    // espace fine
        Replacement(source: "\n", target: " "),
        Replacement(source: "\t", target: " "),
    ]

    // MARK: Tokenisation

    /// Transforme la chaîne normalisée en jetons.
    ///
    /// `expectingOperand` est l'unique état du tokeniseur et c'est lui qui
    /// désambiguïse `-` : préfixe quand un opérande est attendu (début,
    /// après un opérateur, après `(`), binaire sinon. Le même drapeau rejette
    /// au passage toutes les suites impossibles (`2 + * 3`, `2 3`, `()`), ce
    /// qui évite un second passage de validation.
    ///
    /// Conséquence assumée : la multiplication implicite `2(3+4)` est
    /// REFUSÉE — l'accepter demanderait d'insérer un `*` fantôme, donc de
    /// deviner l'intention. Le prompt exige un `*` explicite.
    static func tokenize(_ normalized: String) throws -> [CalculationToken] {
        let characters = Array(normalized)
        var tokens: [CalculationToken] = []
        var index = 0
        var expectingOperand = true

        while index < characters.count {
            let character = characters[index]
            if character == " " {
                index += 1
                continue
            }

            if isDigit(character) || character == "." {
                guard expectingOperand else { throw CalculationExpressionError.unexpectedToken }
                let scanned = try scanNumber(characters, from: index)
                tokens.append(.number(scanned.value))
                index = scanned.nextIndex
                expectingOperand = false
                continue
            }

            if character.isLetter {
                guard expectingOperand else { throw CalculationExpressionError.unexpectedToken }
                let scanned = try scanFunction(characters, from: index)
                tokens.append(.function(scanned.function))
                index = scanned.nextIndex
                expectingOperand = true
                continue
            }

            try appendSymbol(character, to: &tokens, expectingOperand: &expectingOperand)
            index += 1
        }

        guard !tokens.isEmpty else { throw CalculationExpressionError.emptyExpression }
        // Finir en attendant un opérande, c'est finir sur un opérateur ou une
        // parenthèse ouvrante : `2 +`, `sqrt(`.
        guard !expectingOperand else { throw CalculationExpressionError.unexpectedToken }
        return tokens
    }

    /// Caractères d'un seul signe. Extrait de `tokenize` pour garder les deux
    /// fonctions courtes et l'imbrication faible.
    private static func appendSymbol(
        _ character: Character,
        to tokens: inout [CalculationToken],
        expectingOperand: inout Bool
    ) throws {
        switch character {
        case "(":
            guard expectingOperand else { throw CalculationExpressionError.unexpectedToken }
            tokens.append(.leftParenthesis)
            expectingOperand = true
        case ")":
            guard !expectingOperand else { throw CalculationExpressionError.unexpectedToken }
            tokens.append(.rightParenthesis)
            expectingOperand = false
        case "%":
            guard !expectingOperand else { throw CalculationExpressionError.unexpectedToken }
            tokens.append(.percent)
            expectingOperand = false
        case "+":
            // Plus unaire (`+5`, `2 * +3`) : neutre, aucun jeton émis. Une
            // expression réduite à « + » finit donc sans jeton du tout et
            // ressort en `emptyExpression`, ce qui reste un refus correct.
            if !expectingOperand {
                tokens.append(.binaryOperator(.add))
                expectingOperand = true
            }
        case "-":
            if expectingOperand {
                tokens.append(.unaryMinus)  // `expectingOperand` reste vrai : `--5` est licite
            } else {
                tokens.append(.binaryOperator(.subtract))
                expectingOperand = true
            }
        case "*", "/", "^":
            guard !expectingOperand else { throw CalculationExpressionError.unexpectedToken }
            tokens.append(.binaryOperator(try binaryOperator(for: character)))
            expectingOperand = true
        default:
            // Inatteignable via `evaluate` (la liste blanche a filtré avant),
            // atteignable en appelant `tokenize` directement : on refuse
            // explicitement plutôt que d'ignorer le caractère.
            throw CalculationExpressionError.invalidCharacter(character)
        }
    }

    private static func binaryOperator(for character: Character) throws -> CalculationBinaryOperator {
        switch character {
        case "*": return .multiply
        case "/": return .divide
        case "^": return .power
        default: throw CalculationExpressionError.invalidCharacter(character)
        }
    }

    /// `Character.isNumber` est vrai pour les chiffres non-ASCII (٣, ½…) : on
    /// borne à l'ASCII pour que `Double(literal)` ne voie jamais un caractère
    /// qu'il ne sait pas lire.
    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// Lit un littéral : chiffres, au plus un point décimal, exposant
    /// scientifique optionnel (`1e3`, `2.5e-4`) — un modèle en produit dès
    /// qu'on lui parle de grands nombres.
    private static func scanNumber(
        _ characters: [Character],
        from start: Int
    ) throws -> (value: Double, nextIndex: Int) {
        var index = start
        var hasDecimalPoint = false

        while index < characters.count {
            let character = characters[index]
            if isDigit(character) {
                index += 1
                continue
            }
            if character == "." {
                guard !hasDecimalPoint else {
                    throw CalculationExpressionError.malformedNumber(String(characters[start...index]))
                }
                hasDecimalPoint = true
                index += 1
                continue
            }
            // Un `e` sans exposant valide derrière n'appartient pas au nombre :
            // on s'arrête, la lettre sera refusée plus loin.
            if character == "e", let exponentEnd = scanExponent(characters, from: index) {
                index = exponentEnd
            }
            break
        }

        let literal = String(characters[start..<index])
        guard let value = Double(literal) else {
            throw CalculationExpressionError.malformedNumber(literal)
        }
        // `Double("1e999")` ne renvoie pas `nil` mais `+infini` (sémantique
        // strtod) : sans ce garde-fou, un littéral géant traverserait tout le
        // pipeline et s'afficherait comme un résultat.
        guard value.isFinite else { throw CalculationExpressionError.resultNotRepresentable }
        return (value, index)
    }

    /// Index juste après l'exposant si `characters[start]` en ouvre un bien
    /// formé (`e12`, `e+12`, `e-12`), `nil` sinon.
    private static func scanExponent(_ characters: [Character], from start: Int) -> Int? {
        var index = start + 1
        if index < characters.count, characters[index] == "+" || characters[index] == "-" {
            index += 1
        }
        guard index < characters.count, isDigit(characters[index]) else { return nil }
        while index < characters.count, isDigit(characters[index]) { index += 1 }
        return index
    }

    /// Lit un nom de fonction et EXIGE une parenthèse ouvrante derrière.
    ///
    /// L'exigence n'est pas cosmétique : sans parenthèses, `sqrt 16 + 9` est
    /// ambigu (racine de 25 ou racine de 16 plus 9 ?) et le shunting-yard
    /// donnerait silencieusement la première lecture, qui n'est pas celle
    /// attendue. Corollaire documenté : `√16`, normalisé en `sqrt16`, est
    /// refusé ; le prompt demande `sqrt(16)`.
    private static func scanFunction(
        _ characters: [Character],
        from start: Int
    ) throws -> (function: CalculationFunction, nextIndex: Int) {
        var index = start
        while index < characters.count, characters[index].isLetter { index += 1 }
        let name = String(characters[start..<index])
        guard let function = CalculationFunction(rawValue: name) else {
            throw CalculationExpressionError.unknownFunction(name)
        }

        var lookahead = index
        while lookahead < characters.count, characters[lookahead] == " " { lookahead += 1 }
        guard lookahead < characters.count, characters[lookahead] == "(" else {
            throw CalculationExpressionError.unexpectedToken
        }
        return (function, index)
    }

    // MARK: Shunting-yard

    /// Réordonne les jetons infixes en notation polonaise inverse.
    ///
    /// `%` part DIRECTEMENT en sortie : postfixe et de précédence maximale,
    /// il se lie toujours à l'opérande qui le précède, il n'a donc jamais à
    /// attendre sur la pile. Le moins unaire est empilé sans rien dépiler :
    /// préfixe, il n'a rien à sa gauche avec qui disputer un opérande.
    static func shuntingYard(_ tokens: [CalculationToken]) throws -> [CalculationRPNItem] {
        var output: [CalculationRPNItem] = []
        var stack: [CalculationStackItem] = []

        for token in tokens {
            switch token {
            case .number(let value):
                output.append(.number(value))
            case .percent:
                output.append(.percent)
            case .function(let function):
                stack.append(.function(function))
            case .unaryMinus:
                stack.append(.unaryMinus)
            case .binaryOperator(let op):
                popHigherPrecedence(before: op, from: &stack, into: &output)
                stack.append(.binaryOperator(op))
            case .leftParenthesis:
                stack.append(.leftParenthesis)
            case .rightParenthesis:
                try drainUntilLeftParenthesis(from: &stack, into: &output)
            }
        }

        while let top = stack.popLast() {
            guard top != .leftParenthesis else { throw CalculationExpressionError.unbalancedParentheses }
            output.append(rpnItem(for: top))
        }
        return output
    }

    private static func popHigherPrecedence(
        before next: CalculationBinaryOperator,
        from stack: inout [CalculationStackItem],
        into output: inout [CalculationRPNItem]
    ) {
        while let top = stack.last, shouldPop(top, before: next) {
            stack.removeLast()
            output.append(rpnItem(for: top))
        }
    }

    private static func shouldPop(_ top: CalculationStackItem, before next: CalculationBinaryOperator) -> Bool {
        switch top {
        case .leftParenthesis:
            return false
        case .function:
            // Invariant : une fonction est toujours immédiatement suivie de
            // `(` (voir `scanFunction`), donc une parenthèse gauche la
            // recouvre quand un opérateur binaire arrive. Le `false` explicite
            // documente l'invariant au lieu de le confier au hasard.
            return false
        case .unaryMinus:
            return unaryMinusPrecedence >= next.precedence && !next.isRightAssociative
        case .binaryOperator(let existing):
            if existing.precedence > next.precedence { return true }
            return existing.precedence == next.precedence && !next.isRightAssociative
        }
    }

    private static func drainUntilLeftParenthesis(
        from stack: inout [CalculationStackItem],
        into output: inout [CalculationRPNItem]
    ) throws {
        var foundLeftParenthesis = false
        while let top = stack.popLast() {
            if top == .leftParenthesis {
                foundLeftParenthesis = true
                break
            }
            output.append(rpnItem(for: top))
        }
        guard foundLeftParenthesis else { throw CalculationExpressionError.unbalancedParentheses }

        // Une fonction juste sous la parenthèse fermée s'applique à ce qu'elle
        // contenait : c'est ici, et seulement ici, qu'une fonction sort.
        if case .function(let function) = stack.last {
            stack.removeLast()
            output.append(.function(function))
        }
    }

    /// Non `throws` : `.leftParenthesis` est écarté par les deux appelants
    /// AVANT d'arriver ici. Le repli `.number(0)` est donc mort — mais
    /// préférable à un `fatalError` (interdit par le projet) et à une
    /// signature `throws` qui ferait gérer aux appelants un cas inexistant.
    private static func rpnItem(for item: CalculationStackItem) -> CalculationRPNItem {
        switch item {
        case .binaryOperator(let op): return .binaryOperator(op)
        case .unaryMinus: return .unaryMinus
        case .function(let function): return .function(function)
        case .leftParenthesis: return .number(0)
        }
    }

    // MARK: Évaluation

    /// Dépile la notation polonaise inverse. Chaque opération vérifie que sa
    /// sortie reste un `Double` FINI : un `nan` ou un `inf` qui se propage
    /// finirait affiché en « NaN », ce qui serait pire qu'un widget absent.
    static func evaluateRPN(_ items: [CalculationRPNItem]) throws -> Double {
        var stack: [Double] = []

        for item in items {
            switch item {
            case .number(let value):
                stack.append(value)
            case .unaryMinus:
                guard let value = stack.popLast() else { throw CalculationExpressionError.unexpectedToken }
                stack.append(-value)
            case .percent:
                guard let value = stack.popLast() else { throw CalculationExpressionError.unexpectedToken }
                stack.append(try finite(value / 100))
            case .function(let function):
                guard let value = stack.popLast() else { throw CalculationExpressionError.unexpectedToken }
                stack.append(try apply(function, to: value))
            case .binaryOperator(let op):
                guard let rhs = stack.popLast(), let lhs = stack.popLast() else {
                    throw CalculationExpressionError.unexpectedToken
                }
                stack.append(try apply(op, lhs: lhs, rhs: rhs))
            }
        }

        guard stack.count == 1, let result = stack.first else {
            throw CalculationExpressionError.unexpectedToken
        }
        return try finite(result)
    }

    private static func apply(_ function: CalculationFunction, to value: Double) throws -> Double {
        switch function {
        case .squareRoot:
            // Testé AVANT `squareRoot()`, qui renverrait `nan` : refuser
            // explicitement le domaine négatif dit mieux pourquoi.
            guard value >= 0 else { throw CalculationExpressionError.resultNotRepresentable }
            return try finite(value.squareRoot())
        }
    }

    private static func apply(
        _ op: CalculationBinaryOperator,
        lhs: Double,
        rhs: Double
    ) throws -> Double {
        switch op {
        case .add: return try finite(lhs + rhs)
        case .subtract: return try finite(lhs - rhs)
        case .multiply: return try finite(lhs * rhs)
        case .divide:
            // Couvre `0/0` (qui vaudrait `nan`) autant que `1/0` (`inf`).
            guard rhs != 0 else { throw CalculationExpressionError.divisionByZero }
            return try finite(lhs / rhs)
        case .power:
            // `pow` renvoie `inf` pour `0^-1` et `nan` pour `(-8)^(1/3)` :
            // les deux tombent sur `resultNotRepresentable`.
            return try finite(pow(lhs, rhs))
        }
    }

    private static func finite(_ value: Double) throws -> Double {
        guard value.isFinite else { throw CalculationExpressionError.resultNotRepresentable }
        return value
    }
}
