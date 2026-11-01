//
//  CalculationWidgetService.swift
//  Triva
//
//  Created by ben podrojsky on 19/09/2026.
//

import Foundation

// MARK: - Erreurs

/// Motifs d'échec de l'évaluation. Fermé, `Equatable` et `Sendable` : chaque
/// étape (normalisation, tokenisation, shunting-yard, évaluation) est ainsi
/// testable en vérifiant l'erreur EXACTE, pas seulement « ça a échoué ».
///
/// Ces erreurs ne remontent jamais à l'utilisateur : au niveau du service,
/// toutes veulent dire « pas de widget », comme `WeatherWidgetError`.
enum CalculationExpressionError: Error, Sendable, Equatable {
    case emptyExpression
    /// Garde-fou de coût, voir `CalculationExpressionEvaluator.maximumExpressionLength`.
    case expressionTooLong(length: Int)
    /// Porte le caractère fautif pour que le test vérifie LEQUEL a été refusé.
    case invalidCharacter(Character)
    /// Littéral illisible : `1.2.3`, `.`, `1e+`.
    case malformedNumber(String)
    /// Suite de lettres qui n'est pas une fonction connue : `foo(2)`.
    case unknownFunction(String)
    /// Jeton impossible à cet endroit : `2 + * 3`, `10 % 3`, `2 +`.
    case unexpectedToken
    case unbalancedParentheses
    /// Séparée de `resultNotRepresentable` : c'est la seule erreur
    /// d'arithmétique que l'utilisateur provoque volontairement.
    case divisionByZero
    /// Hors du domaine des `Double` finis : `9^9^9`, `1e999`, `sqrt(-1)`.
    case resultNotRepresentable
}

// MARK: - Grammaire

/// Opérateurs binaires reconnus. `precedence` et `isRightAssociative` sont
/// portés par l'opérateur lui-même : c'est le seul endroit où les deux
/// peuvent diverger si on en ajoute un, autant les y rendre inoubliables.
///
/// 1 pour `+ -`, 2 pour `* /`, 4 pour `^`. Le 3 est laissé LIBRE pour le
/// moins unaire (`CalculationExpressionEvaluator.unaryMinusPrecedence`) :
/// c'est ce trou qui fait que `-2^2` vaut `-4` et `-2*3` vaut `-6`, comme en
/// notation mathématique usuelle.
nonisolated enum CalculationBinaryOperator: Sendable, Equatable {
    case add
    case subtract
    case multiply
    case divide
    case power

    var precedence: Int {
        switch self {
        case .add, .subtract: return 1
        case .multiply, .divide: return 2
        case .power: return 4
        }
    }

    /// Seule la puissance est associative à droite : `2^3^2` vaut 512
    /// (`2^(3^2)`) et non 64.
    var isRightAssociative: Bool { self == .power }
}

/// Fonctions autorisées. Un enum à `rawValue` plutôt qu'un dictionnaire de
/// closures : la liste blanche des noms acceptés EST la définition du type,
/// impossible à contourner par une chaîne inattendue.
///
/// `sqrt` est la seule du périmètre 1.5. En ajouter (`abs`, `log`…) coûte une
/// ligne, mais élargit la surface qu'un modèle peut produire et qu'il faut
/// tester : on n'ouvre que ce qui est demandé.
nonisolated enum CalculationFunction: String, Sendable, Equatable, CaseIterable {
    case squareRoot = "sqrt"
}

/// Jeton produit par la tokenisation. Le moins unaire et le pourcentage sont
/// DISTINCTS des opérateurs binaires : le même `-` est tantôt l'un tantôt
/// l'autre selon le contexte, et `%` est postfixe quand tout le reste est
/// infixe ou préfixe. Trancher ici évite de re-décider à chaque étape.
nonisolated enum CalculationToken: Sendable, Equatable {
    case number(Double)
    case binaryOperator(CalculationBinaryOperator)
    case unaryMinus
    case percent
    case function(CalculationFunction)
    case leftParenthesis
    case rightParenthesis
}

/// Élément de la file de sortie en notation polonaise inverse. Pas de
/// parenthèses ici : c'est ce que le shunting-yard élimine.
nonisolated enum CalculationRPNItem: Sendable, Equatable {
    case number(Double)
    case binaryOperator(CalculationBinaryOperator)
    case unaryMinus
    case percent
    case function(CalculationFunction)
}

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

// MARK: - Formatage

