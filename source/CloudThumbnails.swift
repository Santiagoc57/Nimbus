import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

actor ThumbnailCache {
    struct Record: Codable { let data: Data?; let fetchedAt: Date }
    let root: URL
    let maximumBytes: Int
    let maximumFiles: Int
    var keyAccount: String { "thumbnail-cache:" + root.standardizedFileURL.path }

    init(support: URL, maximumBytes: Int = 32 * 1024 * 1024, maximumFiles: Int = 512) {
        root = support.appendingPathComponent("Thumbnails", isDirectory: true)
        self.maximumBytes = max(0, maximumBytes); self.maximumFiles = max(0, maximumFiles)
    }
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func key(_ entry: RemoteEntry) -> String {
        // Name/path/alias changes don't invalidate the file's image.
        let parts = [entry.remote, entry.item.ID ?? "", entry.item.ModTime ?? "", String(entry.item.Size), entry.item.MimeType ?? ""]
        return hash(parts.map { "\($0.utf8.count):\($0)" }.joined())
    }
    private func file(_ entry: RemoteEntry) -> URL {
        root.appendingPathComponent(Self.hash(entry.remote), isDirectory: true).appendingPathComponent(Self.key(entry) + ".thumb")
    }
    func read(_ entry: RemoteEntry, now: Date = Date()) -> Record? {
        let url = file(entry)
        guard let encrypted = try? NimboSecureFile.loadData(from: url, account: keyAccount, keychain: false),
              let record = try? JSONDecoder().decode(Record.self, from: encrypted) else { return nil }
        let age = now.timeIntervalSince(record.fetchedAt)
        guard age >= 0, age < (record.data == nil ? 600 : 7 * 86400) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return record
    }
    func store(_ data: Data?, for entry: RemoteEntry, now: Date = Date()) throws {
        try Task.checkCancellation()
        let record = Record(data: data, fetchedAt: now)
        try NimboSecureFile.saveData(JSONEncoder().encode(record), to: file(entry), account: keyAccount, keychain: false)
        try trim()
    }
    func removeAccounts(except accounts: Set<String>) throws {
        let keep = Set(accounts.map(Self.hash))
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs where !keep.contains(dir.lastPathComponent) && dir.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            try FileManager.default.removeItem(at: dir)
        }
    }
    private func trim() throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        var files: [(URL, Int, Date)] = []
        for case let file as URL in enumerator where file.pathExtension == "thumb" {
            let attrs = try file.resourceValues(forKeys: keys)
            if attrs.isRegularFile == true { files.append((file, attrs.fileSize ?? 0, attrs.contentModificationDate ?? .distantPast)) }
        }
        files.sort { $0.2 < $1.2 }
        var bytes = files.reduce(0) { $0 + $1.1 }, count = files.count
        for file in files {
            guard bytes > maximumBytes || count > maximumFiles else { break }
            try FileManager.default.removeItem(at: file.0); bytes -= file.1; count -= 1
        }
    }

    /// Decode a bounded image and re-encode pixels only. Never retain remote
    /// image metadata or allow huge dimensions to allocate an original bitmap.
    static func normalized(_ data: Data) throws -> Data {
        guard data.count <= 2 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw DriveFailure.invalidResponse }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw DriveFailure.invalidResponse }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 512 * 1024 else { throw DriveFailure.invalidResponse }
        return output as Data
    }
}

actor ThumbnailGate {
    private var free: Int
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(limit: Int = 3) { free = max(1, limit) }
    func run<T>(_ work: () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if free > 0 { free -= 1; continuation.resume() }
                else { waiting.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
        defer {
            if waiting.isEmpty { free += 1 }
            else { waiting.removeFirst().1.resume() }
        }
        try Task.checkCancellation()
        return try await work()
    }
    private func cancel(_ id: UUID) {
        guard let i = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: i).1.resume(throwing: CancellationError())
    }
}

actor CloudThumbnails {
    private struct Request { let task: Task<Data?, Error>; let remote: String; var consumers: Set<UUID> }
    let cache: ThumbnailCache
    private let gate: ThumbnailGate
    private let configuration: URL
    private let session: URLSession
    private var apis: [String: DriveAPI] = [:]
    private var requests: [String: Request] = [:]
    private var accounts: Set<String>?

    init(configuration: URL, support: URL, session: URLSession = .shared, concurrency: Int = 3) {
        self.configuration = configuration; self.session = session
        cache = ThumbnailCache(support: support); gate = ThumbnailGate(limit: concurrency)
    }
    func setAccounts(_ accounts: Set<String>) async {
        self.accounts = accounts
        apis = apis.filter { accounts.contains($0.key) }
        for key in Array(requests.keys) where !accounts.contains(requests[key]!.remote) {
            requests[key]?.task.cancel(); requests.removeValue(forKey: key)
        }
        try? await cache.removeAccounts(except: accounts)
    }
    func thumbnail(_ entry: RemoteEntry) async -> Data? {
        guard !entry.item.IsDir, let id = entry.item.ID, !id.isEmpty,
              accounts == nil || accounts!.contains(entry.remote) else { return nil }
        let cached = await cache.read(entry)
        guard !Task.isCancelled, accounts == nil || accounts!.contains(entry.remote) else { return nil }
        if let cached { return cached.data }
        let key = ThumbnailCache.key(entry), consumer = UUID()
        let task: Task<Data?, Error>
        if var pending = requests[key] {
            pending.consumers.insert(consumer); requests[key] = pending; task = pending.task
        } else {
            let api = apis[entry.remote] ?? DriveAPI(configuration: configuration, remoteName: entry.remote, session: session)
            apis[entry.remote] = api
            let gate = self.gate, cache = self.cache
            task = Task {
                try await gate.run {
                    let raw = try await api.thumbnail(id)
                    try Task.checkCancellation()
                    let image = try raw.map(ThumbnailCache.normalized)
                    try await cache.store(image, for: entry)
                    return image
                }
            }
            requests[key] = Request(task: task, remote: entry.remote, consumers: [consumer])
        }
        defer { release(key, consumer: consumer) }
        return await withTaskCancellationHandler(operation: {
            do { let result = try await task.value; try Task.checkCancellation(); return result }
            catch { return nil }
        }, onCancel: { Task { await self.release(key, consumer: consumer) } })
    }
    private func release(_ key: String, consumer: UUID) {
        guard var request = requests[key], request.consumers.remove(consumer) != nil else { return }
        if request.consumers.isEmpty { request.task.cancel(); requests.removeValue(forKey: key) }
        else { requests[key] = request }
    }
}
