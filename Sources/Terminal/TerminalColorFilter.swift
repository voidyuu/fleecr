import Foundation

struct LightTerminalANSIAdapter {
    private var pending: [UInt8] = []

    mutating func transform(_ data: Data) -> [UInt8] {
        pending.append(contentsOf: data)
        return processPending()
    }

    mutating func transform(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        pending.append(contentsOf: bytes)
        return processPending()
    }

    private mutating func processPending() -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(pending.count)
        var index = 0

        while index < pending.count {
            guard pending[index] == 0x1B else {
                output.append(pending[index])
                index += 1
                continue
            }
            guard index + 1 < pending.count else { break }
            guard pending[index + 1] == 0x5B else {
                output.append(pending[index])
                index += 1
                continue
            }

            var end = index + 2
            while end < pending.count, !(0x40...0x7E).contains(pending[end]) {
                end += 1
            }
            guard end < pending.count else { break }

            let sequence = pending[index...end]
            if pending[end] == 0x6D {
                // A Powerline separator is a foreground-colored shape painted
                // over the next segment's background.  Its foreground is not
                // ordinary text: it is deliberately the previous segment's
                // background.  Wait for the next scalar so the light-theme
                // contrast transform does not turn that join into a dark,
                // blended-looking arrow.
                if let preservesPowerlineForeground = powerlineFollowsSGR(after: end + 1) {
                    output.append(contentsOf: transformSGR(
                        sequence,
                        preservePowerlineForeground: preservesPowerlineForeground
                    ))
                } else if sequenceContainsForegroundColor(sequence) {
                    // Only a foreground SGR can be the color of a following
                    // separator. Do not hold resets/background-only updates at
                    // the end of a PTY read; otherwise typed echo can inherit
                    // the previous cell's style until another output arrives.
                    break
                } else {
                    output.append(contentsOf: transformSGR(sequence))
                }
            } else {
                output.append(contentsOf: sequence)
            }
            index = end + 1
        }

