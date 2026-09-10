import Carbon.HIToolbox
import XCTest
import HerdrKit
@testable import fleecr

@MainActor
final class TabNavigationShortcutTests: XCTestCase {
    func testDefaultTabShortcutsConfiguration() {
        let items = ShortcutItem.defaultItems
        guard let nextTab = items.first(where: { $0.id == "nextTab" }) else {
            XCTFail("Missing nextTab shortcut")
            return
        }
        guard let prevTab = items.first(where: { $0.id == "previousTab" }) else {
            XCTFail("Missing previousTab shortcut")
            return
        }

        XCTAssertEqual(nextTab.category, .general)
        XCTAssertEqual(nextTab.defaultShortcut?.keyCode, UInt16(kVK_Tab))
        XCTAssertEqual(nextTab.defaultShortcut?.modifierFlags, [.control])
        XCTAssertEqual(nextTab.defaultShortcut?.displayString, "⌃⇥")

        XCTAssertEqual(prevTab.category, .general)
        XCTAssertEqual(prevTab.defaultShortcut?.keyCode, UInt16(kVK_Tab))
        XCTAssertEqual(prevTab.defaultShortcut?.modifierFlags, [.shift])
        XCTAssertEqual(prevTab.defaultShortcut?.displayString, "⇧⇥")
    }

    func testShortcutStoreActionMatchingForTabEvents() {
        let store = ShortcutStore(items: ShortcutItem.defaultItems, defaults: UserDefaults(suiteName: "test.shortcuts.\(UUID().uuidString)")!)

        guard let tabEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: UInt16(kVK_Tab)
        ) else {
            XCTFail("Failed to construct tab event")
            return
        }

