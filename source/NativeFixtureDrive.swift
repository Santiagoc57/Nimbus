#if NIMBO_TESTING
import Foundation

/// Local synthetic remote for exercising the real File Provider callbacks.
/// No credentials or network. Excluded from release builds.
actor NativeFixtureDrive:NativeDriveWriting {
    private struct Upload:Codable {let name:String,mime:String,parent:String?}
    private struct State:Codable {var objects:[String:DriveObject];var uploads:[String:Upload]=[:]}
    private let directory:URL
    private var state:State
    static let capabilities=DriveObject.Capabilities(canDownload:true,canEdit:true,canTrash:true,canAddChildren:true,canRename:true)
    init(directory:URL,seed:[String:DriveObject])throws {
        self.directory=directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let index=directory.appendingPathComponent("remote.json")
        if FileManager.default.fileExists(atPath:index.path){state=try JSONDecoder().decode(State.self,from:Data(contentsOf:index))}
        else{state=State(objects:seed.mapValues{var v=$0;v.capabilities=Self.capabilities;return v})}
    }
    private func save()throws {try JSONEncoder().encode(state).write(to:directory.appendingPathComponent("remote.json"),options:.atomic)}
    func all()->[DriveObject] {Array(state.objects.values)}
    func merge(_ values:[DriveObject]) throws {
        for value in values { var object=value; object.capabilities=Self.capabilities; state.objects[value.id]=object }
        try save()
    }
    func revision(_ id:String)throws->DriveRevision {
        guard let object=state.objects[id] else{throw DriveFailure.notFound}
        return DriveRevision(object:object,etag:"\"fixture-\(object.version ?? "0")\"")
    }
    func allocateID()->String {"fixture-"+UUID().uuidString}
    private func parent(_ id:String?)throws {
        guard let id,let object=state.objects[id],object.isFolder,object.trashed != true else{throw DriveFailure.notFound}
    }
    func createFolder(id:String,parent:String,name:String)throws->DriveRevision {
        try self.parent(parent)
        if state.objects[id] != nil{return try revision(id)}
        state.objects[id]=DriveObject(id:id,name:name,mimeType:"application/vnd.google-apps.folder",version:"1",parents:[parent],capabilities:Self.capabilities)
        try save();return try revision(id)
    }
    func updateMetadata(_ id:String,etag:String,name:String?,parent:String?,trashed:Bool?)throws->DriveRevision {
        let current=try revision(id);guard current.etag==etag else{throw DriveFailure.conflict}
        if let parent{try self.parent(parent)}
        let old=current.object
        state.objects[id]=DriveObject(id:id,name:name ?? old.name,mimeType:old.mimeType,size:old.size,modifiedTime:ISO8601DateFormatter().string(from:Date()),createdTime:old.createdTime,version:String((Int(old.version ?? "0") ?? 0)+1),md5Checksum:old.md5Checksum,parents:parent.map{[$0]} ?? old.parents,trashed:trashed ?? old.trashed,capabilities:Self.capabilities,webViewLink:old.webViewLink,resourceKey:old.resourceKey,properties:old.properties)
        try save();return try revision(id)
    }
    func beginUpload(id:String,parent:String?,name:String,mime:String,file:URL,baseETag:String?)throws->DriveUploadSession {
        try self.parent(parent)
        if let baseETag{guard try revision(id).etag==baseETag else{throw DriveFailure.conflict}}
        let fingerprint=try DriveWriteAPI.fingerprint(file)
        let url=URL(string:"https://www.googleapis.com/upload/drive/fixture/"+UUID().uuidString)!
        state.uploads[url.absoluteString]=Upload(name:name,mime:mime,parent:parent);try save()
        return DriveUploadSession(fileID:id,sessionURL:url,baseETag:baseETag,size:fingerprint.size,md5:fingerprint.md5,offset:0)
    }
    func upload(_ file:URL,session:DriveUploadSession,checkpoint:@escaping(DriveUploadSession)throws->Void,progress:@escaping(Int64,Int64)->Void)throws->DriveRevision {
        guard let upload=state.uploads[session.sessionURL.absoluteString] else{throw DriveFailure.notFound}
        if let existing=state.objects[session.fileID],existing.md5Checksum==session.md5{return try revision(session.fileID)}
        if let tag=session.baseETag{guard try revision(session.fileID).etag==tag else{throw DriveFailure.conflict}}
        let fingerprint=try DriveWriteAPI.fingerprint(file)
        guard fingerprint.md5==session.md5,fingerprint.size==session.size else{throw DriveFailure.invalidResponse}
        try DriveAPI.validateID(session.fileID)
        try Data(contentsOf:file).write(to:directory.appendingPathComponent(session.fileID+".bytes"),options:.atomic)
        let version=String((Int(state.objects[session.fileID]?.version ?? "0") ?? 0)+1)
        state.objects[session.fileID]=DriveObject(id:session.fileID,name:upload.name,mimeType:upload.mime,size:String(session.size),modifiedTime:ISO8601DateFormatter().string(from:Date()),version:version,md5Checksum:session.md5,parents:upload.parent.map{[$0]},capabilities:Self.capabilities)
        try save();var complete=session;complete.offset=session.size;try checkpoint(complete);progress(session.size,session.size)
        return try revision(session.fileID)
    }
    func fetch(_ id:String,to url:URL)throws {
        try DriveAPI.validateID(id)
        let file=directory.appendingPathComponent(id+".bytes")
        let data:Data
        if FileManager.default.fileExists(atPath:file.path){data=try Data(contentsOf:file)}
        else{data=Data((id=="hello" ? "Nimbo native placeholder.\n":"Archivo de prueba con acentos.\n").utf8)}
        try data.write(to:url,options:.atomic)
    }
}
#endif