        if index == pending.count {
            pending.removeAll(keepingCapacity: true)
        } else if index > 0 {
            pending.removeSubrange(0..<index)
        }
        return output
    }

    /// WCAG contrast ratio of an sRGB color against a white background.
    static func contrastOnWhite(red: Int, green: Int, blue: Int) -> Double {
        func linear(_ value: Int) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05)
    }

    static func lightRGB(red: Int, green: Int, blue: Int) -> (red: Int, green: Int, blue: Int) {
        let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
        let offset = 255 - 2 * luminance
        return (
            clamp(Double(red) + offset),
            clamp(Double(green) + offset),
            clamp(Double(blue) + offset)
        )
    }

    /// Adapts one color for the light theme.
    ///
    /// Backgrounds flip only when they are dark: the adapter's job is "make
    /// this output suit a light terminal", and a light background already
    /// does. Flipping unconditionally double-inverted agents that are
    /// themselves in a light theme — Claude Code's pale user-message bar
    /// became a black strip, and since the foreground rule keeps dark text
    /// dark, the result was dark-on-black. Dark-themed output (Codex's
    /// `48;2;30;30;30` box, 256-color dark diff backgrounds) still flips.
    ///
    /// Foregrounds keep whichever variant reads better on white — same rule
    /// as the ANSI palette, so an already-dark foreground (diff red, syntax
    /// blue) doesn't wash out to a pastel.
    static func adapt(red: Int, green: Int, blue: Int, isBackground: Bool) -> (red: Int, green: Int, blue: Int) {
        let flipped = lightRGB(red: red, green: green, blue: blue)
        if isBackground {
            let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
            return luminance < 128 ? flipped : (red, green, blue)
        }
        let originalContrast = contrastOnWhite(red: red, green: green, blue: blue)
        let flippedContrast = contrastOnWhite(red: flipped.red, green: flipped.green, blue: flipped.blue)
        return originalContrast >= flippedContrast ? (red, green, blue) : flipped
    }

    /// The standard xterm 256-color palette above the 16 ANSI entries:
    /// 16–231 form a 6×6×6 cube, 232–255 a grayscale ramp.
    static func xterm256RGB(_ index: Int) -> (red: Int, green: Int, blue: Int) {
        if index >= 232 {
            let gray = 8 + 10 * (index - 232)
            return (gray, gray, gray)
        }
        let levels = [0, 95, 135, 175, 215, 255]
        let value = index - 16
        return (levels[value / 36], levels[(value / 6) % 6], levels[value % 6])
    }

    private func sequenceContainsForegroundColor(_ sequence: ArraySlice<UInt8>) -> Bool {
        guard sequence.count >= 3 else { return false }
        let start = sequence.startIndex + 2
        let end = sequence.endIndex - 1
        guard start < end else { return false }
        let parameters = sequence[start..<end]

        var tokenStart = parameters.startIndex
        while tokenStart < parameters.endIndex {
            var tokenEnd = tokenStart
            while tokenEnd < parameters.endIndex && parameters[tokenEnd] != 0x3B {
                tokenEnd += 1
            }
            if tokenEnd - tokenStart == 2 && parameters[tokenStart] == 0x33 && parameters[tokenStart + 1] == 0x38 {
                return true
            }
            tokenStart = tokenEnd < parameters.endIndex ? tokenEnd + 1 : parameters.endIndex
        }
        return false
    }

    /// Looks past complete control sequences for the next UTF-8 scalar.
    /// `nil` means that the current chunk ends before the scalar (or its
    /// intervening CSI), so the caller must retain the SGR for the next feed.
    private func powerlineFollowsSGR(after start: Int) -> Bool? {
        var index = start
        while index < pending.count {
            // SGRs are sometimes split into separate writes by a prompt
            // renderer. Skip a complete CSI while looking for the glyph.
            if pending[index] == 0x1B {
                guard index + 1 < pending.count else { return nil }
                guard pending[index + 1] == 0x5B else { return false }
                var end = index + 2
                while end < pending.count, !(0x40...0x7E).contains(pending[end]) {
                    end += 1
                }
                guard end < pending.count else { return nil }
                index = end + 1
                continue
            }

            // Do not classify an incomplete UTF-8 sequence as an ordinary
            // character: dataReceived can split the glyph across chunks.
            let first = pending[index]
            let scalarLength: Int
            switch first {
            case 0xC2...0xDF: scalarLength = 2
            case 0xE0...0xEF: scalarLength = 3
            case 0xF0...0xF4: scalarLength = 4
            default:
                return false
            }
            guard index + scalarLength <= pending.count else { return nil }
            let scalarBytes = pending[index..<(index + scalarLength)]
            guard let scalar = String(decoding: scalarBytes, as: UTF8.self).unicodeScalars.first else {
                return false
            }
            // Include the thin and rounded Powerline variants as well as the
            // four shapes SwiftTerm draws itself. All of them use the same
            // foreground/background layering contract.
            return (0xE0B0...0xE0D7).contains(scalar.value)
        }
        return nil
    }

    private struct SGRToken {
        let slice: ArraySlice<UInt8>
        let intValue: Int?
    }

    private static func parseAsciiInt(_ slice: ArraySlice<UInt8>) -> Int? {
        guard !slice.isEmpty else { return nil }
        var result = 0
        for b in slice {
            guard b >= 0x30 && b <= 0x39 else { return nil }
            result = result * 10 + Int(b - 0x30)
            if result > 10_000 { return nil }
        }
        return result
    }

    private static func appendAsciiInt(_ buffer: inout [UInt8], _ value: Int) {
        if value == 0 {
            buffer.append(0x30)
            return
        }
        var v = value
        let start = buffer.count
        while v > 0 {
            buffer.append(UInt8(0x30 + (v % 10)))
            v /= 10
        }
        buffer[start...].reverse()
    }

    private func transformSGR(
        _ sequence: ArraySlice<UInt8>,
        preservePowerlineForeground: Bool = false
    ) -> [UInt8] {
        guard sequence.count >= 3 else { return Array(sequence) }
        let start = sequence.startIndex + 2
        let end = sequence.endIndex - 1
        guard start < end else { return Array(sequence) }
        let parameters = sequence[start..<end]

        var tokens: [SGRToken] = []
        var tokenStart = parameters.startIndex
        while tokenStart <= parameters.endIndex {
            var tokenEnd = tokenStart
            while tokenEnd < parameters.endIndex && parameters[tokenEnd] != 0x3B {
                tokenEnd += 1
            }
            let slice = parameters[tokenStart..<tokenEnd]
            tokens.append(SGRToken(slice: slice, intValue: Self.parseAsciiInt(slice)))
            if tokenEnd == parameters.endIndex { break }
            tokenStart = tokenEnd + 1
        }

        var result: [UInt8] = []
        result.reserveCapacity(sequence.count + 16)
        result.append(0x1B)
        result.append(0x5B)

        var index = 0
        var isFirst = true

        func appendSeparatorIfNeeded() {
            if isFirst {
                isFirst = false
            } else {
                result.append(0x3B) // ';'
            }
        }

        while index < tokens.count {
            let token = tokens[index]
            let isColor = token.intValue == 38 || token.intValue == 48
            let isBackground = token.intValue == 48

            if isColor, index + 4 < tokens.count,
               tokens[index + 1].intValue == 2,
               let red = tokens[index + 2].intValue,
               let green = tokens[index + 3].intValue,
               let blue = tokens[index + 4].intValue,
               (0...255).contains(red), (0...255).contains(green), (0...255).contains(blue) {
                let light = preservePowerlineForeground && !isBackground
                    ? Self.adapt(red: red, green: green, blue: blue, isBackground: true)
                    : Self.adapt(red: red, green: green, blue: blue, isBackground: isBackground)
                appendSeparatorIfNeeded()
                result.append(contentsOf: token.slice)
                result.append(0x3B)
                result.append(0x32) // '2'
                result.append(0x3B)
                Self.appendAsciiInt(&result, light.red)
                result.append(0x3B)
                Self.appendAsciiInt(&result, light.green)
                result.append(0x3B)
                Self.appendAsciiInt(&result, light.blue)
                index += 5
            } else if isColor, index + 2 < tokens.count,
                      tokens[index + 1].intValue == 5,
                      let paletteIndex = tokens[index + 2].intValue,
                      (16...255).contains(paletteIndex) {
                let base = Self.xterm256RGB(paletteIndex)
                let light = preservePowerlineForeground && !isBackground
                    ? Self.adapt(red: base.red, green: base.green, blue: base.blue, isBackground: true)
                    : Self.adapt(red: base.red, green: base.green, blue: base.blue, isBackground: isBackground)
                appendSeparatorIfNeeded()
                result.append(contentsOf: token.slice)
                result.append(0x3B)
                result.append(0x32) // '2'
                result.append(0x3B)
                Self.appendAsciiInt(&result, light.red)
                result.append(0x3B)
                Self.appendAsciiInt(&result, light.green)
                result.append(0x3B)
                Self.appendAsciiInt(&result, light.blue)
                index += 3
            } else {
                appendSeparatorIfNeeded()
                result.append(contentsOf: token.slice)
                index += 1
            }
        }

        result.append(0x6D) // 'm'
        return result
    }

    private static func clamp(_ value: Double) -> Int {
        min(255, max(0, Int(value.rounded())))
    }
}