/// Met le résultat en forme pour l'affichage français. Le vrai problème
/// résolu ici est le bruit binaire : `240 * 0.15` vaut `36.000000000000004`
/// en `Double`, et l'afficher décrédibiliserait instantanément le widget.
nonisolated enum CalculationResultFormatter {
    /// Locale FIXE plutôt que `Locale.current` : toute l'interface est en
    /// français (DESIGN.md). Sur un appareil réglé en anglais, `.current`
    /// afficherait « 36.5 » au milieu d'une phrase française, avec un
    /// séparateur décimal différent du reste de l'app.
    static let displayLocale = Locale(identifier: "fr_FR")

    /// 10 décimales maximum : c'est ce seuil, et lui seul, qui fait
    /// disparaître le bruit (`36.000000000000004` arrondi à 10 décimales vaut
    /// exactement 36, et `NumberFormatter` supprime les zéros de fin). Mesuré :
    /// on garde `1/3 -> 0,3333333333` et `123456789012345` intact, là où un
    /// plafond en chiffres SIGNIFICATIFS (essayé à 12) tronquait ce dernier en
    /// `123 456 789 012 000`.
    static let maximumFractionDigits = 10

    /// Au-delà : notation scientifique. 1e15 est juste sous 2^53 ≈ 9,007e15,
    /// limite au-delà de laquelle un `Double` ne représente plus tous les
    /// entiers — afficher 20 chiffres dont les derniers sont faux serait
    /// mentir, et 300 chiffres (`1e300`) serait illisible.
    static let scientificUpperBound = 1e15

    /// En dessous, la notation décimale afficherait « 0 » pour une valeur non
    /// nulle, donc un résultat faux : on bascule aussi.
    static let scientificLowerBound = 1e-10

    /// `nil` si la valeur n'est pas finie. L'évaluateur garantit déjà la
    /// finitude : cette nullité est une ceinture de sécurité pour les
    /// appelants directs (et elle est testée), pas un chemin nominal.
    static func format(_ value: Double, locale: Locale = displayLocale) -> String? {
        guard value.isFinite else { return nil }
        // `-0.0 == 0` est vrai, mais `NumberFormatter` en tire « -0 » :
        // normaliser ici est plus sûr que d'espérer qu'aucun zéro signé ne
        // sorte jamais de l'évaluateur.
        guard value != 0 else { return decimalFormatter(locale: locale).string(from: 0) }

        let magnitude = abs(value)
        let formatter = (magnitude >= scientificUpperBound || magnitude < scientificLowerBound)
            ? scientificFormatter(locale: locale)
            : decimalFormatter(locale: locale)
        return formatter.string(from: NSNumber(value: value))
    }

    /// Un formateur NEUF à chaque appel : `NumberFormatter` est une classe
    /// mutable et non `Sendable`, en partager une instance depuis un contexte
    /// `nonisolated` serait une course de données. Le coût est négligeable
    /// devant l'appel LLM qui précède.
    private static func decimalFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter
    }

    private static func scientificFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .scientific
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 10
        // Par défaut `exponentSymbol` vaut « E » ; « e » est la graphie usuelle.
        formatter.exponentSymbol = "e"
        return formatter
    }
}

// MARK: - Donnée du widget

/// Donnée affichable du widget. Équivalent typé du `data: { expression,
/// result }` de `calculationWidget.ts`, avec en plus le résultat DÉJÀ
/// formaté : une vue n'a pas à connaître la locale ni le seuil de notation
/// scientifique pour afficher un nombre.
struct CalculationWidgetData: Sendable, Equatable {
    /// Expression telle que le modèle l'a écrite (seulement détourée), PAS sa
    /// forme normalisée : c'est celle-là que l'utilisateur reconnaîtra ; la
    /// normalisation est un détail interne de l'analyse.
    let expression: String
    /// Valeur brute, conservée pour les tests et pour un éventuel « copier le
    /// résultat » sans reparser une chaîne formatée.
    let result: Double
    let formattedResult: String
}

/// Sortie complète du service. Même forme que `WeatherWidgetResult`, pour que
/// l'appelant n'ait qu'un modèle mental pour les deux widgets.
struct CalculationWidgetResult: Sendable, Equatable {
    let data: CalculationWidgetData
    let llmContext: String
}

// MARK: - Service

/// Abstraction exposée à l'appelant : une seule méthode, infaillible en
/// surface. `nil` veut dire « pas de widget », quelle qu'en soit la cause.
nonisolated protocol CalculationWidgetServing: Sendable {
    func computeCalculation(forQuery query: String, chatHistory: [ClassifierChatMessage]) async -> CalculationWidgetResult?
}

