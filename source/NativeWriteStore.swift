import Foundation
import FileProvider
import CryptoKit

struct NativeMutationOutcome:Codable {
    var item:DriveObject?
    var additional:[DriveObject]=[]
    var removed:[String]=[]
    var fetchContent=false
}
enum NativeMutationFailure:Error {
    case stale(DriveObject)
    case replayChanged
    case unsupported
}
private struct NativeOperation:Codable {
    let kind:String, name:String, parent:String?, mime:String, isFolder:Bool
    let baseContent:Data?, baseMetadata:Data?, contentMD5:String?
    var target:String?
    var etag:String?
    var upload:DriveUploadSession?
    var conflictID:String?
    var conflictUpload:DriveUploadSession?
    // Freeze the representation before allocating a Drive ID. A retried
    // Finder copy must resume the original format even if settings change.
    var splitGeneration: String?
    var segmentMB: Int?
    var outcome:NativeMutationOutcome?
}

/// All paths are derived from hashes, never a remote filename. Session URLs and
/// staged content remain inside a 0700 directory and private operation records.
private final class NativeOperationJournal:@unchecked Sendable {
    let root:URL
    private let lock=NSLock()
    init(_ root:URL)throws {
        self.root=root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard root.resolvingSymlinksInPath()==root.standardizedFileURL else{throw DriveFailure.denied}
    }
    func directory(_ key:String)->URL {root.appendingPathComponent(SHA256.hash(data:Data(key.utf8)).map{String(format:"%02x",$0)}.joined())}
    func content(_ key:String)->URL {directory(key).appendingPathComponent("content")}
    private func read(_ key:String)throws->NativeOperation? {
        let path=directory(key).appendingPathComponent("operation.json")
        guard FileManager.default.fileExists(atPath:path.path) else{return nil}
        return try JSONDecoder().decode(NativeOperation.self,from:Data(contentsOf:path))
    }
    private func write(_ key:String,_ operation:NativeOperation)throws {
        let dir=directory(key)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let path=dir.appendingPathComponent("operation.json")
        try JSONEncoder().encode(operation).write(to:path,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
    }
    func load(_ key:String)throws->NativeOperation? {lock.lock();defer{lock.unlock()};return try read(key)}
    func save(_ key:String,_ operation:NativeOperation)throws {lock.lock();defer{lock.unlock()};try write(key,operation)}
    func checkpoint(_ key:String,_ session:DriveUploadSession,conflict:Bool)throws {
        lock.lock();defer{lock.unlock()}
        guard var operation=try read(key) else{throw DriveFailure.invalidResponse}
        if conflict{operation.conflictUpload=session}else{operation.upload=session}
        try write(key,operation)
    }
    func discardCompletedContent(_ key:String)throws {
        lock.lock();defer{lock.unlock()}
        guard try read(key)?.outcome != nil else{return}
        let file=content(key)
        if FileManager.default.fileExists(atPath:file.path){try FileManager.default.removeItem(at:file)}
    }
    func stage(_ key:String,source:URL,md5:String)throws {
        let destination=content(key),fm=FileManager.default
        if fm.fileExists(atPath:destination.path) {
            guard try DriveWriteAPI.fingerprint(destination).md5==md5 else{throw NativeMutationFailure.replayChanged};return
        }
        let dir=directory(key);try fm.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temporary=dir.appendingPathComponent("stage-"+UUID().uuidString)
        defer{try? fm.removeItem(at:temporary)}
        try fm.copyItem(at:source,to:temporary)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporary.path)
        guard try DriveWriteAPI.fingerprint(temporary).md5==md5 else{throw NativeMutationFailure.replayChanged}
        try fm.moveItem(at:temporary,to:destination)
    }
}

