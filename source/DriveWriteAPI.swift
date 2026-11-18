import Foundation
import CryptoKit

struct DriveRevision:Codable {
    let object:DriveObject
    let etag:String
}
private struct DriveV2File:Decodable {
    let id:String, title:String, mimeType:String, etag:String
    let fileSize:String?, modifiedDate:String?, createdDate:String?, version:String?, md5Checksum:String?
    let parents:[Parent]?, labels:Labels?, capabilities:DriveObject.Capabilities?
    struct Property: Decodable { let key: String; let value: String?; let visibility: String? }
    let properties: [Property]?
    struct Parent:Decodable {let id:String}
    struct Labels:Decodable {let trashed:Bool?}
    var revision:DriveRevision {DriveRevision(object:DriveObject(id:id,name:title,mimeType:mimeType,size:fileSize,modifiedTime:modifiedDate,createdTime:createdDate,version:version,md5Checksum:md5Checksum,parents:parents?.map{$0.id},trashed:labels?.trashed,capabilities:capabilities,properties:properties?.reduce(into: [:]) { if $1.visibility == "PUBLIC" { $0[$1.key] = $1.value } }).projected(),etag:etag)}
}
struct DriveUploadSession:Codable {
    let fileID:String
    let sessionURL:URL
    let baseETag:String?
    let size:Int64
    let md5:String
    var offset:Int64
}

