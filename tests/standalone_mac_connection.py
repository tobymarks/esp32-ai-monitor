#!/usr/bin/env python3
"""Exercise production standalone/command/disconnect methods with a fake transport.
Usage: python3 test_standalone_mac_connection.py [path/to/main.swift]
Only scheduling hooks and the close syscall are replaced; no app or port is opened.
"""
import pathlib, subprocess, sys, tempfile
source = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'companion/Sources/main.swift').read_text()
methods = source[source.index('    private func performJSONCommandSync('):source.index('    func readLine(timeout:')]
assert methods.count('ioLock.lock()') == 1
methods = methods.replace('ioLock.lock()', '''if pauseBeforeLock {
            reachedRequest.signal()
            permission.wait()
        }
        defer { requestFinished.signal() }
        ioLock.lock()''', 1)
disconnect = source[source.index('    func disconnect() {'):source.index('    /// Mappt eine per `get_info`')]
assert disconnect.count('Darwin.close(fileDescriptor)') == 1
disconnect = disconnect.replace('Darwin.close(fileDescriptor)', 'testClose(fileDescriptor)')
header = r'''
import Foundation
func L(_ key: String) -> String { key }
enum DeviceConnectionState { case connected, disconnected }
final class Harness {
    let ioLock = NSLock()
    var fileDescriptor: Int32 = 10
    var connectionGeneration = 0
    var state = DeviceConnectionState.connected
    var isReadyForCommands: Bool { state == .connected }
    var deviceStandaloneProtocol: Int? = 1
    var deviceFirmwareVersion: String? = "test"
    var deviceSerialTransport: String? = "aim1"
    var deviceMaxFrameBytes: Int? = 4095
    var deviceSceneProtocol: Int? = 2
    var devicePanel: String? = "test"
    var connectedPort: String? = "mock-A"
    var busyPort: String?
    var lastDisconnectAt: Date?
    var portLost = false
    var device = "A"
    var written: [(String, String)] = []
    var lastPayload: [String: Any] = [:]
    var pauseBeforeLock = false
    var pauseResponse = false
    let reachedRequest = DispatchSemaphore(value: 0)
    let permission = DispatchSemaphore(value: 0)
    let requestFinished = DispatchSemaphore(value: 0)
    let reading = DispatchSemaphore(value: 0)
    let respond = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    func encodeJSONForTransport(_ json: String, frameId: Int?) -> Data? { json.data(using: .utf8) }
    func drainInput() {}
    func routeUnsolicited(_ line: String) {}
    func testClose(_ fd: Int32) { closed.signal() }
    func writeAllLocked(_ data: Data) -> Int {
        lastPayload = (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
        written.append((device, lastPayload["cmd"] as! String))
        return data.count
    }
    func readLine(timeout: TimeInterval) -> String? {
        if pauseResponse { pauseResponse = false; reading.signal(); respond.wait() }
        let command = lastPayload["cmd"] as! String
        let response: [String: Any] = command == "standalone_status"
            ? ["type": "standalone_status", "digest": "", "enabled": false]
            : ["type": "standalone_ack", "command": command, "ok": true]
        return String(data: try! JSONSerialization.data(withJSONObject: response), encoding: .utf8)
    }
    func simulateNewDevice() {
        ioLock.lock(); defer { ioLock.unlock() }
        fileDescriptor = 11; state = .connected; deviceStandaloneProtocol = 1
        connectedPort = "mock-B"; device = "B"; portLost = false
    }
'''
footer = r'''
}
var failures: [String] = []
func check(_ condition: Bool, _ detail: String) {
    if !condition { failures.append(detail); print("FAIL: \(detail)") }
}
for action in ["setup", "remove", "enable"] {
    let h = Harness()
    h.pauseBeforeLock = true
    h.performStandalone(action: action) { _ in }
    precondition(h.reachedRequest.wait(timeout: .now()+2) == .success, "request never queued")
    // The production request passed its outer guard but has not acquired ioLock.
    h.disconnect()
    h.simulateNewDevice()
    h.permission.signal()
    precondition(h.requestFinished.wait(timeout: .now()+2) == .success, "queued request stuck")
    check(h.written.isEmpty, "queued \(action) crossed device generation: \(h.written)")
}
do {
    let h = Harness()
    h.pauseResponse = true
    h.performStandalone(action: "remove") { _ in }
    precondition(h.reading.wait(timeout: .now()+2) == .success, "request never reached read")
    let disconnectStarted = DispatchSemaphore(value: 0)
    let disconnectFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        disconnectStarted.signal(); h.disconnect(); disconnectFinished.signal()
    }
    precondition(disconnectStarted.wait(timeout: .now()+2) == .success)
    check(h.closed.wait(timeout: .now()+0.2) == .timedOut,
          "disconnect closed descriptor while command owned ioLock")
    h.respond.signal()
    precondition(disconnectFinished.wait(timeout: .now()+2) == .success, "disconnect deadlocked")
    check(h.connectionGeneration == 1 && h.fileDescriptor == -1,
          "disconnect failed to invalidate connection")
}
if failures.isEmpty { print("5 standalone Mac connection checks passed") }
exit(failures.isEmpty ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix='aimonitor-mac-standalone-') as folder:
    path = pathlib.Path(folder) / 'connection.swift'
    path.write_text(header + disconnect + methods + footer)
    result = subprocess.run(['swift', str(path)])
    sys.exit(result.returncode)
