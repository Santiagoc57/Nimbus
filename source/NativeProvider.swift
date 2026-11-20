import Foundation
import FileProvider
import UniformTypeIdentifiers
import CryptoKit
import Darwin
import notify

func nativeError(_ error:Error)->NSError {
    let native=error as NSError
    if native.domain==NSFileProviderErrorDomain || native.domain==NSCocoaErrorDomain {return native}
    if error is CancellationError { return NSError(domain:NSCocoaErrorDomain,code:NSUserCancelledError) }
    if let e=error as? DriveFailure {
        let code:NSFileProviderError.Code
        switch e {
        case .notAuthenticated,.unsupportedCredentials: code = .notAuthenticated
        case .anchorExpired: code = .syncAnchorExpired
        case .notFound: code = .noSuchItem
        case .quota: code = .insufficientQuota
        case .denied: return NSError(domain:NSCocoaErrorDomain,code:NSFileReadNoPermissionError,userInfo:[NSLocalizedDescriptionKey:e.localizedDescription])
        default: code = .serverUnreachable
        }
        return NSError(domain:NSFileProviderErrorDomain,code:code.rawValue,userInfo:[NSLocalizedDescriptionKey:e.localizedDescription])
    }
    return NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.serverUnreachable.rawValue,userInfo:[NSLocalizedDescriptionKey:"No se pudo consultar Google Drive."])
}
/// Extracts the Drive file id from a Nimbo .webloc placeholder.
func nativeDriveID(webloc url:URL)->String? {
    guard let data=try? Data(contentsOf:url), data.count < 65536,
          let plist=try? PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any],
          let link=plist["URL"] as? String, let components=URLComponents(string:link),
          components.host?.hasSuffix("google.com")==true,
          let id=components.queryItems?.first(where:{$0.name=="id"})?.value, !id.isEmpty else { return nil }
    return id
}
/// Finder shows this description in its alert, so explain why a copy was kept.
func nativeEvictionError(_ error:Error,name:String)->NSError {
    let e=error as NSError
    let message:String
    if e.domain==NSFileProviderErrorDomain && e.code==NSFileProviderError.unsyncedEdits.rawValue {
        message="«\(name)» tiene cambios pendientes de subir a Google Drive. Nimbo conserva la copia local hasta que se sincronicen; volvé a intentarlo después."
    } else if (e.domain==NSFileProviderErrorDomain && [NSFileProviderError.nonEvictable.rawValue,NSFileProviderError.nonEvictableChildren.rawValue].contains(e.code)) || (e.domain==NSPOSIXErrorDomain && e.code==Int(EBUSY)) {
        // macOS reports the same code for an open file and for one whose
        // changes are still uploading, so name both causes.
        message="«\(name)» está abierto o tiene cambios que todavía se están subiendo a Google Drive. Cerralo o esperá a que termine la sincronización y volvé a intentarlo; la copia local no se modificó."
    } else {
        message="No se pudo liberar «\(name)»: \(e.localizedDescription). La copia local se conserva."
    }
    return NSError(domain:e.domain,code:e.code,userInfo:[NSLocalizedDescriptionKey:message,NSUnderlyingErrorKey:e])
}
func nativeSafeName(_ name:String)->String {
    var value=name.replacingOccurrences(of:"%",with:"%25").replacingOccurrences(of:"/",with:"%2F").replacingOccurrences(of:":",with:"%3A").replacingOccurrences(of:"\0",with:"%00").replacingOccurrences(of:"\n",with:"%0A").replacingOccurrences(of:"\r",with:"%0D")
    if value=="." || value==".." { value=value.replacingOccurrences(of:".",with:"%2E") }
    return value.isEmpty ? "%00" : value
}
/// Inverse of `nativeSafeName` for names coming back from Finder. Without it
/// a Drive name such as "14:52:06.jpg" was re-uploaded as "14%3A52%3A06.jpg".
/// Scratch files apps write while saving (Adobe "Name.14162.156415", "~$x.docx",
/// "x.tmp", "x.part", "x.crdownload", "x.sb-…"). They are renamed or deleted
/// seconds later; uploading them races the rename and leaves conflict copies.
/// macOS calls createItem again if one is renamed to a normal name.
func nativeIsTemporaryName(_ name:String)->Bool {
    let lower=name.lowercased()
    if name.hasPrefix("~$") || name.hasPrefix(".~lock.") { return true }
    for ext in [".tmp",".temp",".part",".partial",".crdownload",".download",".swp"] where lower.hasSuffix(ext) { return true }
    if lower.range(of:#"\.sb-[0-9a-f]{8}-[a-z0-9]{6}$"#,options:.regularExpression) != nil { return true }
    return name.range(of:#"\.[0-9]{3,}\.[0-9]{3,}$"#,options:.regularExpression) != nil
}
func nativeDriveName(_ local:String)->String {
    if local=="%2E" { return "." }
    if local=="%2E%2E" { return ".." }
    var value=local
    for (encoded,decoded) in [("%2F","/"),("%3A",":"),("%00","\0"),("%0A","\n"),("%0D","\r")] {
        value=value.replacingOccurrences(of:encoded,with:decoded)
    }
    return value.replacingOccurrences(of:"%25",with:"%")
}
func nativeDisplayName(_ name:String,id:String,webLink:Bool=false)->String {
    let safe=nativeSafeName(name), full=safe+(webLink ? ".webloc" : "")
    guard full.decomposedStringWithCanonicalMapping.utf8.count>240 else{return full}
    let ext=(safe as NSString).pathExtension
    let suffix=webLink ? ".webloc" : (ext.utf8.count<=16 && !ext.isEmpty ? "."+ext : "")
    let stem=(!webLink && !suffix.isEmpty) ? String(safe.dropLast(suffix.count)) : safe
    let tag=" ~"+SHA256.hash(data:Data(id.utf8)).prefix(16).map{String(format:"%02x",$0)}.joined()
    let budget=240-tag.utf8.count-suffix.decomposedStringWithCanonicalMapping.utf8.count
    var prefix=""
    for character in stem {
        let candidate=prefix+String(character)
        if candidate.decomposedStringWithCanonicalMapping.utf8.count>budget {break}
        prefix=candidate
    }
    return prefix+tag+suffix
}
final class NativeItem:NSObject,NSFileProviderItemDecorating {
    let object:DriveObject, rootID:String, pinned:Bool, locallyDownloaded:Bool, writable:Bool
    /// "uploading" while a Mac edit travels to Drive, "failed" if it could not.
    let uploadState:String?
    init(_ object:DriveObject,rootID:String,pinned:Bool,locallyDownloaded:Bool=false,writable:Bool=false,uploadState:String?=nil) { self.object=object; self.rootID=rootID; self.pinned=pinned;self.locallyDownloaded=locallyDownloaded;self.writable=writable;self.uploadState=uploadState }
    var itemIdentifier:NSFileProviderItemIdentifier { object.id==rootID ? .rootContainer : NSFileProviderItemIdentifier(object.id) }
    var parentItemIdentifier:NSFileProviderItemIdentifier { guard let p=object.parents?.first, p != rootID else {return .rootContainer}; return NSFileProviderItemIdentifier(p) }
    var filename:String { nativeDisplayName(object.name,id:object.id,webLink:object.isGoogleDocument) }
    var contentType:UTType { if object.splitLayout != nil { return UTType(filenameExtension: (object.name as NSString).pathExtension) ?? .data }; return object.isFolder ? .folder : object.isGoogleDocument ? .internetLocation : (UTType(mimeType:object.mimeType) ?? .data) }
    var documentSize:NSNumber? {
        if object.isGoogleDocument { return (try? PropertyListSerialization.data(fromPropertyList:["URL":"https://drive.google.com/open?id="+object.id],format:.xml,options:0).count).map{NSNumber(value:$0)} }
        return object.size.flatMap{Int64($0)}.map{NSNumber(value:$0)}
    }
    var capabilities:NSFileProviderItemCapabilities {
        var result:NSFileProviderItemCapabilities=object.isFolder ? [.allowsContentEnumerating,.allowsReading]:[.allowsReading]
        guard writable,!object.isGoogleDocument else{return result}
        if object.capabilities?.canEdit==true { result.insert(.allowsReparenting); if object.splitLayout == nil || object.capabilities?.canAddChildren == true { result.insert(.allowsWriting) } }
        if object.capabilities?.canRename==true {result.insert(.allowsRenaming)}
        if object.capabilities?.canTrash==true {result.insert(.allowsDeleting)}
        if object.isFolder,object.capabilities?.canAddChildren==true {result.insert(.allowsAddingSubItems)}
        if object.id==rootID {result.subtract([.allowsRenaming,.allowsReparenting,.allowsDeleting])}
        return result
    }
    // Only an explicit "Conservar sin conexión" keeps content permanently.
    // "Sincronizar ahora" downloads a copy but leaves the normal lazy policy.
    var contentPolicy:NSFileProviderContentPolicy { pinned ? .downloadEagerlyAndKeepDownloaded : .downloadLazily }
    // Finder uses these transfer-state properties when evaluating the
    // File Provider action predicates.  Google-native documents are exposed
    // as small .webloc placeholders, so the presence of that placeholder must
    // not make an unpinned item look downloaded.
    var isUploaded:Bool { true }
    var isUploading:Bool { false }
    var isDownloaded:Bool { locallyDownloaded }
    var isDownloading:Bool { false }
    var isMostRecentVersionDownloaded:Bool { locallyDownloaded }
    // Replicated providers let macOS infer transfer state from materialized
    // contents, which is misleading for our tiny Google-document .webloc
    // placeholders.  Expose the Nimbo state explicitly for action predicates.
    /// Read by the Finder menu predicates: "links" shows Copiar enlace / Abrir vista web.
    var userInfo:[AnyHashable:Any]? { ["rank": pinned ? 1 : 0, "links": NativeItem.showLinkActions ? 1 : 0] }
    static var showLinkActions = false
    /// File Provider decorations are rendered by Finder even inside
    /// ~/Library/CloudStorage, where Finder Sync badges are not requested.
    /// Keep the cloud/check state in the provider item itself so it survives
    /// Finder restarts and works for Google-native .webloc placeholders.
    var decorations:[NSFileProviderItemDecorationIdentifier]? {
        let name: String
        switch uploadState {
        case "uploading": name = "local.nimbo.cloudsearch.provider.decoration.uploading"
        case "failed": name = "local.nimbo.cloudsearch.provider.decoration.failed"
        default: name = locallyDownloaded ? "local.nimbo.cloudsearch.provider.decoration.synced" : "local.nimbo.cloudsearch.provider.decoration.cloud"
        }
        return [NSFileProviderItemDecorationIdentifier(name)]
    }
    var itemVersion:NSFileProviderItemVersion {
        let content=object.isFolder ? "folder" : (object.md5Checksum ?? object.version ?? "0")
        // Drive can advance version for background processing without changing bytes
        // or location. Compare the represented state; ETags guard the actual write.
        var metadata=[object.mimeType,object.name,object.parents?.joined(separator:",") ?? "",pinned ? "pinned" : "lazy",locallyDownloaded ? "local" : "cloud",writable ? "write" : "read"].joined(separator:"\n") + (uploadState.map { "\n" + $0 } ?? "")
        if object.splitLayout != nil && capabilities.contains(.allowsWriting) { metadata += "\neditable-split" }
        return NSFileProviderItemVersion(contentVersion:Data(SHA256.hash(data:Data(content.utf8))),metadataVersion:Data(SHA256.hash(data:Data(metadata.utf8))))
    }
    var contentModificationDate:Date? { object.modifiedTime.flatMap{ Self.date($0) } }
    var creationDate:Date? { object.createdTime.flatMap{Self.date($0)} }
    private static func date(_ text:String)->Date? { let f=ISO8601DateFormatter(); f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; return f.date(from:text) ?? ISO8601DateFormatter().date(from:text) }
}
private final class NativeRegistry {
    static let shared=NativeRegistry(); private let lock=NSLock(); private var stores:[String:NativeStore]=[:]
    private init() {
        // File Provider extensions do not receive an AppKit termination
        // callback.  Register a normal-process exit hook so each domain's
        // temporary OAuth file is sealed before the extension goes away.
        atexit {
            NativeRegistry.sealAllRuntimes()
        }
    }
    private static func sealAllRuntimes() {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NimboNative", isDirectory: true)
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            try? NimboSecureConfig.resealNative(directory: child)
        }
    }
    func store(_ id:String)throws->NativeStore {
        lock.lock(); defer{lock.unlock()}
        if let store=stores[id] {return store}
        let key=SHA256.hash(data:Data(id.utf8)).map{String(format:"%02x",$0)}.joined()
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NimboNative/"+key)
        let store=try NativeStore(directory:root); stores[id]=store; return store
    }
}
final class NativeEnumerator:NSObject,NSFileProviderEnumerator {
    let store:NativeStore, identifier:NSFileProviderItemIdentifier
    private let lock=NSLock(); private var tasks:[UUID:Task<Void,Never>]=[:]
    init(store:NativeStore,identifier:NSFileProviderItemIdentifier) { self.store=store; self.identifier=identifier }
    func invalidate() { lock.lock(); let active=tasks.values; tasks=[:]; lock.unlock(); active.forEach{$0.cancel()} }
    private func launch(_ work:@escaping () async->Void) {
        let id=UUID(); lock.lock()
        tasks[id]=Task { await work(); self.finished(id) }
        lock.unlock()
    }
    private func finished(_ id:UUID) {lock.lock(); tasks.removeValue(forKey:id); lock.unlock()}
    func enumerateItems(for observer:NSFileProviderEnumerationObserver,startingAt page:NSFileProviderPage) {
        launch {
            do {
                let list:NativeListing
                if self.identifier == .workingSet { list=try await self.store.knownItems(includeRoot:true) }
                else {
                    let parent=self.identifier == .rootContainer ? try await self.store.rootID() : self.identifier.rawValue
                    let token=(page.rawValue == NSFileProviderPage.initialPageSortedByDate as Data || page.rawValue == NSFileProviderPage.initialPageSortedByName as Data) ? nil : String(data:page.rawValue,encoding:.utf8)
                    list=try await self.store.children(parent,page:token)
                }
                try Task.checkCancellation()
                let writable=await self.store.isWritable()
                var items:[NativeItem]=[]
                for object in list.objects {
                    items.append(NativeItem(object,rootID:list.rootID,pinned:list.pinned.contains(object.id),locallyDownloaded:await self.store.hasDownloaded(object.id),writable:writable,uploadState:await self.store.uploadState(object.id)))
                }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo:list.nextPage.map{NSFileProviderPage(Data($0.utf8))})
            } catch { observer.finishEnumeratingWithError(nativeError(error)) }
        }
    }
    func enumerateChanges(for observer:NSFileProviderChangeObserver,from anchor:NSFileProviderSyncAnchor) {
        launch {
            do {
                guard let token=String(data:anchor.rawValue,encoding:.utf8), !token.isEmpty else {
                    throw NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.syncAnchorExpired.rawValue)
                }
                let delta=try await self.store.changes(since:token); try Task.checkCancellation()
                observer.didDeleteItems(withIdentifiers:delta.removed.map{NSFileProviderItemIdentifier($0)})
                let updates=delta.updated.filter { item in
                    if self.identifier == .workingSet {return true}
                    if self.identifier == .rootContainer {return item.parents?.contains(delta.rootID)==true}
                    return item.id==self.identifier.rawValue || item.parents?.contains(self.identifier.rawValue)==true
                }
                let writable=await self.store.isWritable()
                var items:[NativeItem]=[]
                for item in updates { items.append(NativeItem(item,rootID:delta.rootID,pinned:delta.pinned.contains(item.id),locallyDownloaded:await self.store.hasDownloaded(item.id),writable:writable,uploadState:await self.store.uploadState(item.id))) }
                observer.didUpdate(items)
                observer.finishEnumeratingChanges(upTo:NSFileProviderSyncAnchor(Data(delta.anchor.utf8)),moreComing:delta.more)
            } catch {observer.finishEnumeratingWithError(nativeError(error))}
        }
    }
    func currentSyncAnchor(completionHandler:@escaping (NSFileProviderSyncAnchor?)->Void) {
        launch { do {completionHandler(NSFileProviderSyncAnchor(Data(try await self.store.currentAnchor().utf8)))} catch {completionHandler(nil)} }
    }
}

