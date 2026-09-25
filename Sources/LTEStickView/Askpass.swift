import Darwin
import Foundation
import Security

/// Passwords for password-mode targets, kept only in the login Keychain.
/// One generic-password item per target: service "LTE Stick View", account "user@host".
enum Keychain {
    static let service = "LTE Stick View"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ password: String, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(service): \(account)"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Gets a Keychain password to ssh without a terminal, the command line or a lasting environment variable.
///
/// ssh runs with SSH_ASKPASS pointing at this app's own binary and SSH_ASKPASS_REQUIRE=force.
/// When ssh needs a password it starts the binary with the prompt as its argument; the binary sees
/// LSV_ASKPASS=1, connects to a private Unix socket the running app opened, presents a one-time
/// token, and prints the password it gets back. The socket answers once and is then removed.
enum Askpass {
    static let flag = "LSV_ASKPASS"
    static let socketVar = "LSV_ASKPASS_SOCKET"
    static let tokenVar = "LSV_ASKPASS_TOKEN"
    /// Only for tests: the helper appends each prompt it was given to this file.
    static let traceVar = "LSV_ASKPASS_TRACE"

    /// Helper side: runs when ssh starts the binary as its askpass program. Never returns.
    static func runHelper() -> Never {
        let env = ProcessInfo.processInfo.environment
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        if let trace = env[traceVar] {
            let line = "asked: \(prompt.replacingOccurrences(of: "\n", with: " "))\n"
            if let h = FileHandle(forWritingAtPath: trace) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
            else { try? line.write(toFile: trace, atomically: true, encoding: .utf8) }
        }
        // Only password prompts are answered. Host key questions and passphrases are declined.
        guard prompt.lowercased().contains("password"),
              let path = env[socketVar], let token = env[tokenVar] else { exit(1) }
        guard let reply = exchange(path: path, send: token + "\n"), !reply.isEmpty else { exit(1) }
        print(reply)
        exit(0)
    }

    /// Connects to the Unix socket, sends one line, returns what comes back.
    static func exchange(path: String, send: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }
        _ = send.withCString { write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// App side: a socket that hands out one password once, to whoever shows the token.
    final class Server: @unchecked Sendable {
        let path: String
        let token = UUID().uuidString + UUID().uuidString
        private let password: String
        private var fd: Int32 = -1
        private let lock = NSLock()
        private var served = false
        /// Called once, with true when the password was handed out and false on a wrong token.
        var onRequest: (@Sendable (Bool) -> Void)?

        init(password: String) {
            self.password = password
            // Short path: sun_path holds 104 bytes on macOS.
            path = "/tmp/lsv-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        }

        /// The environment ssh needs to use the helper.
        var environment: [String: String] {
            let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            return [
                "SSH_ASKPASS": exe,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0",
                Askpass.flag: "1",
                Askpass.socketVar: path,
                Askpass.tokenVar: token,
            ]
        }

        func start() -> Bool {
            unlink(path)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, b) in bytes.enumerated() { raw[i] = b }
            }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { close(fd); return false }
            chmod(path, 0o600)
            guard listen(fd, 4) == 0 else { stop(); return false }
            let listener = fd
            Thread.detachNewThread { [self] in self.serve(listener) }
            return true
        }

        private func serve(_ listener: Int32) {
            while true {
                let c = accept(listener, nil, nil)
                guard c >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 256)
                let n = read(c, &buf, buf.count)
                let got = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .newlines) : ""
                lock.lock()
                let answer = !served && got == token
                if answer { served = true }
                lock.unlock()
                if answer {
                    let reply = password + "\n"
                    _ = reply.withCString { write(c, $0, strlen($0)) }
                }
                close(c)
                onRequest?(answer)
                if answer { stop(); return }
            }
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 }
            unlink(path)
        }
    }
}
