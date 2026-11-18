import Foundation

/// Drive simulado en memoria: documentos divididos por ID, con ETag y papelera.
final class FakeSplitDrive: SyncSplitRemote {
    struct Doc { var name: String; var parent: String; var data: Data; var etag: Int; var trashed = false; var partBytes: Int64 }
    var docs: [String: Doc] = [:]
    var folders: [String: String] = ["": "ROOT"]
    var next = 0
    var failNextUploadAfterStaging = false
    var createCalls = 0
    func allocateID() throws -> String { next += 1; return "id\(next)" }
    func folderID(_ relative: String) throws -> String {
        if let f = folders[relative] { return f }
        let id = try allocateID(); folders[relative] = id; return id
    }
    func md5(_ d: Data) -> String {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! d.write(to: u); defer { try? FileManager.default.removeItem(at: u) }
        return try! SyncSplitCoordinator.md5(u)
    }
    func remoteFile(_ id: String) -> SyncSplitRemoteFile { let d = docs[id]!; return SyncSplitRemoteFile(id: id, size: Int64(d.data.count), md5: md5(d.data)) }
    func current(_ id: String) throws -> (etag: String, file: SyncSplitRemoteFile, partBytes: Int64, name: String, parent: String)? {
        guard let d = docs[id], !d.trashed else { return nil }
        return ("e\(d.etag)", remoteFile(id), d.partBytes, d.name, d.parent)
    }
    func download(_ id: String, to destination: URL) throws { try docs[id]!.data.write(to: destination) }
    func create(id: String, parent: String, name: String, file: URL, size: Int64, md5: String, partBytes: Int64) throws {
        createCalls += 1
        if failNextUploadAfterStaging { failNextUploadAfterStaging = false; throw SyncFailure.message("Corte de red simulado") }
        if docs[id] != nil { return } // idempotente: mismo ID
        docs[id] = Doc(name: name, parent: parent, data: try Data(contentsOf: file), etag: 1, partBytes: partBytes)
    }
    func edit(id: String, etag: String, name: String, parent: String, generation: String, file: URL, size: Int64, md5: String, partBytes: Int64) throws {
        guard var d = docs[id], "e\(d.etag)" == etag else { throw SyncFailure.message("conflicto de ETag") }
        d.data = try Data(contentsOf: file); d.etag += 1; docs[id] = d
    }
    func trash(_ id: String) throws { docs[id]?.trashed = true }
}

