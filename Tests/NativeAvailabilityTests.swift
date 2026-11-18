import Foundation
import FileProvider
@main struct AvailabilityTests {
 static func main()throws {
  var checks:[String]=[]
  func check(_ condition:Bool,_ text:String)throws{guard condition else{throw NSError(domain:"AvailabilityTests",code:1,userInfo:[NSLocalizedDescriptionKey:text])};checks.append(text);print("PASS: "+text)}
  let pinned=NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.nonEvictable.rawValue)
  let dirty=NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.unsyncedEdits.rawValue)
  let busy=NSError(domain:NSPOSIXErrorDomain,code:16)
  func group(_ children:[NSError])->NSError{NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.nonEvictableChildren.rawValue,userInfo:[NSMultipleUnderlyingErrorsKey:children])}
  try check(NativeClient.waitingForUnpin(group([pinned,group([pinned])])),"Nested pin-propagation errors can be retried")
  try check(!NativeClient.waitingForUnpin(group([pinned,dirty])),"Dirty child stops eviction retries instead of disguising pending edits")
  try check(!NativeClient.waitingForUnpin(group([busy])),"Open-file child stops eviction retries")
  try check(!NativeClient.waitingForUnpin(group([])),"Unknown partial eviction error is not retried blindly")
  try check(NativeClient.evictionFailure([],attemptedCount:3)==nil,"Successful releases do not invent an error")
  try check(NativeClient.evictionFailure([("open.txt",busy)],attemptedCount:1) === busy,"An open-file error retains its POSIX cause instead of becoming a pin error")
  try check(NativeClient.evictionFailure([("edited.txt",dirty)],attemptedCount:1) === dirty,"Pending edits retain their precise File Provider error")
  let partial=NativeClient.evictionFailure([("edited.txt",dirty)],attemptedCount:3)!
  try check(partial.code==NSFileProviderError.nonEvictableChildren.rawValue && partial.underlyingErrors.count==1 && (partial.underlyingErrors[0] as NSError).code==dirty.code,"Partial folder release preserves the failed child's cause")
  let mixed=NativeClient.evictionFailure([("open.txt",busy),("edited.txt",dirty)],attemptedCount:3)!
  try check(mixed.underlyingErrors.count==2 && !NativeClient.waitingForUnpin(mixed),"Mixed open and dirty failures remain distinct and are not retried as pins")
  let report:[String:Any]=["status":"PASS","count":checks.count,"checks":checks]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"outputs/Nimbo/NATIVE_AVAILABILITY_TESTS.json"))
 }
}
