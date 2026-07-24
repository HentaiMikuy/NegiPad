import Foundation

/// The outcome of evaluating a launcher query as a math expression.
struct CalculationResult: Equatable, Sendable {
    /// Reader-friendly form with thousands grouping, e.g. "1,234.5".
    let displayText: String
    /// Plain machine form that lands on the pasteboard, e.g. "1234.5".
    let rawText: String
}

/// A small, safe arithmetic evaluator behind the launcher's calculator tool.
///
/// Hand-rolled instead of NSExpression: malformed input there raises
/// Objective-C exceptions Swift cannot catch, which rules it out for
/// evaluating every keystroke. Supports + - * / % ^ (% is modulo),
/// parentheses, unary signs, the constants pi/e, and a few one-argument
/// functions. Input that is not a complete expression — including anything
/// that looks like an app search — evaluates to nil.
enum CalculatorEngine {
    /// Anything longer is search text, not arithmetic; the cap also bounds
    /// parser recursion depth.
    private static let maxExpressionLength = 120

    static func evaluate(_ query: String) -> CalculationResult? {
        let expression = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty,
              expression.count <= maxExpressionLength,
              let tokens = tokenize(expression) else {
            return nil
        }

        // A bare number or constant ("123", "e") is far more likely an app
        // search than a calculation; require actual arithmetic intent.
        guard tokens.contains(where: \.impliesCalculation) else { return nil }

        var parser = Parser(tokens: tokens)
        guard let value = parser.parse(), value.isFinite else { return nil }
        return makeResult(for: value)
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case function(String)
        case leftParen
        case rightParen

        var impliesCalculation: Bool {
            switch self {
            case .op, .function: true
            case .number, .leftParen, .rightParen: false
            }
        }
    }

    private static func tokenize(_ expression: String) -> [Token]? {
        let characters = Array(normalize(expression))
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == " " {
                index += 1
                continue
            }

            if isDigit(character) || character == "." {
                var text = ""
                while index < characters.count,
                      isDigit(characters[index]) || characters[index] == "." {
                    text.append(characters[index])
                    index += 1
                }
                guard let value = Double(text) else { return nil }
                tokens.append(.number(value))
                continue
            }

            if character.isLetter {
                var name = ""
                while index < characters.count, characters[index].isLetter {
                    name.append(characters[index])
                    index += 1
                }
                switch name.lowercased() {
                case "pi", "π":
                    tokens.append(.number(.pi))
                case "e":
                    tokens.append(.number(M_E))
                case "sqrt", "abs", "sin", "cos", "tan", "log", "ln":
                    tokens.append(.function(name.lowercased()))
                default:
                    // An unknown word means the query is an app search.
                    return nil
                }
                continue
            }

            switch character {
            case "+", "-", "*", "/", "%", "^":
                tokens.append(.op(character))
            case "(":
                tokens.append(.leftParen)
            case ")":
                tokens.append(.rightParen)
            default:
                return nil
            }
            index += 1
        }

        return tokens
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// Chinese input methods produce fullwidth digits, operators, and
    /// parentheses; pretty math symbols arrive from copy-paste. Both fold to
    /// plain ASCII before tokenizing.
    private static func normalize(_ expression: String) -> String {
        String(expression.map { character -> Character in
            if character.unicodeScalars.count == 1,
               let scalar = character.unicodeScalars.first {
                if (0xFF01...0xFF5E).contains(scalar.value),
                   let asciiScalar = UnicodeScalar(scalar.value - 0xFEE0) {
                    return Character(asciiScalar)
                }
                if scalar.value == 0x3000 {
                    return " "
                }
            }

            switch character {
            case "×", "✕":
                return "*"
            case "÷":
                return "/"
            case "−":
                return "-"
            default:
                return character
            }
        })
    }

    // MARK: - Parser

