import Foundation

private final class ShareProtocol: URLProtocol {
    static let lock=NSLock()
    static var existingPublic=false, publicOnSecondPage=false, cycle=false, permissionGets=0, creates=0, deletes=0, fileGets=0
    static var customPermissions: [[String:Any]]?, invalidLink=false
    static var failDelete: String?
    static var calls:[URLRequest]=[], posted:[String:Any]=[:]
    static func reset(existing:Bool, page2Public:Bool=false, cycle:Bool=false) { lock.lock(); defer{lock.unlock()}; existingPublic=existing; publicOnSecondPage=page2Public; Self.cycle=cycle; permissionGets=0; creates=0; deletes=0; fileGets=0; customPermissions=nil; invalidLink=false; calls=[]; posted=[:]; failDelete=nil }
    override class func canInit(with request:URLRequest)->Bool { request.url?.host == "www.googleapis.com" }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    private func reply(_ status:Int,body:String) {
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func startLoading() {
        Self.lock.lock(); Self.calls.append(request); Self.lock.unlock()
        let path=request.url!.path
        if path.contains("/permissions/") && request.httpMethod == "DELETE" {
            Self.lock.lock(); Self.deletes += 1; Self.lock.unlock()
            reply(request.url?.lastPathComponent == Self.failDelete ? 403 : 204,body:"")
            return
        }
        if path.hasSuffix("/permissions") {
            if request.httpMethod == "GET" {
                let page2=request.url?.query?.contains("pageToken=page2") == true
                Self.lock.lock(); Self.permissionGets += 1; let publicAccess=page2 ? Self.publicOnSecondPage : Self.existingPublic; Self.lock.unlock()
                if let custom=Self.customPermissions { reply(200,body:String(data:try! JSONSerialization.data(withJSONObject:["permissions":custom]),encoding:.utf8)!) }
                else if Self.cycle && !page2 { reply(200,body:"{\"permissions\":[],\"nextPageToken\":\"page1\"}") }
                else if Self.cycle && page2 { reply(200,body:"{\"permissions\":[],\"nextPageToken\":\"page1\"}") }
                else if !page2 && Self.publicOnSecondPage { reply(200,body:"{\"permissions\":[],\"nextPageToken\":\"page2\"}") }
                else { reply(200,body:publicAccess ? "{\"permissions\":[{\"id\":\"anyone\",\"type\":\"anyone\",\"role\":\"reader\"}]}" : "{\"permissions\":[]}") }
            } else {
                var body=request.httpBody ?? Data()
                if let stream=request.httpBodyStream {
                    stream.open(); defer {stream.close()}
                    var buffer=[UInt8](repeating:0,count:1024)
                    while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count); if n<=0 { break }; body.append(contentsOf:buffer.prefix(n)) }
                }
                Self.posted=(try? JSONSerialization.jsonObject(with:body)) as? [String:Any] ?? [:]
                Self.lock.lock(); Self.creates += 1; Self.lock.unlock()
                reply(200,body:"{\"id\":\"anyone\",\"type\":\"anyone\",\"role\":\"reader\"}")
            }
            return
        }
        if path.hasSuffix("/files/share-item") {
            Self.lock.lock(); Self.fileGets += 1; Self.lock.unlock()
            let link=Self.invalidLink ? "https://untrusted.invalid/file" : "https://drive.google.com/file/d/share-item/view"
            reply(200,body:"{\"id\":\"share-item\",\"name\":\"Shared.txt\",\"mimeType\":\"text/plain\",\"webViewLink\":\"\(link)\"}")
            return
        }
        reply(404,body:"{}")
    }
    override func stopLoading() {}
}