/// Port de `src/lib/agents/search/widgets/calculationWidget.ts` (web).
///
/// Le web extrait l'expression par LLM puis l'évalue avec `mathjs`. Ici
/// l'extraction est identique (prompt texte + parsing JSON tolérant) mais
/// l'évaluation est native : zéro dépendance (règle absolue du projet) et
/// zéro réseau — après l'extraction, ce widget ne sort jamais de l'appareil.
///
/// DIVERGENCE assumée : le prompt décrit la grammaire EXACTE de notre
/// évaluateur au lieu de renvoyer à « la bibliothèque Math JS ». `mathjs`
/// accepte unités, matrices et variables que notre liste blanche refuse ;
/// demander du mathjs générique produirait des expressions valides côté web
/// et systématiquement rejetées ici, donc un widget qui disparaît sans raison
/// visible.
struct CalculationWidgetService: CalculationWidgetServing {
    /// Messages d'historique injectés dans le prompt. Même valeur que
    /// `WeatherWidgetService` : au-delà on dilue l'attention d'un petit modèle
    /// on-device sans mieux désambiguïser (« et fois 3 ? » ne dépend que du
    /// tour précédent).
    static let defaultMaxHistoryMessages = 8

    private let aiProvider: any AIGenerating

    init(aiProvider: any AIGenerating) {
        self.aiProvider = aiProvider
    }

    /// Ne `throw` jamais. Trois portes de sortie, toutes sur `nil` : le modèle
    /// a échoué, il a dit `notPresent`, ou l'expression n'est pas évaluable.
    /// Aucune n'est un incident : un widget est un bonus, jamais un préalable
    /// à la réponse.
    func computeCalculation(
        forQuery query: String,
        chatHistory: [ClassifierChatMessage] = []
    ) async -> CalculationWidgetResult? {
        let prompt = Self.buildExtractionPrompt(query: query, chatHistory: chatHistory)
        guard let rawOutput = try? await aiProvider.generate(prompt: prompt) else { return nil }
        guard let expression = Self.parseExtraction(rawOutput) else { return nil }
        return Self.makeResult(forExpression: expression)
    }

    /// Évalue et met en forme. Séparée de la partie LLM pour être testable
    /// sans provider : c'est ici que se joue le « 15% de 240 -> 36 » du plan.
    ///
    /// Le `try?` assume de perdre le motif d'échec : à ce niveau, division par
    /// zéro, caractère interdit et parenthèse orpheline ont exactement la même
    /// conséquence. Le motif reste accessible en appelant l'évaluateur
    /// directement, ce que font les tests.
    static func makeResult(forExpression expression: String) -> CalculationWidgetResult? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = try? CalculationExpressionEvaluator.evaluate(trimmed) else { return nil }
        guard let formatted = CalculationResultFormatter.format(value) else { return nil }