final class NativeConnectionService:NSObject,NSFileProviderServiceSource,NSXPCListenerDelegate,NimboNativeConnection {
    let store:Result<NativeStore,Error>, manager:NSFileProviderManager?
    private let listener=NSXPCListener.anonymous()
    private let lock=NSLock(); private var connections:[NSXPCConnection]=[]
    var serviceName:NSFileProviderServiceName {NSFileProviderServiceName(nimboNativeServiceName)}
    var isRestricted:Bool {true}
    init(store:Result<NativeStore,Error>,manager:NSFileProviderManager?) {self.store=store; self.manager=manager; super.init(); listener.delegate=self; listener.resume()}
    func makeListenerEndpoint()throws->NSXPCListenerEndpoint {listener.endpoint}
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection)->Bool {
        connection.exportedInterface=NSXPCInterface(with:NimboNativeConnection.self); connection.exportedObject=self
        lock.lock(); connections.append(connection); lock.unlock()
        connection.invalidationHandler = { [weak self,weak connection] in guard let self,let connection else{return}; self.lock.lock(); self.connections.removeAll{$0 === connection}; self.lock.unlock() }
        connection.resume(); return true
    }
    func invalidate() {listener.invalidate(); lock.lock(); let all=connections; connections=[]; lock.unlock(); all.forEach{$0.invalidate()}}
    private func signal() {manager?.signalEnumerator(for:.rootContainer,completionHandler:{_ in}); manager?.signalEnumerator(for:.workingSet,completionHandler:{_ in})}
    /// File Provider applies the content-policy change asynchronously. Finder
    /// can therefore ask to evict during the short window in which the item is
    /// still considered non-evictable. Mirror the CLI/host retry policy here
    /// so the contextual menu does not surface a false "cannot eject" alert.
    func evictWithRetry(_ identifier:String) async throws {
        guard let manager else { throw NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.providerNotFound.rawValue) }
        for attempt in 0..<15 {
            do {
                try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                    manager.evictItem(identifier:NSFileProviderItemIdentifier(identifier)) { error in
                        if let error { c.resume(throwing:error) } else { c.resume() }
                    }
                }
                return
            } catch {
                let e=error as NSError
                let transient = e.domain == NSFileProviderErrorDomain &&
                    (e.code == NSFileProviderError.nonEvictable.rawValue ||
                     e.code == NSFileProviderError.nonEvictableChildren.rawValue)
                guard transient, attempt < 14 else { throw error }
                try await Task.sleep(nanoseconds:1_000_000_000)
            }
        }
    }
    private func authorized() {
        manager?.signalErrorResolved(NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.notAuthenticated.rawValue),completionHandler:{_ in})
        signal()
        // Spotlight: publish every name in the account, without downloading.
        let store=self.store
        Task.detached(priority:.utility) { [weak self] in
            if let backend=try? store.get(), await backend.indexWholeTree() { self?.signal() }
        }
    }
    func setTransferLimits(download: Int, upload: Int, reply: @escaping (NSError?) -> Void) {
        Task {
            do { try await store.get().setTransferLimits(download: download, upload: upload); reply(nil) }
            catch { reply(nativeError(error)) }
        }
    }
    func setShowLinkActions(_ enabled: Bool, reply: @escaping (NSError?) -> Void) {
        Task {
            do {
                let backend = try store.get()
                let changed = await backend.setShowLinkActions(enabled)
                NativeItem.showLinkActions = enabled
                if changed { signal() }
                reply(nil)
            } catch { reply(nativeError(error)) }
        }
    }
    func setFinderTransferSettings(download: Int, upload: Int, segmentMB: Int, reply: @escaping (NSError?) -> Void) {
        Task {
            do { try await store.get().setTransferLimits(download: download, upload: upload, segmentMB: segmentMB); reply(nil) }
            catch { reply(nativeError(error)) }
        }
    }
    func configure(_ data:Data,reply:@escaping (NSError?)->Void) {configureAccount(data,remoteName:"GoogleDrive",reply:reply)}
    func configureRoot(_ data:Data,rootID:String,reply:@escaping (NSError?)->Void) {configureRootAccount(data,rootID:rootID,remoteName:"GoogleDrive",reply:reply)}
    func configureAccount(_ data:Data,remoteName:String,reply:@escaping (NSError?)->Void) {Task{do{try await store.get().configure(data,remoteName:remoteName); authorized(); reply(nil)}catch{reply(nativeError(error))}}}
    func configureRootAccount(_ data:Data,rootID:String,remoteName:String,reply:@escaping (NSError?)->Void) {Task{do{try await store.get().configure(data,rootID:rootID,remoteName:remoteName); authorized(); reply(nil)}catch{reply(nativeError(error))}}}
    func browserLink(_ identifier: String, reply: @escaping (String?, NSError?) -> Void) {
        Task { do { reply(try await store.get().browserLink(identifier), nil) } catch { reply(nil, nativeError(error)) } }
    }
    func status(reply:@escaping (String?,NSError?)->Void) {Task{do{reply(try await store.get().status(),nil)}catch{reply(nil,nativeError(error))}}}
    func availabilityPage(after:String?,reply:@escaping(Data?,NSError?)->Void) {Task{do{reply(try await store.get().availabilityPage(after:after),nil)}catch{reply(nil,nativeError(error))}}}
    func conflicts(reply:@escaping(Data?,NSError?)->Void) {Task{do{reply(try JSONEncoder().encode(try await store.get().conflicts()),nil)}catch{reply(nil,nativeError(error))}}}
    func acknowledgeConflict(_ identifier:String,reply:@escaping (NSError?)->Void) {Task{do{try await store.get().acknowledgeConflict(identifier); reply(nil)}catch{reply(nativeError(error))}}}
    func resolveConflict(_ identifier:String,action:String,reply:@escaping (NSError?)->Void) {Task{do{try await store.get().resolveConflict(identifier,action:action); reply(nil)}catch{reply(nativeError(error))}}}
    func canAutomaticallyEvict(_ identifier:String,reply:@escaping(Bool,NSError?)->Void) {Task{do{reply(try await store.get().canAutomaticallyEvict(identifier),nil)}catch{reply(false,nativeError(error))}}}
    func takeEvictionMessages(reply:@escaping (Data?,NSError?)->Void) {Task{do{reply(try JSONEncoder().encode(await store.get().takeEvictionMessages()),nil)}catch{reply(nil,nativeError(error))}}}
    func pendingDownloads(reply:@escaping (Data?,NSError?)->Void) {Task{do{reply(try JSONEncoder().encode(await store.get().pendingDownloads()),nil)}catch{reply(nil,nativeError(error))}}}
    func downloadIsPending(_ identifier:String,reply:@escaping (Bool,NSError?)->Void) {Task{do{reply(await (try store.get()).downloadIsPending(identifier),nil)}catch{reply(false,nativeError(error))}}}
    func setPinned(_ identifier:String,value:Bool,limit:Int64,reply:@escaping (NSError?)->Void) {Task{do{let backend=try store.get(); try await backend.setPinned(identifier,value,limit:limit >= 0 ? limit : nil); signal(); reply(nil)}catch{reply(nativeError(error))}}}
    func evictionCandidates(_ identifier:String,reply:@escaping (Data?,NSError?)->Void) {Task{do{reply(try JSONEncoder().encode(try await store.get().evictionCandidates(identifier)),nil)}catch{reply(nil,nativeError(error))}}}
    func prepareDownload(_ identifier:String,reply:@escaping (Data?,NSError?)->Void) {Task{do{let ids=try await store.get().prepareDownload(identifier); signal(); reply(try JSONEncoder().encode(ids),nil); notify_post(nimboMaterializeNotification)}catch{reply(nil,nativeError(error))}}}
    #if NIMBO_TESTING
    func configureFixture(reply:@escaping (NSError?)->Void) {Task{do{try await store.get().configureFixture(); authorized(); reply(nil)}catch{reply(nativeError(error))}}}
    #endif
}