@main struct DriveShareTests {
    static func main() async throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/nimbo/share-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let config=root.appendingPathComponent("rclone.conf")
        let token="{\"access_token\":\"share-test\",\"refresh_token\":\"unused\",\"expiry\":\"2099-01-01T00:00:00Z\"}"
        try Data("[GoogleDrive]\nclient_id = synthetic.apps.googleusercontent.com\nclient_secret = GOCSPX-synthetic\nscope = drive\ntoken = \(token)\n".utf8).write(to:config,options:.atomic)
        let sessionConfig=URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses=[ShareProtocol.self]
        let api=DriveAPI(configuration:config,session:URLSession(configuration:sessionConfig))
        var checks:[String]=[]
        func check(_ value:Bool,_ name:String)throws{guard value else{throw DriveFailure.invalidResponse};checks.append(name);print("PASS: "+name)}
        ShareProtocol.reset(existing:false)
        let created=try await api.createPublicLink("share-item")
        try check(created=="https://drive.google.com/file/d/share-item/view","Public share returns Drive webViewLink")
        try check(ShareProtocol.creates==1 && ShareProtocol.permissionGets==1 && ShareProtocol.fileGets==1 && ShareProtocol.calls.first?.url?.path.hasSuffix("/files/share-item")==true,"Share creation validates the link before changing permissions")
        try check(ShareProtocol.posted["type"] as? String == "anyone" && ShareProtocol.posted["role"] as? String == "reader" && ShareProtocol.posted["allowFileDiscovery"] as? Bool == false,"New public access is reader by link, without search discovery")
        ShareProtocol.reset(existing:true)
        let reused=try await api.createPublicLink("share-item")
        try check(reused==created && ShareProtocol.creates==0,"Existing anyone permission is reused idempotently")
        ShareProtocol.reset(existing:false,page2Public:true)
        let paged=try await api.createPublicLink("share-item")
        try check(paged==created && ShareProtocol.creates==0 && ShareProtocol.permissionGets==2,"Permission pagination finds a public link on a later page")
        let before=ShareProtocol.permissionGets; var rejected=false
        do { _=try await api.createPublicLink("../unsafe") } catch { rejected=true }
        try check(rejected && ShareProtocol.permissionGets==before,"Unsafe share ID is rejected before network access")
        ShareProtocol.reset(existing:true)
        let revoked=try await api.revokePublicLinks("share-item")
        try check(revoked==1 && ShareProtocol.deletes==1,"Revoking a public link deletes only the anyone permission")
        ShareProtocol.reset(existing:false,page2Public:true)
        let pagedRevoked=try await api.revokePublicLinks("share-item")
        try check(pagedRevoked==1 && ShareProtocol.permissionGets==2 && ShareProtocol.deletes==1,"Revoking paginates until the later public permission")
        ShareProtocol.reset(existing:false,cycle:true)
        var cycleRejected=false
        do { _=try await api.revokePublicLinks("share-item") } catch DriveFailure.invalidResponse { cycleRejected=true }
        try check(cycleRejected && ShareProtocol.permissionGets==2,"Repeated permission page tokens are rejected")
        ShareProtocol.reset(existing:false)
        let none=try await api.revokePublicLinks("share-item")
        try check(none==0 && ShareProtocol.deletes==0,"Revoking an item without a public link is a no-op")
        for role in ["reader","commenter","writer"] {
            ShareProtocol.reset(existing:false)
            ShareProtocol.customPermissions=[["id":"anyone","type":"anyone","role":role]]
            _=try await api.createPublicLink("share-item")
            try check(ShareProtocol.creates==0 && ShareProtocol.deletes==0,"Existing public \(role) access is preserved without mutation")
        }
        ShareProtocol.reset(existing:false); ShareProtocol.invalidLink=true
        var invalidRejected=false
        do { _=try await api.createPublicLink("share-item") } catch DriveFailure.invalidResponse { invalidRejected=true }
        try check(invalidRejected && ShareProtocol.creates==0,"Invalid link cannot publish a file before reporting failure")
        let direct:[String:Any]=["id":"direct","type":"anyone","role":"reader","permissionDetails":[["inherited":false]]]
        let inherited:[String:Any]=["id":"inherited","type":"anyone","role":"reader","permissionDetails":[["inherited":true]]]
        ShareProtocol.reset(existing:false); ShareProtocol.customPermissions=[direct,inherited]
        var inheritedRejected=false
        do { _=try await api.revokePublicLinks("share-item") } catch DriveFailure.inheritedPublicAccess { inheritedRejected=true }
        try check(inheritedRejected && ShareProtocol.deletes==0,"Inherited access aborts the whole item before deleting direct grants")
        _=try await api.createPublicLink("share-item")
        try check(ShareProtocol.creates==0,"Inherited public access is reused without changing the parent")
        ShareProtocol.reset(existing:false)
        ShareProtocol.customPermissions=[direct,["id":"user1","type":"user","role":"writer"],["id":"group1","type":"group","role":"reader"],["id":"domain1","type":"domain","role":"reader"]]
        _=try await api.revokePublicLinks("share-item")
        let deletedPaths=ShareProtocol.calls.filter{$0.httpMethod=="DELETE"}.compactMap{$0.url?.path}
        try check(deletedPaths==["/drive/v3/files/share-item/permissions/direct"],"Revocation preserves user, group and domain grants")
        for bad:[String:Any] in [["type":"anyone","role":"reader"],["id":"../unsafe","type":"anyone","role":"reader"],["id":"view","type":"anyone","role":"reader","view":"metadata"]] {
            ShareProtocol.reset(existing:false); ShareProtocol.customPermissions=[direct,bad]
            var refused=false
            do { _=try await api.revokePublicLinks("share-item") } catch DriveFailure.invalidResponse { refused=true }
            try check(refused && ShareProtocol.deletes==0,"Malformed or view-only permission prevents partial revocation")
        }
        ShareProtocol.reset(existing:false); ShareProtocol.customPermissions=[direct,direct]
        let dedup=try await api.revokePublicLinks("share-item")
        try check(dedup==1 && ShareProtocol.deletes==1,"Duplicate permission IDs are removed once")
        ShareProtocol.reset(existing:false); ShareProtocol.failDelete="second"
        ShareProtocol.customPermissions=[direct,["id":"second","type":"anyone","role":"reader"]]
        var partialReported=false
        do { _=try await api.revokePublicLinks("share-item") } catch let error as DrivePublicRevocationFailure { partialReported=error.removed==1 }
        try check(partialReported && ShareProtocol.deletes==2,"A later revocation failure explicitly reports the already removed grant")
        for badRole in ["unknown","publishedReader"] {
            ShareProtocol.reset(existing:false); ShareProtocol.customPermissions=[["type":"anyone","role":badRole]]
            var refused=false
            do { _=try await api.createPublicLink("share-item") } catch DriveFailure.invalidResponse { refused=true }
            try check(refused && ShareProtocol.creates==0,"Unknown public role is not silently converted to reader")
        }
        ShareProtocol.reset(existing:false)
        let cancelled=Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _=try await api.createPublicLink("share-item")
        }
        var cancellationRejected=false
        do { try await cancelled.value } catch is CancellationError { cancellationRejected=true }
        try check(cancellationRejected && ShareProtocol.calls.isEmpty,"Cancelled sharing does not contact Google")
        ShareProtocol.reset(existing:false)
        _=try await api.browserLink("share-item")
        try check(ShareProtocol.fileGets==1 && ShareProtocol.permissionGets==0 && ShareProtocol.creates==0 && ShareProtocol.deletes==0,"Copying an ordinary link never reads or changes permissions")
        let secondaryConfig=root.appendingPathComponent("secondary.conf")
        try Data("[Secondary]\nclient_id = synthetic.apps.googleusercontent.com\nclient_secret = synthetic\nscope = drive\ntoken = \(token.replacingOccurrences(of:"share-test",with:"secondary-test"))\n".utf8).write(to:secondaryConfig,options:.atomic)
        let secondary=DriveAPI(configuration:secondaryConfig,remoteName:"Secondary",session:URLSession(configuration:sessionConfig))
        ShareProtocol.reset(existing:false)
        _=try await secondary.createPublicLink("share-item")
        try check(ShareProtocol.calls.count==3 && ShareProtocol.calls.allSatisfy{$0.value(forHTTPHeaderField:"Authorization")=="Bearer secondary-test"},"Secondary account owns every metadata and permission request")
        try Data("[ReadOnly]\nclient_id = synthetic.apps.googleusercontent.com\nclient_secret = synthetic\nscope = drive.readonly\ntoken = \(token)\n".utf8).write(to:config,options:.atomic)
        let readOnly=DriveAPI(configuration:config,remoteName:"ReadOnly",session:URLSession(configuration:sessionConfig))
        for create in [true,false] {
            ShareProtocol.reset(existing:false); var refused=false
            do { if create { _=try await readOnly.createPublicLink("share-item") } else { _=try await readOnly.revokePublicLinks("share-item") } } catch DriveFailure.denied { refused=true }
            try check(refused && ShareProtocol.calls.isEmpty,"Read-only account cannot \(create ? "create" : "revoke") public permissions")
        }
        let report:[String:Any]=["status":"PASS","count":checks.count,"checks":checks,"synthetic_only":true]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/DRIVE_SHARE_TESTS.json"))
    }
}
