import XCTest
@testable import HerdrKit

final class DeviceStoreTests: XCTestCase {

    // MARK: - ProfileId <-> UUID

    func testProfileIDConversion() {
        let hex = "88a468a53137e617b651956957472081"
        guard let uuid = UUID(profileID: hex) else {
            XCTFail("Failed to convert profile ID to UUID")
            return
        }
        XCTAssertEqual(uuid.uuidString.lowercased(), "88a468a5-3137-e617-b651-956957472081")
        XCTAssertEqual(uuid.profileIDString, hex)

        // Roundtrip random UUIDs
        for _ in 0..<10 {
            let original = UUID()
            let profileID = original.profileIDString
            XCTAssertEqual(profileID.count, 32)
            XCTAssertTrue(profileID.allSatisfy { $0.isHexDigit })
            let roundtripped = UUID(profileID: profileID)
            XCTAssertEqual(roundtripped, original)
        }

        // Invalid inputs
        XCTAssertNil(UUID(profileID: "too-short"))
        XCTAssertNil(UUID(profileID: "88a468a53137e617b651956957472081extra"))
        XCTAssertNil(UUID(profileID: "88a468a53137e617b65195695747208z")) // 'z' is not hex
    }

    // MARK: - Official Herdr 0.9 Models

    func testSavedSshEndpointCodable() throws {
        let json = """
        {
          "id": "88a468a53137e617b651956957472081",
          "label": "shu-a6000",
          "target": "shu-a6000",
          "session": "default",
          "enabled": true
        }
        """.data(using: .utf8)!

        let endpoint = try JSONDecoder().decode(SavedSshEndpoint.self, from: json)
        XCTAssertEqual(endpoint.id, "88a468a53137e617b651956957472081")
        XCTAssertEqual(endpoint.label, "shu-a6000")
        XCTAssertEqual(endpoint.target, "shu-a6000")
        XCTAssertEqual(endpoint.session, "default")
        XCTAssertTrue(endpoint.enabled)

        let encodedData = try JSONEncoder().encode(endpoint)
        let dict = try JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        XCTAssertEqual(dict?["id"] as? String, "88a468a53137e617b651956957472081")
        XCTAssertEqual(dict?["label"] as? String, "shu-a6000")
        XCTAssertEqual(dict?["target"] as? String, "shu-a6000")
        XCTAssertEqual(dict?["session"] as? String, "default")
        XCTAssertEqual(dict?["enabled"] as? Bool, true)
    }