@main struct SyncSplitTests {
    static func main() throws {
        var checks: [String] = []
        func check(_ ok: Bool, _ label: String) throws { guard ok else { throw SyncFailure.message("FAIL: " + label) }; checks.append(label); print("PASS: " + label) }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("nimbo-split-tests-" + UUID().uuidString)
        let local = base.appendingPathComponent("Mac"), work = base.appendingPathComponent("work"), versions = base.appendingPathComponent("versions")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let drive = FakeSplitDrive()
        let threshold: Int64 = 1000 // escala de prueba: 1000 bytes representan el umbral real
        var baseline: [String: SyncSplitBaseline] = [:]
        func data(_ seed: UInt8, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed }) }
        func run(approved: Bool = false, ordinaryKnown: Set<String> = [], remoteOrdinary: Set<String> = []) throws -> SyncSplitPlan {
            let c = SyncSplitCoordinator(remote: drive, local: local, work: work, versions: versions, thresholdBytes: threshold)
            try c.recover(baseline: &baseline, save: { _ in })
            var remote: [String: SyncSplitRemoteFile] = [:]
            for (id, d) in drive.docs where !d.trashed {
                let dir = drive.folders.first { $0.value == d.parent }!.key
                remote[dir.isEmpty ? d.name : dir + "/" + d.name] = drive.remoteFile(id)
            }
            var files: [String: SyncSplitLocalFile] = [:]
            let e = fm.enumerator(at: local, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])!
            for case let u as URL in e {
                let v = try u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard v.isRegularFile == true else { continue }
                files[String(u.resolvingSymlinksInPath().path.dropFirst(local.path.count + 1))] = SyncSplitLocalFile(size: Int64(v.fileSize!), modTime: v.contentModificationDate)
            }
            // Umbral reducido para pruebas: 1000 bytes simulan 100 MB.
            let plan = try SyncSplitPlan.make(remote: remote, remoteOrdinary: remoteOrdinary, local: files, knownOrdinary: ordinaryKnown,
                                              baseline: baseline, thresholdBytes: 1000,
                                              localMD5: { try SyncSplitCoordinator.md5(local.appendingPathComponent($0)) })
            try c.execute(plan, approved: approved, tag: "test1234", baseline: &baseline, save: { _ in })
            return plan
        }
        let big = local.appendingPathComponent("video.mov"), small = local.appendingPathComponent("nota.txt")
        try data(1, 5000).write(to: big); try Data("hola".utf8).write(to: small)

        // 1. Archivo nuevo sobre el umbral: se sube dividido; el ordinario queda para bisync.
        var plan = try run()
        try check(plan.managedPaths == ["video.mov"], "Sólo el archivo grande queda fuera de bisync")
        try check(drive.docs.count == 1 && baseline["video.mov"] != nil, "Archivo nuevo grande subido como documento dividido")
        let id = baseline["video.mov"]!.id
        // 2. Sin cambios: nada que hacer.
        plan = try run()
        try check(plan.actions == [.adopt("video.mov", drive.remoteFile(id))], "Sin cambios no transfiere")
        // 3. Edición desde el Mac conserva el ID, incluso si se achica y queda vacío.
        try data(2, 3000).write(to: big); _ = try run()
        try check(drive.docs.count == 1 && drive.docs[id]!.data == data(2, 3000), "Edición desde el Mac conserva el ID en Drive")
        try Data().write(to: big); _ = try run()
        try check(drive.docs[id]!.data.isEmpty && baseline["video.mov"]!.id == id, "Edición que deja el archivo vacío conserva el ID")
        // 4. Edición desde Drive se descarga y la copia anterior queda en Versions.
        drive.docs[id]!.data = data(3, 4200); drive.docs[id]!.etag += 1
        _ = try run()
        try check(try Data(contentsOf: big) == data(3, 4200), "Edición desde Drive llega al Mac con los mismos bytes")
        try check(fm.fileExists(atPath: versions.appendingPathComponent("video.mov").path), "La copia local anterior se conserva en Versions")
        // 5. Conflicto con dos contenidos distintos: Drive conserva su ID, el Mac queda como copia.
        drive.docs[id]!.data = data(4, 2500); drive.docs[id]!.etag += 1
        try data(5, 2600).write(to: big)
        _ = try run()
        let copies = try fm.contentsOfDirectory(atPath: local.path).filter { $0.contains("conflicto Mac") }
        try check(copies.count == 1 && (try Data(contentsOf: big)) == data(4, 2500), "Conflicto: el documento de Drive conserva su ruta e ID")
        try check(try Data(contentsOf: local.appendingPathComponent(copies[0])) == data(5, 2600), "Conflicto: la versión del Mac se conserva como copia")
        try check(drive.docs.values.contains { $0.data == data(5, 2600) }, "La copia de conflicto grande también sube a Drive")
        // 6. Borrado pendiente de aprobación.
        try fm.removeItem(at: big)
        plan = try run()
        try check(plan.deletions == [SyncDeletion(path: "video.mov", missingFrom: "Mac")] && drive.docs[id]!.trashed == false, "Borrado sin aprobar no se propaga")
        plan = try run(approved: true)
        try check(drive.docs[id]!.trashed && baseline["video.mov"] == nil, "Borrado aprobado va a la papelera de Drive")
        // 7. Interrupción a mitad de subida: se retoma con el mismo ID, sin duplicar.
        let another = local.appendingPathComponent("Sub/otro.bin")
        try fm.createDirectory(at: another.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(6, 7000).write(to: another)
        let before = drive.docs.count
        drive.failNextUploadAfterStaging = true
        var failed = false; do { _ = try run() } catch { failed = true }
        try check(failed && drive.docs.count == before, "Una subida interrumpida no deja documentos a medias")
        _ = try run()
        let created = drive.docs.filter { $0.value.data == data(6, 7000) }
        try check(created.count == 1 && drive.docs.count == before + 1, "Al retomar se completa una sola vez (sin duplicados)")
        // 8. Un archivo ordinario ya conocido por bisync que crece no se convierte en dividido.
        try data(7, 9000).write(to: small)
        plan = try run(ordinaryKnown: ["nota.txt"])
        try check(!plan.managedPaths.contains("nota.txt"), "Un archivo ordinario existente que crece sigue siendo ordinario")
        // 9. Umbral «Nunca»: nada nuevo se divide.
        let never = try SyncSplitPlan.make(remote: [:], remoteOrdinary: [], local: ["x.bin": .init(size: 10_000_000_000, modTime: nil)],
                                           knownOrdinary: [], baseline: [:], thresholdBytes: 0, localMD5: { _ in "" })
        try check(never.actions.isEmpty, "Con «Nunca» no se divide ningún archivo nuevo")
        // 10. Borrado en Drive con copia local intacta: requiere aprobación y conserva la copia.
        let otherID = baseline["Sub/otro.bin"]!.id
        drive.docs[otherID]!.trashed = true
        plan = try run()
        try check(plan.deletions == [SyncDeletion(path: "Sub/otro.bin", missingFrom: "Google Drive")] && fm.fileExists(atPath: another.path), "Borrado en Drive espera aprobación")
        _ = try run(approved: true)
        try check(!fm.fileExists(atPath: another.path) && fm.fileExists(atPath: versions.appendingPathComponent("Sub/otro.bin").path), "Borrado aprobado guarda la copia local en Versions")

        let report: [String: Any] = ["status": "PASS", "count": checks.count, "checks": checks, "synthetic_only": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "SYNC_SPLIT_TESTS.json"))
    }
}
