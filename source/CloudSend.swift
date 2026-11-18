import Foundation
import UniformTypeIdentifiers

struct SendDestination: Codable, Equatable {
    let remote: String
    let folderID: String
    let path: String
}
struct SendTicket: Codable, Equatable {
    let id: UUID
    let destination: SendDestination
    let name: String
    let fileID: String
    let size: Int64
    let md5: String
    var session: DriveUploadSession?
    var segmentMB: Int?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
protocol CloudSendService: Sendable {
    func destination(_ id: String) async throws -> (id: String, names: Set<String>)
    func validateDestination(_ id: String) async throws -> String
    func allocateID() async throws -> String
    func revision(_ id: String) async throws -> DriveRevision
    func begin(_ ticket: SendTicket, file: URL) async throws -> DriveUploadSession
    func upload(_ file: URL, session: DriveUploadSession, checkpoint: @escaping (DriveUploadSession) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> DriveRevision
}
protocol SplitCloudSending: CloudSendService {
    func sendSplit(ticket: SendTicket, file: URL, layout: DriveSplitLayout,
                   checkCancellation: @escaping () throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> DriveRevision
}
actor GoogleSendService: SplitCloudSending {
    private let api: DriveAPI
    private let writer: DriveWriteAPI
    init(config: URL, remote: String) {
        let api = DriveAPI(configuration: config, remoteName: remote)
        self.api=api; writer=DriveWriteAPI(api:api)
    }
    func validateDestination(_ id: String) async throws -> String {
        guard try await api.permitsWrites() else { throw DriveFailure.denied }
        let folder = try await api.item(id)
        guard folder.isFolder, folder.trashed != true, folder.capabilities?.canAddChildren != false else { throw DriveFailure.denied }
        return folder.id
    }
    func destination(_ id: String) async throws -> (id: String, names: Set<String>) {
        let folderID=try await validateDestination(id)
        var page: String?, seen=Set<String>(), names=Set<String>(), count=0
        repeat {
            let result=try await api.children(folderID,page:page)
            count += result.files.count
            guard count <= 200_000 else { throw CloudBackendError.outputLimitExceeded }
            names.formUnion(result.files.map(\.name))
            page=result.nextPageToken
            if let page, !seen.insert(page).inserted { throw DriveFailure.invalidResponse }
        } while page != nil
        return (folderID,names)
    }
    func allocateID() async throws -> String { try await writer.allocateID() }
    func revision(_ id: String) async throws -> DriveRevision { try await writer.revision(id) }
    func begin(_ ticket: SendTicket, file: URL) async throws -> DriveUploadSession {
        try await writer.beginUpload(id:ticket.fileID,parent:ticket.destination.folderID,name:ticket.name,mime:UTType(filenameExtension:(ticket.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream",file:file,baseETag:nil)
    }
    func upload(_ file: URL, session: DriveUploadSession, checkpoint: @escaping (DriveUploadSession) throws -> Void, progress: @escaping (Int64,Int64) -> Void) async throws -> DriveRevision {
        try await writer.upload(file,session:session,checkpoint:checkpoint,progress:progress)
    }
}

extension GoogleSendService {
    func sendSplit(ticket: SendTicket, file: URL, layout: DriveSplitLayout,
                   checkCancellation: @escaping () throws -> Void,
                   progress: @escaping (Int64, Int64) -> Void) async throws -> DriveRevision {
        #if NIMBO_TESTING
        let keychain = false
        #else
        let keychain = true
        #endif
        return try await writer.createSplit(id: ticket.fileID, parent: ticket.destination.folderID,
                                            name: ticket.name, file: file, layout: layout,
                                            journalAccount: "send-jobs", keychain: keychain,
                                            checkCancellation: checkCancellation, progress: progress)
    }
}

/// Create-only uploads. Each staged snapshot and preallocated Google ID is
/// durable before content is sent, so retry cannot silently create duplicates.
actor CloudSendEngine {
    typealias Factory = @Sendable (String) -> any CloudSendService
    private let root: URL
    private let service: Factory
    private var running=Set<UUID>()
    init(root: URL, service: @escaping Factory) { self.root=root; self.service=service }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString,isDirectory:true) }
    private func journal(_ id: UUID) -> URL { directory(id).appendingPathComponent("job.enc") }
    private func content(_ id: UUID) -> URL { directory(id).appendingPathComponent("content") }
    private func save(_ ticket: SendTicket) throws { try NimboSecureFile.save(ticket,to:journal(ticket.id),account:"send-jobs") }
    func pending() throws -> [SendTicket] {
        guard FileManager.default.fileExists(atPath:root.path) else { return [] }
        let directories=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        return try directories.compactMap { url in
            guard let id=UUID(uuidString:url.lastPathComponent),FileManager.default.fileExists(atPath:journal(id).path) else { return nil }
            guard let ticket=try NimboSecureFile.load(SendTicket.self,from:journal(id),account:"send-jobs"),ticket.id==id else { throw DriveFailure.invalidResponse }
            return ticket
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func prepare(files: [URL], destination: SendDestination, segmentMB: Int = 0) async throws -> [SendTicket] {
        try Task.checkCancellation()
        guard SyncSettings.segmentSizes.contains(segmentMB) else { throw DriveFailure.invalidResponse }
        let drive=service(destination.remote)
        let folder=try await drive.destination(destination.folderID)
        var names=folder.names, tickets=[SendTicket]()
        let target=SendDestination(remote:destination.remote,folderID:folder.id,path:destination.path)
        for file in files {
            try Task.checkCancellation()
            let properties=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard properties.isRegularFile==true,properties.isSymbolicLink != true else { throw CloudBackendError.unsafePath }
            let id=UUID(), folder=directory(id)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            var durable=false
            do {
                var coordinationError:NSError?, copyError:Error?
                NSFileCoordinator().coordinate(readingItemAt:file,options:[],error:&coordinationError) { readable in
                    do { try FileManager.default.copyItem(at:readable,to:content(id)) } catch { copyError=error }
                }
                if let coordinationError { throw coordinationError }; if let copyError { throw copyError }
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:content(id).path)
                let fingerprint=try DriveWriteAPI.fingerprint(content(id))
                let name=Self.availableName(file.lastPathComponent,names:names,suffix:String(id.uuidString.prefix(8)))
                names.insert(name)
                let ticket=SendTicket(id:id,destination:target,name:name,fileID:try await drive.allocateID(),size:fingerprint.size,md5:fingerprint.md5,segmentMB:segmentMB)
                try save(ticket); durable=true; tickets.append(ticket)
            } catch {
                if !durable { try? FileManager.default.removeItem(at:folder) }
                throw error // Earlier prepared files remain available in Pending.
            }
        }
        return tickets
    }
    static func availableName(_ name: String, names: Set<String>, suffix: String) -> String {
        guard names.contains(name) else { return name }
        let ext=(name as NSString).pathExtension
        let base=ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number=0, candidate:String
        repeat {
            candidate=base+" (Nimbo-"+suffix+(number==0 ? "":"-\(number)")+")"+(ext.isEmpty ? "":"."+ext)
            number+=1
        } while names.contains(candidate)
        return candidate
    }
    private func verified(_ revision: DriveRevision, ticket: SendTicket) -> Bool {
        let item=revision.object
        return item.id==ticket.fileID && item.trashed != true && item.md5Checksum==ticket.md5 && item.size==String(ticket.size) && item.parents?.contains(ticket.destination.folderID)==true
    }
    func send(_ id: UUID, progress: @escaping @Sendable (Int64,Int64) -> Void = {_,_ in}) async throws -> SendTicket {
        guard running.insert(id).inserted else { throw DriveFailure.conflict }
        defer { running.remove(id) }
        guard var ticket=try NimboSecureFile.load(SendTicket.self,from:journal(id),account:"send-jobs"),ticket.id==id else { throw DriveFailure.notFound }
        let file=content(id), fingerprint=try DriveWriteAPI.fingerprint(file)
        guard fingerprint.size==ticket.size,fingerprint.md5==ticket.md5 else { throw DriveFailure.conflict }
        let drive=service(ticket.destination.remote)
        guard try await drive.validateDestination(ticket.destination.folderID) == ticket.destination.folderID else { throw DriveFailure.invalidResponse } // Recheck permissions without listing the folder again.
        let transfer=TransferCenter.shared.begin(remote:ticket.destination.remote,name:ticket.name,operation:"Envío",totalBytes:ticket.size,canCancel:true)
        do {
            try Task.checkCancellation()
            if let mb = ticket.segmentMB, mb > 0, SyncSettings.segmentSizes.contains(mb), ticket.size > Int64(mb) * 1_000_000 {
                guard let service = drive as? any SplitCloudSending, let layout = DriveSplitLayout(size: ticket.size, partBytes: Int64(mb) * 1_000_000, md5: ticket.md5) else { throw DriveFailure.invalidResponse }
                let result = try await service.sendSplit(ticket: ticket, file: file, layout: layout, checkCancellation: {
                    try Task.checkCancellation()
                    if TransferCenter.shared.isCancellationRequested(transfer) { throw CancellationError() }
                }, progress: { bytes, total in
                    TransferCenter.shared.update(transfer, completedBytes: bytes)
                    progress(bytes, total)
                })
                guard verified(result, ticket: ticket), result.object.splitLayout == layout, !result.object.splitPending else { throw DriveFailure.invalidResponse }
            } else {
                var existing:DriveRevision?
                do { existing=try await drive.revision(ticket.fileID) } catch DriveFailure.notFound {} // All other failures propagate.
                if let existing {
                    guard verified(existing,ticket:ticket) else { throw DriveFailure.conflict }
                } else {
                    if ticket.session==nil { ticket.session=try await drive.begin(ticket,file:file); try save(ticket) }
                    guard let session=ticket.session,session.fileID==ticket.fileID,session.baseETag==nil else { throw DriveFailure.invalidResponse }
                    let ticketSnapshot=ticket, journal=journal(id)
                    let result=try await drive.upload(file,session:session,checkpoint:{ state in
                        try Task.checkCancellation()
                        if TransferCenter.shared.isCancellationRequested(transfer) { throw CancellationError() }
                        var updated=ticketSnapshot; updated.session=state
                        try NimboSecureFile.save(updated,to:journal,account:"send-jobs")
                    },progress:{ bytes,total in
                        TransferCenter.shared.update(transfer,completedBytes:bytes)
                        progress(bytes,total)
                    })
                    guard verified(result,ticket:ticket) else { throw DriveFailure.invalidResponse }
                }
            }
            // A verified server commit wins over a late cancel request.
            TransferCenter.shared.update(transfer,completedBytes:ticket.size)
            TransferCenter.shared.finish(transfer,verified:true,confirmedCommit:true)
            try? FileManager.default.removeItem(at:directory(id))
            return ticket
        } catch {
            switch error {
            case DriveFailure.notFound, DriveFailure.anchorExpired, DriveFailure.http(410):
                ticket.session=nil; try? save(ticket) // Retry creates a fresh session with the same reserved file ID.
            default: break
            }
            TransferCenter.shared.finish(transfer,verified:false,error:error.localizedDescription,cancelled:error is CancellationError)
            throw error
        }
    }
}
