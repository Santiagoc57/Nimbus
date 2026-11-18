import Foundation
actor AvailabilitySource:NativeAutoUnsyncSource {
 var items:[NativeAvailabilityCandidate]=[]
 var local:[String:NativeLocalAvailability]=[:]
 var refused=Set<String>(),evicted:[String]=[]
 var pages=0
 var hold=false,entered=false
 var arrival:CheckedContinuation<Void,Never>?,release:CheckedContinuation<Void,Never>?
 func blockNext(){hold=true;entered=false}
 func waitForLocal() async{if entered{return};await withCheckedContinuation{arrival=$0}}
 func resumeLocal(){release?.resume();release=nil}
 func seed(_ ids:[String],at date:Date,pinned:Set<String>=[],download:Date?=nil) {
  items=ids.map{NativeAvailabilityCandidate(id:$0,pinned:pinned.contains($0),downloadedAt:download)}
  local=Dictionary(uniqueKeysWithValues:ids.map{($0,NativeLocalAvailability(identity:$0,accessed:date,modified:date,created:date))})
 }
 func refuse(_ id:String){refused.insert(id)}
 func touch(_ id:String,at date:Date){local[id]=NativeLocalAvailability(identity:id,accessed:date,modified:date,created:date)}
 func availabilityPage(after:String?) async throws->NativeAvailabilityPage {pages+=1;return NativeAvailabilityPage(items:items,next:nil)}
 func localAvailability(_ id:String) async throws->NativeLocalAvailability?{
  if hold{hold=false;entered=true;arrival?.resume();arrival=nil;await withCheckedContinuation{release=$0}}
  return local[id]
 }
 func evictAutomatically(_ id:String) async throws {
  if refused.contains(id){throw CocoaError(.fileWriteNoPermission)}
  evicted.append(id);local.removeValue(forKey:id)
 }
}
@main struct AutoUnsyncTests {
 static func main() async throws {
  let fm=FileManager.default,now=Date(timeIntervalSince1970:1_700_000_000)
  let directory=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("work/nimbo/native/auto-tests-"+UUID().uuidString)
  let file=directory.appendingPathComponent("state.json"),source=AvailabilitySource()
  let engine=NativeAutoUnsync(file:file,source:source)
  var checks:[String]=[]
  func check(_ test:Bool,_ name:String)throws{guard test else{throw CocoaError(.fileReadCorruptFile)};checks.append(name);print("PASS: "+name)}
  let disabled=try await engine.run(now:now)
  let pages=await source.pages
  try check(disabled.disabled && pages==0,"Disabled default performs no enumeration or eviction")
  await source.seed(["old","pinned","dirty","recent"],at:now.addingTimeInterval(-10*86400),pinned:["pinned"])
  await source.refuse("dirty")
  try await engine.configure(enabled:true,days:1)
  let initial=try await engine.run(now:now)
  try check(initial.evicted==0 && initial.protected==1,"First observation grants the full grace period even to old files")
  await source.touch("recent",at:now.addingTimeInterval(86400))
  let next=try await engine.run(now:now.addingTimeInterval(86400+1))
  try check(next.evicted==1 && next.deferred==1 && next.protected==1,"Only old unpinned content is evicted; refused dirty content remains pending")
  let remaining=await source.local
  try check(remaining["recent"] != nil && remaining["dirty"] != nil && remaining["pinned"] != nil,"Recent, dirty and pinned bytes remain represented after the pass")
  let restored=NativeAutoUnsync(file:file,source:source)
  try check(try await restored.settings()==NativeAutoUnsyncSettings(enabled:true,days:1),"Settings survive host restart")
  let saved=try await restored.lastReport();try check(saved?.evicted==1 && saved?.deferred==1,"Last completion summary survives restart")
  let second=AvailabilitySource();await second.seed(["download"],at:now.addingTimeInterval(-10*86400),download:now.addingTimeInterval(86399))
  let downloadEngine=NativeAutoUnsync(file:directory.appendingPathComponent("download.json"),source:second)
  try await downloadEngine.configure(enabled:true,days:1);_ = try await downloadEngine.run(now:now)
  let download=try await downloadEngine.run(now:now.addingTimeInterval(86401))
  try check(download.evicted==0,"A fresh download resets eligibility even when file dates are old")
  try await restored.configure(enabled:false,days:7)
  try check(try await restored.run(now:now.addingTimeInterval(20*86400)).disabled,"Disabling prevents later automatic passes")
  let permissions=try fm.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber
  try check(permissions?.intValue==0o600,"Availability history uses private file permissions")
  let concurrent=AvailabilitySource();await concurrent.seed(["race"],at:now)
  let concurrentEngine=NativeAutoUnsync(file:directory.appendingPathComponent("concurrent.json"),source:concurrent)
  try await concurrentEngine.configure(enabled:true,days:1);_ = try await concurrentEngine.run(now:now)
  await concurrent.blockNext()
  let pending=Task{try await concurrentEngine.run(now:now.addingTimeInterval(2*86400))}
  await concurrent.waitForLocal();try await concurrentEngine.configure(enabled:false,days:1);await concurrent.resumeLocal()
  let stopped=try await pending.value
  try check(stopped.disabled && stopped.evicted==0,"Disabling during an in-flight metadata lookup prevents eviction")
  try await concurrentEngine.configure(enabled:true,days:1);await concurrent.blockNext()
  let cancelled=Task{try await concurrentEngine.run(now:now.addingTimeInterval(2*86400))}
  await concurrent.waitForLocal();cancelled.cancel();await concurrent.resumeLocal()
  var cancellation=false;do{_ = try await cancelled.value}catch is CancellationError{cancellation=true}
  let cancelledEvictions=await concurrent.evicted
  try check(cancellation && cancelledEvictions.isEmpty,"Cancellation during a lookup prevents the subsequent eviction")
  let invalid=directory.appendingPathComponent("invalid.json")
  try Data("{\"settings\":{\"enabled\":true,\"days\":0},\"observations\":{}}".utf8).write(to:invalid)
  let invalidSource=AvailabilitySource(),invalidEngine=NativeAutoUnsync(file:invalid,source:invalidSource)
  var rejected=false;do{_ = try await invalidEngine.run(now:now)}catch{rejected=true}
  let invalidQueries=await invalidSource.pages
  try check(rejected && invalidQueries==0,"Invalid persisted interval fails closed before contacting the provider")
  let report:[String:Any]=["status":"PASS","count":checks.count,"checks":checks,"synthetic_only":true]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/NATIVE_AUTO_UNSYNC_TESTS.json"))
 }
}
