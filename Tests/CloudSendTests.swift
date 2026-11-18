#if CLOUD_SEND_TESTS
import Foundation

actor FakeSendService: CloudSendService {
    enum Mode { case normal, lostReply, interrupted, lateCancel, wrongReply }
    var mode=Mode.normal, writable=true
    var allocations=0, begins=0, uploads=0
    var records:[String:DriveRevision]=[:]
    var tickets:[String:SendTicket]=[:]
    var uploaded:[Data]=[]
    func configure(_ mode:Mode = .normal,writable:Bool=true) { self.mode=mode; self.writable=writable }
    func counts() -> (Int,Int,Int) { (allocations,begins,uploads) }
    func validateDestination(_ id:String) async throws -> String { guard writable else { throw DriveFailure.denied }; return id=="root" ? "folder":id }
    func destination(_ id:String) async throws -> (id:String,names:Set<String>) { (try await validateDestination(id),Set(["same.txt"]).union(records.values.map{$0.object.name})) }
    func allocateID() async throws -> String { allocations+=1; return "file\(allocations)" }
    func revision(_ id:String) async throws -> DriveRevision { guard let found=records[id] else { throw DriveFailure.notFound }; return found }
    func begin(_ ticket:SendTicket,file:URL) async throws -> DriveUploadSession {
        begins+=1; tickets[ticket.fileID]=ticket
        return DriveUploadSession(fileID:ticket.fileID,sessionURL:URL(string:"https://example.invalid/session/\(ticket.fileID)")!,baseETag:nil,size:ticket.size,md5:ticket.md5,offset:0)
    }
    func upload(_ file:URL,session:DriveUploadSession,checkpoint:@escaping(DriveUploadSession)throws->Void,progress:@escaping(Int64,Int64)->Void) async throws -> DriveRevision {
        uploads+=1; var session=session; session.offset=session.size/2; try checkpoint(session); progress(session.offset,session.size)
        if mode == .interrupted { throw DriveFailure.unavailable }
        let ticket=tickets[session.fileID]!, body=try Data(contentsOf:file)
        uploaded.append(body)
        let object=DriveObject(id:ticket.fileID,name:ticket.name,mimeType:"text/plain",size:String(ticket.size),md5Checksum:mode == .wrongReply ? "WRONG":ticket.md5,parents:[ticket.destination.folderID],trashed:false)
        let result=DriveRevision(object:object,etag:"\"fixture\""); records[ticket.fileID]=result
        if mode == .lostReply { throw DriveFailure.unavailable }
        if mode == .lateCancel,let transfer=TransferCenter.shared.active().first { TransferCenter.shared.requestCancellation(transfer.id) }
        progress(session.size,session.size); return result
    }
}
@main struct CloudSendTests {
    static func main() async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("nimbo-send-test-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true); defer { try? fm.removeItem(at:root) }
        NimboSecureFile.testRoot=root.appendingPathComponent("keys")
        NimboSecureFile.testRead = { (errSecItemNotFound, nil) }
        NimboSecureFile.testAdd = { _ in errSecInteractionNotAllowed }
        TransferCenter.shared.configure(support:root)
        let drive=FakeSendService(),readOnly=FakeSendService()
        await readOnly.configure(writable:false)
        let queue=root.appendingPathComponent("queue")
        let factory:CloudSendEngine.Factory={ $0 == "ReadOnly" ? readOnly : drive }
        let engine=CloudSendEngine(root:queue,service:factory)
        var checks=0
        func check(_ value:Bool,_ message:String) { precondition(value,message); checks+=1 }
        func file(_ directory:String,_ name:String,_ value:String="original") throws -> URL {
            let dir=root.appendingPathComponent(directory);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            let path=dir.appendingPathComponent(name);try Data(value.utf8).write(to:path);return path
        }
        let destination=SendDestination(remote:"Work",folderID:"root",path:"Mi unidad")
        let first=try file("a","same.txt"),second=try file("b","same.txt")
        let tickets=try await engine.prepare(files:[first,second],destination:destination)
        check(tickets.count==2,"two files prepared")
        check(Set(tickets.map(\.name)).count==2 && tickets.allSatisfy{$0.name != "same.txt"},"existing and batch names preserved")
        check(tickets.allSatisfy{$0.destination.folderID=="folder"},"root resolved to stable folder ID")
        check(try await engine.pending().count==2,"jobs durable before upload")
        let journal=try Data(contentsOf:queue.appendingPathComponent(tickets[0].id.uuidString+"/job.enc"))
        check(journal.starts(with:Data("NIMBO-ENC-1\n".utf8)),"journal is encrypted")
        _ = try await engine.send(tickets[0].id)
        check(try await engine.pending().count==1,"verified success removes staged job")
        await drive.configure(.lostReply)
        do { _ = try await engine.send(tickets[1].id); fatalError("lost reply accepted") } catch {}
        check(try await engine.pending().count==1,"unknown commit retains job")
        let counts=await drive.counts()
        let restarted=CloudSendEngine(root:queue,service:factory)
        await drive.configure()
        _ = try await restarted.send(tickets[1].id)
        check(await drive.counts().2==counts.2,"retry resolves committed ID without another upload")
        check(try await restarted.pending().isEmpty,"recovered receipt cleans staging")
        let source=try file("c","resume.txt")
        let resumable=try await restarted.prepare(files:[source],destination:destination)[0]
        await drive.configure(.interrupted)
        do { _ = try await restarted.send(resumable.id); fatalError("interruption accepted") } catch {}
        let saved=try await restarted.pending()[0]
        check(saved.session?.offset==saved.size/2,"checkpoint persisted")
        let beginCount=await drive.counts().1
        try Data("changed original".utf8).write(to:source)
        await drive.configure()
        _ = try await restarted.send(saved.id)
        check(await drive.counts().1==beginCount,"retry reuses session and reserved ID")
        check(await drive.uploaded.last==Data("original".utf8),"immutable snapshot survives original edits")
        do { _ = try await restarted.prepare(files:[source],destination:SendDestination(remote:"ReadOnly",folderID:"root",path:"Mi unidad")); fatalError("read-only accepted") } catch {}
        check(await readOnly.counts().0==0,"read-only cannot reserve or upload")
        let late=try await restarted.prepare(files:[source],destination:destination)[0]
        await drive.configure(.lateCancel)
        _ = try await restarted.send(late.id)
        let committed=TransferCenter.shared.recent().first{$0.name==late.name}!
        check(committed.state == .completed && committed.verified,"server-confirmed commit wins late cancel")
        check(try await restarted.pending().isEmpty,"late cancel cannot leave duplicate pending upload")
        await drive.configure(.wrongReply)
        let bad=try await restarted.prepare(files:[source],destination:destination)[0]
        do { _ = try await restarted.send(bad.id); fatalError("bad checksum accepted") } catch {}
        check(try await restarted.pending().count==1,"unverified server result retains snapshot")
        check(TransferCenter.shared.recent().first{$0.name==bad.name}?.verified==false,"checksum mismatch is never verified")
        print("PASS: \(checks) create-only send, collision, persistence, retry, permissions and commit checks; no network")
    }
}
#endif
