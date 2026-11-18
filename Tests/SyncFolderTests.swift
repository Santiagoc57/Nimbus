import Foundation

@main struct SyncFolderTests {
 static func main()throws {
    let fm=FileManager.default,workspace=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
    let root=workspace.appendingPathComponent("work/nimbo/f-"+UUID().uuidString.prefix(6))
    let remoteRoot=root.appendingPathComponent("remote"),remote=remoteRoot.appendingPathComponent("Proyecto"),local=root.appendingPathComponent("existing")
    try fm.createDirectory(at:remote,withIntermediateDirectories:true);try fm.createDirectory(at:local,withIntermediateDirectories:true)
    func write(_ value:String,_ url:URL)throws{try Data(value.utf8).write(to:url,options:.atomic)}
    func read(_ url:URL)throws->String{try String(contentsOf:url,encoding:.utf8)}
    let config=root.appendingPathComponent("rclone.conf")
    try write("[GoogleDrive]\ntype = alias\nremote = \(remoteRoot.path)\nscope = drive\n",config)
    let binary=workspace.appendingPathComponent("outputs/Nimbo/Nimbo.app/Contents/Resources/rclone")
    let state=root.appendingPathComponent("state"),offline=root.appendingPathComponent("offline")
    let engine=try SyncEngine(root:state,offlineRoot:offline,config:config,binary:binary,testing:true)
    var checks:[String]=[]
    func check(_ condition:Bool,_ label:String)throws{guard condition else{throw SyncFailure.message("FAIL: "+label)};checks.append(label);print("PASS: "+label)}
    func rejected(_ action:()throws->Void)->Bool{do{try action();return false}catch{return true}}
    let folder=CloudItem(Path:"Proyecto",Name:"Proyecto",Size:0,IsDir:true)
    try write("local only",local.appendingPathComponent("local.txt"));try write("remote only",remote.appendingPathComponent("remote.txt"))
    try write("local conflict",local.appendingPathComponent("shared.txt"));try write("cloud conflict",remote.appendingPathComponent("shared.txt"))
    for side in [local,remote]{try write("identical",side.appendingPathComponent("same.txt"))}
    try fm.createDirectory(at:local.appendingPathComponent("Type"),withIntermediateDirectories:false)
    try write("child survives",local.appendingPathComponent("Type/child.txt"));try write("remote type",remote.appendingPathComponent("Type"))
    var plan=try engine.previewExisting(remote:"GoogleDrive",item:folder,local:local)
    try check(plan.moves.count==2 && plan.moves.contains{$0.from=="shared.txt"} && plan.moves.contains{$0.from=="Type"},"Initial preview separates changed content and folder/file conflicts, retaining identical files")
    try check(try read(local.appendingPathComponent("shared.txt"))=="local conflict" && !fm.fileExists(atPath:local.appendingPathComponent("remote.txt").path),"Preview changes neither side")
    try write("changed during review",local.appendingPathComponent("local.txt"))
    try check(rejected{_ = try engine.addExisting(plan)} && engine.relations.isEmpty,"Changed content invalidates reviewed plan before linking")
    plan=try engine.previewExisting(remote:"GoogleDrive",item:folder,local:local)
    let id=try engine.addExisting(plan)
    try engine.synchronize(id)
    try check(engine.relations[0].initialized && engine.relations[0].localPath==local.path,"Existing nonempty folder initializes in place")
    try check(try read(remote.appendingPathComponent("local.txt"))=="changed during review" && read(local.appendingPathComponent("remote.txt"))=="remote only","Initial union uploads local-only and downloads remote-only files")
    for move in plan.moves {
        let path=move.from=="Type" ? move.to+"/child.txt":move.to
        let content=move.from=="Type" ? "child survives":"local conflict"
        try check(try read(local.appendingPathComponent(path))==content && read(remote.appendingPathComponent(path))==content,"Initial conflict preserved on both sides: "+move.from)
    }
    try check(try read(local.appendingPathComponent("shared.txt"))=="cloud conflict" && read(local.appendingPathComponent("Type"))=="remote type","Remote conflicting originals remain available at original names")
    try write("edit existing",local.appendingPathComponent("local.txt"));try engine.synchronize(id)
    try check(try read(remote.appendingPathComponent("local.txt"))=="edit existing","Later edits sync from the chosen existing folder")
    let moved=root.appendingPathComponent("temporarily-absent")
    try fm.moveItem(at:local,to:moved);try fm.createDirectory(at:local,withIntermediateDirectories:false)
    try check(rejected{try engine.synchronize(id)} && (try read(remote.appendingPathComponent("local.txt")))=="edit existing","Replacement directory is rejected without cloud deletion")
    try fm.removeItem(at:local);try fm.moveItem(at:moved,to:local);try engine.synchronize(id)
    try check(engine.relations[0].message.hasPrefix("Al día"),"Original folder identity resumes after temporary absence")
    let otherRemote=remoteRoot.appendingPathComponent("Otro");try fm.createDirectory(at:otherRemote,withIntermediateDirectories:false)
    let other=CloudItem(Path:"Otro",Name:"Otro",Size:0,IsDir:true)
    try check(rejected{_ = try engine.previewExisting(remote:"GoogleDrive",item:other,local:local.appendingPathComponent("Type"))},"Nested local sync root is rejected")
    let link=root.appendingPathComponent("alias");try fm.createSymbolicLink(at:link,withDestinationURL:local)
    try check(rejected{_ = try engine.previewExisting(remote:"GoogleDrive",item:other,local:link)},"Symlink root is rejected")
    let unsafe=root.appendingPathComponent("unsafe");try fm.createDirectory(at:unsafe,withIntermediateDirectories:false)
    try fm.createSymbolicLink(at:unsafe.appendingPathComponent("link"),withDestinationURL:local)
    try check(rejected{_ = try engine.previewExisting(remote:"GoogleDrive",item:other,local:unsafe)},"Nested symlink is rejected before content hashing or upload")
    try check(rejected{_ = try engine.previewExisting(remote:"GoogleDrive",item:other,local:root)},"Folder containing engine state is rejected")
    let identity=try SyncLocalIdentity.read(local)
    let caseLocal=[CloudItem(Path:"Foo",Name:"Foo",Size:1,IsDir:false)],caseRemote=[CloudItem(Path:"foo",Name:"foo",Size:1,IsDir:false)]
    try check(rejected{_ = try SyncFolderPlan.make(remote:"GoogleDrive",folder:folder,localPath:local.path,identity:identity,local:caseLocal,cloud:caseRemote)},"Case-only collisions across roots require correction")
    let unknown=[CloudItem(Path:"x",Name:"x",Size:1,IsDir:false)]
    let unknownPlan=try SyncFolderPlan.make(remote:"GoogleDrive",folder:folder,localPath:local.path,identity:identity,local:unknown,cloud:unknown)
    try check(unknownPlan.moves.count==1,"Missing checksums preserve separate copies instead of assuming equality")
    let newLocal=root.appendingPathComponent("interrupted");try fm.createDirectory(at:newLocal,withIntermediateDirectories:false)
    try write("local new",newLocal.appendingPathComponent("x.txt"));try write("remote new",otherRemote.appendingPathComponent("x.txt"))
    let nextPlan=try engine.previewExisting(remote:"GoogleDrive",item:other,local:newLocal)
    let nextID=try engine.addExisting(nextPlan)
    // Simulate a crash after the durable start marker and local rename.
    let relationsFile=state.appendingPathComponent("relations.json")
    var saved=try NimboSecureFile.load([SyncRelation].self,from:relationsFile,account:"sync-relations") ?? []
    let position=saved.firstIndex{$0.id==nextID}!;saved[position].initialAttempted=true
    try JSONEncoder().encode(saved).write(to:relationsFile,options:.atomic)
    let move=nextPlan.moves[0];try fm.moveItem(at:newLocal.appendingPathComponent(move.from),to:newLocal.appendingPathComponent(move.to))
    let reloaded=try SyncEngine(root:state,offlineRoot:offline,config:config,binary:binary,testing:true)
    try check(rejected{try reloaded.synchronize(nextID)} && (try read(newLocal.appendingPathComponent(move.to)))=="local new" && (try read(otherRemote.appendingPathComponent("x.txt")))=="remote new","Interrupted initial union cannot replay and overwrite surviving copies")
    try check(reloaded.relations.first{$0.id==nextID}?.paused==true,"Interrupted initialization pauses scheduled retries")
    let mode=try fm.attributesOfItem(atPath:state.appendingPathComponent("InitialPlans/"+id.uuidString+".json").path)[.posixPermissions] as! NSNumber
    try check(mode.intValue==0o600,"Reviewed initial plan is persisted privately")
    try engine.forget(id)
    try check(fm.fileExists(atPath:local.appendingPathComponent("local.txt").path) && fm.fileExists(atPath:remote.appendingPathComponent("local.txt").path),"Unlink preserves both existing folders")
    let report:[String:Any]=["status":"PASS","count":checks.count,"checks":checks,"synthetic_only":true,"backend":"rclone local alias; no real USB disconnect tested"]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:workspace.appendingPathComponent("outputs/Nimbo/SYNC_FOLDER_TESTS.json"))
 }
}
