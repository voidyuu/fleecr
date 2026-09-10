import Foundation
import XCTest
@testable import HerdrKit

final class WorkspaceDirectoryTests: XCTestCase {
    func testCurrentPathPrefersSelectedPaneThenActiveTab() throws {
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(#"""
        {
          "agents": [],
          "workspaces": [{
            "workspace_id": "w1", "number": 1, "label": "Space 1",
            "focused": true, "pane_count": 2, "tab_count": 2,
            "active_tab_id": "w1:t1", "agent_status": "idle"
          }],
          "panes": [
            {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","cwd":"/active"},
            {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2","cwd":"/selected"}
          ]
        }
        """#.utf8))

        XCTAssertEqual(snapshot.workspaceCWD(workspaceID: "w1"), "/active")
        XCTAssertEqual(snapshot.workspaceCWD(workspaceID: "w1", preferredPaneID: "w1:p2"), "/selected")
    }
}
