import XCTest
@testable import fleecr

final class TerminalColorFilterTests: XCTestCase {
    func testTruecolorLightTheme() {
        var adapter = LightTerminalANSIAdapter()
        let source = Array("\u{1B}[38;2;230;230;230;48;2;30;30;30mCodex".utf8)
        let result = String(decoding: adapter.transform(source[...]), as: UTF8.self)

        XCTAssert(result.contains("38;2;25;25;25"), "light foreground should become dark")
        XCTAssert(result.contains("48;2;225;225;225"), "dark input background should become light")
    }

    func testResetIsNotHeldForNextChunk() {
        var adapter = LightTerminalANSIAdapter()
        let result = String(decoding: adapter.transform(Array("\u{1B}[0m".utf8)[...]), as: UTF8.self)
        XCTAssertEqual(result, "\u{1B}[0m", "a trailing reset should not wait for another output chunk")
    }

    func testSplitEscapeSequence() {
        var adapter = LightTerminalANSIAdapter()
        let first = Array("before\u{1B}[48;2;30;".utf8)
        let second = Array("30;30mafter".utf8)
        let result = adapter.transform(first[...]) + adapter.transform(second[...])
        XCTAssertEqual(
            String(decoding: result, as: UTF8.self),
            "before\u{1B}[48;2;225;225;225mafter",
            "split escape sequences should be transformed without corruption"
        )
    }

    func testIndexed256Colors() {
        // herdr passes 256-indexed SGR through verbatim (48;5;22 etc.), which is
        // what Claude Code's diff backgrounds arrive as — they must be resolved
        // through the xterm palette and adapted like truecolor.
        var adapter = LightTerminalANSIAdapter()
        let indexed = Array("\u{1B}[0;38;5;114;48;5;22mdiff".utf8)
        let result = String(decoding: adapter.transform(indexed[...]), as: UTF8.self)
        XCTAssert(result.contains("38;2;6;86;6"), "256-color light green foreground should become dark")
        XCTAssert(result.contains("48;2;119;214;119"), "256-color dark diff background should become light")
    }

    func testLightThemePassthrough() {
        // A light-themed agent's output must pass through untouched: light
        // backgrounds already suit a light terminal, and flipping them was
        // how Claude Code's pale user-message bar became a black strip.
        var adapter = LightTerminalANSIAdapter()
        let lightTheme = Array("\u{1B}[38;2;50;50;50;48;2;245;245;245mrow".utf8)
        let result = String(decoding: adapter.transform(lightTheme[...]), as: UTF8.self)
        XCTAssert(result.contains("48;2;245;245;245"), "light backgrounds must not flip dark")
        XCTAssert(result.contains("38;2;50;50;50"), "dark foregrounds on light rows must stay dark")
    }

    func testPowerlineSeparatorLayering() {
        // Powerline separators are layered: the separator foreground is the
        // previous segment's background, while the cell background is the next
        // segment's background. Do not run the foreground through the normal
        // contrast transform or the join turns into a dark blended arrow.
        var adapter = LightTerminalANSIAdapter()
        let powerlineText = "\u{1B}[48;2;243;139;168;38;2;17;17;27muser"
            + "\u{1B}[48;2;250;179;135;38;2;243;139;168m\u{E0B0}"
            + "\u{1B}[38;2;17;17;27mpath"
        let result = String(decoding: adapter.transform(Array(powerlineText.utf8)[...]), as: UTF8.self)
        XCTAssert(
            result.contains("48;2;250;179;135;38;2;243;139;168m\u{E0B0}"),
            "powerline foreground should retain the neighboring segment color"
        )
        XCTAssert(
            result.contains("38;2;17;17;27mpath"),
            "ordinary foreground after a powerline separator should still adapt normally"
        )
    }

    func testDarkPowerlineFollowsFlippedBackground() {
        var adapter = LightTerminalANSIAdapter()
        let darkPowerline = Array("\u{1B}[48;2;30;30;30;38;2;30;30;30m\u{E0B0}".utf8)
        let result = String(decoding: adapter.transform(darkPowerline[...]), as: UTF8.self)
        XCTAssert(
            result.contains("48;2;225;225;225;38;2;225;225;225m\u{E0B0}"),
            "a dark powerline separator should follow the flipped neighboring background"
        )
    }

    func testSplitPowerlineGlyph() {
        // The separator and its UTF-8 bytes may arrive in separate PTY reads.
        var adapter = LightTerminalANSIAdapter()
        let splitPowerlineBytes = Array("\u{E0B0}next".utf8)
        let first = Array("\u{1B}[48;2;250;179;135;38;2;243;139;168m".utf8)
            + [splitPowerlineBytes[0]]
        let second = Array(splitPowerlineBytes[1...])
        let result = adapter.transform(first[...]) + adapter.transform(second[...])
        XCTAssertEqual(
            String(decoding: result, as: UTF8.self),
            "\u{1B}[48;2;250;179;135;38;2;243;139;168m\u{E0B0}next",
            "split powerline glyphs should retain their layered foreground"
        )
    }

    func testDarkTruecolorForegroundKept() {
        // Foregrounds that already read well on white keep their color;
        // only dark backgrounds flip.
        var adapter = LightTerminalANSIAdapter()
        let darkRed = Array("\u{1B}[38;2;220;50;47merror".utf8)
        let result = String(decoding: adapter.transform(darkRed[...]), as: UTF8.self)
        XCTAssert(result.contains("38;2;220;50;47"), "an already-dark truecolor foreground should not wash out")
    }

    func testPaletteContrast() {
        // The light palette keeps whichever variant reads better on white:
        // ANSI red is already dark and must not wash out to a pastel, while
        // bright white must flip to dark. Mirrors TerminalDefaults.lightPalette.
        let redOriginal = LightTerminalANSIAdapter.contrastOnWhite(red: 194, green: 54, blue: 33)
        let redFlipped = LightTerminalANSIAdapter.lightRGB(red: 194, green: 54, blue: 33)
        XCTAssertGreaterThanOrEqual(
            redOriginal,
            LightTerminalANSIAdapter.contrastOnWhite(red: redFlipped.red, green: redFlipped.green, blue: redFlipped.blue),
            "ANSI red should survive the light palette unflipped"
        )

        let brightWhiteOriginal = LightTerminalANSIAdapter.contrastOnWhite(red: 233, green: 235, blue: 235)
        let brightWhiteFlipped = LightTerminalANSIAdapter.lightRGB(red: 233, green: 235, blue: 235)
        XCTAssertGreaterThan(
            LightTerminalANSIAdapter.contrastOnWhite(
                red: brightWhiteFlipped.red, green: brightWhiteFlipped.green, blue: brightWhiteFlipped.blue
            ),
            brightWhiteOriginal,
            "ANSI bright white should flip to a dark color"
        )
    }
}