        guard let shiftTabEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: UInt16(kVK_Tab)
        ) else {
            XCTFail("Failed to construct shift-tab event")
            return
        }

        XCTAssertEqual(store.actionItemID(for: tabEvent), "nextTab")
        XCTAssertEqual(store.actionItemID(for: shiftTabEvent), "previousTab")
    }

    func testTabCyclingIncludesBothAgentsAndTerminals() throws {
        let model = AppModel()
        let deviceID = UUID()
        let device = Device(
            id: deviceID,
            name: "TestDevice",
            kind: .local
        )
        model.devices = [device]

        let snapshotJSON = """
        {
          "workspaces": [
            { "workspace_id": "w1", "number": 1, "label": "Work" }
          ],
          "agents": [
            { "pane_id": "p-agent-1", "agent": "codex", "agent_status": "idle", "workspace_id": "w1", "tab_id": "t1", "terminal_id": "term-a1" },
            { "pane_id": "p-agent-2", "agent": "claude", "agent_status": "idle", "workspace_id": "w1", "tab_id": "t2", "terminal_id": "term-a2" }
          ],
          "panes": [
            { "pane_id": "p-agent-1", "terminal_id": "term-a1", "workspace_id": "w1", "tab_id": "t1" },
            { "pane_id": "p-agent-2", "terminal_id": "term-a2", "workspace_id": "w1", "tab_id": "t2" },
            { "pane_id": "p-term-1", "terminal_id": "term-1", "workspace_id": "w1", "tab_id": "t3" },
            { "pane_id": "p-term-2", "terminal_id": "term-2", "workspace_id": "w1", "tab_id": "t4" }
          ],
          "tabs": [
            { "tab_id": "t1", "workspace_id": "w1", "number": 1, "label": "Agent 1" },
            { "tab_id": "t2", "workspace_id": "w1", "number": 2, "label": "Agent 2" },
            { "tab_id": "t3", "workspace_id": "w1", "number": 3, "label": "Term 1" },
            { "tab_id": "t4", "workspace_id": "w1", "number": 4, "label": "Term 2" }
          ]
        }
        """

        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(snapshotJSON.utf8))
        var sessionState = DeviceSessionState()
        sessionState.workspaces = snapshot.workspaces
        sessionState.agents = snapshot.agents
        sessionState.panes = snapshot.ordinaryTerminalPanes
        sessionState.tabs = snapshot.tabs ?? []
        model.sessions[deviceID] = sessionState

        let spaceRef = SpaceRef(deviceID: deviceID, workspaceID: "w1")
        model.selectedSpace = spaceRef

        let expectedRefs = [
            PaneRef(deviceID: deviceID, paneID: "p-agent-1"),
            PaneRef(deviceID: deviceID, paneID: "p-agent-2"),
            PaneRef(deviceID: deviceID, paneID: "p-term-1"),
            PaneRef(deviceID: deviceID, paneID: "p-term-2")
        ]

        XCTAssertEqual(model.allVisibleTabPaneRefs, expectedRefs)

        // 1. Initial selection: start at first agent
        model.selectedPane = expectedRefs[0]

        // Cycle next: agent-1 -> agent-2 -> term-1 -> term-2 -> agent-1
        model.selectNextTab()
        XCTAssertEqual(model.selectedPane, expectedRefs[1])

        model.selectNextTab()
        XCTAssertEqual(model.selectedPane, expectedRefs[2])

        model.selectNextTab()
        XCTAssertEqual(model.selectedPane, expectedRefs[3])

        model.selectNextTab()
        XCTAssertEqual(model.selectedPane, expectedRefs[0], "Should loop back to first agent")

        // Cycle previous: agent-1 -> term-2 -> term-1 -> agent-2 -> agent-1
        model.selectPreviousTab()
        XCTAssertEqual(model.selectedPane, expectedRefs[3], "Should wrap to last terminal")

        model.selectPreviousTab()
        XCTAssertEqual(model.selectedPane, expectedRefs[2])

        model.selectPreviousTab()
        XCTAssertEqual(model.selectedPane, expectedRefs[1])

        model.selectPreviousTab()
        XCTAssertEqual(model.selectedPane, expectedRefs[0])
    }

    func testTabCyclingEdgeCases() throws {
        let model = AppModel()
        let deviceID = UUID()
        let device = Device(
            id: deviceID,
            name: "TestDevice",
            kind: .local
        )
        model.devices = [device]

        let snapshotJSON = """
        {
          "workspaces": [
            { "workspace_id": "w1", "number": 1, "label": "Work" }
          ],
          "agents": [],
          "panes": [
            { "pane_id": "p-term-1", "terminal_id": "term-1", "workspace_id": "w1", "tab_id": "t1" }
          ],
          "tabs": [
            { "tab_id": "t1", "workspace_id": "w1", "number": 1, "label": "Term 1" }
          ]
        }
        """

        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(snapshotJSON.utf8))
        var sessionState = DeviceSessionState()
        sessionState.workspaces = snapshot.workspaces
        sessionState.agents = snapshot.agents
        sessionState.panes = snapshot.ordinaryTerminalPanes
        sessionState.tabs = snapshot.tabs ?? []
        model.sessions[deviceID] = sessionState
        model.selectedSpace = SpaceRef(deviceID: deviceID, workspaceID: "w1")

        // When selectedPane is nil, next tab selects first
        model.selectedPane = nil
        model.selectNextTab()
        XCTAssertEqual(model.selectedPane, PaneRef(deviceID: deviceID, paneID: "p-term-1"))

        // When selectedPane is nil, previous tab selects last
        model.selectedPane = nil
        model.selectPreviousTab()
        XCTAssertEqual(model.selectedPane, PaneRef(deviceID: deviceID, paneID: "p-term-1"))

        // When space has no tabs, cycling does nothing
        model.sessions[deviceID]?.panes = []
        model.selectedPane = nil
        model.selectNextTab()
        XCTAssertNil(model.selectedPane)
        model.selectPreviousTab()
        XCTAssertNil(model.selectedPane)
    }
}
