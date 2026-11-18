import Foundation
final class MockGoogle: URLProtocol {
 static let lock=NSLock()
 static var mode="normal", calls=0, refreshes=0
 static var onRefresh:(()->Void)?
 override class func canInit(with request:URLRequest)->Bool { true }
 override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
 override func startLoading() {
  Self.lock.lock(); Self.calls += 1; let mode=Self.mode, callCount=Self.calls
  let refresh=request.url!.host=="oauth2.googleapis.com"
  if refresh { Self.refreshes += 1 }
  let hook=Self.onRefresh; Self.lock.unlock()
  var status=200, body=""
  if refresh {
   hook?(); body="{\"access_token\":\"fresh-synthetic\",\"expires_in\":3600,\"token_type\":\"Bearer\"}"
  } else if mode=="transient" && callCount < 3 { status=503; body="{}" }
  else if mode=="404" { status=404; body="{}" }
  else if mode=="quota" { status=403; body="{\"error\":{\"reason\":\"userRateLimitExceeded\"}}" }
  else if mode=="expired" && request.url!.path.hasSuffix("/changes") { status=410; body="{}" }
  else if mode=="401" && request.value(forHTTPHeaderField:"Authorization") != "Bearer fresh-synthetic" { status=401; body="{}" }
  else if request.url!.path.hasSuffix("/files") {
   let q=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
   if q.first(where:{$0.name=="q"})?.value != "'root' in parents and trashed = false" { status=400; body="{}" }
   else { body="{\"files\":[{\"id\":\"one\",\"name\":\"Café.txt\",\"mimeType\":\"text/plain\",\"size\":\"3\",\"parents\":[\"root\"]}],\"nextPageToken\":\"page-two\"}" }
  } else if request.url!.path.hasSuffix("/startPageToken") { body="{\"startPageToken\":\"123\"}" }
  else if request.url!.path.hasSuffix("/changes") {
   if mode=="changes-cycle" { let token=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="pageToken"})?.value ?? ""; body="{\"changes\":[],\"nextPageToken\":\"\(token)\"}" }
   else { body="{\"changes\":[{\"fileId\":\"gone\",\"removed\":true}],\"newStartPageToken\":\"124\"}" }
  }
  else { body="{\"id\":\"root\",\"name\":\"Mi unidad\",\"mimeType\":\"application/vnd.google-apps.folder\",\"version\":\"1\"}" }
  let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
  client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
 static func reset(_ mode:String) { lock.lock(); self.mode=mode; calls=0; refreshes=0; onRefresh=nil; lock.unlock() }
}
final class MockResumableUpload: URLProtocol {
 static let lock=NSLock()
 static var total:Int64=0, committed:Int64=0, failRemaining=0, md5="", calls=0
 static func reset(total:Int64,md5:String) { lock.lock(); self.total=total; self.committed=0; self.failRemaining=3; self.md5=md5; self.calls=0; lock.unlock() }
 private static func reply(_ owner:MockResumableUpload,status:Int,headers:[String:String]=[:],body:Data=Data()) {
  let response=HTTPURLResponse(url:owner.request.url!,statusCode:status,httpVersion:nil,headerFields:headers)!; owner.client?.urlProtocol(owner,didReceive:response,cacheStoragePolicy:.notAllowed); if !body.isEmpty { owner.client?.urlProtocol(owner,didLoad:body) }; owner.client?.urlProtocolDidFinishLoading(owner)
 }
 override class func canInit(with request:URLRequest)->Bool { request.url?.host=="www.googleapis.com" }
 override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
 override func startLoading() {
  Self.lock.lock(); Self.calls += 1; let total=Self.total; let committed=Self.committed; let fail=Self.failRemaining > 0; Self.lock.unlock()
  guard let url=request.url else { Self.reply(self,status:400); return }
  if url.path=="/upload/drive/v2/files" && request.httpMethod=="POST" {
   Self.reply(self,status:200,headers:["Location":"https://www.googleapis.com/upload/drive/v2/files/session-1"]); return
  }
  guard url.path.hasSuffix("/session-1") else { Self.reply(self,status:404); return }
  let range=request.value(forHTTPHeaderField:"Content-Range") ?? ""
  if range.hasPrefix("bytes */") {
   if committed>0 { Self.reply(self,status:308,headers:["Range":"bytes=0-\(committed-1)"]) }
   else { Self.reply(self,status:308) }
   return
  }
  var bodyData=request.httpBody
  if bodyData == nil, let stream=request.httpBodyStream {
   stream.open(); defer { stream.close() }
   var collected=Data(); var buffer=[UInt8](repeating:0,count:64*1024)
   while stream.hasBytesAvailable { let read=stream.read(&buffer,maxLength:buffer.count); if read<=0 { break }; collected.append(buffer, count:read) }
   bodyData=collected
  }
  let chunk=Int64(bodyData?.count ?? 0)
  guard chunk>0 else { Self.reply(self,status:400); return }
  Self.lock.lock(); let shouldFail=fail
  if shouldFail { Self.failRemaining -= 1; Self.lock.unlock(); Self.reply(self,status:503,body:Data("temporary network failure".utf8)); return }
  Self.committed += chunk; let newCommitted=Self.committed; Self.lock.unlock()
  if newCommitted<total { Self.reply(self,status:308,headers:["Range":"bytes=0-\(newCommitted-1)"]); return }
  let body=Data("{\"id\":\"upload-file\",\"title\":\"large.bin\",\"mimeType\":\"application/octet-stream\",\"etag\":\"\\\"etag-1\\\"\",\"fileSize\":\"\(total)\",\"md5Checksum\":\"\(Self.md5)\"}".utf8)
  Self.reply(self,status:200,headers:["Content-Type":"application/json"],body:body)
 }
 override func stopLoading() {}
}
@main struct Tests {
 static func main() async throws {
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/nimbo/native/api-tests-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let config=root.appendingPathComponent("rclone.conf")
  func write(expired:Bool=false,refresh:String="synthetic-refresh") throws {
   let value="[Other]\nscope = unchanged\n[GoogleDrive]\nclient_id = synthetic.apps.googleusercontent.com\nclient_secret = GOCSPX-synthetic\nscope = drive\ntoken = {\"access_token\":\"old-synthetic\",\"refresh_token\":\"\(refresh)\",\"expiry\":\"\(expired ? "2020" : "2099")-01-01T00:00:00Z\"}\n"
   try Data(value.utf8).write(to:config,options:.atomic)
  }
  let c=URLSessionConfiguration.ephemeral; c.protocolClasses=[MockGoogle.self]; let session=URLSession(configuration:c)
  var checks:[String]=[]
  func check(_ pass:Bool,_ name:String) throws { guard pass else { throw DriveFailure.invalidResponse }; checks.append(name); print("PASS: "+name) }
  try write(); MockGoogle.reset("normal"); let api=DriveAPI(configuration:config,session:session)
  var multiText=try Data(contentsOf:config); multiText.append(Data("\n[GoogleDrive-2]\nclient_id = second.apps.googleusercontent.com\nclient_secret = GOCSPX-second\nscope = drive.readonly\ntoken = {\"access_token\":\"second\",\"refresh_token\":\"second-refresh\"}\n".utf8)); try multiText.write(to:config,options:.atomic)
  let second=DriveAPI(configuration:config,remoteName:"GoogleDrive-2",session:session)
  try check(!(try await second.permitsWrites()),"Named Drive API selects the requested account section")
  let item=try await api.item("root"); try check(item.isFolder && item.id=="root","Root metadata decoded by stable ID")
  MockGoogle.reset("transient"); let recovered=try await api.item("root"); try check(recovered.id=="root" && MockGoogle.calls==3,"Transient Drive failures retry with bounded backoff"); MockGoogle.reset("normal")
  let page=try await api.children("root"); try check(page.files[0].name=="Café.txt" && page.nextPageToken=="page-two","Unicode listing, parent query and pagination preserved")
  let before=MockGoogle.calls; var rejected=false
  do { _ = try await api.item("../bad?query") } catch { rejected=true }
  try check(rejected && MockGoogle.calls==before,"Unsafe ID rejected before any network request")
  let anchor=try await api.currentAnchor(); let changes=try await api.changes(since:anchor)
  try check(anchor=="123" && changes.changes[0].removed==true && changes.newStartPageToken=="124","Change feed distinguishes removals and continuation anchor")
  MockGoogle.reset("changes-cycle"); rejected=false
  do { _ = try await api.changes(since:"cycle-token") } catch DriveFailure.invalidResponse { rejected=true }
  try check(rejected,"Repeated Drive change cursor is rejected before File Provider can loop")
  MockGoogle.reset("expired"); rejected=false
  do { _ = try await api.changes(since:"old-token") } catch DriveFailure.anchorExpired { rejected=true }
  try check(rejected,"Expired Drive change cursor maps to a File Provider re-enumeration error")
  MockGoogle.reset("404"); rejected=false
  do { _ = try await api.item("gone") } catch DriveFailure.notFound { rejected=true }
  try check(rejected,"HTTP 404 maps to missing item")
  MockGoogle.reset("quota"); rejected=false
  do { _ = try await api.item("root") } catch DriveFailure.quota { rejected=true }
  try check(rejected,"User rate limit maps to retryable quota error")
  MockGoogle.reset("401"); _ = try await api.item("root")
  try check(MockGoogle.refreshes==1,"401 refreshes token and retries metadata request")
  let saved=try String(contentsOf:config,encoding:.utf8)
  let mode=(try FileManager.default.attributesOfItem(atPath:config.path)[.posixPermissions] as! NSNumber).intValue
  try check(saved.contains("fresh-synthetic") && saved.contains("synthetic-refresh") && saved.contains("[Other]\nscope = unchanged") && mode==0o600,"Refresh preserves account configuration and private permissions")
  try write(expired:true); MockGoogle.reset("normal"); let concurrent=DriveAPI(configuration:config,session:session)
  try await withThrowingTaskGroup(of:Void.self) { group in
   for _ in 0..<12 { group.addTask { _ = try await concurrent.item("root") } }
   try await group.waitForAll()
  }
  try check(MockGoogle.refreshes==1,"Concurrent requests share one OAuth refresh")
  try write(expired:true)
  var twoAccountText=try Data(contentsOf:config); twoAccountText.append(Data("\n[GoogleDrive-2]\nclient_id = second.apps.googleusercontent.com\nclient_secret = GOCSPX-second\nscope = drive\ntoken = {\"access_token\":\"old-second\",\"refresh_token\":\"second-refresh\",\"expiry\":\"2020-01-01T00:00:00Z\"}\n".utf8)); try twoAccountText.write(to:config,options:.atomic)
  MockGoogle.reset("normal"); let firstAccount=DriveAPI(configuration:config,session:session), secondAccount=DriveAPI(configuration:config,remoteName:"GoogleDrive-2",session:session)
  try await withThrowingTaskGroup(of:Void.self) { group in
   group.addTask { _ = try await firstAccount.item("root") }; group.addTask { _ = try await secondAccount.item("root") }; try await group.waitForAll()
  }
  let afterTwoRefreshes=try String(contentsOf:config,encoding:.utf8)
  try check(MockGoogle.refreshes==2 && afterTwoRefreshes.components(separatedBy:"fresh-synthetic").count >= 3,"Concurrent account refreshes preserve both runtime token sections")
  try write(expired:true); MockGoogle.reset("normal"); MockGoogle.onRefresh={ try! write(expired:false,refresh:"new-account-refresh") }
  let replaced=DriveAPI(configuration:config,session:session); rejected=false
  do { _ = try await replaced.item("root") } catch DriveFailure.notAuthenticated { rejected=true } catch { throw error }
  let afterReauth=try String(contentsOf:config,encoding:.utf8); try check(rejected && afterReauth.contains("new-account-refresh"),"Reauthorization during refresh cannot be overwritten by old account")
  let large=Data(repeating:0x5a,count:9*1024*1024+123),largeURL=root.appendingPathComponent("large.bin");try large.write(to:largeURL,options:.atomic)
  let fingerprint=try DriveWriteAPI.fingerprint(largeURL);let uploadConfig=URLSessionConfiguration.ephemeral;uploadConfig.protocolClasses=[MockResumableUpload.self]
  let uploadAPI=DriveAPI(configuration:config,session:URLSession(configuration:uploadConfig));let writer=DriveWriteAPI(api:uploadAPI)
  MockResumableUpload.reset(total:fingerprint.size,md5:fingerprint.md5)
  let sessionState=try await writer.beginUpload(id:"upload-file",parent:"root",name:"large.bin",mime:"application/octet-stream",file:largeURL,baseETag:nil)
  var checkpoints:[Int64]=[];var interrupted=false
  do { _=try await writer.upload(largeURL,session:sessionState,checkpoint:{checkpoints.append($0.offset)}) } catch DriveFailure.unavailable { interrupted=true }
  try check(interrupted,"Mid-transfer network failure is surfaced without discarding the resumable session")
  let resumed=try await writer.upload(largeURL,session:sessionState,checkpoint:{checkpoints.append($0.offset)})
  try check(resumed.object.md5Checksum==fingerprint.md5 && resumed.object.size==String(fingerprint.size),"Resuming a failed upload returns the complete Drive object")
  try check(checkpoints.contains(8*1024*1024) && MockResumableUpload.committed==fingerprint.size,"Resume probes the server offset and does not resend the acknowledged first chunk")
  let report:[String:Any]=["status":"PASS","count":checks.count,"checks":checks,"synthetic_only":true]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/NATIVE_DRIVE_API_TESTS.json"))
 }
}
