import Foundation
import Darwin
import CryptoKit
import Yams

public struct AppFailure: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum Files {
    public static let fm = FileManager.default
    public static var home: URL { fm.homeDirectoryForCurrentUser }
    public static var state: URL { home.appendingPathComponent("Library/Application Support/EasyClash") }
    public static var clash: URL { home.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev") }
    public static func prepare(_ dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public static func write(_ data: Data, to url: URL) throws {
        try prepare(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let fd = open(url.path, O_RDONLY); if fd >= 0 { _ = fsync(fd); close(fd) }
    }
    public static func json<T: Encodable>(_ value: T, to url: URL) throws { try write(JSONEncoder().encode(value), to: url) }
    public static func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x", $0) }.joined() }
    public static func yaml(_ url: URL) throws -> [String: Any] {
        do { guard let v = try Yams.load(yaml: String(contentsOf: url)) as? [String: Any] else { throw AppFailure("配置不是 YAML 对象") }; return v }
        catch { throw AppFailure("无法读取配置（路径或 YAML 格式有误）") }
    }
    public static func yamlText(_ object: [String: Any]) throws -> String {
        do { return try Yams.dump(object: object, allowUnicode: true, sortKeys: true) }
        catch { throw AppFailure("无法生成 YAML 配置") }
    }
}
public final class FileLock {
    private let fd: Int32
    public init(_ url: URL) throws {
        try Files.prepare(url.deletingLastPathComponent())
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; throw AppFailure("另一个协调操作正在进行") }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
public struct CommandResult { public let code: Int32; public let out: String }
public enum Command {
    // No shell, no interpolated commands. Drain both pipes while the child runs.
    public static func run(_ path: String, _ args: [String], input: Data? = nil, timeout: Double = 10) throws -> CommandResult {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where ["http_proxy","https_proxy","all_proxy"].contains(key.lowercased()) { environment.removeValue(forKey:key) }
        p.environment = environment
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        p.standardOutput = stdout; p.standardError = stderr; p.standardInput = stdin
        let done = DispatchSemaphore(value:0)
        // Register before launch: waitUntilExit on a different worker can miss the
        // launching thread's run-loop notification for a short-lived process.
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        let readers = DispatchGroup()
        let output = DataBox()
        readers.enter(); DispatchQueue.global().async { output.set(stdout.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        readers.enter(); DispatchQueue.global().async { _ = stderr.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
        DispatchQueue.global().async { if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }; try? stdin.fileHandleForWriting.close() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout:.now()+1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                guard done.wait(timeout:.now()+2) == .success else {throw AppFailure("检测子进程无法结束，稍后重试")}
            }
        }
        guard readers.wait(timeout:.now()+2) == .success else {throw AppFailure("检测输出未能及时结束，稍后重试")}
        return CommandResult(code:p.terminationStatus, out:String(data:output.get(),encoding:.utf8) ?? "")
    }
}
private final class DataBox: @unchecked Sendable {
    private var value=Data(); private let lock=NSLock()
    func set(_ d:Data) { lock.lock(); defer {lock.unlock()}; value=d }
    func get()->Data { lock.lock(); defer {lock.unlock()}; return value }
}
public struct Settings: Codable, Equatable {
    public var domains: [String] = []
    public var dns: String = ""
    public var probeHost: String = ""
    public var effectiveProbeHost: String {probeHost.isEmpty ? (domains.first ?? "") : probeHost}
    public var client:ProxyClient = .verge
    public var clashDirectory: String = Files.clash.path
    public var configURL:URL {URL(fileURLWithPath:clashDirectory).appendingPathComponent(client.configName)}
    public init() {}
    enum CodingKeys:String,CodingKey {case domains,dns,clashDirectory,client,probeHost}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        client=try c.decodeIfPresent(ProxyClient.self,forKey:.client) ?? .verge
        domains=try c.decodeIfPresent([String].self,forKey:.domains) ?? []
        dns=try c.decodeIfPresent(String.self,forKey:.dns) ?? ""
        probeHost=try c.decodeIfPresent(String.self,forKey:.probeHost) ?? ""
        clashDirectory=try c.decodeIfPresent(String.self,forKey:.clashDirectory) ?? client.directory.path
    }
    public func validated() throws -> Settings {
        var s=self
        s.domains = Array(Set(domains.map { $0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }.filter {!$0.isEmpty})).sorted()
        guard !s.domains.isEmpty, s.domains.count <= 30, s.domains.allSatisfy({ d in
            d.count <= 253 && d.contains(".") && d.split(separator:".",omittingEmptySubsequences:false).allSatisfy { label in
                !label.isEmpty && label.count <= 63 && label.range(of:"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$",options:.regularExpression) != nil
            }
        }) else { throw AppFailure("域名格式有误：填写完整域名，不含通配符、协议或路径") }
        s.probeHost=probeHost.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if !s.probeHost.isEmpty {
            let labels=s.probeHost.split(separator:".",omittingEmptySubsequences:false)
            guard s.probeHost.count<=253,labels.allSatisfy({!$0.isEmpty && $0.count<=63 && $0.range(of:"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$",options:.regularExpression) != nil}),s.domains.contains(where:{s.probeHost == $0 || s.probeHost.hasSuffix("."+$0)}) else {throw AppFailure("探测主机必须属于已配置的公司域名，且不含协议或路径")}
        }
        var ip=in_addr()
        guard inet_pton(AF_INET,s.dns,&ip)==1, !s.dns.hasPrefix("127."), s.dns != "0.0.0.0", !s.dns.hasPrefix("198.18."), !s.dns.hasPrefix("198.19.") else { throw AppFailure("公司 DNS 必须是有效的非回环 IPv4 地址") }
        guard s.clashDirectory.hasPrefix("/") else { throw AppFailure("Clash 配置目录必须是绝对路径") }
        return s
    }
}
public final class Audit {
    let url:URL
    public init(root:URL) { url=root.appendingPathComponent("events.jsonl") }
    // Event codes only: never raw errors, configuration, URLs, query strings, or process output.
    public func event(_ code:String) {
        // Serialize small event writes across the app and guardian; never lose a record by racing atomic replacements.
        try? Files.prepare(url.deletingLastPathComponent())
        let fd=open(url.deletingLastPathComponent().appendingPathComponent("audit.lock").path,O_CREAT | O_RDWR,0o600)
        guard fd>=0 else {return}
        guard flock(fd,LOCK_EX)==0 else {close(fd);return}
        defer {flock(fd,LOCK_UN);close(fd)}
        let line="{\"time\":\"\(ISO8601DateFormatter().string(from:Date()))\",\"event\":\"\(code.filter { $0.isLetter || $0.isNumber || $0 == "_" })\"}\n"
        var data=(try? Data(contentsOf:url)) ?? Data()
        if data.count > 256_000 { data=Data() }
        data.append(Data(line.utf8)); try? Files.write(data,to:url)
    }
}
