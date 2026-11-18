import Foundation
import FileProvider

actor FaultDrive:NativeDriveWriting {
 let base:DriveWriteAPI
 var loseUpload=false,loseMetadata=false,loseFolder=false
 var concurrent:(String,URL)?
 init(_ base:DriveWriteAPI){self.base=base}
 func arm(upload:Bool=false,metadata:Bool=false,folder:Bool=false){loseUpload=upload;loseMetadata=metadata;loseFolder=folder}
 func race(_ id:String,file:URL){concurrent=(id,file)}
 func revision(_ id:String) async throws->DriveRevision{try await base.revision(id)}
 func allocateID() async throws->String{try await base.allocateID()}
 func createFolder(id:String,parent:String,name:String) async throws->DriveRevision {
  let result=try await base.createFolder(id:id,parent:parent,name:name)
  if loseFolder{loseFolder=false;throw DriveFailure.unavailable};return result
 }
 func updateMetadata(_ id:String,etag:String,name:String?,parent:String?,trashed:Bool?) async throws->DriveRevision {
  let result=try await base.updateMetadata(id,etag:etag,name:name,parent:parent,trashed:trashed)
  if loseMetadata{loseMetadata=false;throw DriveFailure.unavailable};return result
 }
 func beginUpload(id:String,parent:String?,name:String,mime:String,file:URL,baseETag:String?) async throws->DriveUploadSession {
  try await base.beginUpload(id:id,parent:parent,name:name,mime:mime,file:file,baseETag:baseETag)
 }
 func upload(_ file:URL,session:DriveUploadSession,checkpoint:@escaping(DriveUploadSession)throws->Void,progress:@escaping(Int64,Int64)->Void) async throws->DriveRevision {
  if let (id,source)=concurrent,id==session.fileID {
   concurrent=nil
   let current=try await base.revision(id)
   let other=try await base.beginUpload(id:id,parent:nil,name:current.object.name,mime:current.object.mimeType,file:source,baseETag:current.etag)
   _ = try await base.upload(source,session:other,checkpoint:{_ in})
  }
  let result=try await base.upload(file,session:session,checkpoint:checkpoint,progress:progress)
  if loseUpload{loseUpload=false;throw DriveFailure.unavailable};return result
 }
}

