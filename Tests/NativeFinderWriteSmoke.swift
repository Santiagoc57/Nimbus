import Foundation
import FileProvider

/// Operates only on a new, uniquely named synthetic folder. It never reads or
/// modifies personal files. Requires the installed native domain to be writable.
@main struct NativeFinderWriteSmoke {
 static func main() async throws {
  let fm=FileManager.default
  let support=fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Nimbo")
  let config=try NimboSecureConfig.prepareApp(support:support)
  defer { try? NimboSecureConfig.resealApp(runtime:config,support:support) }
  let api=DriveAPI(configuration:config)
  let root=try await api.item("root")
  let name="Nimbo prueba escritura "+UUID().uuidString.prefix(8)
  let folder=fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage/Nimbo-GoogleDrive/"+name)
  let work=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("work/nimbo/native/finder-write-"+UUID().uuidString)
  try fm.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  var folderID:String?,checks:[String]=[],step="create folder"
  func record(_ state:String)throws {
   try JSONSerialization.data(withJSONObject:["state":state,"ownedFolderName":name,"ownedFolderID":folderID ?? "","step":step]).write(to:work.appendingPathComponent("cleanup.json"),options:.atomic)
  }
  func coordinate(_ url:URL,options:NSFileCoordinator.WritingOptions=[],_ action:@escaping(URL)throws->Void)async throws {
   try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in
    DispatchQueue.global(qos:.userInitiated).async {
     var error:NSError?,result:Result<Void,Error>?
     NSFileCoordinator(filePresenter:nil).coordinate(writingItemAt:url,options:options,error:&error){u in result=Result{try action(u)}}
     c.resume(with:result ?? .failure(error ?? DriveFailure.unavailable as NSError))
    }
   }
  }
  func find(_ parent:String,_ filename:String)async throws->DriveObject? {
   func escape(_ text:String)->String{text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"'",with:"\\'")}
   var url=URLComponents(string:"https://www.googleapis.com/drive/v3/files")!
   url.queryItems=[.init(name:"q",value:"'\(escape(parent))' in parents and name = '\(escape(filename))' and trashed = false"),.init(name:"fields",value:"files(\(DriveAPI.fields))"),.init(name:"pageSize",value:"10")]
   let (data,response)=try await api.send(url.url!,method:"GET");try DriveAPI.validate(response.statusCode,data:data)
   let items=try JSONDecoder().decode(DrivePage.self,from:data).files
   guard items.count<=1 else{throw DriveFailure.invalidResponse};return items.first
  }
  func waitFor(_ condition:@escaping()async throws->DriveObject?)async throws->DriveObject {
   for _ in 0..<90 {
    if let item=try await condition(){return item}
    try await Task.sleep(nanoseconds:1_000_000_000)
   }
   throw DriveFailure.unavailable
  }
  func passed(_ text:String){checks.append(text);print("PASS: "+text)}
  try record("planned")
  do {
   try await coordinate(folder){try fm.createDirectory(at:$0,withIntermediateDirectories:false)}
   let created=try await waitFor{try await find(root.id,name)};folderID=created.id;try record("created")
   passed("Folder created in native Finder reaches real Drive")
   step="create content";try record("created")
   let file=folder.appendingPathComponent("Original.txt"),bytes=Data("Nimbo: prueba real de escritura nativa.\n".utf8)
   try await coordinate(file){try bytes.write(to:$0,options:.atomic)}
   let original=try await waitFor{try await find(created.id,"Original.txt")}
   let expected=work.appendingPathComponent("expected.txt");try bytes.write(to:expected)
   let hash=try DriveWriteAPI.fingerprint(expected).md5
   guard original.md5Checksum==hash else{throw DriveFailure.invalidResponse}
   passed("Created file bytes match remote checksum")
   step="edit content";try record("created")
   let revised=Data("Nimbo: edición nativa confirmada.\n".utf8);try revised.write(to:expected)
   let revisedHash=try DriveWriteAPI.fingerprint(expected).md5
   try await coordinate(file,options:.forReplacing){try revised.write(to:$0,options:.atomic)}
   _ = try await waitFor{let item=try await api.item(original.id);return item.md5Checksum==revisedHash ? item:nil}
   passed("Native edit updates remote bytes under the same ID")
   step="rename";try record("created")
   let renamed=folder.appendingPathComponent("Renombrado.txt")
   try await coordinate(file,options:.forMoving){try fm.moveItem(at:$0,to:renamed)}
   _ = try await waitFor{let item=try await api.item(original.id);return item.name=="Renombrado.txt" ? item:nil}
   passed("Native rename preserves remote ID")
   step="trash file";try record("created")
   try await coordinate(renamed,options:.forDeleting){try fm.removeItem(at:$0)}
   _ = try await waitFor{let item=try await api.item(original.id);return item.trashed==true ? item:nil}
   passed("Native deletion uses Google Drive trash")
   step="cleanup folder";try record("created")
   try await coordinate(folder,options:.forDeleting){try fm.removeItem(at:$0)}
   _ = try await waitFor{let item=try await api.item(created.id);return item.trashed==true ? item:nil}
   try record("trashed");passed("Owned synthetic folder also trashed through native provider")
   let report:[String:Any]=["status":"PASS","checks":checks,"count":checks.count,"real_native_domain":true,"synthetic_only":true,"cleanup":"trashed through native provider"]
   try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/NATIVE_FINDER_REAL_WRITE_TEST.json"))
  } catch {
   try? record("needs_review_after_failure")
   print("FAIL at step:",step,"error domain:",(error as NSError).domain,"code:",(error as NSError).code)
   throw error
  }
 }
}
