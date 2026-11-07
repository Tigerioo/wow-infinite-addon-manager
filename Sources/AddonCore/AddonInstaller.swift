import Foundation
import ZIPFoundation

/// A successful install keeps the prior directory as a recoverable backup.
public struct InstallOutcome {
    public let addonDirectory: String
    public let backupURL: URL?
}

public enum AddonInstallError: LocalizedError {
    case invalidDirectoryName
    case invalidDestination
    case invalidArchive(String)
    case unmanagedExistingDirectory(String)
    case unsafeExistingDirectory(String)
    case installationInProgress(String)
    case interruptedInstallation(String)
    case replacementFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectoryName: return "插件目录名只能包含英文字母、数字、下划线和连字符。"
        case .invalidDestination: return "插件目标目录不存在或不可写。"
        case .invalidArchive(let reason): return "安装包不符合要求：\(reason)"
        case .unmanagedExistingDirectory(let path): return "插件目录已存在但未由本应用管理，未覆盖：\(path)"
        case .unsafeExistingDirectory(let path): return "插件目标不是普通目录，未覆盖：\(path)"
        case .installationInProgress(let path): return "该插件正在安装，或上次安装异常中断。请检查：\(path)"
        case .interruptedInstallation(let path): return "发现上次未完成的安装备份，请先人工检查恢复：\(path)"
        case .replacementFailed(let details): return "安装替换失败：\(details)"
        }
    }
}

/// Installs only one explicitly named add-on; no other directory is modified.
public struct AddonInstaller {
    private let maximumEntries = 10_000
    private let maximumBytes: UInt64 = 512 * 1024 * 1024
    public init() {}

