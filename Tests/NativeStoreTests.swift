import Foundation
import FileProvider
import CryptoKit
final class ChangesProbe:NSObject,NSFileProviderChangeObserver {
 var items:[NSFileProviderItem]=[]
 let done:([NSFileProviderItem],Error?)->Void
 init(_ done:@escaping([NSFileProviderItem],Error?)->Void){self.done=done}
 func didUpdate(_ updatedItems:[NSFileProviderItem]) {items += updatedItems}
 func didDeleteItems(withIdentifiers:[NSFileProviderItemIdentifier]) {}
 func finishEnumeratingChanges(upTo:NSFileProviderSyncAnchor,moreComing:Bool){done(items,nil)}
 func finishEnumeratingWithError(_ error:Error){done(items,error)}
}
final class ItemsProbe:NSObject,NSFileProviderEnumerationObserver {
 var items:[NSFileProviderItem]=[]
 let done:([NSFileProviderItem],NSFileProviderPage?,Error?)->Void
 init(_ done:@escaping([NSFileProviderItem],NSFileProviderPage?,Error?)->Void){self.done=done}
 func didEnumerate(_ updatedItems:[NSFileProviderItem]) {items += updatedItems}
 func finishEnumerating(upTo page:NSFileProviderPage?) {done(items,page,nil)}
 func finishEnumeratingWithError(_ error:Error) {done(items,nil,error)}
}
@main struct Tests {
 static func main() async throws {
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/nimbo/native/store-tests-"+UUID().uuidString)
  #if SECURE_KEYCHAIN_TESTS
  NimboSecureFile.testRoot=root.appendingPathComponent("TestKeys")
  #endif
  let store=try NativeStore(directory:root)
  var checks:[String]=[]
  func check(_ value:Bool,_ text:String)throws {guard value else{throw DriveFailure.invalidResponse}; checks.append(text); print("PASS: "+text)}
  var rejected=false; do{_ = try await store.rootID()}catch DriveFailure.notAuthenticated{rejected=true}
  try check(rejected,"Unconfigured native domain reports authentication required")
  try await store.configureFixture(); let rootID=try await store.rootID()
  try check(try await store.conflicts().isEmpty,"Native conflict list is durable and empty before any divergent write")
  let list=try await store.children(rootID,page:nil)
  try check(list.objects.count==2 && list.objects.contains(where:{$0.id=="projects"}),"Native directory enumerates only direct children by ID")
  let webRoot = try await store.browserLink(NSFileProviderItemIdentifier.rootContainer.rawValue)
  try check(webRoot.contains("id=fixture-root"),"Finder root identifier resolves to the configured Drive root")
  let webHello = try await store.browserLink("hello")
  try check(webHello.contains("id=hello"),"Provider returns metadata-only link for a real item identity")
  var missingLinkRejected=false
  do {_ = try await store.browserLink("missing-web-item")}catch {missingLinkRejected=true}
  try check(missingLinkRejected,"Missing Finder item cannot fabricate a web link")
  try check(try await store.pendingDownloads().isEmpty,"Obtaining a Finder link cannot enqueue downloads")
  let sub=try await store.children("projects",page:nil)
  try check(sub.objects.count==1 && sub.objects[0].name=="Café [2026].txt","Nested Unicode file metadata preserved")
  let before=try await store.currentAnchor(); try await store.setPinned("projects",true)
  let delta=try await store.changes(since:before)
  try check(delta.pinned.contains("projects") && delta.pinned.contains("cafe") && !delta.pinned.contains("hello"),"Folder offline policy applies to descendants only")
  try check((try await store.knownItems()).objects.count==3,"Pinning a folder discovers paginated descendants without fetching file bytes")
  try check(delta.anchor != before,"Local availability change advances durable sync anchor")
  let reloaded=try NativeStore(directory:root); let restored=try await reloaded.knownItems()
  try check(restored.pinned.contains("cafe") && restored.objects.count==3,"Native index and offline policy survive extension restart")
  let encryptedIndex=root.appendingPathComponent("index.json.enc")
  let encryptedBytes=try Data(contentsOf:encryptedIndex)
  try check(encryptedBytes.starts(with:Data("NIMBO-ENC-1\n".utf8)) && encryptedBytes.range(of:Data("fixture-root".utf8)) == nil && !FileManager.default.fileExists(atPath:root.appendingPathComponent("index.json").path),"Native metadata index is encrypted and no plaintext index remains")
  let output=root.appendingPathComponent("download.txt"); let (object,_,_)=try await reloaded.fetch("hello",to:output)
  try check(try String(contentsOf:output,encoding:.utf8)=="Nimbo native placeholder.\n" && object.id=="hello","Materialization returns bytes for requested stable ID")
  let native=NativeItem(object,rootID:rootID,pinned:false)
  try check(native.parentItemIdentifier == .rootContainer && native.filename=="Hola.txt" && native.contentPolicy == .downloadLazily,"Native item maps root and lazy content policy")
  let pinned=NativeItem(object,rootID:rootID,pinned:true)
  try check(pinned.contentPolicy == .downloadEagerlyAndKeepDownloaded && pinned.itemVersion.metadataVersion != native.itemVersion.metadataVersion,"Offline policy changes metadata version and blocks automatic eviction")
  let googleDocument=DriveObject(id:"native-doc",name:"Plan",mimeType:"application/vnd.google-apps.document",parents:[rootID])
  let documentItem=NativeItem(googleDocument,rootID:rootID,pinned:false,writable:true)
  try check(documentItem.filename=="Plan.webloc" && documentItem.contentType == .internetLocation,"Native Google document is represented by a Finder web link")
  try check(documentItem.documentSize != nil && !documentItem.capabilities.contains(.allowsWriting),"Native Google document exposes a link payload and remains browser-only")
  try check(nativeSafeName("a/b:c%\n")=="a%2Fb%3Ac%25%0A" && nativeSafeName("..") == "%2E%2E","Unsafe native filename characters encoded without path traversal")
  let enumerator=NativeEnumerator(store:reloaded,identifier:.rootContainer)
  let emptyError:Error?=await withCheckedContinuation { c in
   let observer=ChangesProbe{_,error in c.resume(returning:error)}
   enumerator.enumerateChanges(for:observer,from:NSFileProviderSyncAnchor(Data()))
  }
  try check((emptyError as NSError?)?.code==NSFileProviderError.syncAnchorExpired.rawValue,"Empty startup anchor requests re-enumeration instead of permanent network error")
  let changed:[NSFileProviderItem]=try await withCheckedThrowingContinuation { c in
   let observer=ChangesProbe{items,error in if let error{c.resume(throwing:error)}else{c.resume(returning:items)}}
   enumerator.enumerateChanges(for:observer,from:NSFileProviderSyncAnchor(Data(before.utf8)))
  }
  try check(Set(changed.map{$0.itemIdentifier.rawValue})==Set(["hello","projects"]),"Root changes do not leak grandchildren into a directory enumeration")
  try await reloaded.configureFixture()
  let afterReconnect=try await reloaded.knownItems()
  try check(afterReconnect.pinned.contains("cafe"),"Fixture reconnection preserves offline preferences")
  let longName=String(repeating:"é",count:130)+".txt"
  let shortened=nativeDisplayName(longName,id:"long-A")
  try check(shortened.decomposedStringWithCanonicalMapping.utf8.count<=240 && shortened.hasSuffix(".txt"),"Long Unicode names fit macOS while preserving the extension")
  try check(shortened != nativeDisplayName(longName,id:"long-B") && shortened==nativeDisplayName(longName,id:"long-A"),"Shortened names have stable ID-based disambiguation")
  try check(nativeDisplayName(String(repeating:"a",count:247),id:"doc",webLink:true).hasSuffix(".webloc"),"Long Google document names reserve space for their web link suffix")
  try await reloaded.setPinned("cafe",false)
  let overridden=try await reloaded.knownItems()
  try check(overridden.pinned.contains("projects") && !overridden.pinned.contains("cafe"),"Explicit child release overrides a pinned parent without changing the parent")
  let again=try NativeStore(directory:root);let persisted=try await again.knownItems()
  try check(!persisted.pinned.contains("cafe") && persisted.pinned.contains("projects"),"Child release preference survives extension restart")
  try await again.setPinned("cafe",true);try await again.setPinned("projects",false)
  let childKept=try await again.knownItems()
  try check(childKept.pinned.contains("cafe") && !childKept.pinned.contains("projects"),"Releasing a folder preserves a separately pinned child")
  let offlineRoot = root.appendingPathComponent("offline-policy")
  let offlineStore = try NativeStore(directory: offlineRoot)
  try await offlineStore.configureFixture()
  // The fixture backend requires a directory here. Leave cached metadata
  // readable but make every remote lookup fail.
  try Data().write(to: offlineRoot.appendingPathComponent("FixtureRemote"))
  var offlineRemoteFailed = false
  do { _ = try await offlineStore.item("hello") } catch { offlineRemoteFailed = true }
  try check(offlineRemoteFailed, "Offline policy test has an unavailable remote")
  try await offlineStore.setPinned("hello", false)
  try check(try await offlineStore.evictionCandidates("hello").map { $0.id } == ["hello"], "Cached file can be released without contacting Drive")
  let releaseRoot=root.appendingPathComponent("release-tests")
  let releaseStore=try NativeStore(directory:releaseRoot)
  try await releaseStore.configureFixture()
  try await releaseStore.requestFolderDownload("projects")
  try await releaseStore.requestDownload("hello")
  try check(Set(await releaseStore.pendingDownloads())==Set(["cafe","hello"]),"Folder Sync queues descendants without downloading unrelated content")
  try await releaseStore.setPinned("projects",false)
  try check(await releaseStore.pendingDownloads()==["hello"],"Folder Unsync cancels its queued downloads and preserves unrelated requests")
  let releaseReloaded=try NativeStore(directory:releaseRoot)
  try check(await releaseReloaded.pendingDownloads()==["hello"],"Cancelled folder requests stay cancelled after provider restart")
  try await releaseReloaded.setPinned("cafe",true)
  try await releaseReloaded.setPinned("projects",false)
  try check(try await releaseReloaded.evictionCandidates("projects").isEmpty,"Folder eviction excludes an explicitly retained child")
  try check(Set(await releaseReloaded.pendingDownloads())==Set(["hello","cafe"]),"A separately pinned child remains pending when its parent is released")
  try await releaseReloaded.setPinned("cafe",false)
  try check(try await releaseReloaded.evictionCandidates("projects").map{$0.id}==["cafe"],"Explicitly releasing the child makes it eligible for folder eviction")
  try check(await releaseReloaded.pendingDownloads()==["hello"],"Direct Unsync cancels the child's pending download")
  try await releaseReloaded.setPinned("hello",true)
  try check(try await releaseReloaded.evictionCandidates("hello").isEmpty,"A newly pinned file is protected when eviction candidates are resolved")
  try check(try await releaseReloaded.prepareDownload("projects")==["cafe"],"Sync returns nested file identifiers instead of requesting only folder enumeration")
  try check(!(try await releaseReloaded.knownItems()).pinned.contains("cafe"),"Folder Sync downloads once without changing the child's offline preference")
  try check(await releaseReloaded.downloadIsPending("cafe"),"Single-item pending check recognizes a one-time Sync request")
  try await releaseReloaded.setPinned("cafe",false)
  try check(!(await releaseReloaded.downloadIsPending("cafe")),"Single-item pending check rejects an Unsync-cancelled request")
  try check(await releaseReloaded.downloadIsPending("hello"),"Single-item pending check retains unrelated offline intent")
  try check(!(await releaseReloaded.downloadIsPending("missing")),"Single-item pending check rejects unknown content")
  let queueDirectory=root.appendingPathComponent("completed-queue")
  let queueStore=try NativeStore(directory:queueDirectory)
  try await queueStore.configureFixture();_ = try await queueStore.children("projects",page:nil)
  try await queueStore.noteDownloaded("hello")
  // The system can finish the download before the action records its request.
  try await queueStore.requestDownload("hello");try await queueStore.requestDownload("cafe")
  try check(!(try await queueStore.reconcileMaterialized(["hello"])),"Completed queue cleanup does not spuriously change file metadata")
  let queueRestarted=try NativeStore(directory:queueDirectory)
  try await queueRestarted.clearDownloaded("hello")
  try check(!(await queueRestarted.downloadIsPending("hello")),"Completed download request stays cleared across restart and later eviction")
  try check(await queueRestarted.pendingDownloads()==["cafe"],"Completed queue cleanup preserves unrelated requested downloads")
  let refreshDirectory=root.appendingPathComponent("metadata-refresh")
  let refreshStore=try NativeStore(directory:refreshDirectory)
  try await refreshStore.configureFixture()
  try await refreshStore.requestDownload("hello")
  let refreshAnchor=try await refreshStore.currentAnchor()
  try await refreshStore.renameFixtureRemotely("hello",name:"Renombrado en Drive.txt")
  try check(try await refreshStore.knownItems().objects.first(where:{$0.id=="hello"})?.name=="Hola.txt","Remote rename remains separate from cached metadata before refresh")
  let refreshContainers=try await refreshStore.refreshMetadata("hello")
  try check(try await refreshStore.knownItems().objects.first(where:{$0.id=="hello"})?.name=="Renombrado en Drive.txt","Explicit metadata refresh retrieves the changed remote name")
  try check(refreshContainers==[NSFileProviderItemIdentifier.rootContainer.rawValue],"File refresh targets its containing folder")
  try check(try await refreshStore.currentAnchor() != refreshAnchor,"Metadata refresh publishes a new local anchor")
  let refreshPending=await refreshStore.pendingDownloads(), refreshDownloaded=await refreshStore.hasDownloaded("hello")
  try check(refreshPending==["hello"] && !refreshDownloaded,"Refresh preserves download intent without materializing the file")
  try await refreshStore.addFixtureLargeTree()
  let folderContainers=try await refreshStore.refreshMetadata("large-folder")
  let refreshedItems=try await refreshStore.knownItems()
  try check(refreshedItems.objects.filter{$0.parents==["large-folder"]}.count==520 && folderContainers.contains("large-folder"),"Folder refresh reads every metadata page and targets the folder itself")
  let largeDownloaded=await refreshStore.hasDownloaded("large-0519"), largePending=await refreshStore.pendingDownloads()
  try check(!refreshedItems.pinned.contains("large-0519") && !largeDownloaded && largePending==["hello"],"Large-folder refresh neither pins nor queues its descendants")
  _ = try await refreshStore.refreshMetadata(NSFileProviderItemIdentifier.rootContainer.rawValue)
  try check(try await refreshStore.knownItems().pinned.isEmpty,"Root refresh preserves cloud-only policy")
  var refreshMissing=false
  do { _ = try await refreshStore.refreshMetadata("missing-refresh") } catch DriveFailure.notFound { refreshMissing=true }
  try check(refreshMissing,"Refreshing a missing item reports failure instead of claiming cached success")
  let cancelledRefresh=Task { try await refreshStore.refreshMetadata("large-folder") }
  cancelledRefresh.cancel()
  var refreshCancelled=false
  do { _ = try await cancelledRefresh.value } catch is CancellationError { refreshCancelled=true }
  try check(refreshCancelled,"Cancelled refresh cannot report successful completion")
  let legacyDir=root.appendingPathComponent("legacy");try FileManager.default.createDirectory(at:legacyDir,withIntermediateDirectories:true)
  var legacy=try JSONDecoder().decode(NativeSnapshot.self,from:try NimboSecureFile.loadData(from:encryptedIndex,account:"native-index-" + SHA256.hash(data:Data(root.standardizedFileURL.path.utf8)).map{String(format:"%02x",$0)}.joined(),keychain:false)!)
  let unauthenticatedDirectory=root.appendingPathComponent("cached-without-credentials")
  try FileManager.default.createDirectory(at:unauthenticatedDirectory,withIntermediateDirectories:true)
  var unauthenticatedSnapshot=legacy;unauthenticatedSnapshot.fixture=false
  try JSONEncoder().encode(unauthenticatedSnapshot).write(to:unauthenticatedDirectory.appendingPathComponent("index.json"))
  let unauthenticatedStore=try NativeStore(directory:unauthenticatedDirectory)
  var authenticationRequired=false
  do { _ = try await unauthenticatedStore.refreshMetadata("hello") } catch DriveFailure.notAuthenticated { authenticationRequired=true }
  try check(authenticationRequired,"Explicit refresh rejects missing authentication even when cached metadata exists")
  legacy.offlineRules=nil;legacy.pinned=["projects"]
  try JSONEncoder().encode(legacy).write(to:legacyDir.appendingPathComponent("index.json"))
  let legacyStore=try NativeStore(directory:legacyDir)
  try check(try await legacyStore.knownItems().pinned.contains("cafe"),"Old persisted pin format retains recursive offline behavior")
  try check(FileManager.default.fileExists(atPath:legacyDir.appendingPathComponent("index.json.enc").path) && !FileManager.default.fileExists(atPath:legacyDir.appendingPathComponent("index.json").path),"Legacy native index migrates to encrypted storage")
  let readOnlyDir=root.appendingPathComponent("readonly");try FileManager.default.createDirectory(at:readOnlyDir,withIntermediateDirectories:true)
  var readOnlySnapshot=legacy;readOnlySnapshot.writable=false;readOnlySnapshot.offlineRules=[:];readOnlySnapshot.pinned=[]
  try JSONEncoder().encode(readOnlySnapshot).write(to:readOnlyDir.appendingPathComponent("index.json"))
  let readOnly=try NativeStore(directory:readOnlyDir)
  try await readOnly.clearDownloaded("hello")
  try check(!(await readOnly.isWritable()),"Readonly fixture retains its cloud permission level")
  try await readOnly.setPinned("hello",true)
  let (readOnlyObject,_,_)=try await readOnly.fetch("hello",to:readOnlyDir.appendingPathComponent("content.txt"))
  let localReadOnly=NativeItem(readOnlyObject,rootID:rootID,pinned:true,locallyDownloaded:await readOnly.hasDownloaded("hello"),writable:false)
  try check(localReadOnly.isDownloaded && !localReadOnly.capabilities.contains(.allowsWriting),"Readonly account can keep content offline without gaining write permission")
  try await readOnly.setPinned("hello",false);try await readOnly.clearDownloaded("hello")
  let cloudReadOnly=NativeItem(readOnlyObject,rootID:rootID,pinned:false,locallyDownloaded:await readOnly.hasDownloaded("hello"),writable:false)
  try check(!cloudReadOnly.isDownloaded && cloudReadOnly.decorations != localReadOnly.decorations,"Readonly local release changes the cloud/check decoration state")
  _ = try await readOnly.refreshMetadata("hello")
  let refreshedReadOnlyWritable=await readOnly.isWritable(), refreshedReadOnlyDownloaded=await readOnly.hasDownloaded("hello")
  try check(!refreshedReadOnlyWritable && !refreshedReadOnlyDownloaded,"Readonly account refresh does not gain write permission or download content")
  for number in 0..<300 {
   let id=String(format:"bulk-%04d",number)
   legacy.objects[id]=DriveObject(id:id,name:id+".txt",mimeType:"text/plain",size:"1",parents:[rootID])
  }
  legacy.objects["document"]=DriveObject(id:"document",name:"Documento",mimeType:"application/vnd.google-apps.document",parents:[rootID])
  legacy.objects["trashed"]=DriveObject(id:"trashed",name:"Borrado",mimeType:"text/plain",parents:[rootID],trashed:true)
  let downloadedAt=Date(timeIntervalSince1970:1_700_000_000)
  legacy.offlineRules=[rootID:true,"bulk-0000":false];legacy.downloadedAt=["bulk-0000":downloadedAt]
  let pagedDir=root.appendingPathComponent("paged")
  try FileManager.default.createDirectory(at:pagedDir,withIntermediateDirectories:true)
  try JSONEncoder().encode(legacy).write(to:pagedDir.appendingPathComponent("index.json"))
  let paged=try NativeStore(directory:pagedDir)
  let first=try JSONDecoder().decode(NativeAvailabilityPage.self,from:await paged.availabilityPage(after:nil))
  let second=try JSONDecoder().decode(NativeAvailabilityPage.self,from:await paged.availabilityPage(after:first.next))
  try check(first.items.count==250 && second.items.count==53 && second.next==nil,"Availability listing pages metadata, includes browser-link documents and excludes folders and trash")
  try check(Set((first.items+second.items).map{ $0.id }).count==303 && (first.items+second.items).contains(where:{$0.id=="document"}),"Availability pagination does not duplicate or omit candidates, including Google documents")
  try check(first.items.first?.downloadedAt==downloadedAt && first.items.first?.pinned==false,"Availability candidates carry download time and effective offline preference")
  let allowed=await paged.canAutomaticallyEvict("bulk-0000"),blocked=await paged.canAutomaticallyEvict("bulk-0001"),unknown=await paged.canAutomaticallyEvict("unknown")
  try check(allowed && !blocked && !unknown,"Automatic eviction guard rejects pinned and unknown IDs")
  var thresholdSnapshot=legacy
  thresholdSnapshot.objects["big-file"]=DriveObject(id:"big-file",name:"Grande.bin",mimeType:"application/octet-stream",size:"209715200",parents:[rootID])
  thresholdSnapshot.offlineRules=[rootID:true]
  thresholdSnapshot.offlineLimits=[rootID:Int64(100*1024*1024)]
  let thresholdDir=root.appendingPathComponent("threshold")
  try FileManager.default.createDirectory(at:thresholdDir,withIntermediateDirectories:true)
  try JSONEncoder().encode(thresholdSnapshot).write(to:thresholdDir.appendingPathComponent("index.json"))
  let thresholdStore=try NativeStore(directory:thresholdDir),thresholdListing=try await thresholdStore.knownItems()
  try check(!thresholdListing.pinned.contains("big-file") && thresholdListing.pinned.contains("bulk-0001"),"Folder download limit leaves oversized descendants as placeholders")
  try await thresholdStore.setPinned("big-file",true)
  try check(try await thresholdStore.knownItems().pinned.contains("big-file"),"Explicit child conservation overrides the parent size limit")
  try await store.addFixtureConflict()
  try check((try await store.conflicts()).count==1,"Native conflict list exposes a divergent copy")
  try await store.acknowledgeConflict("fixture-conflict")
  try check(try await store.conflicts().isEmpty,"Marking a conflict reviewed hides it without deleting the Drive copy")
  let conflictReload=try NativeStore(directory:root); try check(try await conflictReload.conflicts().isEmpty,"Reviewed conflict state survives extension restart")
  try await store.recordConflict(identifier:"cafe",kind:"rename",localName:"Café-local.txt",parent:"projects",remoteName:"Café [2026].txt",detail:"Cambio de nombre concurrente")
  let metadataConflict=try await store.conflicts().first(where:{$0.kind=="rename"})
  try check(metadataConflict?.name=="Café-local.txt" && metadataConflict?.remoteID=="cafe" && metadataConflict?.detail=="Cambio de nombre concurrente","Metadata conflict records local intent and remote context")
  try await store.resolveConflict(metadataConflict!.id,action:"retryLocal")
  let renamed=try await store.item("cafe").0
  let afterRenameConflicts=try await store.conflicts()
  try check(renamed.name=="Café-local.txt" && afterRenameConflicts.allSatisfy{$0.kind != "rename"},"Applying a local rename uses the current ETag and clears only that metadata conflict")
  try await store.recordConflict(identifier:"hello",kind:"delete",localName:"Hola.txt",parent:"fixture-root",remoteName:"Hola.txt",detail:"Borrado local pendiente")
  let deleteConflict=try await store.conflicts().first(where:{$0.kind=="delete"})
  try await store.resolveConflict(deleteConflict!.id,action:"keepRemote")
  let hello=try await store.item("hello").0,afterKeepConflicts=try await store.conflicts()
  try check(hello.trashed != true && afterKeepConflicts.allSatisfy{$0.kind != "delete"},"Keeping the Drive version preserves the remote item and clears the delete conflict")
  try await store.addFixtureLinkedConflict()
  let contentConflict=try await store.conflicts().first(where:{$0.kind=="content" && $0.id=="fixture-linked-conflict"})
  try await store.resolveConflict(contentConflict!.id,action:"retryLocal")
  let contentReload=try await store.knownItems(),contentConflicts=try await store.conflicts()
  try check(contentReload.objects.contains(where:{$0.id=="fixture-linked-conflict"}) && contentConflicts.allSatisfy{$0.id != "fixture-linked-conflict"},"Applying a content conflict uploads the preserved copy and keeps that copy as a Drive backup")
  try await store.addFixtureLargeTree()
  try await store.setPinned("large-folder",true)
  let largeListing=try await store.knownItems()
  let largeItems=largeListing.objects.filter{$0.parents?.contains("large-folder")==true}
  try check(largeItems.count==520 && largeListing.pinned.contains("large-0519"),"Large folder conservation walks every metadata page and pins all 520 descendants")
  let bytes=URL(fileURLWithPath:root.path).appendingPathComponent("FixtureRemote")
  let materializedLarge=try FileManager.default.contentsOfDirectory(at:bytes,includingPropertiesForKeys:nil).contains{$0.pathExtension=="bytes" && $0.lastPathComponent.hasPrefix("large-")}
  try check(!materializedLarge,"Large folder conservation does not materialize file bytes")
  let largeEnumerator=NativeEnumerator(store:store,identifier:NSFileProviderItemIdentifier("large-folder"))
  var finderPage:NSFileProviderPage?=NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data);var finderItems:[NSFileProviderItem]=[]
  while let page=finderPage {
   let result:([NSFileProviderItem],NSFileProviderPage?)=try await withCheckedThrowingContinuation { c in
    let observer=ItemsProbe{items,next,error in if let error{c.resume(throwing:error)}else{c.resume(returning:(items,next))}}
    largeEnumerator.enumerateItems(for:observer,startingAt:page)
   }
   finderItems += result.0;finderPage=result.1
  }
  try check(finderItems.count==520 && Set(finderItems.map{$0.itemIdentifier.rawValue}).count==520,"File Provider enumerator walks every large-folder page without duplicates")
  let report:[String:Any]=["status":"PASS","count":checks.count,"checks":checks,"synthetic_only":true]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/NATIVE_STORE_TESTS.json"))
 }
}