/// Mutations use v2 because the real-account conditional probe showed v3
/// accepting stale If-Match requests. No overwrite silently drops its condition.
protocol NativeDriveWriting:Sendable {
    func revision(_ id:String) async throws->DriveRevision
    func allocateID() async throws->String
    func createFolder(id:String,parent:String,name:String) async throws->DriveRevision
    func updateMetadata(_ id:String,etag:String,name:String?,parent:String?,trashed:Bool?) async throws->DriveRevision
    func beginUpload(id:String,parent:String?,name:String,mime:String,file:URL,baseETag:String?) async throws->DriveUploadSession
    func upload(_ file:URL,session:DriveUploadSession,checkpoint:@escaping(DriveUploadSession)throws->Void,progress:@escaping(Int64,Int64)->Void) async throws->DriveRevision
}
actor DriveWriteAPI:NativeDriveWriting {
    let api:DriveAPI
    static let fields="id,title,mimeType,etag,fileSize,modifiedDate,createdDate,version,md5Checksum,parents(id),properties(key,value,visibility),labels(trashed),capabilities(canDownload,canEdit,canTrash,canAddChildren,canRename)"
    init(api:DriveAPI){self.api=api}
    private func url(_ path:String,_ query:[URLQueryItem]=[])throws->URL {
        var c=URLComponents();c.scheme="https";c.host="www.googleapis.com";c.path=path;c.queryItems=query
        guard let result=c.url else{throw DriveFailure.invalidResponse};return result
    }
    private func json(_ value:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:value)}
    private func checkedTag(_ etag:String)throws->String {
        guard etag.hasPrefix("\""),etag.hasSuffix("\""),etag.utf8.count<2048,!etag.contains("\r"),!etag.contains("\n") else{throw DriveFailure.invalidResponse}
        return etag
    }
    private func decode(_ data:Data)throws->DriveRevision {
        let value=try JSONDecoder().decode(DriveV2File.self,from:data)
        try DriveAPI.validateID(value.id); _ = try checkedTag(value.etag)
        return value.revision
    }
    func revision(_ id:String) async throws->DriveRevision {
        try DriveAPI.validateID(id)
        let (data,response)=try await api.send(url("/drive/v2/files/"+id,[.init(name:"fields",value:Self.fields),.init(name:"supportsAllDrives",value:"true")]),method:"GET")
        try DriveAPI.validate(response.statusCode,data:data);return try decode(data)
    }
    func allocateID() async throws->String {
        struct IDs:Decodable{let ids:[String]}
        let (data,response)=try await api.send(url("/drive/v3/files/generateIds",[.init(name:"count",value:"1"),.init(name:"space",value:"drive")]),method:"GET")
        try DriveAPI.validate(response.statusCode,data:data)
        guard let id=try JSONDecoder().decode(IDs.self,from:data).ids.first else{throw DriveFailure.invalidResponse}
        try DriveAPI.validateID(id);return id
    }
    func createFolder(id:String,parent:String,name:String) async throws->DriveRevision {
        try await createFolder(id: id, parent: parent, name: name, split: nil)
    }
    func createFolder(id: String, parent: String, name: String, split: DriveSplitLayout?) async throws -> DriveRevision {
        try DriveAPI.validateID(id);try DriveAPI.validateID(parent)
        var metadata:[String:Any]=["id":id,"title":name,"mimeType":"application/vnd.google-apps.folder","parents":[["id":parent]]]
        if let split { metadata["properties"] = split.properties.map { ["key":$0.key, "value":$0.value, "visibility":"PUBLIC"] } }
        let (data,response)=try await api.send(url("/drive/v2/files",[.init(name:"fields",value:Self.fields)]),method:"POST",headers:["Content-Type":"application/json"],body:json(metadata))
        if response.statusCode==409 {
            // A preallocated ID is never recycled to create a second folder.
            let existing=try await revision(id)
            guard existing.object.splitLayout == split,existing.object.isFolder,existing.object.name==name,existing.object.parents?.contains(parent)==true,existing.object.trashed != true else{throw DriveFailure.conflict}
            return existing
        }
        try DriveAPI.validate(response.statusCode,data:data);return try decode(data)
    }
    func updateMetadata(_ id:String,etag:String,name:String?=nil,parent:String?=nil,trashed:Bool?=nil) async throws->DriveRevision {
        try DriveAPI.validateID(id)
        var metadata:[String:Any]=[:]
        if let name{metadata["title"]=name}
        if let parent{try DriveAPI.validateID(parent);metadata["parents"]=[["id":parent]]}
        if let trashed{metadata["labels"]=["trashed":trashed]}
        let (data,response)=try await api.send(url("/drive/v2/files/"+id,[.init(name:"fields",value:Self.fields),.init(name:"supportsAllDrives",value:"true")]),method:"PATCH",headers:["Content-Type":"application/json","If-Match":checkedTag(etag)],body:json(metadata))
        try DriveAPI.validate(response.statusCode,data:data);return try decode(data)
    }
    /// Switch the logical file to a fully uploaded generation under the same
    /// Drive ID. Carry unrelated public and private properties through the
    /// array update. The same ETag protects both the read and the patch.
    func commitSplit(_ id: String, etag: String, name: String, parent: String, layout: DriveSplitLayout) async throws -> DriveRevision {
        try DriveAPI.validateID(id)
        try DriveAPI.validateID(parent)
        guard layout.generation != nil else { throw DriveFailure.invalidResponse }
        let endpoint = try url("/drive/v2/files/" + id, [.init(name: "fields", value: Self.fields), .init(name: "supportsAllDrives", value: "true")])
        let (before, response) = try await api.send(endpoint, method: "GET")
        try DriveAPI.validate(response.statusCode, data: before)
        let old = try JSONDecoder().decode(DriveV2File.self, from: before)
        guard old.etag == etag, old.labels?.trashed != true, old.revision.object.splitLayout != nil else { throw DriveFailure.conflict }
        let replacement = layout.properties
        var properties = (old.properties ?? []).compactMap { field -> [String: String]? in
            guard !(field.visibility == "PUBLIC" && replacement[field.key] != nil), let value = field.value else { return nil }
            return ["key": field.key, "value": value, "visibility": field.visibility ?? "PRIVATE"]
        }
        properties += replacement.map { ["key": $0.key, "value": $0.value, "visibility": "PUBLIC"] }
        var metadata: [String: Any] = ["properties": properties]
        if name != old.title { metadata["title"] = name }
        if old.parents?.map({ $0.id }) != [parent] { metadata["parents"] = [["id": parent]] }
        let (bytes, reply) = try await api.send(endpoint, method: "PATCH",
            headers: ["Content-Type": "application/json", "If-Match": checkedTag(etag)], body: json(metadata))
        try DriveAPI.validate(reply.statusCode, data: bytes)
        let result = try decode(bytes)
        guard result.object.id == id, result.object.name == name, result.object.parents == [parent],
              result.object.splitLayout == layout else { throw DriveFailure.invalidResponse }
        return result
    }
    static func fingerprint(_ file:URL)throws->(size:Int64,md5:String) {
        let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true else{throw DriveFailure.denied}
        let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()}
        var hash=Insecure.MD5(),count:Int64=0
        while let block=try handle.read(upToCount:1024*1024),!block.isEmpty {try Task.checkCancellation();hash.update(data:block);count+=Int64(block.count)}
        return (count,hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
    /// Persist the returned session in a private journal before sending content.
    /// The source must be an immutable staged copy retained until completion.
    func beginUpload(id:String,parent:String?,name:String,mime:String,file:URL,baseETag:String?) async throws->DriveUploadSession {
        try DriveAPI.validateID(id)
        let fingerprint=try Self.fingerprint(file)
        var metadata:[String:Any]=["title":name,"mimeType":mime]
        if let parent{try DriveAPI.validateID(parent);metadata["parents"]=[["id":parent]]}
        if baseETag==nil{metadata["id"]=id;guard parent != nil else{throw DriveFailure.invalidResponse}}
        var headers=["Content-Type":"application/json","X-Upload-Content-Type":mime,"X-Upload-Content-Length":String(fingerprint.size)]
        if let baseETag{headers["If-Match"]=try checkedTag(baseETag)}
        let path="/upload/drive/v2/files"+(baseETag==nil ? "":"/"+id)
        let (data,response)=try await api.send(url(path,[.init(name:"uploadType",value:"resumable"),.init(name:"fields",value:Self.fields),.init(name:"supportsAllDrives",value:"true")]),method:baseETag==nil ? "POST":"PUT",headers:headers,body:json(metadata))
        try DriveAPI.validate(response.statusCode,data:data)
        guard let location=response.value(forHTTPHeaderField:"Location"),let session=URL(string:location),session.scheme=="https",session.host=="www.googleapis.com",session.path.hasPrefix("/upload/drive/") else{throw DriveFailure.invalidResponse}
        return DriveUploadSession(fileID:id,sessionURL:session,baseETag:baseETag,size:fingerprint.size,md5:fingerprint.md5,offset:0)
    }
    private func offset(_ response:HTTPURLResponse,total:Int64)throws->Int64 {
        guard let range=response.value(forHTTPHeaderField:"Range") else{return 0}
        guard range.hasPrefix("bytes=0-"),let end=Int64(range.dropFirst(8)),end>=0,end<total else{throw DriveFailure.invalidResponse}
        return end+1
    }
    private func completed(_ data:Data,state:DriveUploadSession)throws->DriveRevision {
        let result=try decode(data)
        guard result.object.id==state.fileID,result.object.md5Checksum==state.md5,result.object.size==String(state.size) else{throw DriveFailure.invalidResponse}
        return result
    }
    func upload(_ file:URL,session initial:DriveUploadSession,checkpoint:@escaping(DriveUploadSession)throws->Void,progress:@escaping(Int64,Int64)->Void={_,_ in}) async throws->DriveRevision {
        let fingerprint=try Self.fingerprint(file)
        guard fingerprint.size==initial.size,fingerprint.md5==initial.md5 else{throw DriveFailure.conflict}
        var state=initial
        var condition:[String:String]=[:]
        if let tag=state.baseETag{condition["If-Match"]=try checkedTag(tag)}
        // Ask the server even on first use. An interrupted final reply may have
        // committed already; a 200 here resolves that uncertainty without a rewrite.
        var query=condition;query["Content-Range"]="bytes */\(state.size)";query["Content-Length"]="0"
        let (statusData,status)=try await api.send(state.sessionURL,method:"PUT",headers:query,body:Data())
        if status.statusCode==200 || status.statusCode==201{return try completed(statusData,state:state)}
        if status.statusCode != 308 {try DriveAPI.validate(status.statusCode,data:statusData);throw DriveFailure.invalidResponse}
        state.offset=try offset(status,total:state.size);try checkpoint(state)
        let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()}
        let rate = await api.transferRate(.upload)
        let chunk = NativeBandwidthClock.chunkBytes(rate: rate)
        repeat {
            try Task.checkCancellation()
            try handle.seek(toOffset:UInt64(state.offset))
            let data=try handle.read(upToCount:Int(min(chunk,state.size-state.offset))) ?? Data()
            guard !data.isEmpty || state.size==0 else{throw DriveFailure.invalidResponse}
            var headers=condition;headers["Content-Type"]="application/octet-stream";headers["Content-Length"]=String(data.count)
            headers["Content-Range"]=state.size==0 ? "bytes */0" : "bytes \(state.offset)-\(state.offset+Int64(data.count)-1)/\(state.size)"
            try await NativeBandwidthClock.shared.reserve(bytes: Int64(data.count), rate: rate, direction: .upload)
            let (reply,response)=try await api.send(state.sessionURL,method:"PUT",headers:headers,body:data)
            if response.statusCode==200 || response.statusCode==201 {let result=try completed(reply,state:state);progress(state.size,state.size);return result}
            guard response.statusCode==308 else{try DriveAPI.validate(response.statusCode,data:reply);throw DriveFailure.invalidResponse}
            let next=try offset(response,total:state.size)
            guard next>state.offset,next<=state.offset+Int64(data.count) else{throw DriveFailure.invalidResponse}
            state.offset=next;try checkpoint(state);progress(next,state.size)
        } while state.offset<state.size
        throw DriveFailure.invalidResponse
    }
}
