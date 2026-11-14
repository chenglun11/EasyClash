import Foundation
import Darwin

public enum UpdateProduct: String, CaseIterable, Identifiable {
    case easyClash = "EasyClash", netBird = "NetBird"
    public var id: Self { self }

    var repository: String {
        self == .netBird ? "netbirdio/netbird" : "chenglun11/EasyClash"
    }

    public func installedVersion() throws -> String? {
        if self == .easyClash {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                throw AppFailure("无法读取应用版本")
            }
            return value
        }
        guard let cli = NetBirdConnection.executable else { return nil }
        let result = try Command.run(cli, ["version"], timeout: 5)
        guard result.code == 0 else { throw AppFailure("无法读取 NetBird 客户端版本") }
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ReleaseUpdate {
    public let version: String
    public let name: String
    public let url: URL
    let digest: String
    let size: Int

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let digest: String?
            let size: Int
            let browser_download_url: String
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    // Stable releases use three numeric components. Reject malformed tags and
    // pre-release suffixes rather than turning them into an available upgrade.
    static func parts(_ value: String) throws -> [Int] {
        let parts = value.components(separatedBy: ".")
        guard parts.count == 3 else { throw AppFailure("无法识别版本号") }
        return try parts.map { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let n = Int(part), String(n) == part else { throw AppFailure("无法识别版本号") }
            return n
        }
    }

    public func isNewer(than installed: String) throws -> Bool {
        try Self.parts(installed).lexicographicallyPrecedes(Self.parts(version))
    }

    package static func parse(_ data: Data, product: UpdateProduct, arm: Bool) throws -> ReleaseUpdate {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v") else {
            throw AppFailure("尚无可用的稳定版本")
        }
        let version = String(release.tag_name.dropFirst())
        _ = try parts(version)
        if product == .easyClash && !arm { throw AppFailure("公开安装包目前仅支持 Apple Silicon") }
        let file = product == .netBird ? "netbird_\(version)_darwin_\(arm ? "arm64" : "amd64").pkg"
                                       : "EasyClash-\(version)-NetBird-macOS-arm64.dmg"
        let path = "https://github.com/\(product.repository)/releases/download/\(release.tag_name)/\(file)"
        guard let a = release.assets.first(where: { $0.name == file && $0.browser_download_url == path }),
              let sha = a.digest, sha.hasPrefix("sha256:"), sha.count == 71,
              sha.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              a.size > 0, a.size <= 256 * 1024 * 1024, let url = URL(string: path) else {
            throw AppFailure("发布页缺少匹配的安装包或 SHA-256 校验值")
        }
        return ReleaseUpdate(version: version, name: file, url: url, digest: String(sha.dropFirst(7)), size: a.size)
    }

    public static func latest(_ product: UpdateProduct) async throws -> ReleaseUpdate {
        let url = URL(string: "https://api.github.com/repos/\(product.repository)/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("EasyClash-update", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppFailure("GitHub 暂时未返回发布信息，请稍后重试")
        }
        #if arch(arm64)
        let arm = true
        #else
        let arm = false
        #endif
        return try parse(data, product: product, arm: arm)
    }

    package func verify(_ file: URL) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == size, Files.hash(data) == digest else { throw AppFailure("下载文件的 SHA-256 校验失败") }
        if name.hasSuffix(".pkg") {
            let result = try Command.run("/usr/sbin/pkgutil", ["--check-signature", file.path], timeout: 30)
            guard result.code == 0, result.out.components(separatedBy: .newlines).contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == "1. Developer ID Installer: NetBird GmbH (TA739QLA7A)"
            }) else { throw AppFailure("NetBird 安装包签名未通过验证") }
        }
    }

    public func download() async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 120))
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure("下载失败，请重试") }
        try verify(temp)
        let parent = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("com.easyclash.app/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dest = parent.appendingPathComponent(name)
        let stage = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temp, to: stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        guard rename(stage.path, dest.path) == 0 else { throw AppFailure("无法保存已验证的更新包") }
        return dest
    }
}
