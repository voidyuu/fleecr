import Darwin
import Foundation
import XCTest
@testable import HerdrKit

final class SocketRPCTests: XCTestCase {
    func testConnectDisablesSIGPIPE() throws {
        // Names stay short because sockaddr_un caps paths at 104 bytes and
        // temporaryDirectory already burns most of that (/var/folders/…).
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("s.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        XCTAssertLessThan(pathBytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(listener, socketAddress, addressLength)
            }
        }
        XCTAssertEqual(bindResult, 0, String(cString: strerror(errno)))
        XCTAssertEqual(listen(listener, 1), 0, String(cString: strerror(errno)))

        let client = try SocketRPC.connect(path: path)
        defer { close(client) }

        var noSigPipe: Int32 = 0
        var optionLength = socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        XCTAssertEqual(
            getsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &optionLength),
            0,
            String(cString: strerror(errno))
        )
        XCTAssertEqual(noSigPipe, 1)
    }

    func testReadLineClearsReceiveTimeoutWhenTimeoutIsNil() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let reader = fds[0]
        let writer = fds[1]
        defer {
            close(reader)
            close(writer)
        }

        let ack = "ack\n"
        _ = ack.withCString { Darwin.write(writer, $0, ack.utf8.count) }
        var buffer = Data()
        let firstLine = try SocketRPC.readLine(fd: reader, timeoutSeconds: 15, buffer: &buffer)
        XCTAssertEqual(firstLine, Data("ack".utf8))

        var tv = timeval()
        var len = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(getsockopt(reader, SOL_SOCKET, SO_RCVTIMEO, &tv, &len), 0)
        XCTAssertEqual(tv.tv_sec, 15)

        let event = "event\n"
        _ = event.withCString { Darwin.write(writer, $0, event.utf8.count) }

        let secondLine = try SocketRPC.readLine(fd: reader, timeoutSeconds: nil, buffer: &buffer)
        XCTAssertEqual(secondLine, Data("event".utf8))

        XCTAssertEqual(getsockopt(reader, SOL_SOCKET, SO_RCVTIMEO, &tv, &len), 0)
        XCTAssertEqual(tv.tv_sec, 0)
        XCTAssertEqual(tv.tv_usec, 0)
    }
}
