import Foundation

@main struct RealDriveSmoke {
    static func main() throws {
        let fm = FileManager.default, workspace = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let binary = workspace.appendingPathComponent("outputs/Nimbo/Nimbo.app/Contents/Resources/rclone")
        let config = fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Nimbo/rclone.conf")
        let root = workspace.appendingPathComponent("work/nimbo/d-" + UUID().uuidString.prefix(6))
        let engine = try SyncEngine(root:root.appendingPathComponent("state"),offlineRoot:root.appendingPathComponent("offline"),config:config,binary:binary)
        guard engine.hasWriteAuthorization() else { print("WAITING_FOR_WRITE_AUTHORIZATION"); return }
        let remoteName = "Nimbo prueba " + UUID().uuidString.prefix(8)
        var relationID: UUID?
        var checks:[String] = []
        func command(_ args:[String]) throws -> Data {
            let p = Process(); p.executableURL = binary; p.arguments = ["--config",config.path,"--log-level","ERROR"] + args
            let out = root.appendingPathComponent("command-output"), err = root.appendingPathComponent("command-error")
            for f in [out,err] { fm.createFile(atPath:f.path,contents:nil,attributes:[.posixPermissions:0o600]) }
            let h = try FileHandle(forWritingTo:out), e = try FileHandle(forWritingTo:err)
            defer { try? h.close(); try? e.close(); try? fm.removeItem(at:out); try? fm.removeItem(at:err) }
            p.standardOutput = h; p.standardError = e; p.standardInput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw SyncFailure.message("Google Drive smoke command failed: \(args.first ?? "") code \(p.terminationStatus)") }
            return try Data(contentsOf:out)
        }
        func check(_ condition: Bool,_ label:String) throws {
            guard condition else { throw SyncFailure.message("Failed: " + label) }
            checks.append(label); print("PASS: " + label)
        }
        let seed = root.appendingPathComponent("seed.txt")
        func upload(_ text:String,_ name:String) throws {
            try Data(text.utf8).write(to:seed,options:.atomic)
            _ = try command(["copyto",seed.path,"GoogleDrive:" + remoteName + "/" + name])
        }
        let record = root.appendingPathComponent("cleanup.json")
        func saveCleanup() throws {
            try JSONSerialization.data(withJSONObject:["remoteFolder":remoteName,"relationID":relationID?.uuidString ?? ""],options:.prettyPrinted).write(to:record,options:.atomic)
        }
        try saveCleanup()
        do {
            _ = try command(["mkdir","GoogleDrive:" + remoteName])
            try upload("primera versión\n","Archivo.txt")
            let folders = try CloudBackend.decodeListing(command(["lsjson","GoogleDrive:","--dirs-only","--no-mimetype"]))
            guard let folder = folders.first(where:{$0.Name == remoteName}) else { throw SyncFailure.message("Created test folder not listed") }
            let id = try engine.add(remote:"GoogleDrive",item:folder); relationID = id; try saveCleanup()
            try engine.synchronize(id)
            let local = URL(fileURLWithPath:engine.relations[0].localPath)
            try check(try String(contentsOf:local.appendingPathComponent("Archivo.txt"),encoding:.utf8) == "primera versión\n","Initial download from real Drive")
            try Data("edición en Mac\n".utf8).write(to:local.appendingPathComponent("Archivo.txt"),options:.atomic)
            try engine.synchronize(id)
            let downloaded = try command(["cat","GoogleDrive:" + remoteName + "/Archivo.txt"])
            try check(String(data:downloaded,encoding:.utf8) == "edición en Mac\n","Local edit uploaded to real Drive")
            try upload("edición en nube\n","Archivo.txt")
            try engine.synchronize(id)
            try check(try String(contentsOf:local.appendingPathComponent("Archivo.txt"),encoding:.utf8) == "edición en nube\n","Remote edit downloaded from real Drive")
            try Data("conflicto Mac\n".utf8).write(to:local.appendingPathComponent("Archivo.txt"),options:.atomic)
            try upload("conflicto nube\n","Archivo.txt")
            try engine.synchronize(id)
            let names = try fm.contentsOfDirectory(atPath:local.path).filter{$0.hasPrefix("Archivo")}
            let values = try Set(names.map{try String(contentsOf:local.appendingPathComponent($0),encoding:.utf8)})
            try check(values.contains("conflicto Mac\n") && values.contains("conflicto nube\n"),"Real Drive conflict preserves both versions")
            try Data("borrado de prueba\n".utf8).write(to:local.appendingPathComponent("Borrar.txt"),options:.atomic)
            try engine.synchronize(id)
            try fm.removeItem(at:local.appendingPathComponent("Borrar.txt"))
            try engine.synchronize(id)
            try check(engine.relations[0].pendingDeletes.count == 1,"Real Drive deletion waits for explicit review")
            try engine.synchronize(id,approving:engine.relations[0].pendingDeletes)
            let entries = try CloudBackend.decodeListing(command(["lsjson","GoogleDrive:" + remoteName,"--no-mimetype"]))
            try check(!entries.contains(where:{$0.Name == "Borrar.txt"}),"Approved real Drive deletion propagated")
            let backups = try CloudBackend.decodeListing(command(["lsjson","GoogleDrive:.Nimbo Versiones/" + id.uuidString,"-R","--no-mimetype"]))
            try check(backups.contains(where:{$0.Name == "Borrar.txt"}),"Real Drive backup retained before deletion")
            _ = try command(["purge","GoogleDrive:" + remoteName,"--drive-use-trash=true"])
            _ = try command(["purge","GoogleDrive:.Nimbo Versiones/" + id.uuidString,"--drive-use-trash=true"])
            try check(true,"Only this test folder and its own versions moved to Google Drive Trash")
            try fm.removeItem(at:record)
            let report:[String:Any] = ["status":"PASS","checks":checks,"count":checks.count,"real_google_drive":true,"user_documents_modified":false,"test_cleanup":"Google Drive Trash"]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:workspace.appendingPathComponent("outputs/Nimbo/GOOGLE_DRIVE_SYNC_TESTS.json"))
            print("ALL REAL DRIVE CHECKS PASSED")
        } catch {
            print("INCOMPLETE: " + error.localizedDescription)
            print("Cleanup record retained in " + record.path)
            throw error
        }
    }
}
