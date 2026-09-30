import XCTest
@testable import fleecr

final class TerminalCJKFontTests: XCTestCase {
    func testMapPinsHanWhenThePrimaryFaceHasNone() {
        let lines = TerminalCJKFont.mapValues(primaryFontName: "Menlo", languages: ["zh-Hans"])
        guard TerminalCJKFont.familyInstalled("PingFang SC") else {
            XCTAssertTrue(lines.isEmpty)
            return
        }
        XCTAssertEqual(lines.count, TerminalCJKFont.ranges.count)
        XCTAssertTrue(lines.contains("U+3000-U+303F=PingFang SC"))
        XCTAssertTrue(lines.contains("U+4E00-U+9FFF=PingFang SC"))
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix("=PingFang SC") })
    }

    func testMapFollowsTraditionalAndJapanesePreferences() {
        if TerminalCJKFont.familyInstalled("PingFang TC") {
            let lines = TerminalCJKFont.mapValues(primaryFontName: "Menlo", languages: ["zh-Hant"])
            XCTAssertTrue(lines.contains("U+3000-U+303F=PingFang TC"))
        }
        if TerminalCJKFont.familyInstalled("Hiragino Sans") {
            let lines = TerminalCJKFont.mapValues(primaryFontName: "", languages: ["ja"])
            XCTAssertTrue(lines.contains("U+4E00-U+9FFF=Hiragino Sans"))
        }
    }

    func testMapLeavesAFaceThatAlreadyDrawsHan() {
        guard TerminalCJKFont.primaryCoversHan("PingFangSC-Regular") else { return }
        XCTAssertTrue(TerminalCJKFont.mapValues(primaryFontName: "PingFangSC-Regular").isEmpty)
    }
}

final class TerminalFrameBytesTests: XCTestCase {
    func testFrameResetsHostModesBeforeBlit() {
        let frame = Data("\u{1B}[?2026h\u{1B}[1;1H".utf8)
        let payload = TerminalFrameBytes.payload(frame: frame)
        let prelude = Data(payload.dropLast(frame.count))

        XCTAssertFalse(prelude.contains(Data([0x1B, 0x63])))
        XCTAssertTrue(prelude.contains(Data("\u{1B}[?1049l".utf8)))
        XCTAssertTrue(prelude.contains(Data("\u{1B}[r".utf8)))
        XCTAssertTrue(prelude.contains(Data("\u{1B}[?7l".utf8)))
        XCTAssertTrue(prelude.contains(Data("\u{1B}[?25h".utf8)))
        XCTAssertEqual(Data(payload.suffix(frame.count)), frame)
    }

    func testFrameDropsModesThatWouldUndoTheReset() {
        let frame = Data("\u{1B}[?7h\u{1B}[?1049h\u{1B}[2;23r\u{1B}[1;1Hkeep\u{1B}[?25l".utf8)
        let payload = TerminalFrameBytes.payload(frame: frame)
        let replayed = Data(payload.dropFirst(TerminalFrameBytes.reset.count))

        XCTAssertFalse(replayed.contains(Data("\u{1B}[?7h".utf8)))
        XCTAssertFalse(replayed.contains(Data("\u{1B}[?1049h".utf8)))
        XCTAssertFalse(replayed.contains(Data("\u{1B}[2;23r".utf8)))
        XCTAssertTrue(replayed.contains(Data("\u{1B}[1;1Hkeep".utf8)))
        XCTAssertTrue(replayed.contains(Data("\u{1B}[?25l".utf8)))
    }

    func testCombinedPrivateModeKeepsTheOtherModes() {
        let frame = Data("\u{1B}[?25;1049h\u{1B}[?1000;1049l\u{1B}[1;1Hkeep".utf8)
        let replayed = TerminalFrameBytes.sanitize(frame)

        XCTAssertFalse(replayed.contains(Data("1049".utf8)))
        XCTAssertTrue(replayed.contains(Data("\u{1B}[?25h".utf8)))
        XCTAssertTrue(replayed.contains(Data("\u{1B}[?1000l".utf8)))
        XCTAssertTrue(replayed.contains(Data("\u{1B}[1;1Hkeep".utf8)))
    }

    func testSanitizeDropsAltScreenSaveAndRestore() {
        let frame = Data("\u{1B}[?1049s\u{1B}[?47u\u{1B}[?47hkeep".utf8)
        let replayed = TerminalFrameBytes.sanitize(frame)

        XCTAssertEqual(replayed, Data("keep".utf8))
    }