    func testEndpointCatalogCodable() throws {
        let catalog = EndpointCatalog(
            version: 1,
            selectedProfile: nil,
            ssh: [
                SavedSshEndpoint(
                    id: "88a468a53137e617b651956957472081",
                    label: "shu-a6000",
                    target: "shu-a6000",
                    session: "default",
                    enabled: true
                )
            ]
        )

        let data = try JSONEncoder().encode(catalog)
        let jsonString = String(data: data, encoding: .utf8)!
        // selected_profile should be omitted when nil (satisfies Rust #[serde(skip_serializing_if = "Option::is_none")])
        XCTAssertFalse(jsonString.contains("selected_profile"))

        let decoded = try JSONDecoder().decode(EndpointCatalog.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertNil(decoded.selectedProfile)
        XCTAssertEqual(decoded.ssh.count, 1)
        XCTAssertEqual(decoded.ssh[0].label, "shu-a6000")
    }

    func testEndpointSelectionCodable() throws {
        // Selection with null
        let nullJson = """
        {
          "version": 1,
          "selected_profile": null
        }
        """.data(using: .utf8)!
        let selNull = try JSONDecoder().decode(EndpointSelection.self, from: nullJson)
        XCTAssertEqual(selNull.version, 1)
        XCTAssertNil(selNull.selectedProfile)

        let encodedNull = try JSONEncoder().encode(selNull)
        let encodedNullString = String(data: encodedNull, encoding: .utf8)!
        XCTAssertTrue(encodedNullString.contains("\"selected_profile\" : null") || encodedNullString.contains("\"selected_profile\":null"))

        // Selection with profile ID
        let profileJson = """
        {
          "version": 1,
          "selected_profile": "88a468a53137e617b651956957472081"
        }
        """.data(using: .utf8)!
        let selProfile = try JSONDecoder().decode(EndpointSelection.self, from: profileJson)
        XCTAssertEqual(selProfile.selectedProfile, "88a468a53137e617b651956957472081")
    }

    // MARK: - DeviceStore CRUD & Selection

    func testDeviceStoreSaveAndLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = DeviceStore(directory: tempDir)
        let remoteID = UUID(profileID: "88a468a53137e617b651956957472081")!
        let remoteDevice = Device(
            id: remoteID,
            name: "shu-a6000",
            kind: .ssh(target: "shu-a6000"),
            session: "custom-session",
            isEnabled: false
        )

        store.save([Device.local, remoteDevice])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0], Device.local)
        XCTAssertEqual(loaded[1].id, remoteID)
        XCTAssertEqual(loaded[1].name, "shu-a6000")
        XCTAssertEqual(loaded[1].sshTarget, "shu-a6000")
        XCTAssertEqual(loaded[1].session, "custom-session")
        XCTAssertFalse(loaded[1].isEnabled)
        XCTAssertEqual(loaded[1].subtitle, "shu-a6000 (custom-session) · SSH")

        // Test Selection persistence
        store.saveSelectedProfile(remoteID)
        XCTAssertEqual(store.loadSelectedProfile(), remoteID)

        store.saveSelectedProfile(nil)
        XCTAssertNil(store.loadSelectedProfile())
    }

    // MARK: - Legacy Migration

    func testDeviceStoreLegacyMigration() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-test-mig-\(UUID().uuidString)")
        let legacyDir = tempDir.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write legacy devices.json
        let legacyJson = """
        [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Local",
            "kind": { "local": {} }
          },
          {
            "id": "04B9206F-E711-4366-A496-B694094EF97C",
            "name": "a6000",
            "kind": { "ssh": { "target": "zy@navi.ts.net" } }
          }
        ]
        """.data(using: .utf8)!
        try legacyJson.write(to: legacyDir.appendingPathComponent("devices.json"))

        let store = DeviceStore(directory: tempDir, legacyDirectory: legacyDir)
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0], Device.local)
        XCTAssertEqual(loaded[1].name, "a6000")
        XCTAssertEqual(loaded[1].sshTarget, "zy@navi.ts.net")
        XCTAssertEqual(loaded[1].session, "default")
        XCTAssertTrue(loaded[1].isEnabled)

        // Verify that endpoints.json was written in official format
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.endpointsURL.path))
        let catalogData = try Data(contentsOf: store.endpointsURL)
        let catalog = try JSONDecoder().decode(EndpointCatalog.self, from: catalogData)
        XCTAssertEqual(catalog.ssh.count, 1)
        XCTAssertEqual(catalog.ssh[0].label, "a6000")
        XCTAssertEqual(catalog.ssh[0].target, "zy@navi.ts.net")
    }

    // MARK: - SSHTunnel Socket Path

    func testSSHTunnelSocketPath() {
        let defaultSocket = SSHTunnel.remoteSocketPath(home: "/home/user", session: "default")
        XCTAssertEqual(defaultSocket, "/home/user/.config/herdr/herdr.sock")

        let customSocket = SSHTunnel.remoteSocketPath(home: "/home/user", session: "my-work")
        XCTAssertEqual(customSocket, "/home/user/.config/herdr/sessions/my-work/herdr.sock")
    }

    // MARK: - HerdrService Attach Command with Session

    func testHerdrServiceAttachCommandWithSession() {
        let defaultDevice = Device(
            name: "box",
            kind: .ssh(target: "box"),
            session: "default"
        )
        let defaultService = HerdrService(device: defaultDevice, autoStartLocalServer: false)
        let defaultCmd = defaultService.attachCommand(paneID: "pane-1")
        XCTAssertFalse(defaultCmd.args.joined().contains("--session"))

        let customDevice = Device(
            name: "box",
            kind: .ssh(target: "box"),
            session: "ai-session"
        )
        let customService = HerdrService(device: customDevice, autoStartLocalServer: false)
        let customCmd = customService.attachCommand(paneID: "pane-1")
        let customScript = customCmd.args.joined(separator: " ")
        XCTAssertTrue(customScript.contains("--session") && customScript.contains("ai-session"))
    }

    // MARK: - HerdrMachineCLI Binary Resolution

    func testHerdrMachineCLIResolveBinary() {
        let binary = HerdrMachineCLI.resolveBinary()
        XCTAssertNotNil(binary)
    }
}