/// Durable mutation state is separate from the disposable metadata cache. A
/// remote commit can be reconciled after a crash without uploading it twice.
actor NativeWriteStore {
    private let writer:any NativeDriveWriting
    private let journal:NativeOperationJournal
    private var running:[String:Task<NativeMutationOutcome,Error>]=[:]
    init(directory:URL,writer:any NativeDriveWriting)throws{self.writer=writer;journal=try NativeOperationJournal(directory)}
    private func perform(_ key:String,_ action:@escaping()async throws->NativeMutationOutcome) async throws->NativeMutationOutcome {
        if let existing=running[key]{return try await existing.value}
        let task=Task{try await action()};running[key]=task
        defer{running.removeValue(forKey:key)}
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
    }
    private func matches(_ operation:NativeOperation,_ item:DriveObject)->Bool {
        // The metadata version encodes Nimbo-only state (pin, local copy,
        // write access). Accept every combination so that state never turns a
        // legitimate edit into a false conflict copy.
        var metadata:[Data]=[]
        for pinned in [false,true] { for local in [false,true] { for writable in [false,true] { for upload in [nil,"uploading","failed"] as [String?] {
            metadata.append(NativeItem(item,rootID:"root",pinned:pinned,locallyDownloaded:local,writable:writable,uploadState:upload).itemVersion.metadataVersion)
        } } } }
        let content=NativeItem(item,rootID:"root",pinned:false).itemVersion.contentVersion
        return operation.baseContent==content && metadata.contains(operation.baseMetadata ?? Data())
    }
    private func revisionIfPresent(_ id:String) async throws->DriveRevision? {
        do{return try await writer.revision(id)}catch DriveFailure.notFound{return nil}
    }
    private func finish(_ key:String,_ outcome:NativeMutationOutcome)throws->NativeMutationOutcome {
        guard var operation=try journal.load(key) else{throw DriveFailure.invalidResponse}
        operation.outcome=outcome;try journal.save(key,operation)
        try journal.discardCompletedContent(key)
        return outcome
    }
    func create(template:String,parent:String,name:String,mime:String,isFolder:Bool,contents:URL?,segmentMB:Int = 0) async throws->NativeMutationOutcome {
        let key="create:"+template
        return try await perform(key){try await self.createRun(key,parent:parent,name:name,mime:mime,isFolder:isFolder,contents:contents,segmentMB:segmentMB)}
    }
    private func createRun(_ key:String,parent:String,name:String,mime:String,isFolder:Bool,contents:URL?,segmentMB:Int) async throws->NativeMutationOutcome {
        guard isFolder || contents != nil else{throw NativeMutationFailure.unsupported}
        let input = try contents.map(DriveWriteAPI.fingerprint)
        let fingerprint = input?.md5
        var operation:NativeOperation
        if let saved=try journal.load(key) {
            guard saved.parent==parent,saved.name==name,saved.contentMD5==fingerprint,saved.isFolder==isFolder else{throw NativeMutationFailure.replayChanged}
            if let outcome=saved.outcome{try journal.discardCompletedContent(key);return outcome};operation=saved
        } else {
            operation=NativeOperation(kind:"create",name:name,parent:parent,mime:mime,isFolder:isFolder,baseContent:nil,baseMetadata:nil,contentMD5:fingerprint,segmentMB:segmentMB)
            try journal.save(key,operation)
        }
        if let contents,let fingerprint{try journal.stage(key,source:contents,md5:fingerprint)}
        if operation.target==nil{operation.target=try await writer.allocateID();try journal.save(key,operation)}
        let id=operation.target!
        if !isFolder, let input, let mb = operation.segmentMB, mb > 0 {
            guard SyncSettings.segmentSizes.contains(mb) else { throw DriveFailure.invalidResponse }
            let partBytes = Int64(mb) * 1_000_000
            if input.size > partBytes {
                guard let layout = DriveSplitLayout(size: input.size, partBytes: partBytes, md5: input.md5),
                      let splitWriter = writer as? any DriveSplitCreating else { throw NativeMutationFailure.unsupported }
                let result = try await splitWriter.createSplit(id: id, parent: parent, name: name, file: journal.content(key),
                    layout: layout, journalAccount: "native-split-writes", keychain: false,
                    checkCancellation: { try Task.checkCancellation() }, progress: { _, _ in })
                guard result.object.id == id, result.object.splitLayout == layout, result.object.name == name,
                      result.object.parents == [parent], !result.object.splitPending else { throw DriveFailure.conflict }
                return try finish(key, NativeMutationOutcome(item: result.object))
            }
        }
        if let existing=try await revisionIfPresent(id) {
            guard existing.object.trashed != true,existing.object.name==name,existing.object.parents?.contains(parent)==true,
                  (isFolder && existing.object.isFolder) || (!isFolder && existing.object.md5Checksum==fingerprint) else{throw NativeMutationFailure.replayChanged}
            return try finish(key,NativeMutationOutcome(item:existing.object))
        }
        let result:DriveRevision
        if isFolder {result=try await writer.createFolder(id:id,parent:parent,name:name)}
        else {result=try await transfer(key,conflict:false)}
        return try finish(key,NativeMutationOutcome(item:result.object))
    }
    private func transfer(_ key:String,conflict:Bool) async throws->DriveRevision {
        guard var operation=try journal.load(key),let target=conflict ? operation.conflictID:operation.target else{throw DriveFailure.invalidResponse}
        let name=conflict ? Self.conflictName(operation.name,id:target):operation.name
        var session=conflict ? operation.conflictUpload:operation.upload
        let source=journal.content(key)
        if session==nil {
            session=try await writer.beginUpload(id:target,parent:operation.parent,name:name,mime:operation.mime,file:source,baseETag:conflict ? nil:operation.etag)
            try journal.checkpoint(key,session!,conflict:conflict)
        }
        do {
            return try await writer.upload(source,session:session!,checkpoint:{[journal] state in try journal.checkpoint(key,state,conflict:conflict)},progress:{_,_ in})
        } catch DriveFailure.notFound {
            // A session may expire after an uncertain commit. Reconcile by ID
            // and checksum before deciding whether it is safe to start another.
            if let current=try await revisionIfPresent(target),current.object.md5Checksum==operation.contentMD5,current.object.name==name,current.object.trashed != true {return current}
            if !conflict,let tag=operation.etag {
                guard let current=try await revisionIfPresent(target),current.etag==tag else{throw DriveFailure.conflict}
            } else if try await revisionIfPresent(target) != nil {throw DriveFailure.conflict}
            operation=try journal.load(key)!
            if conflict{operation.conflictUpload=nil}else{operation.upload=nil}
            try journal.save(key,operation)
            throw DriveFailure.unavailable // bounded: the system retries later
        }
    }
    static func conflictName(_ original:String,id:String)->String {
        let ext=(original as NSString).pathExtension
        let suffix=ext.isEmpty ? "":"."+ext
        let stem=suffix.isEmpty ? original:String(original.dropLast(suffix.count))
        let tag=SHA256.hash(data:Data(id.utf8)).prefix(6).map{String(format:"%02x",$0)}.joined()
        return stem+" (conflicto Mac "+tag+")"+suffix
    }
    func modify(id:String,base:NSFileProviderItemVersion,name:String,parent:String,mime:String,isFolder:Bool,contents:URL?) async throws->NativeMutationOutcome {
        let md5=try contents.map{try DriveWriteAPI.fingerprint($0).md5}
        let intent=[id,base.contentVersion.base64EncodedString(),base.metadataVersion.base64EncodedString(),name,parent,md5 ?? "metadata"].joined(separator:"\n")
        let key="modify:"+intent
        return try await perform(key){try await self.modifyRun(key,id:id,base:base,name:name,parent:parent,mime:mime,isFolder:isFolder,contents:contents,md5:md5)}
    }
    private func modifyRun(_ key:String,id:String,base:NSFileProviderItemVersion,name:String,parent:String,mime:String,isFolder:Bool,contents:URL?,md5:String?) async throws->NativeMutationOutcome {
        var operation=try journal.load(key) ?? NativeOperation(kind:"modify",name:name,parent:parent,mime:mime,isFolder:isFolder,baseContent:base.contentVersion,baseMetadata:base.metadataVersion,contentMD5:md5,target:id)
        if let outcome=operation.outcome{try journal.discardCompletedContent(key);return outcome}
        try journal.save(key,operation)
        if let contents,let md5{try journal.stage(key,source:contents,md5:md5)}
        guard let current=try await revisionIfPresent(id) else {
            guard contents != nil,!isFolder else{throw DriveFailure.notFound}
            let missing=DriveObject(id:id,name:name,mimeType:mime,parents:[parent],trashed:true)
            return try await conflictCopy(key,current:missing)
        }
        if let md5,current.object.trashed != true,current.object.md5Checksum==md5,current.object.name==name,current.object.parents==[parent],operation.etag != nil {
            return try finish(key,NativeMutationOutcome(item:current.object))
        }
        // Metadata-only commits can also lose their response.
        if md5==nil,operation.etag != nil,current.object.name==name,current.object.parents==[parent],current.object.trashed != true {
            return try finish(key,NativeMutationOutcome(item:current.object))
        }
        if current.object.trashed==true || !matches(operation,current.object) || operation.conflictID != nil {
            guard contents != nil,!isFolder else{throw NativeMutationFailure.stale(current.object)}
            return try await conflictCopy(key,current:current.object)
        }
        if operation.etag==nil{operation.etag=current.etag;try journal.save(key,operation)}
        do {
            let result:DriveRevision
            if let md5, let old = current.object.splitLayout {
                guard let writer = writer as? DriveWriteAPI else { throw NativeMutationFailure.unsupported }
                if operation.splitGeneration == nil {
                    operation.splitGeneration = try await writer.allocateID()
                    try journal.save(key, operation)
                }
                let file = journal.content(key)
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let size, let generation = operation.splitGeneration,
                      let inner = DriveSplitLayout(size: Int64(size), partBytes: old.partBytes, md5: md5, editing: true),
                      let next = DriveSplitLayout(size: Int64(size), partBytes: old.partBytes, md5: md5, editing: true, generation: generation) else {
                    throw DriveFailure.invalidResponse
                }
                _ = try await writer.createSplit(id: generation, parent: id, name: ".nimbo-version-" + generation,
                    file: file, layout: inner, journalAccount: "native-split-writes", keychain: false,
                    checkCancellation: { try Task.checkCancellation() }, progress: { _, _ in })
                result = try await writer.commitSplit(id, etag: operation.etag!, name: name, parent: parent, layout: next)
            } else if contents != nil { result = try await transfer(key, conflict: false) }
            else{result=try await writer.updateMetadata(id,etag:operation.etag!,name:name,parent:parent,trashed:nil)}
            return try finish(key,NativeMutationOutcome(item:result.object))
        } catch DriveFailure.conflict {
            let latest=try await writer.revision(id)
            guard contents != nil,!isFolder else{throw NativeMutationFailure.stale(latest.object)}
            return try await conflictCopy(key,current:latest.object)
        }
    }
    private func conflictCopy(_ key:String,current:DriveObject) async throws->NativeMutationOutcome {
        guard var operation=try journal.load(key) else{throw DriveFailure.invalidResponse}
        if operation.conflictID==nil{operation.conflictID=try await writer.allocateID();try journal.save(key,operation)}
        let copy:DriveRevision
        if let existing=try await revisionIfPresent(operation.conflictID!) {
            guard existing.object.md5Checksum==operation.contentMD5,existing.object.trashed != true else{throw NativeMutationFailure.replayChanged};copy=existing
        } else {copy=try await transfer(key,conflict:true)}
        return try finish(key,NativeMutationOutcome(item:current.trashed==true ? nil:current,additional:[copy.object],removed:current.trashed==true ? [current.id]:[],fetchContent:true))
    }
    func delete(id:String,base:NSFileProviderItemVersion) async throws->NativeMutationOutcome {
        let key="delete:"+id+":"+base.contentVersion.base64EncodedString()+":"+base.metadataVersion.base64EncodedString()
        return try await perform(key){try await self.deleteRun(key,id:id,base:base)}
    }
    private func deleteRun(_ key:String,id:String,base:NSFileProviderItemVersion) async throws->NativeMutationOutcome {
        var operation=try journal.load(key) ?? NativeOperation(kind:"delete",name:"",parent:nil,mime:"",isFolder:false,baseContent:base.contentVersion,baseMetadata:base.metadataVersion,contentMD5:nil,target:id)
        if let outcome=operation.outcome{try journal.discardCompletedContent(key);return outcome}
        try journal.save(key,operation)
        guard let current=try await revisionIfPresent(id),current.object.trashed != true else{return try finish(key,NativeMutationOutcome(item:nil,removed:[id]))}
        guard matches(operation,current.object) else{throw NativeMutationFailure.stale(current.object)}
        if operation.etag==nil{operation.etag=current.etag;try journal.save(key,operation)}
        do{_ = try await writer.updateMetadata(id,etag:operation.etag!,name:nil,parent:nil,trashed:true)}
        catch DriveFailure.conflict{throw NativeMutationFailure.stale(try await writer.revision(id).object)}
        return try finish(key,NativeMutationOutcome(item:nil,removed:[id]))
    }
}
