import Foundation
import CryptoKit
import FileProvider

struct NativeSnapshot: Codable {
    var root: DriveObject?
    var objects: [String:DriveObject] = [:]
    var anchor: String?
    var pinned: Set<String> = []
    var fixture: Bool? = nil
    var localRevision:Int? = nil
    var localUpdates:[String:Int]? = nil
    var writable:Bool? = nil
    var offlineRules:[String:Bool]? = nil
    /// Optional maximum byte size for descendants of an explicit offline
    /// folder rule. Nil means no threshold; the map is encrypted with the
    /// rest of the native index.
    var offlineLimits:[String:Int64]? = nil
    var downloadedAt:[String:Date]? = nil
    var requestedDownloads:[String]? = nil
    var acknowledgedConflicts:Set<String>? = nil
    var metadataConflicts:[String:NativeConflict]? = nil
    var remoteName:String? = nil
    var publishedEditableSplitItems: Bool?
}
private struct NativeAnchor:Codable {let google:String; let local:Int}
struct NativeListing { let objects:[DriveObject]; let nextPage:String?; let rootID:String; let pinned:Set<String> }
struct NativeDelta { let updated:[DriveObject]; let removed:[String]; let anchor:String; let more:Bool; let rootID:String; let pinned:Set<String> }

/// Durable metadata only. File contents are handed to the system's File Provider
/// cache, which owns materialization, coordinated eviction and dirty-file safety.
actor NativeStore {
    let directory: URL
    private let config:URL
    private let index:URL
    private let legacyIndex:URL
    private let indexAccount:String
    private var snapshot: NativeSnapshot
    private var api:DriveAPI?
    private var mutations:NativeWriteStore?
    #if NIMBO_TESTING
    private var fixtureRemote:NativeFixtureDrive?
    private func fixtureWriter()throws->NativeFixtureDrive {
        if let fixtureRemote{return fixtureRemote}
        let writer=try NativeFixtureDrive(directory:directory.appendingPathComponent("FixtureRemote"),seed:snapshot.objects)
        fixtureRemote=writer;return writer
    }
    #endif
    init(directory:URL) throws {
        self.directory=directory; config=try NimboSecureConfig.prepareNative(directory: directory); index=directory.appendingPathComponent("index.json.enc"); legacyIndex=directory.appendingPathComponent("index.json"); indexAccount="native-index-" + SHA256.hash(data:Data(directory.standardizedFileURL.path.utf8)).map{String(format:"%02x",$0)}.joined()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard directory.resolvingSymlinksInPath()==directory.standardizedFileURL else { throw DriveFailure.denied }
        if FileManager.default.fileExists(atPath:index.path) {
            guard let clear=try NimboSecureFile.loadData(from:index,account:indexAccount,keychain:false) else { throw DriveFailure.invalidResponse }
            snapshot=try JSONDecoder().decode(NativeSnapshot.self,from:clear)
        } else if FileManager.default.fileExists(atPath:legacyIndex.path) {
            snapshot=try JSONDecoder().decode(NativeSnapshot.self,from:Data(contentsOf:legacyIndex))
            // Migrate the old plaintext index only after the encrypted copy is
            // durably published. Keeping the legacy file on a failed write
            // gives a later launch another chance to recover it.
            try Self.persist(snapshot, to:index, account:indexAccount)
            try? FileManager.default.removeItem(at:legacyIndex)
        } else { snapshot=NativeSnapshot() }
        if FileManager.default.fileExists(atPath:config.path) { api=DriveAPI(configuration:config, remoteName:snapshot.remoteName ?? "GoogleDrive") }
    }
    func setTransferLimits(download: Int, upload: Int, segmentMB: Int? = nil) throws {
        guard SyncSettings.allowed.contains(download), SyncSettings.allowed.contains(upload) else { throw DriveFailure.invalidResponse }
        let file = SyncSettings.file(for: config)
        var current = SyncSettings.read(at: file)
        let segment = segmentMB ?? current.finderSegmentMB
        guard SyncSettings.segmentSizes.contains(segment) else { throw DriveFailure.invalidResponse }
        if current.downloadKBps == download && current.uploadKBps == upload && current.finderSegmentMB == segment { return }
        current.finderSegmentMB = segment
        current.downloadKBps = download
        current.uploadKBps = upload
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(current).write(to: file, options: .atomic)
    }

    private func save() throws {
        try Self.persist(snapshot, to:index, account:indexAccount)
    }
    private static func persist(_ snapshot:NativeSnapshot,to index:URL,account:String)throws {
        try NimboSecureFile.saveData(JSONEncoder().encode(snapshot),to:index,account:account,keychain:false)
    }
    func configure(_ data:Data, rootID requestedRootID:String? = nil, remoteName requestedRemoteName:String = "GoogleDrive") async throws {
        guard data.count<=65536, let text=String(data:data,encoding:.utf8), !requestedRemoteName.isEmpty, !requestedRemoteName.contains("["), !requestedRemoteName.contains("]"), text.contains("[\(requestedRemoteName)]"), text.contains("client_id"), text.contains("token") else { throw DriveFailure.unsupportedCredentials }
        let pending=directory.appendingPathComponent(".authorization-"+UUID().uuidString)
        try data.write(to:pending,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:pending.path)
        defer { try? FileManager.default.removeItem(at:pending) }
        let candidate=DriveAPI(configuration:pending, remoteName:requestedRemoteName)
        if let requestedRootID { try DriveAPI.validateID(requestedRootID) }
        let root=try await candidate.item(requestedRootID ?? "root")
        guard root.isFolder else { throw DriveFailure.invalidResponse }
        // A domain is never silently switched to a different Google account or root.
        guard snapshot.root==nil || snapshot.root?.id==root.id else { throw DriveFailure.denied }
        let anchor=try await candidate.currentAnchor()
        _ = try NimboSecureConfig.publishNative(Data(contentsOf: pending), directory: directory)
        api=DriveAPI(configuration:config, remoteName:requestedRemoteName); snapshot.remoteName=requestedRemoteName; snapshot.root=root; snapshot.objects[root.id]=root
        let writable=try await candidate.permitsWrites()
        if snapshot.writable != writable {
            snapshot.writable=writable
            let revision=(snapshot.localRevision ?? 0)+1;snapshot.localRevision=revision
            snapshot.localUpdates=Dictionary(uniqueKeysWithValues:snapshot.objects.keys.map{($0,revision)})
        }
        if snapshot.publishedEditableSplitItems != true {
            // Republish existing package permissions after upgrading a
            // previously read-only placeholder. No content is downloaded.
            let packages = snapshot.objects.values.filter { $0.splitLayout != nil }.map { $0.id }
            bumpLocal(packages)
            snapshot.publishedEditableSplitItems = true
        }
        if snapshot.anchor==nil { snapshot.anchor=anchor }
        try save()
    }
    /// The persisted domain owns its account. A host restart or a renamed
    /// Finder alias must never route this lookup through the default account.
    func browserLink(_ identifier: String) async throws -> String {
        let root = try rootID()
        let id = identifier == NSFileProviderItemIdentifier.rootContainer.rawValue ? root : identifier
        #if NIMBO_TESTING
        if snapshot.fixture == true {
            let object = try await fixtureWriter().revision(id).object
            guard object.trashed != true else { throw DriveFailure.notFound }
            return try DriveAPI.browserLink(for: object).absoluteString
        }
        #endif
        guard let api else { throw DriveFailure.notAuthenticated }
        return try await api.browserLink(id).absoluteString
    }
    func status() throws -> String {
        let value:[String:Any]=["configured":snapshot.root != nil,"knownItems":snapshot.objects.count,"fixture":snapshot.fixture == true,"rootID":snapshot.root?.id ?? "","writable":snapshot.writable==true]
        return String(data:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),encoding:.utf8)!
    }
    private func anchor(_ google:String)throws->String {
        String(data:try JSONEncoder().encode(NativeAnchor(google:google,local:snapshot.localRevision ?? 0)),encoding:.utf8)!
    }
    private func descendant(_ id:String,of ancestor:String)->Bool {
        var current:String?=id,seen=Set<String>()
        while let value=current,seen.insert(value).inserted {
            if value==ancestor{return true}; current=snapshot.objects[value]?.parents?.first
        }
        return false
    }
    private func effectivePins()->Set<String> {
        // The nearest explicit preference wins. A released file can remain
        // lazy inside an offline folder without unpinning its siblings.
        let rules=snapshot.offlineRules ?? Dictionary(uniqueKeysWithValues:snapshot.pinned.map{($0,true)})
        let limits=snapshot.offlineLimits ?? [:]
        return Set(snapshot.objects.keys.filter { id in
            hasOfflinePreference(id,rules:rules,limits:limits)
        })
    }
    private func hasOfflinePreference(_ id:String,rules:[String:Bool],limits:[String:Int64])->Bool {
            var current:String?=id,seen=Set<String>()
            while let value=current,seen.insert(value).inserted {
                if let rule=rules[value] {
                    guard rule else { return false }
                    if let limit=limits[value], limit >= 0,
                       let object=snapshot.objects[id], !object.isFolder,
                       let size=object.size.flatMap(Int64.init), size > limit { return false }
                    return true
                }
                current=snapshot.objects[value]?.parents?.first
            }
            return false
    }
    func downloadIsPending(_ id:String)->Bool {
        guard snapshot.downloadedAt?[id]==nil,let object=snapshot.objects[id],!object.isFolder,object.trashed != true else{return false}
        if snapshot.requestedDownloads?.contains(id)==true{return true}
        guard !object.isGoogleDocument else{return false}
        return hasOfflinePreference(id,rules:snapshot.offlineRules ?? Dictionary(uniqueKeysWithValues:snapshot.pinned.map{($0,true)}),limits:snapshot.offlineLimits ?? [:])
    }
    func rootID() throws -> String { guard let id=snapshot.root?.id else { throw DriveFailure.notAuthenticated }; return id }
    func isWritable()->Bool {snapshot.writable==true}
    private func writeEngine() throws->NativeWriteStore {
        guard snapshot.writable==true else{throw DriveFailure.denied}
        if let mutations{return mutations}
        let writer:any NativeDriveWriting
        #if NIMBO_TESTING
        if snapshot.fixture==true {writer=try fixtureWriter()}
        else {guard let api else{throw DriveFailure.denied};writer=DriveWriteAPI(api:api)}
        #else
        guard let api else{throw DriveFailure.denied};writer=DriveWriteAPI(api:api)
        #endif
        let engine=try NativeWriteStore(directory:directory.appendingPathComponent("Operations"),writer:writer)
        mutations=engine;return engine
    }
    /// Expanding an offline folder is metadata-only. It walks paginated
    /// descendants so File Provider can publish eager content policies for
    /// every known child without downloading file bytes at this point.
    /// Learns the names of the whole Drive tree (metadata only) so Spotlight
    /// finds files in folders the user never opened. Once a day at most.
    private var lastFullIndex:Date?
    func indexWholeTree() async -> Bool {
        if let last=lastFullIndex, Date().timeIntervalSince(last) < 86_400 { return false }
        guard let root=snapshot.root?.id else { return false }
        lastFullIndex=Date()
        do { try await discoverDescendants(root); return true } catch { return false }
    }
    private func discoverDescendants(_ parent:String) async throws {
        var pending=[parent],seen=Set<String>()
        while let current=pending.popLast() {
            guard seen.insert(current).inserted else { continue }
            var page:String?
            repeat {
                try Task.checkCancellation()
                let listing=try await children(current,page:page)
                for object in listing.objects where object.isFolder { pending.append(object.id) }
                page=listing.nextPage
            } while page != nil
        }
    }
    private func publish(_ result:NativeMutationOutcome)throws {
        let revision=(snapshot.localRevision ?? 0)+1;snapshot.localRevision=revision
        var updates=snapshot.localUpdates ?? [:]
        for item in result.additional+(result.item.map{[$0]} ?? []) {snapshot.objects[item.id]=item;updates[item.id]=revision}
        for id in result.removed {snapshot.objects.removeValue(forKey:id);updates.removeValue(forKey:id)}
        if let original=result.item, let copy=result.additional.first(where:{$0.name.contains(" (conflicto Mac ")}) {
            var conflicts=snapshot.metadataConflicts ?? [:]
            conflicts[copy.id]=NativeConflict(id:copy.id,name:copy.name,parent:copy.parents?.first,kind:"content",detail:"Copia local conservada; el archivo remoto original sigue separado.",remoteID:original.id)
            snapshot.metadataConflicts=conflicts;snapshot.acknowledgedConflicts?.remove(copy.id)
        }
        snapshot.localUpdates=updates;try save()
    }
    func create(template:String,parent:String,name:String,mime:String,isFolder:Bool,contents:URL?) async throws->NativeMutationOutcome {
        // After a domain remount/reimport macOS re-submits materialized files
        // as new items. Reuse an identical Drive file (same parent, name and
        // MD5) instead of uploading a duplicate copy every time.
        if !isFolder, let existing=try await identicalRemoteFile(parent:parent,name:name,contents:contents) {
            var outcome=NativeMutationOutcome(); outcome.item=existing
            try publish(outcome); return outcome
        }
        let segment = SyncSettings.read(at: SyncSettings.file(for: config)).finderSegmentMB
        let result=try await writeEngine().create(template:template,parent:parent,name:name,mime:mime,isFolder:isFolder,contents:contents,segmentMB:segment)
        try publish(result);return result
    }
    /// `.mayAlreadyExist` re-submissions (after a remount/reimport) refer to
    /// items that are already in Drive. Resolve them by parent + name: folders
    /// by name, files by name (and size when known), oldest first. Never
    /// creates anything.
    func existingForReimport(parent:String,name:String,isFolder:Bool,size:Int64?) async throws->NativeMutationOutcome? {
        guard snapshot.fixture != true, let api else { return nil }
        var siblings:[DriveObject]=[]; var page:String?=nil
        repeat {
            let result=try await api.children(parent,page:page)
            siblings += result.files; page=result.nextPageToken
        } while page != nil
        var named=siblings.filter{ $0.name==name && $0.isFolder==isFolder && $0.trashed != true }
        if !isFolder, let size { let sized=named.filter{ $0.size.flatMap{Int64($0)}==size }; if !sized.isEmpty { named=sized } }
        guard let match=named.sorted(by:{ ($0.createdTime ?? "") < ($1.createdTime ?? "") }).first else { return nil }
        var outcome=NativeMutationOutcome(); outcome.item=match
        try publish(outcome); return outcome
    }
    private func identicalRemoteFile(parent:String,name:String,contents:URL?) async throws->DriveObject? {
        guard let contents, snapshot.fixture != true, let api else { return nil }
        var siblings:[DriveObject]=[]; var page:String?=nil
        repeat {
            let result=try await api.children(parent,page:page)
            siblings += result.files; page=result.nextPageToken
        } while page != nil
        let named=siblings.filter{ $0.name==name && !$0.isFolder && $0.trashed != true && $0.md5Checksum != nil }
        guard !named.isEmpty else { return nil }
        let handle=try FileHandle(forReadingFrom:contents); defer { try? handle.close() }
        var hash=Insecure.MD5()
        while let data=try handle.read(upToCount:1024*1024), !data.isEmpty { hash.update(data:data) }
        let local=hash.finalize().map{String(format:"%02x",$0)}.joined()
        return named.filter{ $0.md5Checksum==local }.sorted{ ($0.createdTime ?? "") < ($1.createdTime ?? "") }.first
    }
    func modify(id:String,base:NSFileProviderItemVersion,name:String,parent:String,mime:String,isFolder:Bool,contents:URL?) async throws->NativeMutationOutcome {
        let result=try await writeEngine().modify(id:id,base:base,name:name,parent:parent,mime:mime,isFolder:isFolder,contents:contents)
        try publish(result);return result
    }
    func delete(id:String,base:NSFileProviderItemVersion) async throws {
        let result=try await writeEngine().delete(id:id,base:base);try publish(result)
    }
    func item(_ id:String) async throws -> (DriveObject,String,Set<String>) {
        let root=try rootID()
        if id==root, let item=snapshot.root { return (item,root,effectivePins()) }
        #if NIMBO_TESTING
        if snapshot.fixture==true {
            let object=try await fixtureWriter().revision(id).object
            guard object.trashed != true else{throw DriveFailure.notFound}
            snapshot.objects[id]=object;try save()
            return (object,root,effectivePins())
        }
        #endif
        // Finder asks for an item immediately when it builds its contextual
        // menu.  A transient Drive/API error must not turn a known local item
        // into an error row or remove its actions.  Prefer fresh metadata,
        // then fall back to the last catalog snapshot for read-only provider
        // operations such as decorations and custom actions.
        if let api {
            do {
                let object=try await api.item(id)
                guard object.trashed != true else { throw DriveFailure.notFound }
                snapshot.objects[id]=object; try save()
                return (object,root,effectivePins())
            } catch {
                if let cached=snapshot.objects[id], cached.trashed != true {
                    return (cached,root,effectivePins())
                }
                throw error
            }
        }
        if let cached=snapshot.objects[id], cached.trashed != true {
            return (cached,root,effectivePins())
        }
        throw DriveFailure.notAuthenticated
    }
    /// Explicit refresh must reach the remote, not silently reuse item()'s
    /// offline fallback. Only metadata is fetched; availability rules and
    /// pending downloads are left unchanged. Publish after every page succeeds.
    func refreshMetadata(_ identifier:String) async throws -> [String] {
        try Task.checkCancellation()
        let root = try rootID()
        let id = identifier == NSFileProviderItemIdentifier.rootContainer.rawValue ? root : identifier
        let oldParents = snapshot.objects[id]?.parents ?? []
        let object:DriveObject
        var refreshed:[DriveObject]
        #if NIMBO_TESTING
        if snapshot.fixture == true {
            object = try await fixtureWriter().revision(id).object
            refreshed = [object]
        } else {
            guard let api else { throw DriveFailure.notAuthenticated }
            object = try await api.item(id)
            refreshed = [object]
        }
        #else
        guard let api else { throw DriveFailure.notAuthenticated }
        object = try await api.item(id)
        refreshed = [object]
        #endif
        guard object.id == id, object.trashed != true else { throw DriveFailure.notFound }
        if object.isFolder {
            var page:String?, seen=Set<String>()
            repeat {
                try Task.checkCancellation()
                let result=try await readChildren(id,page:page)
                refreshed += result.objects
                page=result.next
                if let page, !seen.insert(page).inserted { throw DriveFailure.invalidResponse }
            } while page != nil
        }
        try Task.checkCancellation()
        for value in refreshed { snapshot.objects[value.id]=value }
        if id == root { snapshot.root=object }
        bumpLocal(refreshed.map(\.id)); try save()
        var containers=Set(oldParents + (object.parents ?? []))
        if object.isFolder { containers.insert(id) }
        return containers.map { $0 == root ? NSFileProviderItemIdentifier.rootContainer.rawValue : $0 }.sorted()
    }
    func itemForMutation(_ id:String) async throws -> (DriveObject,String,Set<String>) {
        do{return try await item(id)}
        catch DriveFailure.notFound {
            // Cached metadata lets an offline edit be saved as a conflict copy
            // even after the original was removed remotely.
            guard let object=snapshot.objects[id] else{throw DriveFailure.notFound}
            return (object,try rootID(),effectivePins())
        }
    }
    func children(_ parent:String,page:String?) async throws -> NativeListing {
        let root=try rootID()
        let result=try await readChildren(parent,page:page)
        for object in result.objects { snapshot.objects[object.id]=object }
        try save()
        return NativeListing(objects:result.objects,nextPage:result.next,rootID:root,pinned:effectivePins())
    }
    private func readChildren(_ parent:String,page:String?) async throws -> (objects:[DriveObject],next:String?) {
        #if NIMBO_TESTING
        if snapshot.fixture==true {
            let all=try await fixtureWriter().all().filter{$0.parents?.contains(parent)==true && $0.trashed != true}.sorted{$0.name<$1.name}
            let start=page.flatMap{Int($0)} ?? 0
            guard start >= 0 && start <= all.count else { throw DriveFailure.invalidResponse }
            let objects=Array(all.dropFirst(start).prefix(100))
            let end=start+objects.count
            return (objects,end < all.count ? String(end):nil)
        }
        #endif
        guard let api else { throw DriveFailure.notAuthenticated }
        let result=try await api.children(parent,page:page)
        return (result.files,result.nextPageToken)
    }
    func knownItems(includeRoot:Bool=false) throws -> NativeListing {
        let root=try rootID()
        return NativeListing(objects:snapshot.objects.values.filter{includeRoot || $0.id != root},nextPage:nil,rootID:root,pinned:effectivePins())
    }
    func conflicts() throws -> [NativeConflict] {
        let acknowledged=snapshot.acknowledgedConflicts ?? []
        let linked=Set((snapshot.metadataConflicts ?? [:]).keys)
        let copies=snapshot.objects.values
            .filter { !$0.isFolder && $0.name.contains(" (conflicto Mac ") && $0.trashed != true && !acknowledged.contains($0.id) && !linked.contains($0.id) }
            .map { NativeConflict(id:$0.id,name:$0.name,parent:$0.parents?.first,kind:"content") }
        let metadata=(snapshot.metadataConflicts ?? [:]).values.filter{!acknowledged.contains($0.id)}
        return (copies+metadata).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func acknowledgeConflict(_ id:String) throws {
        let objectConflict=snapshot.objects[id].map{!$0.isFolder && $0.name.contains(" (conflicto Mac ") && $0.trashed != true} == true
        let metadataConflict=snapshot.metadataConflicts?[id] != nil
        guard objectConflict || metadataConflict else { throw DriveFailure.notFound }
        var acknowledged=snapshot.acknowledgedConflicts ?? []; acknowledged.insert(id); snapshot.acknowledgedConflicts=acknowledged; try save()
    }
    func recordConflict(identifier:String,kind:String,localName:String,parent:String?,remoteName:String?,detail:String?) throws {
        let key="metadata-\(identifier)-\(kind)"
        var values=snapshot.metadataConflicts ?? [:]
        values[key]=NativeConflict(id:key,name:localName,parent:parent,kind:kind,detail:detail ?? (remoteName.map{"Google Drive conserva «\($0)»."}),remoteID:identifier); snapshot.metadataConflicts=values
        snapshot.acknowledgedConflicts?.remove(key)
        try save()
    }
    func resolveConflict(_ id:String,action:String) async throws {
        guard let conflict=snapshot.metadataConflicts?[id] else {
            if action == "keepRemote" { try acknowledgeConflict(id); return }
            throw DriveFailure.notFound
        }
        if action == "keepRemote" { try acknowledgeConflict(id); return }
        guard action == "retryLocal", let remoteID=conflict.remoteID else { throw DriveFailure.denied }
        let (current,root,_)=try await item(remoteID)
        guard current.trashed != true else { throw DriveFailure.notFound }
        let base=NativeItem(current,rootID:root,pinned:false,writable:snapshot.writable==true).itemVersion
        if conflict.kind == "content" {
            let temporary=directory.appendingPathComponent(".conflict-retry-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:temporary) }
            _=try await fetch(conflict.id,to:temporary)
            _=try await modify(id:remoteID,base:base,name:current.name,parent:current.parents?.first ?? root,mime:current.mimeType,isFolder:current.isFolder,contents:temporary)
        } else if conflict.kind == "delete" {
            try await delete(id:remoteID,base:base)
        } else if ["rename","move"].contains(conflict.kind) {
            let name=conflict.kind == "rename" ? conflict.name : current.name
            let parent=conflict.kind == "move" ? (conflict.parent ?? current.parents?.first ?? root) : (current.parents?.first ?? root)
            _=try await modify(id:remoteID,base:base,name:name,parent:parent,mime:current.mimeType,isFolder:current.isFolder,contents:nil)
        } else { throw DriveFailure.denied }
        snapshot.metadataConflicts?.removeValue(forKey:id); var acknowledged=snapshot.acknowledgedConflicts ?? [];acknowledged.insert(id);snapshot.acknowledgedConflicts=acknowledged;try save()
    }
    func currentAnchor() async throws -> String {
        if let value=snapshot.anchor { return try anchor(value) }
        guard let api else { throw DriveFailure.notAuthenticated }
        let anchor=try await api.currentAnchor(); snapshot.anchor=anchor; try save(); return try self.anchor(anchor)
    }
    func changes(since anchor:String) async throws -> NativeDelta {
        let root=try rootID()
        let previous=(try? JSONDecoder().decode(NativeAnchor.self,from:Data(anchor.utf8))) ?? NativeAnchor(google:anchor,local:0)
        #if NIMBO_TESTING
        if snapshot.fixture==true {
            let remote=try await fixtureWriter().all()
            let active=remote.filter{$0.trashed != true}
            let removed=remote.filter{$0.trashed==true}.map{$0.id}
            for object in active{snapshot.objects[object.id]=object}
            for id in removed{snapshot.objects.removeValue(forKey:id)}
            try save()
            return NativeDelta(updated:active,removed:removed,anchor:try self.anchor("fixture-1"),more:false,rootID:root,pinned:effectivePins())
        }
        #endif
        guard let api else { throw DriveFailure.notAuthenticated }
        let result=try await api.changes(since:previous.google)
        if result.nextPageToken == previous.google { throw DriveFailure.invalidResponse }
        var updated:[DriveObject]=[], removed:[String]=[]
        for change in result.changes {
            guard let id=change.fileId else { continue }
            if change.removed==true || change.file?.trashed==true {
                // Deletes are replayable even if a previous delivery was interrupted.
                removed.append(id); snapshot.objects.removeValue(forKey:id); continue
            }
            guard let object=change.file else { continue }
            // Publish only the known working set and children of known folders.
            // Other shared items are discovered when their container is enumerated.
            let parentKnown=object.parents?.contains(where:{$0==root || snapshot.objects[$0]?.isFolder==true})==true
            if parentKnown || snapshot.objects[id] != nil {
                snapshot.objects[id]=object; updated.append(object)
            }
        }
        guard let next=result.nextPageToken ?? result.newStartPageToken else { throw DriveFailure.invalidResponse }
        for (id,revision) in snapshot.localUpdates ?? [:] where revision>previous.local {
            if let object=snapshot.objects[id], !updated.contains(where:{$0.id==id}) {updated.append(object)}
        }
        if let root=snapshot.root,!updated.contains(where:{$0.id==root.id}){updated.append(root)}
        // Do not advance the durable anchor while Drive still has pages. If
        // the extension exits between pages, replaying from the old anchor is
        // safe and prevents a partially delivered page from being skipped.
        if result.nextPageToken == nil { snapshot.anchor=next }
        try save()
        return NativeDelta(updated:updated,removed:removed,anchor:try self.anchor(next),more:result.nextPageToken != nil,rootID:root,pinned:effectivePins())
    }
    func availabilityPage(after:String?)throws->Data {
        let pins=effectivePins()
        // Google documents are represented in Finder as downloadable .webloc
        // payloads. Keep them in the availability index so a placeholder can
        // be resolved after eviction; automatic eviction still rejects them
        // through canAutomaticallyEvict because they are browser links.
        let eligible=snapshot.objects.values.filter{!$0.isFolder && $0.trashed != true && (after==nil || $0.id>after!)}.sorted{$0.id<$1.id}
        let batch=eligible.prefix(250)
        let page=NativeAvailabilityPage(items:batch.map{NativeAvailabilityCandidate(id:$0.id,pinned:pins.contains($0.id),downloadedAt:snapshot.downloadedAt?[$0.id])},next:eligible.count>250 ? batch.last?.id:nil)
        return try JSONEncoder().encode(page)
    }
    func canAutomaticallyEvict(_ id:String)->Bool {
        guard let object=snapshot.objects[id],!object.isFolder,!object.isGoogleDocument,object.trashed != true else{return false}
        return !effectivePins().contains(id)
    }
    private func downloaded(_ id:String)throws {
        var times=snapshot.downloadedAt ?? [:];times[id]=Date();snapshot.downloadedAt=times
        snapshot.requestedDownloads?.removeAll{ $0==id }
        bumpLocal([id]);try save()
    }
    /// Re-publish items whose Nimbo state changed (pin/download marker) in the
    /// working set, so Finder redraws their cloud/check decoration.
    private func bumpLocal(_ ids:[String]) {
        guard !ids.isEmpty else { return }
        // Folders show the aggregate state of their files: re-publish ancestors.
        var all=Set(ids)
        for id in ids {
            var current=snapshot.objects[id]?.parents?.first, seen=Set<String>()
            while let parent=current, seen.insert(parent).inserted, snapshot.objects[parent] != nil {
                all.insert(parent); current=snapshot.objects[parent]?.parents?.first
            }
        }
        let ids=Array(all)
        let revision=(snapshot.localRevision ?? 0)+1; snapshot.localRevision=revision
        var updates=snapshot.localUpdates ?? [:]
        for id in ids { updates[id]=revision }
        snapshot.localUpdates=updates
    }
    /// Aligns the local-availability markers with the files macOS really keeps
    /// materialized (system downloads, opens, evictions and storage pressure
    /// included). Returns true when at least one item changed.
    func reconcileMaterialized(_ ids:Set<String>) throws -> Bool {
        var times=snapshot.downloadedAt ?? [:]
        var changed:[String]=[]
        for id in ids {
            guard times[id]==nil, let object=snapshot.objects[id], !object.isFolder else { continue }
            times[id]=Date(); changed.append(id)
        }
        for id in Array(times.keys) where !ids.contains(id) {
            times.removeValue(forKey:id); changed.append(id)
        }
        let previousRequests = snapshot.requestedDownloads
        snapshot.requestedDownloads?.removeAll{ ids.contains($0) }
        guard !changed.isEmpty else {
            // A fetch may finish before its action queues the request. Even
            // with unchanged availability, persist queue cleanup so a later
            // restart and eviction cannot resurrect that completed download.
            if snapshot.requestedDownloads != previousRequests { try save() }
            return false
        }
        snapshot.downloadedAt=times.isEmpty ? nil : times
        bumpLocal(changed); try save()
        return true
    }
    /// Records a successful File Provider materialization even when the
    /// system already had a local copy and therefore did not call fetch().
    func noteDownloaded(_ id:String) throws { try downloaded(id) }
    /// Removes the local availability marker after an explicit eviction.
    func clearDownloaded(_ id:String) throws {
        guard var times=snapshot.downloadedAt else { return }
        times.removeValue(forKey:id)
        snapshot.downloadedAt=times.isEmpty ? nil : times
        bumpLocal([id]); try save()
    }
    /// Upload state per item for Finder badges. In memory: after a restart,
    /// macOS replays pending edits and the state is set again.
    private var uploadStates:[String:String]=[:]
    func uploadState(_ id:String)->String? { uploadStates[id] }
    /// Optional Finder actions (Copiar enlace / Abrir vista web), off by default.
    nonisolated var linkActionsEnabled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("link-actions-enabled").path) }
    func setShowLinkActions(_ enabled: Bool) -> Bool {
        let flag = directory.appendingPathComponent("link-actions-enabled")
        guard enabled != linkActionsEnabled else { return false }
        if enabled { FileManager.default.createFile(atPath: flag.path, contents: Data()) } else { try? FileManager.default.removeItem(at: flag) }
        bumpLocal(Array(snapshot.objects.keys))
        return true
    }
    /// Drive thumbnail (metadata only, the file is not downloaded).
    func thumbnail(_ id:String) async throws -> Data? {
        guard let api, let object=snapshot.objects[id], !object.isFolder, object.trashed != true else { return nil }
        return try await api.thumbnail(id)
    }
    func setUploadState(_ id:String,_ value:String?) { uploadStates[id]=value; bumpLocal([id]) }
    private var evictionMessages:[String]=[]
    func recordEvictionFailure(_ message:String) { evictionMessages.append(message) }
    func takeEvictionMessages()->[String] { defer { evictionMessages=[] }; return evictionMessages }
    /// Remembers an explicit download request until macOS materializes it.
    func requestDownload(_ id:String) throws {
        var list=snapshot.requestedDownloads ?? []
        if !list.contains(id) { list.append(id) }
        snapshot.requestedDownloads=list; try save()
    }
    func pendingDownloads() -> [String] {
        // Explicit requests plus files kept offline that are still cloud-only.
        let pinnedFiles=effectivePins().filter{ id in snapshot.objects[id].map{ !$0.isFolder && !$0.isGoogleDocument && $0.trashed != true } ?? false }
        var ids=snapshot.requestedDownloads ?? []
        for id in pinnedFiles.sorted() where !ids.contains(id) { ids.append(id) }
        return ids.filter{ snapshot.downloadedAt?[$0]==nil }
    }
    func hasDownloaded(_ id:String) -> Bool {
        guard let object=snapshot.objects[id], object.isFolder else { return snapshot.downloadedAt?[id] != nil }
        // A folder is "Disponible sin conexión" when every known file below it
        // (Google documents excluded) is local.
        let files=folderFiles(id)
        return !files.isEmpty && files.allSatisfy{ snapshot.downloadedAt?[$0] != nil }
    }
    private func folderFiles(_ folder:String)->[String] {
        snapshot.objects.filter{ id,object in !object.isFolder && !object.isGoogleDocument && object.trashed != true && id != folder && descendant(id,of:folder) }.map{$0.key}
    }
    /// Drive files below a folder (id, name), so "Desincronizar" can release
    /// them one by one. Evicting the folder itself fails as soon as Finder
    /// leaves a local-only file in it (.DS_Store), which never goes to Drive.
    func filesForEviction(_ folder:String)->[(id:String,name:String)] {
        let kept=effectivePins()
        return snapshot.objects.keys.filter{ id in
            guard let object=snapshot.objects[id] else{return false}
            return !object.isFolder && object.trashed != true && id != folder && descendant(id,of:folder) && !kept.contains(id)
        }.sorted().compactMap{ id in snapshot.objects[id].map{ (id,$0.name) } }
    }
    /// Pinning and eviction are local policies. Only a catalog miss needs
    /// Drive metadata. File Provider still checks for dirty or open files.
    private func policyItem(_ id: String) async throws -> DriveObject {
        _ = try rootID()
        if let known = snapshot.objects[id] {
            guard known.trashed != true else { throw DriveFailure.notFound }
            return known
        }
        return try await item(id).0
    }
    func evictionCandidates(_ id:String) async throws -> [NativeEvictionCandidate] {
        let object = try await policyItem(id)
        if object.isFolder { return filesForEviction(id).map{NativeEvictionCandidate(id:$0.id,name:$0.name)} }
        return effectivePins().contains(id) ? [] : [NativeEvictionCandidate(id:id,name:object.name)]
    }
    /// "Sincronizar ahora" on a folder: list every file below it and queue them
    /// for an immediate download, without making the folder an offline preference.
    func requestFolderDownload(_ folder:String) async throws {
        try await discoverDescendants(folder)
        var list=snapshot.requestedDownloads ?? []
        for id in folderFiles(folder) where snapshot.downloadedAt?[id]==nil && !list.contains(id) { list.append(id) }
        snapshot.requestedDownloads=list; try save()
    }
    func prepareDownload(_ id:String) async throws -> [String] {
        let (object,_,_)=try await item(id)
        if object.isFolder {
            try await requestFolderDownload(id)
            return folderFiles(id).sorted()
        }
        try requestDownload(id)
        return [id]
    }
    func setPinned(_ id:String,_ value:Bool,limit:Int64?=nil) async throws {
        let object = try await policyItem(id)
        if let limit, limit < 0 { throw DriveFailure.invalidResponse }
        if value, object.isFolder { try await discoverDescendants(id) }
        var rules=snapshot.offlineRules ?? Dictionary(uniqueKeysWithValues:snapshot.pinned.map{($0,true)})
        rules[id]=value;snapshot.offlineRules=rules
        var limits=snapshot.offlineLimits ?? [:]
        if value, object.isFolder, let limit { limits[id]=limit }
        else { limits.removeValue(forKey:id) }
        snapshot.offlineLimits=limits.isEmpty ? nil : limits
        if !value {
            // An earlier Sync request must not download this content again
            // after Unsync. Separately pinned children retain their intent.
            let retained=effectivePins()
            snapshot.requestedDownloads=snapshot.requestedDownloads?.filter{ !descendant($0,of:id) || retained.contains($0) }
        }
        // Retain the old field for compatible reads by a previous build.
        if value { snapshot.pinned.insert(id) } else { snapshot.pinned.remove(id) }
        let revision=(snapshot.localRevision ?? 0)+1; snapshot.localRevision=revision
        var updates=snapshot.localUpdates ?? [:]
        for item in snapshot.objects.keys where descendant(item,of:id) {updates[item]=revision}
        snapshot.localUpdates=updates; try save()
    }
    func fetch(_ id:String,to url:URL) async throws -> (DriveObject,String,Set<String>) {
        let (object,root,pins)=try await item(id)
        guard !object.isFolder else { throw DriveFailure.denied }
        if object.isGoogleDocument {
            let data=try PropertyListSerialization.data(fromPropertyList:["URL":"https://drive.google.com/open?id="+object.id],format:.xml,options:0)
            try data.write(to:url,options:.atomic); try downloaded(id); return (object,root,pins)
        }
        #if NIMBO_TESTING
        if snapshot.fixture==true {
            try await fixtureWriter().fetch(id,to:url);try downloaded(id); return (object,root,pins)
        }
        #endif
        guard let api else { throw DriveFailure.notAuthenticated }
        do {
            if object.splitLayout != nil { try await api.downloadSplit(object, to: url) }
            else { try await api.download(id,to:url,expectedSize:object.size.flatMap(Int64.init)) }
            if let expected=object.md5Checksum {
                let handle=try FileHandle(forReadingFrom:url); defer { try? handle.close() }
                var hash=Insecure.MD5()
                while let data=try handle.read(upToCount:1024*1024), !data.isEmpty { hash.update(data:data) }
                let actual=hash.finalize().map{String(format:"%02x",$0)}.joined()
                guard actual==expected else { throw DriveFailure.invalidResponse }
            }
            let current=try await api.item(id)
            guard current.trashed != true, (current.md5Checksum ?? current.version)==(object.md5Checksum ?? object.version) else { throw DriveFailure.invalidResponse }
            snapshot.objects[id]=current; try downloaded(id); return (current,root,effectivePins())
        } catch { try? FileManager.default.removeItem(at:url); throw error }
    }
    #if NIMBO_TESTING
    func renameFixtureRemotely(_ id:String,name:String) async throws {
        guard snapshot.fixture == true else { throw DriveFailure.denied }
        let writer=try fixtureWriter(), revision=try await writer.revision(id)
        _ = try await writer.updateMetadata(id,etag:revision.etag,name:name,parent:nil,trashed:nil)
    }
    func addFixtureConflict() throws {
        guard snapshot.fixture == true else { throw DriveFailure.denied }
        let conflict=DriveObject(id:"fixture-conflict",name:"Hola (conflicto Mac fixture).txt",mimeType:"text/plain",size:"4",version:"1",parents:["projects"])
        snapshot.objects[conflict.id]=conflict; try save()
    }
    func addFixtureLinkedConflict() async throws {
        guard snapshot.fixture == true else { throw DriveFailure.denied }
        let copy=DriveObject(id:"fixture-linked-conflict",name:"Hola (conflicto Mac linked).txt",mimeType:"text/plain",size:"4",version:"1",parents:["projects"])
        try await fixtureWriter().merge([copy])
        snapshot.objects[copy.id]=copy
        var conflicts=snapshot.metadataConflicts ?? [:];conflicts[copy.id]=NativeConflict(id:copy.id,name:copy.name,parent:copy.parents?.first,kind:"content",detail:"Copia local conservada",remoteID:"hello");snapshot.metadataConflicts=conflicts
        try save()
    }
    func addFixtureLargeTree() async throws {
        guard snapshot.fixture == true else { throw DriveFailure.denied }
        let folder=DriveObject(id:"large-folder",name:"Árbol grande",mimeType:"application/vnd.google-apps.folder",version:"1",parents:[try rootID()])
        var values=[folder]
        for number in 0..<520 {
            values.append(DriveObject(id:String(format:"large-%04d",number),name:String(format:"archivo-%04d.txt",number),mimeType:"text/plain",size:"1",version:"1",parents:[folder.id]))
        }
        try await fixtureWriter().merge(values);snapshot.objects[folder.id]=folder;try save()
    }
    func configureFixture() throws {
        guard snapshot.root==nil || snapshot.fixture==true else { throw DriveFailure.denied }
        if snapshot.fixture==true {snapshot.writable=true;snapshot.root?.capabilities=NativeFixtureDrive.capabilities;if let root=snapshot.root{snapshot.objects[root.id]=root};snapshot.localRevision=(snapshot.localRevision ?? 0)+1;try save();return}
        let folder="application/vnd.google-apps.folder"
        let root=DriveObject(id:"fixture-root",name:"Nimbo Native",mimeType:folder,version:"1",capabilities:NativeFixtureDrive.capabilities)
        let hello=DriveObject(id:"hello",name:"Hola.txt",mimeType:"text/plain",size:String(Data("Nimbo native placeholder.\n".utf8).count),version:"1",parents:[root.id])
        let sub=DriveObject(id:"projects",name:"Proyectos",mimeType:folder,version:"1",parents:[root.id])
        let child=DriveObject(id:"cafe",name:"Café [2026].txt",mimeType:"text/plain",size:String(Data("Archivo de prueba con acentos.\n".utf8).count),version:"1",parents:[sub.id])
        snapshot=NativeSnapshot(root:root,objects:[root.id:root,hello.id:hello,sub.id:sub,child.id:child],anchor:"fixture-1",fixture:true,writable:true)
        api=nil; try save()
    }
    #endif
}