    public func install(archive: URL, destination: URL, addonDirectory: String, isManaged: Bool) throws -> InstallOutcome {
        guard !addonDirectory.isEmpty,
              addonDirectory.utf8.count <= 180,
              addonDirectory.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) })
        else { throw AddonInstallError.invalidDirectoryName }
        let fm = FileManager.default
        let root = destination.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard destination.isFileURL, fm.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue, fm.isWritableFile(atPath: root.path)
        else { throw AddonInstallError.invalidDestination }

        let lock = root.appendingPathComponent(".addon-manager-install-\(addonDirectory).lock", isDirectory: true)
        do {
            try fm.createDirectory(at: lock, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw AddonInstallError.installationInProgress(lock.path)
        }
        defer { try? fm.removeItem(at: lock) }
        let recoveryPrefix = ".addon-manager-recovery-\(addonDirectory)-"
        if let pending = try fm.contentsOfDirectory(atPath: root.path).first(where: { $0.hasPrefix(recoveryPrefix) }) {
            throw AddonInstallError.interruptedInstallation(root.appendingPathComponent(pending).path)
        }

        let target = root.appendingPathComponent(addonDirectory, isDirectory: true)
        let targetExists = itemExistsWithoutFollowingSymlinks(target)
        if targetExists {
            let attributes = try fm.attributesOfItem(atPath: target.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw AddonInstallError.unsafeExistingDirectory(target.path)
            }
            guard isManaged else { throw AddonInstallError.unmanagedExistingDirectory(target.path) }
        }

        let zip: Archive
        do { zip = try Archive(url: archive, accessMode: .read) }
        catch { throw AddonInstallError.invalidArchive("无法读取 ZIP 文件。") }
        let declaredEntries = try validateCentralDirectory(archive)
        let entries = try validate(zip, addonDirectory: addonDirectory, declaredEntries: declaredEntries)
        let identity = UUID().uuidString
        let stage = root.appendingPathComponent(".addon-manager-stage-\(identity)", isDirectory: true)
        let stagedAddon = stage.appendingPathComponent(addonDirectory, isDirectory: true)
        try fm.createDirectory(at: stagedAddon, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        try extract(entries, from: zip, to: stagedAddon)

        // The recovery marker is deliberately kept until replacement succeeds. A crash cannot erase the old version.
        var recovery: URL?
        if targetExists {
            let path = root.appendingPathComponent(recoveryPrefix + identity, isDirectory: true)
            try fm.moveItem(at: target, to: path)
            recovery = path
        }
        do {
            try fm.moveItem(at: stagedAddon, to: target)
        } catch {
            if let recovery {
                do { try fm.moveItem(at: recovery, to: target) }
                catch { throw AddonInstallError.replacementFailed("原版本保存在 \(recovery.path)，请手动恢复。") }
            }
            throw AddonInstallError.replacementFailed(error.localizedDescription)
        }
        // Preserve the old version even if the final backup rename fails.
        var backup: URL?
        if let recovery {
            let finalBackup = root.appendingPathComponent(".addon-manager-backup-\(addonDirectory)-\(identity)", isDirectory: true)
            do { try fm.moveItem(at: recovery, to: finalBackup); backup = finalBackup }
            catch { backup = recovery }
        }
        return InstallOutcome(addonDirectory: addonDirectory, backupURL: backup)
    }

    private struct ValidatedEntry {
        let entry: Entry
        let components: [String]
    }

    /// ZIPFoundation does not expose raw Unix file kinds or detect every truncated
    /// directory while iterating. Inspect the bounded central directory first.
    private func validateCentralDirectory(_ archive: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw AddonInstallError.invalidArchive("ZIP 目录损坏。") }
        let tailLength = Int(min(length, 65_557))
        try handle.seek(toOffset: length - UInt64(tailLength))
        let tail = [UInt8](try handle.read(upToCount: tailLength) ?? Data())
        func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
        func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(b, i)) | (UInt32(u16(b, i + 2)) << 16) }
        guard tail.count >= 22 else { throw AddonInstallError.invalidArchive("ZIP 目录损坏。") }
        let eocdIndex = stride(from: tail.count - 22, through: 0, by: -1).first { index in
            u32(tail, index) == 0x06054b50 && index + 22 + Int(u16(tail, index + 20)) == tail.count
        }
        guard let eocdIndex else { throw AddonInstallError.invalidArchive("缺少 ZIP 中央目录。") }
        let entries = Int(u16(tail, eocdIndex + 10))
        let centralSize = UInt64(u32(tail, eocdIndex + 12))
        let centralOffset = UInt64(u32(tail, eocdIndex + 16))
        let eocdOffset = length - UInt64(tailLength) + UInt64(eocdIndex)
        guard u16(tail, eocdIndex + 4) == 0, u16(tail, eocdIndex + 6) == 0,
              u16(tail, eocdIndex + 8) == u16(tail, eocdIndex + 10),
              entries != 0xffff, entries > 0, entries <= maximumEntries,
              centralSize != 0xffffffff, centralOffset != 0xffffffff,
              centralOffset <= eocdOffset, centralSize <= eocdOffset - centralOffset
        else { throw AddonInstallError.invalidArchive("不支持分卷、ZIP64 或损坏的压缩包。") }
        try handle.seek(toOffset: centralOffset)
        var consumed: UInt64 = 0
        for _ in 0 ..< entries {
            guard consumed + 46 <= centralSize,
                  let data = try handle.read(upToCount: 46), data.count == 46 else {
                throw AddonInstallError.invalidArchive("ZIP 文件清单不完整。")
            }
            let header = [UInt8](data)
            guard u32(header, 0) == 0x02014b50, (u16(header, 8) & 1) == 0,
                  u32(header, 20) != 0xffffffff, u32(header, 24) != 0xffffffff,
                  u32(header, 42) != 0xffffffff else {
                throw AddonInstallError.invalidArchive("不支持加密、ZIP64 或损坏的文件。")
            }
            let host = header[5]
            if host == 3 || host == 19 {
                let type = (u32(header, 38) >> 16) & 0xf000
                guard type == 0 || type == 0x8000 || type == 0x4000 else {
                    throw AddonInstallError.invalidArchive("压缩包包含链接或特殊文件。")
                }
            }
            let extra = UInt64(u16(header, 28)) + UInt64(u16(header, 30)) + UInt64(u16(header, 32))
            guard extra <= centralSize - consumed - 46 else { throw AddonInstallError.invalidArchive("ZIP 文件清单不完整。") }
            consumed += 46 + extra
            try handle.seek(toOffset: centralOffset + consumed)
        }
        guard consumed == centralSize else { throw AddonInstallError.invalidArchive("ZIP 文件清单不完整。") }
        return entries
    }

    private func validate(_ zip: Archive, addonDirectory: String, declaredEntries: Int) throws -> [ValidatedEntry] {
        var raw: [(Entry, [String])] = []
        var total: UInt64 = 0
        for entry in zip {
            guard raw.count < maximumEntries else { throw AddonInstallError.invalidArchive("文件数量过多。") }
            let path = entry.path
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
                throw AddonInstallError.invalidArchive("存在不安全路径。")
            }
            let stripped = path.hasSuffix("/") ? String(path.dropLast()) : path
            let parts = stripped.components(separatedBy: "/")
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else {
                throw AddonInstallError.invalidArchive("存在不安全路径。")
            }
            guard entry.type != .symlink else { throw AddonInstallError.invalidArchive("不支持符号链接。") }
            guard entry.uncompressedSize <= maximumBytes - total else { throw AddonInstallError.invalidArchive("解压后内容过大。") }
            total += entry.uncompressedSize
            raw.append((entry, parts))
        }
        guard raw.count == declaredEntries else { throw AddonInstallError.invalidArchive("ZIP 文件清单不完整或包含不支持的条目。") }
        let wrapped = raw.allSatisfy { $0.1.first == addonDirectory }
        var foundTOC = false
        var paths = Set<String>()
        var validated: [ValidatedEntry] = []
        for (entry, fullPath) in raw {
            let path = wrapped ? Array(fullPath.dropFirst()) : fullPath
            if path.isEmpty {
                guard entry.type == .directory else { throw AddonInstallError.invalidArchive("插件目录结构不正确。") }
                continue
            }
            let key = path.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted else { throw AddonInstallError.invalidArchive("存在重复文件路径。") }
            if path.count == 1 && path[0].lowercased() == "\(addonDirectory).toc".lowercased() && entry.type == .file { foundTOC = true }
            validated.append(ValidatedEntry(entry: entry, components: path))
        }
        guard foundTOC else { throw AddonInstallError.invalidArchive("未找到插件根目录中的 \(addonDirectory).toc。") }
        return validated
    }

    private func extract(_ entries: [ValidatedEntry], from zip: Archive, to root: URL) throws {
        let fm = FileManager.default
        var bytesWritten: UInt64 = 0
        for item in entries {
            let url = item.components.reduce(root) { $0.appendingPathComponent($1) }
            if item.entry.type == .directory {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AddonInstallError.invalidArchive("无法创建解压文件。")
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var entryBytes: UInt64 = 0
            let checksum = try zip.extract(item.entry) { chunk in
                let count = UInt64(chunk.count)
                guard count <= self.maximumBytes - bytesWritten,
                      count <= item.entry.uncompressedSize - entryBytes else {
                    throw AddonInstallError.invalidArchive("解压内容超过声明大小。")
                }
                bytesWritten += count
                entryBytes += count
                try handle.write(contentsOf: chunk)
            }
            guard entryBytes == item.entry.uncompressedSize, checksum == item.entry.checksum else {
                throw AddonInstallError.invalidArchive("文件大小或校验不匹配。")
            }
        }
    }

    private func itemExistsWithoutFollowingSymlinks(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
