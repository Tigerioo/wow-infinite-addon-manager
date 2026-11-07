import Foundation
import CryptoKit

public struct ReleaseAsset: Decodable, Sendable {
    public let id: Int64
    public let name: String
    public let size: Int64
    public let digest: String?
    public let browserDownloadURL: URL
    enum CodingKeys: String, CodingKey {
        case id, name, size, digest
        case browserDownloadURL = "browser_download_url"
    }
}
public struct Release: Decodable, Sendable {
    public let id: Int64
    public let tagName: String
    public let assets: [ReleaseAsset]
    enum CodingKeys: String, CodingKey {
        case id, assets
        case tagName = "tag_name"
    }
}

public struct GitHubReleaseClient {
    public init() {}

    public static func parseRepository(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw AddonError.message("请输入 GitHub 的 HTTPS 仓库地址或 owner/repository。")
            }
            value = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            value = trimmed
        }
        let clean = value.hasSuffix(".git") ? String(value.dropLast(4)) : value
        let parts = clean.split(separator: "/", omittingEmptySubsequences: false)
        let pattern = "^[A-Za-z0-9_.-]+$"
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && String($0).range(of: pattern, options: .regularExpression) != nil && $0 != "." && $0 != ".." }) else {
            throw AddonError.message("仓库格式应为 owner/repository。")
        }
        return clean
    }

    public func latest(repository: String) async throws -> Release {
        let repo = try Self.parseRepository(repository)
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { throw AddonError.message("仓库地址无效。") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WoWAddonManager", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AddonError.message("GitHub 响应无效。") }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw AddonError.message("仓库或正式 Release 不存在；目前仅支持公开仓库。") }
            if http.statusCode == 403 || http.statusCode == 429 { throw AddonError.message("GitHub 拒绝请求或请求次数受限，请稍后重试。") }
            throw AddonError.message("GitHub 检查失败（HTTP \(http.statusCode)）。")
        }
        do { return try JSONDecoder().decode(Release.self, from: data) }
        catch { throw AddonError.message("无法读取 GitHub Release 信息。") }
    }

    public func asset(named name: String, in release: Release) throws -> ReleaseAsset {
        let expression = "^" + name.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + "$"
        let matches = release.assets.filter { $0.name.range(of: expression, options: .regularExpression) != nil }
        guard matches.count == 1, let asset = matches.first else { throw AddonError.message("未找到唯一匹配的 Release 附件“\(name)”，请检查附件名称或通配规则。") }
        guard asset.name.lowercased().hasSuffix(".zip") else { throw AddonError.message("目前只支持 ZIP 格式的 Release 附件。") }
        guard asset.size > 0 && asset.size <= 200 * 1024 * 1024 else { throw AddonError.message("附件为空或超过 200 MB。") }
        guard asset.browserDownloadURL.scheme == "https", asset.browserDownloadURL.host?.lowercased() == "github.com" else { throw AddonError.message("附件下载地址无效。") }
        return asset
    }

    public func download(_ asset: ReleaseAsset, to destination: URL) async throws {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("WoWAddonManager", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AddonError.message("下载附件失败，请稍后重试。") }
        let attrs = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size == asset.size && size > 0 && size <= 200 * 1024 * 1024 else { throw AddonError.message("下载的附件大小与 Release 不符。") }
        if let digest = asset.digest {
            guard digest.hasPrefix("sha256:") else { throw AddonError.message("附件校验类型不受支持。") }
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == String(digest.dropFirst(7)).lowercased() else { throw AddonError.message("附件 SHA-256 校验失败。") }
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
