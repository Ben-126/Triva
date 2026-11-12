//
//  CalculationExpressionGrammar.swift
//  Triva
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation

// Sorti de `CalculationWidgetService.swift` (mission E1c) : déplacement pur,
// aucun changement de code ni de comportement. Les erreurs et la grammaire (opérateurs, fonctions, jetons, éléments RPN) de l'évaluateur.

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

