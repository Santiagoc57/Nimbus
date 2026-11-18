import Foundation

@objc protocol NimboNativeConnection {
    func setTransferLimits(download: Int, upload: Int, reply: @escaping (NSError?) -> Void)
    func setFinderTransferSettings(download: Int, upload: Int, segmentMB: Int, reply: @escaping (NSError?) -> Void)
    func setShowLinkActions(_ enabled: Bool, reply: @escaping (NSError?) -> Void)
    func configure(_ data:Data,reply:@escaping (NSError?)->Void)
    func configureRoot(_ data:Data,rootID:String,reply:@escaping (NSError?)->Void)
    func configureAccount(_ data:Data,remoteName:String,reply:@escaping (NSError?)->Void)
    func configureRootAccount(_ data:Data,rootID:String,remoteName:String,reply:@escaping (NSError?)->Void)
    func browserLink(_ identifier: String, reply: @escaping (String?, NSError?) -> Void)
    func status(reply:@escaping (String?,NSError?)->Void)
    func availabilityPage(after:String?,reply:@escaping(Data?,NSError?)->Void)
    func conflicts(reply:@escaping(Data?,NSError?)->Void)
    func acknowledgeConflict(_ identifier:String,reply:@escaping (NSError?)->Void)
    func resolveConflict(_ identifier:String,action:String,reply:@escaping (NSError?)->Void)
    func canAutomaticallyEvict(_ identifier:String,reply:@escaping(Bool,NSError?)->Void)
    func setPinned(_ identifier:String,value:Bool,limit:Int64,reply:@escaping (NSError?)->Void)
    /// Files eligible for a manual release, after applying the unpin rule.
    /// Folder results exclude children explicitly kept offline.
    func evictionCandidates(_ identifier:String,reply:@escaping (Data?,NSError?)->Void)
    func prepareDownload(_ identifier:String,reply:@escaping (Data?,NSError?)->Void)
    /// JSON array of item ids the user asked to download (Sincronizar ahora /
    /// Conservar) that macOS has not materialized yet.
    func pendingDownloads(reply:@escaping (Data?,NSError?)->Void)
    func downloadIsPending(_ identifier:String,reply:@escaping (Bool,NSError?)->Void)
    /// Messages for evictions that macOS refused (open file, pending upload).
    func takeEvictionMessages(reply:@escaping (Data?,NSError?)->Void)
    #if NIMBO_TESTING
    func configureFixture(reply:@escaping (NSError?)->Void)
    #endif
}
let nimboNativeServiceName = "local.nimbo.connection"

struct NativeAvailabilityCandidate:Codable {
    let id:String
    let pinned:Bool
    let downloadedAt:Date?
}
struct NativeEvictionCandidate:Codable {
    let id:String
    let name:String
}
struct NativeAvailabilityPage:Codable {
    let items:[NativeAvailabilityCandidate]
    let next:String?
}
struct NativeConflict:Codable,Equatable {
    let id:String
    let name:String
    let parent:String?
    let kind:String
    let detail:String?
    let remoteID:String?
    init(id:String,name:String,parent:String?,kind:String="content",detail:String?=nil,remoteID:String?=nil) {
        self.id=id;self.name=name;self.parent=parent;self.kind=kind;self.detail=detail;self.remoteID=remoteID
    }
}

/// Darwin notification the File Provider extension posts after a download
/// request, so the app materializes the item right away.
let nimboMaterializeNotification = "local.nimbo.cloudsearch.materialize"
let nimboEvictionFailedNotification = "local.nimbo.cloudsearch.eviction-failed"