@objc(NimboNativeProvider) final class NimboNativeProvider:NSObject,NSFileProviderReplicatedExtension,NSFileProviderServicing,NSFileProviderCustomAction,NSFileProviderThumbnailing {
    let domain:NSFileProviderDomain, store:Result<NativeStore,Error>, service:NativeConnectionService
    required init(domain:NSFileProviderDomain) {
        self.domain=domain; store=Result{try NativeRegistry.shared.store(domain.identifier.rawValue)}
        service=NativeConnectionService(store:store,manager:NSFileProviderManager(for:domain)); super.init()
        if let backend=try? store.get() { NativeItem.showLinkActions = backend.linkActionsEnabled }
    }
    func invalidate() {service.invalidate()}
    /// Finder thumbnails from Drive, so images, PDFs and videos show their
    /// content in Finder without downloading the file.
    func fetchThumbnails(for itemIdentifiers:[NSFileProviderItemIdentifier],requestedSize size:CGSize,perThumbnailCompletionHandler:@escaping (NSFileProviderItemIdentifier,Data?,Error?)->Void,completionHandler:@escaping (Error?)->Void)->Progress {
        let progress=Progress(totalUnitCount:Int64(itemIdentifiers.count))
        let task=Task {
            for identifier in itemIdentifiers {
                if Task.isCancelled { break }
                var data:Data?
                if identifier != .rootContainer, let backend=try? self.store.get() { data=try? await backend.thumbnail(identifier.rawValue) }
                perThumbnailCompletionHandler(identifier,data,nil)
                progress.completedUnitCount += 1
            }
            completionHandler(Task.isCancelled ? CocoaError(.userCancelled) : nil)
        }
        progress.cancellationHandler={task.cancel()}
        return progress
    }
    func enumerator(for identifier:NSFileProviderItemIdentifier,request:NSFileProviderRequest)throws->NSFileProviderEnumerator {
        if identifier == .trashContainer {throw NSError(domain:NSCocoaErrorDomain,code:NSFeatureUnsupportedError)}
        return NativeEnumerator(store:try store.get(),identifier:identifier)
    }
    func supportedServiceSources(for itemIdentifier:NSFileProviderItemIdentifier,completionHandler:@escaping ([NSFileProviderServiceSource]?,Error?)->Void)->Progress {completionHandler([service],nil); return Progress(totalUnitCount:1)}
    /// File Provider's native Finder menu path. This remains available even
    /// when macOS has not loaded the optional Finder Sync extension.
    func performAction(identifier:NSFileProviderExtensionActionIdentifier,onItemsWithIdentifiers identifiers:[NSFileProviderItemIdentifier],completionHandler:@escaping (Error?)->Void)->Progress {
        let progress=Progress(totalUnitCount:Int64(max(identifiers.count,1)))
        let task=Task {
            do {
                let backend=try self.store.get()
                // These actions change only local availability/preferences.
                // Cloud write permissions are enforced by create/modify, not
                // by download, keep-offline or local eviction.
                guard let action = NativeFileAction.resolve(identifier.rawValue) else {
                    throw NSError(domain:NSCocoaErrorDomain,code:NSFeatureUnsupportedError,userInfo:[NSLocalizedDescriptionKey:"Acción de File Provider no reconocida."])
                }
                let sync = action == .sync, pin = action == .pin, evict = action == .evict
                var evictions:[(id:String,name:String,wasPinned:Bool,isFolder:Bool)]=[]
                for itemIdentifier in identifiers {
                    try Task.checkCancellation()
                    let raw=itemIdentifier == .rootContainer ? try await backend.rootID() : itemIdentifier.rawValue
                    if action == .refresh {
                        let containers=try await backend.refreshMetadata(raw)
                        guard let manager=NSFileProviderManager(for:self.domain) else { throw CocoaError(.fileNoSuchFile) }
                        for container in Set(containers + [NSFileProviderItemIdentifier.workingSet.rawValue]) {
                            try Task.checkCancellation()
                            try await manager.signalEnumerator(for:NSFileProviderItemIdentifier(container))
                        }
                        progress.completedUnitCount += 1
                        continue
                    }
                    let current=try await backend.item(raw)
                    if sync || pin {
                        if pin { try await backend.setPinned(raw,true,limit:nil) }
                        guard let manager = NSFileProviderManager(for: self.domain) else { throw CocoaError(.fileNoSuchFile) }
                        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                            manager.requestDownloadForItem(withIdentifier:NSFileProviderItemIdentifier(raw),requestedRange:NSRange(location:NSNotFound,length:0)) { error in
                                if let error { c.resume(throwing:error) } else { c.resume() }
                            }
                        }
                        // Not downloaded yet: macOS only scheduled a background
                        // download. Record the request and wake the app, which
                        // materializes it immediately with a coordinated read.
                        // The check decoration appears once content is local.
                        if current.0.isFolder {
                            // Pinning already queues only eligible descendants.
                            // A blanket Sync queue would override child exclusions.
                            if sync { try await backend.requestFolderDownload(raw) }
                        }
                        else { try await backend.requestDownload(raw) }
                        notify_post(nimboMaterializeNotification)
                    } else if evict {
                        // macOS does not apply the new policy nor evict an item
                        // while this action is still running, so evicting here
                        // deadlocked until a timeout. Drop the preference now
                        // and evict right after the action completes.
                        try await backend.setPinned(raw,false,limit:nil)
                        evictions.append((raw,current.0.name,current.2.contains(raw),current.0.isFolder))
                    }
                    progress.completedUnitCount += 1
                }
                if action != .refresh { self.changed() }
                completionHandler(nil)
                for eviction in evictions {
                    if eviction.isFolder { self.scheduleFolderEviction(eviction.id,name:eviction.name,wasPinned:eviction.wasPinned,backend:backend) }
                    else { self.scheduleEviction(eviction.id,name:eviction.name,wasPinned:eviction.wasPinned,backend:backend) }
                }
            } catch {
                completionHandler(nativeError(error))
            }
        }
        progress.cancellationHandler={task.cancel()}
        return progress
    }
    /// Evicts after the custom action finished. Success clears the local
    /// marker (cloud decoration); failure (open file, pending upload) restores
    /// the user's preference, keeps the copy and asks the app to explain why.
    private func scheduleEviction(_ id:String,name:String,wasPinned:Bool,backend:NativeStore) {
        let service=self.service
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds:1_000_000_000)
            do {
                try await service.evictWithRetry(id)
                try? await backend.clearDownloaded(id)
                NSLog("Nimbo eviction finished: %@", name)
            } catch {
                if wasPinned { try? await backend.setPinned(id,true,limit:nil) }
                let message=nativeEvictionError(error,name:name).localizedDescription
                NSLog("Nimbo eviction failed: %@ (%@)", message, String(describing:error))
                await backend.recordEvictionFailure(message)
                notify_post(nimboEvictionFailedNotification)
            }
            self?.changed()
        }
    }
    /// Folders: release every Drive file below it one by one. Local-only files
    /// Finder creates (.DS_Store) made a whole-folder eviction fail with a
    /// misleading "open or uploading" alert. Only files that really cannot be
    /// released (open, uploading) are reported, by name, in one message.
    private func scheduleFolderEviction(_ id:String,name:String,wasPinned:Bool,backend:NativeStore) {
        let service=self.service
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds:1_000_000_000)
            var kept:[String]=[]
            for file in await backend.filesForEviction(id) {
                do {
                    try await service.evictWithRetry(file.id)
                    try? await backend.clearDownloaded(file.id)
                } catch {
                    let e=error as NSError
                    // Already cloud-only or gone: nothing to release.
                    if e.domain==NSFileProviderErrorDomain && e.code==NSFileProviderError.noSuchItem.rawValue { continue }
                    NSLog("Nimbo folder eviction kept %@ (%@)", file.name, String(describing:error))
                    kept.append(file.name)
                }
            }
            if kept.isEmpty {
                NSLog("Nimbo folder eviction finished: %@", name)
            } else {
                let list=kept.prefix(5).map{"«\($0)»"}.joined(separator:", ")+(kept.count>5 ? " y \(kept.count-5) más" : "")
                let message="Se liberó «\(name)», salvo \(kept.count==1 ? "este archivo, que está abierto" : "estos archivos, que están abiertos") o todavía se \(kept.count==1 ? "está" : "están") subiendo: \(list). Cerralos o esperá a que terminen de subir y volvé a intentarlo."
                await backend.recordEvictionFailure(message)
                notify_post(nimboEvictionFailedNotification)
            }
            self?.changed()
        }
    }
    private func work(_ action:@escaping ()async->Void)->Progress {
        let progress=Progress(totalUnitCount:1)
        let task=Task{await action(); progress.completedUnitCount=1; progress.cancellationHandler=nil}
        progress.cancellationHandler={task.cancel()}; return progress
    }
    func item(for identifier:NSFileProviderItemIdentifier,request:NSFileProviderRequest,completionHandler:@escaping (NSFileProviderItem?,Error?)->Void)->Progress {
        work {do{let backend=try self.store.get(); let id=identifier == .rootContainer ? try await backend.rootID() : identifier.rawValue; let (item,root,pins)=try await backend.item(id); try Task.checkCancellation(); completionHandler(NativeItem(item,rootID:root,pinned:pins.contains(id),locallyDownloaded:await backend.hasDownloaded(id),writable:await backend.isWritable(),uploadState:await backend.uploadState(id)),nil)}catch{completionHandler(nil,nativeError(error))}}
    }
    func fetchContents(for identifier:NSFileProviderItemIdentifier,version:NSFileProviderItemVersion?,request:NSFileProviderRequest,completionHandler:@escaping (URL?,NSFileProviderItem?,Error?)->Void)->Progress {
        work {
            var file:URL?
            do {
                guard let manager=NSFileProviderManager(for:self.domain) else{throw DriveFailure.unavailable}
                let temporary=try manager.temporaryDirectoryURL(); let url=temporary.appendingPathComponent(UUID().uuidString); file=url
                let (object,root,pins)=try await self.store.get().fetch(identifier.rawValue,to:url); try Task.checkCancellation()
                let backend = try await self.store.get()
                completionHandler(url,NativeItem(object,rootID:root,pinned:pins.contains(object.id),locallyDownloaded:await backend.hasDownloaded(object.id),writable:await backend.isWritable(),uploadState:await backend.uploadState(object.id)),nil)
                // Parent folders show the aggregate state: let macOS re-read them.
                self.changed()
            } catch {if let file{try? FileManager.default.removeItem(at:file)}; completionHandler(nil,nil,nativeError(error))}
        }
    }
    /// Called by macOS whenever the set of materialized items changes (open,
    /// download, eviction, storage pressure). Reconcile Nimbo's markers so the
    /// "Sólo en la nube" / "Disponible sin conexión" decorations stay truthful.
    func materializedItemsDidChange(completionHandler:@escaping ()->Void) {
        Task {
            defer { completionHandler() }
            guard let manager=NSFileProviderManager(for:domain), let backend=try? store.get() else { return }
            let enumerator=manager.enumeratorForMaterializedItems()
            defer { enumerator.invalidate() }
            var ids=Set<String>()
            var page=NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)
            while true {
                let result:(Set<String>,NSFileProviderPage?,Error?)=await withCheckedContinuation { c in
                    let collector=NativeMaterializedCollector { c.resume(returning:($0.ids,$0.next,$0.error)) }
                    enumerator.enumerateItems(for:collector,startingAt:page)
                }
                if result.2 != nil { return }
                ids.formUnion(result.0)
                guard let next=result.1 else { break }
                page=next
            }
            let updated=(try? await backend.reconcileMaterialized(ids)) == true
            NSLog("Nimbo materialized items: %d (markers changed: %@)", ids.count, updated ? "yes" : "no")
            if updated { changed() }
        }
    }
    private func changed() {NSFileProviderManager(for:domain)?.signalEnumerator(for:.workingSet,completionHandler:{_ in});NSFileProviderManager(for:domain)?.signalEnumerator(for:.rootContainer,completionHandler:{_ in})}
    private func rendered(_ object:DriveObject,store:NativeStore) async throws->NativeItem {
        let root=try await store.rootID()
        // Mutation results are already committed. Avoid a second network read
        // between the commit and its completion callback.
        let known=try await store.knownItems()
        return NativeItem(object,rootID:root,pinned:known.pinned.contains(object.id),locallyDownloaded:await store.hasDownloaded(object.id),writable:await store.isWritable(),uploadState:await store.uploadState(object.id))
    }
    func createItem(basedOn itemTemplate:NSFileProviderItem,fields:NSFileProviderItemFields,contents:URL?,options:NSFileProviderCreateItemOptions,request:NSFileProviderRequest,completionHandler:@escaping (NSFileProviderItem?,NSFileProviderItemFields,Bool,Error?)->Void)->Progress {
        work {
            do {
                let backend=try self.store.get()
                guard await backend.isWritable() else{throw DriveFailure.denied}
                guard itemTemplate.contentType != .symbolicLink else{throw NativeMutationFailure.unsupported}
                // "Icon\r" holds the custom Finder icon Nimbo sets on each account folder.
                if itemTemplate.filename==".DS_Store" || itemTemplate.filename=="Icon\r" || itemTemplate.filename.hasPrefix("._") || nativeIsTemporaryName(itemTemplate.filename) {throw NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.excludedFromSync.rawValue)}
                // Google documents are exposed as .webloc links to their Drive
                // URL. When macOS re-submits one (e.g. `.mayAlreadyExist` after
                // a remount) map it back to the existing document instead of
                // failing forever or creating a copy.
                if itemTemplate.filename.lowercased().hasSuffix(".webloc") {
                    if let contents, let linked=nativeDriveID(webloc:contents) {
                        let existing=try await backend.item(linked).0
                        let item=try await self.rendered(existing,store:backend); self.changed()
                        completionHandler(item,[],false,nil); return
                    }
                    throw NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.excludedFromSync.rawValue)
                }
                let root=try await backend.rootID()
                let parent=itemTemplate.parentItemIdentifier == .rootContainer ? root:itemTemplate.parentItemIdentifier.rawValue
                let isFolder=itemTemplate.contentType?.conforms(to:.folder)==true
                // Folders and content-less submissions are resolved against Drive
                // by name first: macOS re-propagates local folders that lost
                // their identity after remounts, which created duplicate folders.
                if isFolder || contents == nil, let found=try await backend.existingForReimport(parent:parent,name:nativeDriveName(itemTemplate.filename),isFolder:isFolder,size:itemTemplate.documentSize??.int64Value), let object=found.item {
                    let item=try await self.rendered(object,store:backend); self.changed()
                    completionHandler(item,[],false,nil); return
                }
                if options.contains(.mayAlreadyExist) && (isFolder || contents == nil) {
                    guard let found=try await backend.existingForReimport(parent:parent,name:nativeDriveName(itemTemplate.filename),isFolder:isFolder,size:itemTemplate.documentSize??.int64Value),let object=found.item else {
                        throw NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.excludedFromSync.rawValue)
                    }
                    let item=try await self.rendered(object,store:backend); self.changed()
                    completionHandler(item,[],false,nil); return
                }
                let result=try await backend.create(template:itemTemplate.itemIdentifier.rawValue,parent:parent,name:nativeDriveName(itemTemplate.filename),mime:itemTemplate.contentType?.preferredMIMEType ?? "application/octet-stream",isFolder:itemTemplate.contentType?.conforms(to:.folder)==true,contents:contents)
                guard let object=result.item else{throw DriveFailure.invalidResponse}
                let item=try await self.rendered(object,store:backend);self.changed()
                completionHandler(item,[],result.fetchContent,nil)
            }catch{
                NSLog("Nimbo createItem failed for %@ (template %@, options %lu): %@", itemTemplate.filename, itemTemplate.itemIdentifier.rawValue, options.rawValue, String(describing:error))
                // A stale journal entry for a different name/content: uploading
                // would create yet another copy in Drive. Keep it local only.
                if case NativeMutationFailure.replayChanged = error {
                    completionHandler(nil,fields,false,NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.excludedFromSync.rawValue)); return
                }
                completionHandler(nil,fields,false,nativeError(error))
            }
        }
    }
    func modifyItem(_ item:NSFileProviderItem,baseVersion:NSFileProviderItemVersion,changedFields:NSFileProviderItemFields,contents:URL?,options:NSFileProviderModifyItemOptions,request:NSFileProviderRequest,completionHandler:@escaping (NSFileProviderItem?,NSFileProviderItemFields,Bool,Error?)->Void)->Progress {
        work {
            do {
                let backend=try self.store.get()
                guard await backend.isWritable(),item.itemIdentifier != .rootContainer else{throw DriveFailure.denied}
                let root=try await backend.rootID()
                let current:DriveObject
                do{current=try await backend.itemForMutation(item.itemIdentifier.rawValue).0}
                catch DriveFailure.notFound {
                    guard contents != nil else{throw DriveFailure.notFound}
                    let parent=item.parentItemIdentifier == .rootContainer ? root:item.parentItemIdentifier.rawValue
                    current=DriveObject(id:item.itemIdentifier.rawValue,name:nativeDriveName(item.filename),mimeType:item.contentType?.preferredMIMEType ?? "application/octet-stream",parents:[parent])
                }
                guard !current.isGoogleDocument else{throw DriveFailure.denied}
                let supported:NSFileProviderItemFields=[.contents,.filename,.parentItemIdentifier]
                guard !changedFields.intersection(supported).isEmpty else{completionHandler(try await self.rendered(current,store:backend),changedFields,false,nil);return}
                let name=changedFields.contains(.filename) ? nativeDriveName(item.filename):current.name
                let parent=changedFields.contains(.parentItemIdentifier) ? (item.parentItemIdentifier == .rootContainer ? root:item.parentItemIdentifier.rawValue):(current.parents?.first ?? root)
                if changedFields.contains(.contents),contents==nil,!current.isFolder{throw NativeMutationFailure.unsupported}
                let uploadingContent=changedFields.contains(.contents) && !current.isFolder
                if uploadingContent { await backend.setUploadState(current.id,"uploading") }
                let result:NativeMutationOutcome
                do { result=try await backend.modify(id:current.id,base:baseVersion,name:name,parent:parent,mime:current.mimeType,isFolder:current.isFolder,contents:changedFields.contains(.contents) ? contents:nil) }
                catch { if uploadingContent { await backend.setUploadState(current.id,"failed"); self.changed() }; throw error }
                if uploadingContent { await backend.setUploadState(current.id,nil) }
                let rendered:NSFileProviderItem?
                if let object=result.item{rendered=try await self.rendered(object,store:backend)}else{rendered=nil}
                self.changed();completionHandler(rendered,[],result.fetchContent,nil)
            }catch NativeMutationFailure.stale(let current) {
                do {
                    let backend=try self.store.get()
                    let kind=changedFields.contains(.filename) ? "rename" : (changedFields.contains(.parentItemIdentifier) ? "move" : "metadata")
                    let parent=item.parentItemIdentifier == .rootContainer ? (current.parents?.first ?? item.parentItemIdentifier.rawValue) : item.parentItemIdentifier.rawValue
                    try await backend.recordConflict(identifier:current.id,kind:kind,localName:item.filename,parent:parent,remoteName:current.name,detail:"Cambio local de \(kind) detenido porque Google Drive cambió el elemento.")
                } catch {}
                completionHandler(nil,changedFields,false,NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.cannotSynchronize.rawValue,userInfo:[NSLocalizedDescriptionKey:"El archivo cambió en Google Drive. Se conserva la operación local para revisar el conflicto."]))
            }catch{completionHandler(nil,changedFields,false,nativeError(error))}
        }
    }
    func deleteItem(identifier:NSFileProviderItemIdentifier,baseVersion:NSFileProviderItemVersion,options:NSFileProviderDeleteItemOptions,request:NSFileProviderRequest,completionHandler:@escaping (Error?)->Void)->Progress {
        work {
            do {
                guard identifier != .rootContainer,identifier != .trashContainer else{throw DriveFailure.denied}
                try await self.store.get().delete(id:identifier.rawValue,base:baseVersion)
                self.changed();completionHandler(nil)
            }catch NativeMutationFailure.stale(let current) {
                do { let backend=try self.store.get(); try await backend.recordConflict(identifier:current.id,kind:"delete",localName:current.name,parent:current.parents?.first,remoteName:current.name,detail:"El borrado local fue detenido porque Google Drive cambió el elemento.") } catch {}
                do{let item=try await self.rendered(current,store:self.store.get());completionHandler(NSError.fileProviderErrorForRejectedDeletion(of:item))}catch{completionHandler(nativeError(error))}
            }catch{completionHandler(nativeError(error))}
        }
    }
}

/// Collects one page of `enumeratorForMaterializedItems()`. Keeps itself alive
/// until the enumerator reports the end of the page.
private final class NativeMaterializedCollector:NSObject,NSFileProviderEnumerationObserver {
    private static var live=Set<NativeMaterializedCollector>()
    private static let lock=NSLock()
    var ids=Set<String>(), next:NSFileProviderPage?, error:Error?
    private let done:(NativeMaterializedCollector)->Void
    init(done:@escaping (NativeMaterializedCollector)->Void) {
        self.done=done; super.init()
        Self.lock.lock(); Self.live.insert(self); Self.lock.unlock()
    }
    func didEnumerate(_ updatedItems:[NSFileProviderItemProtocol]) { for item in updatedItems { ids.insert(item.itemIdentifier.rawValue) } }
    func finishEnumerating(upTo nextPage:NSFileProviderPage?) { next=nextPage; finish() }
    func finishEnumeratingWithError(_ error:Error) { self.error=error; finish() }
    private func finish() { done(self); Self.lock.lock(); Self.live.remove(self); Self.lock.unlock() }
}