        let data = CalculationWidgetData(expression: trimmed, result: value, formattedResult: formatted)
        return CalculationWidgetResult(data: data, llmContext: llmContext(for: data))
    }

    /// Phrase française autoportante : `AIGenerating` n'a qu'un canal texte,
    /// autant donner au modèle une phrase reprenable telle quelle plutôt qu'un
    /// objet à interpréter (le web, lui, sérialise du JSON).
    static func llmContext(for data: CalculationWidgetData) -> String {
        "Résultat du calcul « \(data.expression) » : \(data.formattedResult)."
    }

    // MARK: Prompt d'extraction

    static func buildExtractionPrompt(
        query: String,
        chatHistory: [ClassifierChatMessage],
        maxHistoryMessages: Int = defaultMaxHistoryMessages
    ) -> String {
        let history = chatHistory.suffix(max(0, maxHistoryMessages))
            .map { message in
                switch message.role {
                case .user: return "User: \(message.content)"
                case .assistant: return "AI: \(message.content)"
                }
            }
            .joined(separator: "\n")

        return """
        \(extractionSystemPrompt)

        <conversation_history>
        \(history)
        </conversation_history>

        <user_query>
        \(query)
        </user_query>
        """
    }

    /// La section `<grammar>` n'existe pas dans le prompt du web : elle est la
    /// contrepartie directe du choix d'un évaluateur maison. Chaque règle
    /// correspond à une limite réelle de `CalculationExpressionEvaluator`, et
    /// l'exemple du pourcentage est celui du plan (« 15% de 240 »).
    private static let extractionSystemPrompt: String = """
    <role>
    Tu extrais une expression mathématique. Tu reçois la dernière question de l'utilisateur et l'historique de la conversation.
    Ta tâche est de déterminer si un calcul doit être effectué et, si oui, d'écrire l'expression correspondante.
    </role>

    <grammar>
    - Opérateurs autorisés : + - * / ^ (puissance) et les parenthèses.
    - Racine carrée : sqrt(x), toujours avec des parenthèses.
    - Séparateur décimal : le POINT. N'écris jamais de virgule ni de séparateur de milliers.
    - Pourcentage : le signe % placé après un nombre veut dire « divisé par 100 ». Écris « 15% * 240 » ou « 240 * 15 / 100 » pour « 15% de 240 ». Pour « augmenter 240 de 10% », écris « 240 * 1.1 ».
    - Multiplication toujours explicite : écris « 2 * (3 + 4) », jamais « 2(3 + 4) ».
    - Interdits : variables, unités, symboles monétaires, fonctions autres que sqrt.
    </grammar>

    <instructions>
    - Si la question ne demande aucun calcul, mets notPresent à true.
    - Si tu ne peux pas écrire d'expression respectant la grammaire ci-dessus, mets notPresent à true.
    - Résous les références à l'historique (« et fois 3 ? ») en une expression complète et autonome.
    - N'écris jamais le résultat, seulement l'expression.
    </instructions>

    <output_format>
    Réponds STRICTEMENT au format JSON suivant, sans aucun texte, explication ou phrase de remplissage :
    {
      "expression": chaîne de caractères,
      "notPresent": booléen
    }
    </output_format>
    """

    // MARK: Parsing tolérant de la sortie LLM

    /// Même stratégie que `WeatherWidgetService.parseExtraction` et
    /// `QueryClassifier.parse` — voir cette dernière pour la justification de
    /// fond : aucun des trois moteurs IA de Triva n'expose de sortie
    /// structurée fiable, donc un parsing qui ne `throw` jamais et retombe sur
    /// un repli sûr. Ici le repli sûr est `nil`, donc « pas de widget ».
    /// `notPresent: true` et une sortie illisible renvoient tous deux `nil` :
    /// la distinction n'aurait aucune conséquence observable.
    static func parseExtraction(_ rawOutput: String) -> String? {
        for candidate in jsonCandidates(from: rawOutput) {
            guard let decoded = decodeCandidate(candidate) else { continue }
            if decoded.notPresent == true { return nil }
            let expression = decoded.expression?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !expression.isEmpty { return expression }
            // Décodé mais sans expression exploitable : on tente le candidat
            // suivant, un autre bloc de la réponse peut être complet.
        }
        return nil
    }

    private struct RawExtraction: Decodable {
        let expression: String?
        let notPresent: Bool?
    }

    private static func decodeCandidate(_ candidate: String) -> RawExtraction? {
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RawExtraction.self, from: data)
    }

    /// Duplication volontaire et minimale de l'extraction de candidats JSON de
    /// `WeatherWidgetService` : cette logique n'a toujours pas de foyer partagé
    /// et le périmètre de cette mission n'autorise pas à en créer un. Signalé
    /// pour un futur ticket de nettoyage, pas fait ici.
    private static func jsonCandidates(from rawOutput: String) -> [String] {
        var candidates: [String] = []
        for block in fencedBlocks(from: rawOutput) {
            candidates.append(bracesSubstring(from: block) ?? block)
        }
        if let braces = bracesSubstring(from: rawOutput) {
            candidates.append(braces)
        }
        return candidates
    }

    private static func fencedBlocks(from rawOutput: String) -> [String] {
        let components = rawOutput.components(separatedBy: "```")
        guard components.count >= 3 else { return [] }

        var blocks: [String] = []
        var index = 1
        while index < components.count {
            var block = components[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if block.hasPrefix("json") {
                block.removeFirst("json".count)
            }
            blocks.append(block.trimmingCharacters(in: .whitespacesAndNewlines))
            index += 2
        }
        return blocks
    }

    private static func bracesSubstring(from rawOutput: String) -> String? {
        guard
            let firstBrace = rawOutput.firstIndex(of: "{"),
            let lastBrace = rawOutput.lastIndex(of: "}"),
            firstBrace < lastBrace
        else {
            return nil
        }
        return String(rawOutput[firstBrace...lastBrace])
    }
}
