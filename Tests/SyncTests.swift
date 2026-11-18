import Foundation

@main struct SyncTests {
    static func main() throws {
        let fm = FileManager.default
        let workspace = URL(fileURLWithPath:fm.currentDirectoryPath)
        let root = workspace.appendingPathComponent("work/nimbo/t-" + UUID().uuidString.prefix(6))
        let remoteRoot = root.appendingPathComponent("remote"), remote = remoteRoot.appendingPathComponent("Proyecto")
        try fm.createDirectory(at:remote,withIntermediateDirectories:true)
        func write(_ text:String,_ url:URL) throws { try Data(text.utf8).write(to:url,options:.atomic) }
        func read(_ url:URL) throws -> String { try String(contentsOf:url,encoding:.utf8) }
        try write("original",remote.appendingPathComponent("local.txt"))
        try write("remote first",remote.appendingPathComponent("remote.txt"))
        try write("original conflict",remote.appendingPathComponent("conflict.txt"))
        let config=root.appendingPathComponent("rclone.conf")
        try write("[GoogleDrive]\ntype = alias\nremote = \(remoteRoot.path)\nscope = drive\n",config)
        let binary=workspace.appendingPathComponent("outputs/Nimbo/Nimbo.app/Contents/Resources/rclone")
        let engine=try SyncEngine(root:root.appendingPathComponent("state"),offlineRoot:root.appendingPathComponent("offline"),config:config,binary:binary,testing:true)
        var checks:[String]=[]
        func check(_ value:Bool,_ name:String) throws {
            guard value else { throw SyncFailure.message("FAILED: " + name) }; checks.append(name)
            print("PASS: " + name)
        }
        let item=CloudItem(Path:"Proyecto",Name:"Proyecto",Size:0,IsDir:true)
        let id=try engine.add(remote:"GoogleDrive",item:item)
        let local=URL(fileURLWithPath:engine.relations[0].localPath)
        try engine.synchronize(id)
        try check(try read(local.appendingPathComponent("local.txt")) == "original","Initial remote files materialized in a new local folder")
        try check(engine.relations[0].initialized,"Successful first sync persists baseline")
        try fm.createDirectory(at:local.appendingPathComponent("Vacía"),withIntermediateDirectories:true)
        try engine.synchronize(id)
        try check(fm.fileExists(atPath:remote.appendingPathComponent("Vacía").path),"Empty local folder reaches remote")
        try fm.removeItem(at:local.appendingPathComponent("Vacía"))
        try engine.synchronize(id)
        try check(engine.relations[0].pendingDeletes.contains(where:{$0.path == "Vacía"}),"Empty folder deletion requires review")
        try engine.synchronize(id,approving:engine.relations[0].pendingDeletes)
        try check(!fm.fileExists(atPath:remote.appendingPathComponent("Vacía").path),"Approved empty folder deletion propagates")
        var rejected=false
        do { _ = try engine.add(remote:"GoogleDrive",item:item) } catch { rejected=true }
        try check(rejected,"Overlapping sync roots are refused")
        let prior=try fm.attributesOfItem(atPath:local.appendingPathComponent("local.txt").path)[.modificationDate] as! Date
        try write("modified",local.appendingPathComponent("local.txt"))
        try fm.setAttributes([.modificationDate:prior],ofItemAtPath:local.appendingPathComponent("local.txt").path)
        try engine.synchronize(id)
        try check(try read(remote.appendingPathComponent("local.txt")) == "modified","Checksum detects same-size edit even with unchanged mtime")
        try write("remote changed",remote.appendingPathComponent("remote.txt"))
        try engine.synchronize(id)
        try check(try read(local.appendingPathComponent("remote.txt")) == "remote changed","Remote edits reach local copy")
        try write("local simultaneous edit",local.appendingPathComponent("conflict.txt"))
        try write("remote simultaneous edit",remote.appendingPathComponent("conflict.txt"))
        try engine.synchronize(id)
        let conflictNames=try fm.contentsOfDirectory(atPath:local.path).filter{$0.hasPrefix("conflict")}
        let contents=try Set(conflictNames.map{try read(local.appendingPathComponent($0))})
        try check(contents.contains("local simultaneous edit") && contents.contains("remote simultaneous edit"),"Concurrent edits preserve both versions")
        try write("new local",local.appendingPathComponent("nuevo.txt"))
        try write("second local",local.appendingPathComponent("segundo.txt"))
        try engine.synchronize(id)
        try check(try read(remote.appendingPathComponent("nuevo.txt")) == "new local","New local file uploads")
        try fm.removeItem(at:local.appendingPathComponent("nuevo.txt"))
        try engine.synchronize(id)
        try check(engine.relations[0].pendingDeletes.count == 1 && fm.fileExists(atPath:remote.appendingPathComponent("nuevo.txt").path),"Local deletion waits for review and leaves remote intact")
        let approvals=engine.relations[0].pendingDeletes
        try fm.removeItem(at:local.appendingPathComponent("segundo.txt"))
        try engine.synchronize(id,approving:approvals)
        try check(engine.relations[0].pendingDeletes.count == 2 && fm.fileExists(atPath:remote.appendingPathComponent("nuevo.txt").path) && fm.fileExists(atPath:remote.appendingPathComponent("segundo.txt").path),"Changed deletion set invalidates earlier approval")
        try engine.synchronize(id,approving:engine.relations[0].pendingDeletes)
        try check(!fm.fileExists(atPath:remote.appendingPathComponent("nuevo.txt").path),"Approved local deletion propagates")
        let versionRoot=remoteRoot.appendingPathComponent(".Nimbo Versiones")
        let versionFiles=fm.enumerator(at:versionRoot,includingPropertiesForKeys:nil)!.allObjects.compactMap{$0 as? URL}
        try check(versionFiles.contains { $0.lastPathComponent == "nuevo.txt" },"Deleted remote file retained in version backup")
        try fm.removeItem(at:remote.appendingPathComponent("remote.txt"))
        try engine.synchronize(id)
        try check(engine.relations[0].pendingDeletes.first?.missingFrom == "Google Drive" && fm.fileExists(atPath:local.appendingPathComponent("remote.txt").path),"Remote deletion waits for review and leaves local intact")
        try engine.synchronize(id,approving:engine.relations[0].pendingDeletes)
        try check(!fm.fileExists(atPath:local.appendingPathComponent("remote.txt").path),"Approved remote deletion propagates")
        let marker=engine.relations[0].marker
        try fm.removeItem(at:remote.appendingPathComponent(marker))
        rejected=false
        do { try engine.synchronize(id) } catch { rejected=true }
        try check(rejected && fm.fileExists(atPath:local.appendingPathComponent("local.txt").path),"Missing access marker stops sync without deleting local content")
        try write("Nimbo sync anchor\n",remote.appendingPathComponent(marker))
        try engine.synchronize(id)
        let unavailable = root.appendingPathComponent("remote-offline")
        try fm.moveItem(at:remoteRoot,to:unavailable)
        try write("edit while offline",local.appendingPathComponent("local.txt"))
        rejected=false
        do { try engine.synchronize(id) } catch { rejected=true }
        try check(rejected && (try read(local.appendingPathComponent("local.txt"))) == "edit while offline","Unavailable remote preserves offline edits")
        try fm.moveItem(at:unavailable,to:remoteRoot)
        try engine.synchronize(id)
        try check(try read(remote.appendingPathComponent("local.txt")) == "edit while offline","Offline edits upload after remote becomes available")
        try engine.setPaused(id,true)
        try write(#"{"bandwidthKBps":1024,"splitLargeFiles":true}"#, root.appendingPathComponent("state/settings.json"))
        let reloaded=try SyncEngine(root:root.appendingPathComponent("state"),offlineRoot:root.appendingPathComponent("offline"),config:config,binary:binary,testing:true)
        try check(reloaded.relations[0].paused && reloaded.relations[0].initialized,"Relations, pause, and baseline survive restart")
        try check(reloaded.settings.uploadKBps == 1024 && reloaded.settings.downloadKBps == 1024 && reloaded.settings.splitLargeFiles, "Old settings migrate in both directions")
        try reloaded.setBandwidthLimit(5120, for: .upload)
        try check(reloaded.settings.rcloneArguments == ["--bwlimit","5120k:1024k"],"Bandwidth limit accepts a supported rate")
        let settingsReloaded=try SyncEngine(root:root.appendingPathComponent("state"),offlineRoot:root.appendingPathComponent("offline"),config:config,binary:binary,testing:true)
        try check(settingsReloaded.settings == reloaded.settings,"Bandwidth limit survives restart")
        try write("[GoogleDrive]\ntype = drive\nscope = drive.readonly\n",config)
        let realMode=try SyncEngine(root:root.appendingPathComponent("auth-check"),offlineRoot:root.appendingPathComponent("offline-2"),config:config,binary:binary)
        try check(!realMode.hasWriteAuthorization(),"Read-only OAuth cannot enable writes")
        try write("[GoogleDrive]\ntype = drive\nscope = drive.readonly\n[GoogleDrive-2]\ntype = drive\nscope = drive\n",config)
        let multiMode=try SyncEngine(root:root.appendingPathComponent("auth-multi"),offlineRoot:root.appendingPathComponent("offline-3"),config:config,binary:binary)
        try check(!multiMode.hasWriteAuthorization(remote:"GoogleDrive") && multiMode.hasWriteAuthorization(remote:"GoogleDrive-2"),"Write authorization is checked per Google Drive account")
        let original = "[Other]\nscope = other\n[GoogleDrive]\nscope = drive.readonly\ntoken = SYNTHETIC\nclient_id = example\n"
        let upgraded = try oauthConfiguration(original,writeAccess:true)
        try check(upgraded.contains("[Other]\nscope = other") && upgraded.contains("scope = drive\n") && upgraded.contains("token = SYNTHETIC") && upgraded.contains("client_id = example"),"OAuth upgrade preserves credentials and other sections")
        let multi = try oauthConfigurationWithRemote(original, remote:"GoogleDrive-2", clientID:"second.apps.googleusercontent.com", clientSecret:"GOCSPX-second", writeAccess:false)
        try check(multi.contains("[GoogleDrive]\nscope = drive.readonly\ntoken = SYNTHETIC") && multi.contains("[GoogleDrive-2]\ntype = drive\nscope = drive.readonly") && multi.contains("client_secret = GOCSPX-second"),"Second Google Drive account is appended without changing the first")
        let replaced = try oauthConfigurationWithRemote(multi, remote:"GoogleDrive-2", clientID:"second.apps.googleusercontent.com", clientSecret:"GOCSPX-updated", writeAccess:true)
        try check(replaced.components(separatedBy:"[GoogleDrive-2]").count == 2 && replaced.contains("[GoogleDrive-2]\ntype = drive\nscope = drive\nclient_id = second.apps.googleusercontent.com\nclient_secret = GOCSPX-updated"),"Reauthorizing a named Google Drive account replaces only its section")
        let report:[String:Any]=["status":"PASS","checks":checks,"count":checks.count,"synthetic_only":true]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:workspace.appendingPathComponent("outputs/Nimbo/SYNC_TESTS.json"))
        print("ALL \(checks.count) CHECKS PASSED")
    }
}
