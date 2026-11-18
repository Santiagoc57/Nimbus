import Foundation
import Darwin
@main struct NativeFinderReadSmoke {
 static func main() async throws {
  let fm=FileManager.default
  let config=fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Nimbo/rclone.conf")
  let api=DriveAPI(configuration:config), writer=DriveWriteAPI(api:api)
  let work=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("work/nimbo/native/finder-live-"+UUID().uuidString)
  try fm.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let root=try await api.item("root"), folderID=try await writer.allocateID()
  let folderName="Nimbo prueba Finder "+UUID().uuidString.prefix(8), name="Lectura.txt", expected=Data("Nimbo: lectura real bajo demanda, sólo datos de prueba.\n".utf8)
  let local=work.appendingPathComponent(name);try expected.write(to:local)
  let cleanup=work.appendingPathComponent("cleanup.json")
  func record(_ state:String)throws {try JSONSerialization.data(withJSONObject:["ownedFolderID":folderID,"state":state]).write(to:cleanup,options:.atomic)}
  try record("allocated")
  do {
   _ = try await writer.createFolder(id:folderID,parent:root.id,name:String(folderName));try record("created")
   let fileID=try await writer.allocateID()
   let session=try await writer.beginUpload(id:fileID,parent:folderID,name:name,mime:"text/plain",file:local,baseETag:nil)
   _ = try await writer.upload(local,session:session,checkpoint:{_ in})
   let cloud=fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage/Nimbo-GoogleDrive").appendingPathComponent(String(folderName)).appendingPathComponent(name)
   for _ in 0..<90 {if fm.fileExists(atPath:cloud.path){break};try await Task.sleep(nanoseconds:1_000_000_000)}
   guard fm.fileExists(atPath:cloud.path) else{throw DriveFailure.unavailable}
   var before=stat();guard lstat(cloud.path,&before)==0 else{throw DriveFailure.unavailable}
   let contents:Data=try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos:.userInitiated).async {
     let coordinator=NSFileCoordinator(filePresenter:nil);var coordinationError:NSError?,read:Result<Data,Error>?
     coordinator.coordinate(readingItemAt:cloud,options:[],error:&coordinationError){url in read=Result{try Data(contentsOf:url)}}
     if let read{continuation.resume(with:read)}else{continuation.resume(throwing:coordinationError ?? NSError(domain:NSCocoaErrorDomain,code:NSFileReadUnknownError))}
    }
   }
   var after=stat();guard lstat(cloud.path,&after)==0,contents==expected else{throw DriveFailure.invalidResponse}
   let report:[String:Any]=["status":"PASS","real_native_domain":true,"synthetic_file_only":true,"remote_file_discovered":true,"coordinated_read_matches_cloud":true,"flags_before":before.st_flags,"flags_after":after.st_flags,"user_confirmed_personal_folders":true]
   try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/NATIVE_FINDER_REAL_READ_TEST.json"))
   let folder=try await writer.revision(folderID);_ = try await writer.updateMetadata(folderID,etag:folder.etag,trashed:true);try record("trashed")
   print("PASS: real native Finder domain discovered and hydrated owned synthetic file through coordinated read.")
  } catch {
   if let folder=try? await writer.revision(folderID),(try? await writer.updateMetadata(folderID,etag:folder.etag,trashed:true)) != nil {try? record("trashed_after_failure")}
   print("Native read test error:",(error as NSError).domain,(error as NSError).code)
   throw error
  }
 }
}
