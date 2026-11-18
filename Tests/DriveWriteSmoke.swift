import Foundation
@main struct DriveWriteSmoke {
 enum Interrupted:Error {case intentional}
 static func main() async throws {
  let fm=FileManager.default
  let config=fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Nimbo/rclone.conf")
  let api=DriveAPI(configuration:config),work=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("work/nimbo/native/writes/live-"+UUID().uuidString)
  try fm.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let writer=DriveWriteAPI(api:api),root=try await api.item("root")
  let folderID=try await writer.allocateID(),folderName="Nimbo prueba escritura "+UUID().uuidString.prefix(8)
  let cleanup=work.appendingPathComponent("cleanup.json")
  func saveCleanup(_ state:String)throws{try JSONSerialization.data(withJSONObject:["ownedFolderID":folderID,"state":state]).write(to:cleanup,options:.atomic)}
  try saveCleanup("allocated")
  var checks:[String]=[]
  func check(_ value:Bool,_ name:String)throws{guard value else{throw DriveFailure.invalidResponse};checks.append(name);print("PASS: "+name)}
  do {
   let folder=try await writer.createFolder(id:folderID,parent:root.id,name:String(folderName));try saveCleanup("created")
   let replay=try await writer.createFolder(id:folderID,parent:root.id,name:String(folderName))
   try check(folder.object.id==replay.object.id,"Preallocated folder ID makes creation replay idempotent")
   let file=work.appendingPathComponent("staged.bin");try Data(repeating:0x61,count:8*1024*1024+137).write(to:file)
   let fileID=try await writer.allocateID()
   let session=try await writer.beginUpload(id:fileID,parent:folderID,name:"Subida.bin",mime:"application/octet-stream",file:file,baseETag:nil)
   let journal=work.appendingPathComponent("upload.json")
   func save(_ state:DriveUploadSession)throws{try JSONEncoder().encode(state).write(to:journal,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:journal.path)}
   try save(session)
   var interrupted=false
   do{_ = try await writer.upload(file,session:session,checkpoint:{state in try save(state);if state.offset>0{throw Interrupted.intentional}})}catch Interrupted.intentional{interrupted=true}
   try check(interrupted,"Large upload stops after first acknowledged chunk with a durable checkpoint")
   let loaded=try JSONDecoder().decode(DriveUploadSession.self,from:Data(contentsOf:journal))
   let uploaded=try await writer.upload(file,session:loaded,checkpoint:save)
   try check(uploaded.object.id==fileID && uploaded.object.size==String(8*1024*1024+137),"Upload resumes from server offset and validates complete size and MD5")
   let completedReplay=try await writer.upload(file,session:loaded,checkpoint:save)
   try check(completedReplay.object.id==fileID,"Completed upload can be reconciled after a lost final reply")
   let renamed=try await writer.updateMetadata(fileID,etag:uploaded.etag,name:"Renombrado.bin")
   try check(renamed.object.name=="Renombrado.bin","Conditional rename updates metadata")
   var rejected=false;do{_ = try await writer.updateMetadata(fileID,etag:uploaded.etag,name:"stale.bin")}catch DriveFailure.conflict{rejected=true}
   try check(rejected,"Stale metadata edit is rejected without overwriting the current name")
   let subID=try await writer.allocateID();_ = try await writer.createFolder(id:subID,parent:folderID,name:"Destino")
   let moved=try await writer.updateMetadata(fileID,etag:renamed.etag,parent:subID)
   try check(moved.object.parents==[subID],"Conditional move changes the parent by stable ID")
   let local=work.appendingPathComponent("local.txt"),remote=work.appendingPathComponent("remote.txt")
   try Data("local pending".utf8).write(to:local);try Data("remote intervening".utf8).write(to:remote)
   let pending=try await writer.beginUpload(id:fileID,parent:nil,name:"Renombrado.bin",mime:"application/octet-stream",file:local,baseETag:moved.etag)
   let other=try await writer.beginUpload(id:fileID,parent:nil,name:"Renombrado.bin",mime:"application/octet-stream",file:remote,baseETag:moved.etag)
   let remoteResult=try await writer.upload(remote,session:other,checkpoint:{_ in})
   rejected=false;do{_ = try await writer.upload(local,session:pending,checkpoint:{_ in})}catch DriveFailure.conflict{rejected=true}
   let downloaded=work.appendingPathComponent("verify.txt");try await api.download(fileID,to:downloaded)
   try check(rejected && (try Data(contentsOf:downloaded))==Data("remote intervening".utf8),"An edit during resumable upload is rejected and remote content survives")
   let empty=work.appendingPathComponent("empty.txt");try Data().write(to:empty)
   let emptyID=try await writer.allocateID();let emptySession=try await writer.beginUpload(id:emptyID,parent:folderID,name:"Vacio.txt",mime:"text/plain",file:empty,baseETag:nil)
   let emptyResult=try await writer.upload(empty,session:emptySession,checkpoint:{_ in})
   try check(emptyResult.object.size=="0","Zero-byte file upload completes with validated checksum")
   let trashed=try await writer.updateMetadata(fileID,etag:remoteResult.etag,trashed:true)
   try check(trashed.object.trashed==true,"Conditional deletion moves only the synthetic file to Drive trash")
   let folderNow=try await writer.revision(folderID)
   _ = try await writer.updateMetadata(folderID,etag:folderNow.etag,trashed:true);try saveCleanup("trashed")
   try? fm.removeItem(at:journal)
   let report:[String:Any]=["status":"PASS","checks":checks,"count":checks.count,"scope":"New synthetic folder/files only","cleanup":"owned folder moved to Drive trash","native_finder_writes":"NOT_ENABLED_YET"]
   try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/DRIVE_WRITE_TESTS.json"))
  } catch {
   if let current=try? await writer.revision(folderID), (try? await writer.updateMetadata(folderID,etag:current.etag,trashed:true)) != nil {try? saveCleanup("trashed_after_failure")}
   throw error
  }
 }
}
