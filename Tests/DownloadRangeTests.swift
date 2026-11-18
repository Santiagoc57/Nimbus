import Foundation

private final class RangeDownloadProtocol: URLProtocol {
    static let lock=NSLock()
    static var payload=Data(), ranges:[String]=[], requestCount=0, failAfter:Int?=nil, failuresRemaining=0
    static func reset(failAfter:Int?=nil, failures:Int=0) {
        lock.lock(); defer{lock.unlock()}
        payload=Data((0..<(17*1024*1024+123)).map{UInt8($0 % 251)})
        ranges=[]; requestCount=0; self.failAfter=failAfter; failuresRemaining=failures
    }
    override class func canInit(with request:URLRequest)->Bool { request.url?.host == "www.googleapis.com" }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    private func reply(_ status:Int,headers:[String:String]=[:],body:Data=Data()) {
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if !body.isEmpty { client?.urlProtocol(self,didLoad:body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func startLoading() {
        guard request.url?.path.hasPrefix("/drive/v3/files/") == true else { reply(404); return }
        Self.lock.lock(); Self.requestCount += 1; let number=Self.requestCount
        if let failAfter=Self.failAfter, number > failAfter, Self.failuresRemaining > 0 {
            Self.failuresRemaining -= 1; Self.lock.unlock(); reply(503,body:Data("temporary".utf8)); return
        }
        let payload=Self.payload; let range=request.value(forHTTPHeaderField:"Range") ?? ""; Self.ranges.append(range); Self.lock.unlock()
        guard range.hasPrefix("bytes=") else { reply(400); return }
        let bounds=range.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
        guard let start=Int(bounds.first ?? "-1"), start >= 0 else { reply(416); return }
        let requestedEnd=Int(bounds.dropFirst().first ?? "-1") ?? (payload.count-1)
        guard start < payload.count else { reply(416,headers:["Content-Range":"bytes */\(payload.count)"]); return }
        let end=min(requestedEnd,payload.count-1)
        let body=payload.subdata(in:start..<(end+1))
        reply(206,headers:["Content-Range":"bytes \(start)-\(end)/\(payload.count)","Content-Length":String(body.count)],body:body)
    }
    override func stopLoading() {}
}

@main struct DownloadRangeTests {
    static func main() async throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/nimbo/download-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let config=root.appendingPathComponent("rclone.conf")
        let token="{\"access_token\":\"download-test\",\"refresh_token\":\"unused\",\"expiry\":\"2099-01-01T00:00:00Z\"}"
        try Data("[GoogleDrive]\nclient_id = synthetic.apps.googleusercontent.com\nclient_secret = GOCSPX-synthetic\nscope = drive\ntoken = \(token)\n".utf8).write(to:config,options:.atomic)
        let sessionConfig=URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses=[RangeDownloadProtocol.self]
        let api=DriveAPI(configuration:config,session:URLSession(configuration:sessionConfig))
        var checks:[String]=[]
        func check(_ value:Bool,_ name:String)throws{guard value else{throw DriveFailure.invalidResponse};checks.append(name);print("PASS: "+name)}

        RangeDownloadProtocol.reset()
        let expected=RangeDownloadProtocol.payload
        let destination=root.appendingPathComponent("first.bin")
        let partial=destination.appendingPathExtension("nimbo.part")
        try Data(expected.prefix(5*1024*1024)).write(to:partial,options:.atomic)
        try await api.download("download-item",to:destination,expectedSize:Int64(expected.count))
        try check(Data(contentsOf:destination)==expected,"Range download resumes an existing partial file and preserves bytes")
        try check((RangeDownloadProtocol.ranges.first ?? "").hasPrefix("bytes=5242880-"),"First request starts at the persisted partial offset")
        try check(RangeDownloadProtocol.ranges.count >= 2,"Large content is fetched in bounded ranges")

        RangeDownloadProtocol.reset(failAfter:1,failures:3)
        let interrupted=root.appendingPathComponent("interrupted.bin")
        var failed=false
        do { try await api.download("download-item",to:interrupted,expectedSize:Int64(expected.count)) }
        catch DriveFailure.unavailable { failed=true }
        try check(failed,"A transient failure after a committed range leaves the download resumable")
        let saved=try (FileManager.default.attributesOfItem(atPath:interrupted.appendingPathExtension("nimbo.part").path)[.size] as! NSNumber).int64Value
        try check(saved == 8*1024*1024,"The partial file contains exactly the acknowledged first range")
        RangeDownloadProtocol.reset()
        try await api.download("download-item",to:interrupted,expectedSize:Int64(expected.count))
        try check(Data(contentsOf:interrupted)==expected,"A second invocation resumes after the network failure")
        try check((RangeDownloadProtocol.ranges.first ?? "").hasPrefix("bytes=8388608-"),"Resume begins at the saved post-failure offset")
        let report:[String:Any]=["status":"PASS","count":checks.count,"checks":checks,"synthetic_only":true]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/NATIVE_DRIVE_DOWNLOAD_TESTS.json"))
    }
}
