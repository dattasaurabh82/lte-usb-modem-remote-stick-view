import Darwin
import Foundation
import Network

/// Small blocking helpers. Call them off the main actor.
enum System {

    /// Runs a program by absolute path and returns its exit status and stdout.
    /// `env` is added on top of the app's own environment.
    static func run(_ path: String, _ args: [String], env: [String: String] = [:]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !env.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// True when nothing listens on 127.0.0.1:port, checked by binding to it and letting go.
    /// SO_REUSEADDR as ssh uses it: closed connections still in TIME_WAIT (left for about 30 s
    /// after a browser used the proxy) must not count as taken, a listener still must.
    static func portIsFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = loopback(port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// True when something accepts a TCP connection on 127.0.0.1:port.
    static func canConnect(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = loopback(port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// Name of the process listening on a local TCP port, read from lsof.
    static func listenerName(_ port: UInt16) -> String? {
        let r = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fc"])
        return r.out.split(separator: "\n").first { $0.hasPrefix("c") }.map { String($0.dropFirst()) }
    }

    /// Full command line of a running process, or nil if it is gone.
    static func commandLine(of pid: Int32) -> String? {
        guard kill(pid, 0) == 0 else { return nil }
        let r = run("/bin/ps", ["-p", "\(pid)", "-o", "command="])
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return a
    }
}

/// Asks the stick who it is, through the SOCKS proxy.
enum Stick {
    static func deviceName(base: URL, socksPort: UInt16) async -> String? {
        let cfg = URLSessionConfiguration.ephemeral
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: socksPort)!)
        cfg.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let url = base.appendingPathComponent("api/device/information")
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        guard let a = xml.range(of: "<DeviceName>"),
              let b = xml.range(of: "</DeviceName>", range: a.upperBound..<xml.endIndex) else {
            return "answered"
        }
        return String(xml[a.upperBound..<b.lowerBound])
    }
}
