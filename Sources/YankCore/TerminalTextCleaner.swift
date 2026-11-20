import Foundation

/// Removes terminal presentation artifacts while preserving line breaks and relative indentation.
enum TerminalTextCleaner {
    private static let escape: Unicode.Scalar = "\u{1B}"
    private static let bell: Unicode.Scalar = "\u{07}"
    private static let csiParameters: ClosedRange<UInt32> = 0x30...0x3F
    private static let csiIntermediates: ClosedRange<UInt32> = 0x20...0x2F
    private static let csiFinals: ClosedRange<UInt32> = 0x40...0x7E
    private static let shortEscapeLetters: ClosedRange<UInt32> = 0x40...0x5A
    private static let shortEscapeSymbols: ClosedRange<UInt32> = 0x5C...0x5F
    private static let boxDrawing: ClosedRange<UInt32> = 0x2500...0x257F
    private static let decimalDigits: ClosedRange<UInt32> = 0x30...0x39

    static func clean(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let scalars = stripEscapes(Array(normalized.unicodeScalars))
        var lines = scalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map(Array.init)
            .filter { !isBoxDrawingLine($0) }

        stripFrames(&lines)
        for index in lines.indices {
            if let marker = lines[index].firstIndex(where: { $0 != " " }),
               lines[index][marker] == "⏺" || lines[index][marker] == "⎿" {
                lines[index][marker] = " "
            }
        }
        stripLineNumbers(&lines)
        for index in lines.indices {
            while let last = lines[index].last, last == " " || last == "\t" {
                lines[index].removeLast()
            }
        }

        let nonBlank = lines.indices.filter { !isBlank(lines[$0]) }
        guard let first = nonBlank.first, let last = nonBlank.last else { return "" }
        var prefixLength = lines[first].prefix(while: { $0.properties.isWhitespace }).count
        for index in nonBlank.dropFirst() {
            var matched = 0
            while matched < prefixLength, matched < lines[index].count,
                  lines[first][matched] == lines[index][matched] {
                matched += 1
            }
            prefixLength = matched
        }
        return lines[first...last].map { line in
            isBlank(line) ? "" : String(String.UnicodeScalarView(line.dropFirst(prefixLength)))
        }.joined(separator: "\n")
    }

    private static func stripEscapes(_ input: [Unicode.Scalar]) -> [Unicode.Scalar] {
        // An unterminated OSC must not rescan the remaining suffix for every escape.
        let lastTerminator = input.indices.reversed().first { index in
            input[index] == bell || (input[index] == "\\" && index > 0 && input[index - 1] == escape)
        }
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            if input[index] == escape, index + 1 < input.count {
                let next = input[index + 1]
                if next == "[" {
                    var end = index + 2
                    while end < input.count, csiParameters.contains(input[end].value) { end += 1 }
                    while end < input.count, csiIntermediates.contains(input[end].value) { end += 1 }
                    if end < input.count, csiFinals.contains(input[end].value) {
                        index = end + 1
                        continue
                    }
                } else if next == "]", let lastTerminator, lastTerminator > index + 1 {
                    var end = index + 2
                    while end < input.count {
                        if input[end] == bell {
                            end += 1
                            break
                        }
                        if input[end] == escape, end + 1 < input.count, input[end + 1] == "\\" {
                            end += 2
                            break
                        }
                        end += 1
                    }
                    index = end
                    continue
                }
                if shortEscapeLetters.contains(next.value) || shortEscapeSymbols.contains(next.value) {
                    index += 2
                    continue
                }
            }
            switch input[index] {
            case "\u{00A0}": output.append(" ")
            case "\u{200B}", "\u{FEFF}": break
            default: output.append(input[index])
            }
            index += 1
        }
        return output
    }

    private static func isBlank(_ line: [Unicode.Scalar]) -> Bool {
        line.allSatisfy { $0.properties.isWhitespace }
    }

    private static func isBoxDrawingLine(_ line: [Unicode.Scalar]) -> Bool {
        var hasBoxDrawing = false
        for scalar in line {
            if boxDrawing.contains(scalar.value) {
                hasBoxDrawing = true
            } else if !scalar.properties.isWhitespace {
                return false
            }
        }
        return hasBoxDrawing
    }

    private static func stripFrames(_ lines: inout [[Unicode.Scalar]]) {
        let nonBlank = lines.indices.filter { !isBlank(lines[$0]) }
        if !nonBlank.isEmpty, nonBlank.allSatisfy({ index in
            lines[index].first(where: { $0 != " " }) == "│"
        }) {
            for index in nonBlank {
                guard let edge = lines[index].firstIndex(where: { $0 != " " }) else { continue }
                lines[index].remove(at: edge)
                if edge < lines[index].count, lines[index][edge] == " " {
                    lines[index].remove(at: edge)
                }
            }
        }
        let remaining = lines.indices.filter { !isBlank(lines[$0]) }
        if !remaining.isEmpty, remaining.allSatisfy({ index in
            lines[index].last(where: { !$0.properties.isWhitespace }) == "│"
        }) {
            for index in remaining {
                if let edge = lines[index].lastIndex(where: { !$0.properties.isWhitespace }) {
                    lines[index].remove(at: edge)
                }
            }
        }
    }

    private static func stripLineNumbers(_ lines: inout [[Unicode.Scalar]]) {
        let nonBlank = lines.indices.filter { !isBlank(lines[$0]) }
        guard nonBlank.count >= 2 else { return }
        var prefixes: [(line: Int, end: Int)] = []
        var previous: [UInt32]?
        for index in nonBlank {
            let line = lines[index]
            var end = line.prefix(while: { $0.properties.isWhitespace }).count
            let start = end
            while end < line.count, decimalDigits.contains(line[end].value) { end += 1 }
            guard end > start, end < line.count, line[end] == "→" || line[end] == "\t" else { return }
            var number = Array(line[start..<end].map(\.value).drop(while: { $0 == decimalDigits.lowerBound }))
            if number.isEmpty { number = [decimalDigits.lowerBound] }
            if let previous, increment(previous) != number { return }
            previous = number
            prefixes.append((index, end + 1))
        }
        for prefix in prefixes {
            lines[prefix.line].removeFirst(prefix.end)
        }
    }

    private static func increment(_ number: [UInt32]) -> [UInt32] {
        var result = number
        for index in result.indices.reversed() {
            if result[index] < decimalDigits.upperBound {
                result[index] += 1
                return result
            }
            result[index] = decimalDigits.lowerBound
        }
        result.insert(decimalDigits.lowerBound + 1, at: 0)
        return result
    }
}