    /// Recursive descent over the token stream:
    ///
    ///     expression := term (('+' | '-') term)*
    ///     term       := signed (('*' | '/' | '%') signed)*
    ///     signed     := ('+' | '-') signed | power
    ///     power      := primary ('^' signed)?          // right-associative
    ///     primary    := number | function '(' expression ')' | '(' expression ')'
    ///
    /// '^' binding tighter than unary minus gives the conventional
    /// -2^2 = -4, while its exponent being `signed` allows 2^-3.
    private struct Parser {
        private let tokens: [Token]
        private var index = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        mutating func parse() -> Double? {
            guard let value = parseExpression(), index == tokens.count else {
                return nil
            }
            return value
        }

        private mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while case let .op(symbol)? = peek(), symbol == "+" || symbol == "-" {
                index += 1
                guard let rhs = parseTerm() else { return nil }
                value = symbol == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parseSigned() else { return nil }
            while case let .op(symbol)? = peek(),
                  symbol == "*" || symbol == "/" || symbol == "%" {
                index += 1
                guard let rhs = parseSigned() else { return nil }
                switch symbol {
                case "*":
                    value *= rhs
                case "/":
                    value /= rhs
                default:
                    value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        private mutating func parseSigned() -> Double? {
            if case let .op(symbol)? = peek(), symbol == "+" || symbol == "-" {
                index += 1
                guard let value = parseSigned() else { return nil }
                return symbol == "-" ? -value : value
            }
            return parsePower()
        }

        private mutating func parsePower() -> Double? {
            guard let base = parsePrimary() else { return nil }
            if peek() == .op("^") {
                index += 1
                guard let exponent = parseSigned() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func parsePrimary() -> Double? {
            switch peek() {
            case let .number(value)?:
                index += 1
                return value

            case .leftParen?:
                index += 1
                guard let value = parseExpression(), consume(.rightParen) else {
                    return nil
                }
                return value

            case let .function(name)?:
                index += 1
                guard consume(.leftParen),
                      let argument = parseExpression(),
                      consume(.rightParen) else {
                    return nil
                }
                return apply(name, to: argument)

            default:
                return nil
            }
        }

        private func apply(_ name: String, to argument: Double) -> Double? {
            switch name {
            case "sqrt": sqrt(argument)
            case "abs": abs(argument)
            case "sin": sin(argument)
            case "cos": cos(argument)
            case "tan": tan(argument)
            case "log": log10(argument)
            case "ln": log(argument)
            default: nil
            }
        }

        private func peek() -> Token? {
            index < tokens.count ? tokens[index] : nil
        }

        private mutating func consume(_ token: Token) -> Bool {
            guard peek() == token else { return false }
            index += 1
            return true
        }
    }

    // MARK: - Formatting

    private static func makeResult(for value: Double) -> CalculationResult? {
        let normalizedValue = value == 0 ? 0 : value  // collapse "-0"

        // Doubles past 2^53 (and rounded-to-zero tails) would display
        // misleading exact-looking digits; switch to scientific notation.
        if normalizedValue.magnitude >= 1e15
            || (normalizedValue != 0 && normalizedValue.magnitude < 1e-9) {
            let text = String(format: "%.6g", normalizedValue)
            return CalculationResult(displayText: text, rawText: text)
        }

        let displayFormatter = NumberFormatter()
        displayFormatter.numberStyle = .decimal
        displayFormatter.usesGroupingSeparator = true
        displayFormatter.maximumFractionDigits = 10

        // The pasteboard copy stays locale-independent: no grouping, "." as
        // the decimal separator, so it pastes cleanly anywhere.
        let rawFormatter = NumberFormatter()
        rawFormatter.locale = Locale(identifier: "en_US_POSIX")
        rawFormatter.numberStyle = .decimal
        rawFormatter.usesGroupingSeparator = false
        rawFormatter.maximumFractionDigits = 10

        guard
            let displayText = displayFormatter.string(from: NSNumber(value: normalizedValue)),
            let rawText = rawFormatter.string(from: NSNumber(value: normalizedValue))
        else {
            return nil
        }
        return CalculationResult(displayText: displayText, rawText: rawText)
    }
}