    func testSanitizeDropsC1AltScreenButKeepsOtherC1() {
        var frame = Data([0x9B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68])
        frame.append(Data("keep".utf8))
        frame.append(Data([0x9B, 0x31, 0x3B, 0x31, 0x48]))

        XCTAssertEqual(TerminalFrameBytes.sanitize(frame), Data("keep".utf8) + Data([0x9B, 0x31, 0x3B, 0x31, 0x48]))
    }

    func testSanitizeKeepsCursorRestoreAndDropsOnlyScrollRegions() {
        let frame = Data("\u{1B}[r\u{1B}[2;23r\u{1B}[u\u{1B}[?25r".utf8)
        let replayed = TerminalFrameBytes.sanitize(frame)

        XCTAssertFalse(replayed.contains(Data("\u{1B}[2;23r".utf8)))
        XCTAssertEqual(replayed, Data("\u{1B}[r\u{1B}[u\u{1B}[?25r".utf8))
    }

    func testSanitizeCopiesStringSequencesWhole() {
        let frame = Data("\u{1B}]0;report?7h\u{0007}\u{1B}]8;;https://h.example\u{1B}\\keep".utf8)
        XCTAssertEqual(TerminalFrameBytes.sanitize(frame), frame)
    }

    func testSanitizeKeepsAnUnterminatedSequenceIntact() {
        let frame = Data("keep\u{1B}[?7".utf8)
        XCTAssertEqual(TerminalFrameBytes.sanitize(frame), frame)
    }

    func testSanitizeIgnoresAModeNumberPastFourDigits() {
        let frame = Data("\u{1B}[?00001049h\u{1B}[1;1Hkeep".utf8)
        let replayed = TerminalFrameBytes.sanitize(frame)

        XCTAssertTrue(replayed.contains(Data("\u{1B}[?00001049h".utf8)))
        XCTAssertTrue(replayed.contains(Data("\u{1B}[1;1Hkeep".utf8)))
    }

    func testResetClearsTheVisibleScreenWithoutErasingScrollback() {
        XCTAssertTrue(TerminalFrameBytes.reset.contains(Data("\u{1B}[H\u{1B}[2J".utf8)))
        XCTAssertFalse(TerminalFrameBytes.reset.contains(Data([0x1B, 0x63])))
    }

    func testSanitizeDropsLeadingZeroesSpacesAndColonParameters() {
        let frame = Data("\u{1B}[?007h\u{1B}[?25:1049h\u{1B}[;23r\u{1B}[2;r\u{1B}[1;1Hkeep".utf8)
        let replayed = TerminalFrameBytes.sanitize(frame)

        XCTAssertFalse(replayed.contains(Data("\u{1B}[?007h".utf8)))
        XCTAssertFalse(replayed.contains(Data("1049".utf8)))
        XCTAssertFalse(replayed.contains(Data("\u{1B}[;23r".utf8)))
        XCTAssertFalse(replayed.contains(Data("\u{1B}[2;r".utf8)))
        XCTAssertTrue(replayed.contains(Data("\u{1B}[?25h".utf8)))
        XCTAssertTrue(replayed.contains(Data("\u{1B}[1;1Hkeep".utf8)))
    }
}

final class PendingTerminalFramesTests: XCTestCase {
    func testOnlyTheNewestFrameIsKeptUntilTheGridSettles() {
        let pending = PendingTerminalFrames()
        XCTAssertFalse(pending.accept(Data("first".utf8)))
        XCTAssertFalse(pending.accept(Data("second".utf8)))

        let generation = pending.gridWillChange()
        XCTAssertEqual(pending.takeSettled(generation), Data("second".utf8))
        XCTAssertNil(pending.takeSettled(generation))
        XCTAssertTrue(pending.accept(Data("live".utf8)))
    }

    func testALaterResizeKeepsTheFrameForTheFinalSize() {
        let pending = PendingTerminalFrames()
        XCTAssertFalse(pending.accept(Data("held".utf8)))
        let first = pending.gridWillChange()
        let last = pending.gridWillChange()

        XCTAssertNil(pending.takeSettled(first))
        XCTAssertEqual(pending.takeSettled(last), Data("held".utf8))
    }

    func testAResizeHoldsFramesAgainUntilItSettles() {
        let pending = PendingTerminalFrames()
        let generation = pending.gridWillChange()
        XCTAssertNil(pending.takeSettled(generation))
        XCTAssertTrue(pending.accept(Data("live".utf8)))

        let next = pending.gridWillChange()
        XCTAssertFalse(pending.accept(Data("during drag".utf8)))
        XCTAssertEqual(pending.takeSettled(next), Data("during drag".utf8))
    }
}

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
