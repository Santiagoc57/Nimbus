import Foundation

@main struct SyncRestoreTests {
 static func main()throws {
  let fm=FileManager.default,workspace=URL(fileURLWithPath:fm.currentDirectoryPath)
  let root=workspace.appendingPathComponent("work/nimbo/restore-"+UUID().uuidString.prefix(6)),remoteRoot=root.appendingPathComponent("remote"),remote=remoteRoot.appendingPathComponent("Proyecto")
  try fm.createDirectory(at:remote,withIntermediateDirectories:true)
  func write(_ text:String,_ url:URL)throws{try Data(text.utf8).write(to:url,options:.atomic)}
  func read(_ url:URL)throws->String{try String(contentsOf:url,encoding:.utf8)}
  let config=root.appendingPathComponent("rclone.conf");try write("[GoogleDrive]\ntype = alias\nremote = \(remoteRoot.path)\nscope = drive\n",config)
  let binary=workspace.appendingPathComponent("outputs/Nimbo/Nimbo.app/Contents/Resources/rclone")
  let engine=try SyncEngine(root:root.appendingPathComponent("state"),offlineRoot:root.appendingPathComponent("offline"),config:config,binary:binary,testing:true)
  var checks:[String]=[];func check(_ ok:Bool,_ label:String)throws{guard ok else{throw SyncFailure.message("FAIL: "+label)};checks.append(label);print("PASS: "+label)}
  let item=CloudItem(Path:"Proyecto",Name:"Proyecto",Size:0,IsDir:true),id=try engine.add(remote:"GoogleDrive",item:item);try engine.synchronize(id)
  let local=URL(fileURLWithPath:engine.relations[0].localPath);try write("current",local.appendingPathComponent("archivo.txt"))
  let stamp=root.appendingPathComponent("state/Versions/"+id.uuidString+"/test-version");try fm.createDirectory(at:stamp,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:stamp.path);try write("old version",stamp.appendingPathComponent("archivo.txt"))
  let entries=try engine.backupEntries(id);try check(entries.count==1 && entries[0].relativePath=="test-version/archivo.txt","Version listing returns only regular backup files")
  try engine.restoreLocalBackup(id,url:entries[0].url)
  let conflict=local.appendingPathComponent("archivo.txt (conflicto antes de restaurar "+id.uuidString.prefix(8)+")")
  try check(try read(local.appendingPathComponent("archivo.txt"))=="old version","Selected version replaces the local file")
  try check(try read(conflict)=="current","Current content is retained as a conflict copy")
  try check(engine.relations[0].message.contains("Versión restaurada"),"Restore leaves an explicit sync message")
  try check((try? engine.restoreLocalBackup(id,url:root)) == nil,"A path outside the version store is rejected")
  try check((try? engine.restoreLocalBackup(UUID(),url:entries[0].url)) == nil,"Unknown synchronization is rejected")
  let mode=try fm.attributesOfItem(atPath:stamp.path)[.posixPermissions] as! NSNumber
  try check(mode.intValue==0o700,"Version directories remain private")
  let report:[String:Any]=["status":"PASS","count":checks.count,"checks":checks,"synthetic_only":true]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:workspace.appendingPathComponent("outputs/Nimbo/SYNC_RESTORE_TESTS.json"))
 }
}
