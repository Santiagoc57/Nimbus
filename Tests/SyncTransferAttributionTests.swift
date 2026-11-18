#if SYNC_ATTRIBUTION_TESTS
import AppKit

@main struct SyncTransferAttributionTests {
    static func main() throws {
        let fm=FileManager.default, workspace=URL(fileURLWithPath:fm.currentDirectoryPath)
        let root=workspace.appendingPathComponent("work/nimbo/sync-attribution-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        NimboSecureFile.testRoot=root.appendingPathComponent("keys")
        var checks=0
        func check(_ ok:Bool,_ message:String) { precondition(ok,message); checks+=1 }
        func wait(_ condition:()->Bool) {
            let end=Date().addingTimeInterval(45)
            while !condition(),Date()<end { RunLoop.main.run(until:Date().addingTimeInterval(0.01)) }
            precondition(condition(),"scheduled task did not finish")
        }
        for backup in [false,true] {
            let scenario=root.appendingPathComponent(backup ? "backup":"sync")
            let cloud=scenario.appendingPathComponent("cloud")
            for folder in ["A","B"] {
                try fm.createDirectory(at:cloud.appendingPathComponent(folder),withIntermediateDirectories:true)
                try Data("synthetic ".appending(folder).utf8).write(to:cloud.appendingPathComponent(folder+"/sample.txt"))
            }
            let config=scenario.appendingPathComponent("rclone.conf")
            try Data("[AccountA]\ntype = alias\nremote = \(cloud.path)\nscope = drive\n[AccountB]\ntype = alias\nremote = \(cloud.path)\nscope = drive\n".utf8).write(to:config)
            let engine=try SyncEngine(root:scenario.appendingPathComponent("state"),offlineRoot:scenario.appendingPathComponent("offline"),config:config,binary:URL(fileURLWithPath:"/Users/santiagoimac/Applications/Nimbo.app/Contents/Resources/rclone"),testing:true)
            let a=try engine.add(remote:"AccountA",item:CloudItem(Path:"A",Name:"Folder A",Size:0,IsDir:true))
            let b=try engine.add(remote:"AccountB",item:CloudItem(Path:"B",Name:"Folder B",Size:0,IsDir:true))
            try engine.setPaused(a,true)
            if backup {
                try engine.synchronize(b)
                try engine.setBackupSchedule(b,enabled:true,intervalMinutes:15,retention:1)
            }
            TransferCenter.shared.configure(support:scenario)
            // No window or selected row: the old implementation lost this job.
            let controller=SyncController(engine:engine)
            wait { !controller.running && TransferCenter.shared.recent().contains { $0.state == .completed || $0.state == .failed } }
            let entries=TransferCenter.shared.recent()
            check(entries.count==1,"exactly one scheduled transfer must be recorded")
            let entry=entries[0]
            check(entry.remote=="AccountB","account key must name actual remote, without path")
            check(entry.name=="Folder B","folder comes from executed relation")
            check(entry.operation==(backup ? "Backup":"Sincronización"),"operation matches scheduler")
            check(entry.state == .completed && entry.verified,"local synthetic operation must complete")
            check(engine.relations.first(where:{$0.id==a})?.initialized==false,"paused other relation is untouched")
            var stopped=false; controller.shutdown { stopped=true }; wait { stopped }
        }
        print("PASS: \(checks) scheduled sync/backup attribution checks; two local aliases, no Google network, no GUI")
    }
}
#endif
