import Foundation

enum TransferDirection: String, CaseIterable {
    case download, upload
    var title: String { self == .download ? "Descarga" : "Subida" }
}

struct SyncSettings: Codable, Equatable {
    var downloadKBps = 0
    var uploadKBps = 0
    // Retain the legacy transport preference without converting existing files.
    var splitLargeFiles = false
    var finderSegmentMB = 0
    var backupSegmentMB = 0
    /// Threshold for new files in linked folders («Sincronizar carpeta»). 0 = Nunca.
    var linkedSegmentMB = 0
    static let segmentSizes = [0, 100, 500, 1000, 2000]
    static func segmentLabel(_ size: Int) -> String {
        if size == 0 { return "Nunca" }
        return size >= 1000 ? "\(size / 1000) GB" : "\(size) MB"
    }

    static let allowed = [0, 1024, 5120, 20480]
    init() {}

    private enum CodingKeys: String, CodingKey { case downloadKBps, uploadKBps, splitLargeFiles, backupSegmentMB, finderSegmentMB, linkedSegmentMB }
    private enum LegacyKeys: String, CodingKey { case bandwidthKBps }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let previous = try legacy.decodeIfPresent(Int.self, forKey: .bandwidthKBps) ?? 0
        downloadKBps = try fields.decodeIfPresent(Int.self, forKey: .downloadKBps) ?? previous
        uploadKBps = try fields.decodeIfPresent(Int.self, forKey: .uploadKBps) ?? previous
        guard Self.allowed.contains(downloadKBps), Self.allowed.contains(uploadKBps) else {
            throw DecodingError.dataCorruptedError(forKey: .downloadKBps, in: fields, debugDescription: "Límite de transferencia desconocido")
        }
        backupSegmentMB = try fields.decodeIfPresent(Int.self, forKey: .backupSegmentMB) ?? 0
        guard Self.segmentSizes.contains(backupSegmentMB) else { throw DecodingError.dataCorruptedError(forKey: .backupSegmentMB, in: fields, debugDescription: "Tamaño de segmento desconocido") }
        finderSegmentMB = try fields.decodeIfPresent(Int.self, forKey: .finderSegmentMB) ?? 0
        guard Self.segmentSizes.contains(finderSegmentMB) else { throw DecodingError.dataCorruptedError(forKey: .finderSegmentMB, in: fields, debugDescription: "Tamaño de segmento de Finder desconocido") }
        linkedSegmentMB = try fields.decodeIfPresent(Int.self, forKey: .linkedSegmentMB) ?? 0
        guard Self.segmentSizes.contains(linkedSegmentMB) else { throw DecodingError.dataCorruptedError(forKey: .linkedSegmentMB, in: fields, debugDescription: "Tamaño de segmento de carpetas vinculadas desconocido") }
        splitLargeFiles = try fields.decodeIfPresent(Bool.self, forKey: .splitLargeFiles) ?? false
    }

    static func read(at file: URL) -> Self {
        guard let data = try? Data(contentsOf: file), let result = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return result
    }

    subscript(_ direction: TransferDirection) -> Int {
        get { direction == .download ? downloadKBps : uploadKBps }
        set { if direction == .download { downloadKBps = newValue } else { uploadKBps = newValue } }
    }

    static func label(_ kbps: Int) -> String {
        kbps == 0 ? "Sin límite" : "\(kbps / 1024) MiB/s"
    }

    static func file(for configuration: URL) -> URL {
        configuration.deletingLastPathComponent().appendingPathComponent("Sync/settings.json")
    }

    var rcloneArguments: [String] {
        guard uploadKBps > 0 || downloadKBps > 0 else { return [] }
        func rate(_ kbps: Int) -> String { kbps == 0 ? "off" : "\(kbps)k" }
        return ["--bwlimit", "\(rate(uploadKBps)):\(rate(downloadKBps))"]
    }
}

// Google resumable uploads require non-final chunks to be multiples of 256 KiB.
// Reserve request starts independently per direction so parallel native transfers
// within this process share the allowance. The first chunk may start immediately.
actor NativeBandwidthClock {
    static let shared = NativeBandwidthClock()
    private var nextStart: [TransferDirection: UInt64] = [:]

    static func chunkBytes(rate: Int) -> Int64 {
        guard rate > 0 else { return 8 * 1024 * 1024 }
        return Int64(max(1, rate / 1024)) * 256 * 1024
    }

    func reserve(bytes: Int64, rate: Int, direction: TransferDirection) async throws {
        guard rate > 0, bytes > 0 else { return }
        try Task.checkCancellation()
        let now = DispatchTime.now().uptimeNanoseconds
        let start = max(now, nextStart[direction] ?? now)
        let duration = UInt64(bytes) * 1_000_000_000 / UInt64(rate * 1024)
        nextStart[direction] = start + duration
        if start > now { try await Task.sleep(nanoseconds: start - now) }
        try Task.checkCancellation()
    }
}