@main struct NativeWriteSmoke {
 static func main() async throws {
  let fm=FileManager.default
  let config=fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Nimbo/rclone.conf")
  let api=DriveAPI(configuration:config),writer=DriveWriteAPI(api:api)
  let work=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("work/nimbo/native/writes/journal-live-"+UUID().uuidString)
  try fm.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let journal=work.appendingPathComponent("operations"),fault=FaultDrive(writer)
  func engine()throws->NativeWriteStore{try NativeWriteStore(directory:journal,writer:fault)}
  func version(_ item:DriveObject)->NSFileProviderItemVersion{NativeItem(item,rootID:"root",pinned:false,writable:true).itemVersion}
  func staged(_ text:String)throws->URL{let p=work.appendingPathComponent(UUID().uuidString+".txt");try Data(text.utf8).write(to:p);return p}
  func dataFiles()->[URL]{(fm.enumerator(at:journal,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []).filter{$0.lastPathComponent=="content"}}
  let folderID=try await writer.allocateID(),root=try await api.item("root")
  let cleanup=work.appendingPathComponent("cleanup.json")
  func record(_ state:String)throws{try JSONSerialization.data(withJSONObject:["ownedFolderID":folderID,"state":state]).write(to:cleanup,options:.atomic)}
  try record("allocated");var checks:[String]=[]
  func check(_ value:Bool,_ text:String)throws{guard value else{throw DriveFailure.invalidResponse};checks.append(text);print("PASS: "+text)}
  do {
   _ = try await writer.createFolder(id:folderID,parent:root.id,name:"Nimbo prueba diario "+UUID().uuidString.prefix(8));try record("created")
   let original=try staged("original A")
   await fault.arm(upload:true)
   var failed=false
   do{_ = try await engine().create(template:"template-1",parent:folderID,name:"Archivo.txt",mime:"text/plain",isFolder:false,contents:original)}catch DriveFailure.unavailable{failed=true}
   try check(failed && dataFiles().count==1,"Lost upload response leaves staged bytes and durable operation intact")
   let restored=try await engine().create(template:"template-1",parent:folderID,name:"Archivo.txt",mime:"text/plain",isFolder:false,contents:original)
   let item=restored.item!
   try check(try await api.children(folderID).files.count==1,"A new journal instance reconciles committed create without duplicating it")
   try check(dataFiles().isEmpty,"Confirmed commit releases staging bytes while retaining replay record")
   let changed=try staged("local B")
   let updated=try await engine().modify(id:item.id,base:version(item),name:item.name,parent:folderID,mime:item.mimeType,isFolder:false,contents:changed)
   try check(updated.item?.id==item.id && updated.item?.md5Checksum==DriveWriteAPI.fingerprint(changed).md5,"Normal modification updates the same remote ID")
   let remote=try staged("remote C"),local=try staged("local D")
   let current=try await writer.revision(item.id)
   let remoteSession=try await writer.beginUpload(id:item.id,parent:nil,name:item.name,mime:item.mimeType,file:remote,baseETag:current.etag)
   _ = try await writer.upload(remote,session:remoteSession,checkpoint:{_ in})
   let conflict=try await engine().modify(id:item.id,base:version(updated.item!),name:item.name,parent:folderID,mime:item.mimeType,isFolder:false,contents:local)
   try check(conflict.fetchContent && conflict.additional.count==1 && conflict.item?.md5Checksum==DriveWriteAPI.fingerprint(remote).md5 && conflict.additional[0].md5Checksum==DriveWriteAPI.fingerprint(local).md5,"Pre-existing conflict preserves remote bytes and creates a separate Mac copy")
   let replay=try await engine().modify(id:item.id,base:version(updated.item!),name:item.name,parent:folderID,mime:item.mimeType,isFolder:false,contents:local)
   let conflictCount=try await api.children(folderID).files.count
   try check(replay.additional.first?.id==conflict.additional.first?.id && conflictCount==2,"Conflict replay after restart does not create another conflict copy")
   let latest=try await writer.revision(item.id),intervening=try staged("remote E"),newLocal=try staged("local F")
   await fault.race(item.id,file:intervening)
   let raced=try await engine().modify(id:item.id,base:version(latest.object),name:item.name,parent:folderID,mime:item.mimeType,isFolder:false,contents:newLocal)
   try check(raced.fetchContent && raced.item?.md5Checksum==DriveWriteAPI.fingerprint(intervening).md5 && raced.additional.first?.md5Checksum==DriveWriteAPI.fingerprint(newLocal).md5,"A remote edit during upload also produces two preserved versions")
   let beforeRename=try await writer.revision(item.id)
   await fault.arm(metadata:true);failed=false
   do{_ = try await engine().modify(id:item.id,base:version(beforeRename.object),name:"Nuevo.txt",parent:folderID,mime:item.mimeType,isFolder:false,contents:nil)}catch DriveFailure.unavailable{failed=true}
   let rename=try await engine().modify(id:item.id,base:version(beforeRename.object),name:"Nuevo.txt",parent:folderID,mime:item.mimeType,isFolder:false,contents:nil)
   try check(failed && rename.item?.name=="Nuevo.txt","Lost metadata reply is reconciled after journal reload")
   var staleRejected=false
   do{_ = try await engine().delete(id:item.id,base:version(beforeRename.object))}catch NativeMutationFailure.stale{staleRejected=true}
   let afterRejectedDelete=try await writer.revision(item.id)
   try check(staleRejected && afterRejectedDelete.object.trashed != true,"Deletion based on stale metadata is rejected")
   let beforeDelete=try await writer.revision(item.id)
   await fault.arm(metadata:true);failed=false
   do{_ = try await engine().delete(id:item.id,base:version(beforeDelete.object))}catch DriveFailure.unavailable{failed=true}
   let removed=try await engine().delete(id:item.id,base:version(beforeDelete.object))
   try check(failed && removed.removed==[item.id],"Trash operation with a lost reply replays without hard deletion")
   let rescued=try await engine().modify(id:item.id,base:version(beforeDelete.object),name:beforeDelete.object.name,parent:folderID,mime:item.mimeType,isFolder:false,contents:try staged("local edit after cloud trash"))
   try check(rescued.item==nil && rescued.removed==[item.id] && rescued.additional.count==1,"Local edits after remote trash survive as a separate conflict copy")
   let absent=try await writer.allocateID()
   let missing=try await engine().modify(id:absent,base:version(beforeDelete.object),name:"Ausente.txt",parent:folderID,mime:"text/plain",isFolder:false,contents:try staged("local edit after missing original"))
   try check(missing.item==nil && missing.removed==[absent] && missing.additional.count==1,"Local edits survive when the original remote ID is no longer accessible")
   await fault.arm(folder:true);failed=false
   do{_ = try await engine().create(template:"folder-template",parent:folderID,name:"Carpeta",mime:"application/vnd.google-apps.folder",isFolder:true,contents:nil)}catch DriveFailure.unavailable{failed=true}
   let folderReplay=try await engine().create(template:"folder-template",parent:folderID,name:"Carpeta",mime:"application/vnd.google-apps.folder",isFolder:true,contents:nil)
   try check(failed && folderReplay.item?.isFolder==true,"Folder creation is recovered after a lost reply")
   let files=(fm.enumerator(at:journal,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []).filter{$0.lastPathComponent=="operation.json"}
   try check(try files.allSatisfy{((try fm.attributesOfItem(atPath:$0.path)[.posixPermissions] as? NSNumber)?.intValue)==0o600},"Operation records containing upload URLs use private file permissions")
   let clean=try await writer.revision(folderID);_ = try await writer.updateMetadata(folderID,etag:clean.etag,trashed:true);try record("trashed")
   let report:[String:Any]=["status":"PASS","count":checks.count,"checks":checks,"real_drive":true,"synthetic_only":true,"cleanup":"owned test folder trashed","native_finder_writes":"NOT_ENABLED"]
   try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/NATIVE_WRITE_JOURNAL_TESTS.json"))
  }catch {
   if let folder=try? await writer.revision(folderID),(try? await writer.updateMetadata(folderID,etag:folder.etag,trashed:true)) != nil {try? record("trashed_after_failure")}
   throw error
  }
 }
}
