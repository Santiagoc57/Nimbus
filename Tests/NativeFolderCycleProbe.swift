#if NATIVE_FOLDER_CYCLE_PROBE
import Foundation
import Darwin
import FileProvider

/// Creates only a UUID-owned folder and three small synthetic files. Uses the
/// installed host command, not simulated provider flags or GUI automation.
@main struct NativeFolderCycleProbe {
    static func item(_ name:String,parent:String,api:DriveAPI) async throws -> DriveObject {
        var url=URLComponents(string:"https://www.googleapis.com/drive/v3/files")!
        url.queryItems=[.init(name:"q",value:"'\(parent)' in parents and name = '\(name)' and trashed = false"),.init(name:"fields",value:"files(\(DriveAPI.fields))"),.init(name:"pageSize",value:"10")]
        for _ in 0..<60 {
            let (data,response)=try await api.send(url.url!,method:"GET")
            try DriveAPI.validate(response.statusCode,data:data)
            let files=try JSONDecoder().decode(DrivePage.self,from:data).files
            try NativeFinderCycleProbe.require(files.count<=1)
            if let file=files.first{return file}
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        throw DriveFailure.unavailable
    }
    static func main() async {
        let work=URL(fileURLWithPath:"work/nimbo/native-folder-cycle-"+UUID().uuidString)
        var report:[String:Any]=["result":"FAIL"],folderID:String?,writer:DriveWriteAPI?,phase="setup",openHandle:FileHandle?
        let fm=FileManager.default
        do {
            guard CommandLine.arguments.count==4 else{throw DriveFailure.invalidResponse}
            let support=URL(fileURLWithPath:CommandLine.arguments[1]),host=URL(fileURLWithPath:CommandLine.arguments[2]),mount=URL(fileURLWithPath:CommandLine.arguments[3])
            guard mount.lastPathComponent.hasPrefix("Nimbo-GoogleDrive") else{throw DriveFailure.invalidResponse}
            try fm.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let api=DriveAPI(configuration:support.appendingPathComponent(".rclone-runtime.conf"))
            writer=DriveWriteAPI(api:api)
            let name="Nimbo-folder-probe-"+UUID().uuidString,folder=mount.appendingPathComponent(name),nested=folder.appendingPathComponent("Nested")
            try JSONSerialization.data(withJSONObject:["path":folder.path,"synthetic":true]).write(to:work.appendingPathComponent("cleanup.json"))
            phase="create-folder"
            try fm.createDirectory(at:nested,withIntermediateDirectories:true)
            let remoteFolder=try await item(name,parent:"root",api:api);folderID=remoteFolder.id
            let remoteNested=try await item("Nested",parent:remoteFolder.id,api:api)
            let files=[folder.appendingPathComponent("kept.txt"),folder.appendingPathComponent("release.txt"),nested.appendingPathComponent("nested.txt")]
            let payload=Data(String(repeating:"Nimbo synthetic nested folder fixture.\n",count:80).utf8)
            let expected=work.appendingPathComponent("expected.txt");try payload.write(to:expected)
            let checksum=try DriveWriteAPI.fingerprint(expected).md5
            phase="upload-files"
            for (i,file) in files.enumerated() {
                try await NativeFinderCycleProbe.coordinateWrite(file,bytes:payload)
                let remote=try await item(file.lastPathComponent,parent:i==2 ? remoteNested.id : remoteFolder.id,api:api)
                try NativeFinderCycleProbe.require(remote.md5Checksum==checksum)
            }
            report["uploadedAndVerifiedFiles"]=files.count
            var states:[[String:Any]]=[]
            func action(_ action:String,_ file:URL) throws {
                _ = try NativeFinderCycleProbe.state(action,file:file,host:host,work:work)
            }
            func verify(_ label:String,_ clouds:[Bool],_ pins:[Bool]) async throws {
                var rows:[[String:Any]]=[]
                for (i,file) in files.enumerated() {
                    var state=try await NativeFinderCycleProbe.awaitState(dataless:clouds[i],pinned:pins[i],file:file,host:host,work:work)
                    state.removeValue(forKey:"id");state["fixtureFile"]=file.lastPathComponent
                    rows.append(state)
                }
                states.append(["phase":label,"files":rows]);report["states"]=states
            }
            phase="folder-unsync";try action("unsync",folder)
            try await verify(phase,[true,true,true],[false,false,false])
            phase="recursive-sync";try action("sync",folder)
            try await verify(phase,[false,false,false],[false,false,false])
            phase="partial-release-open-child"
            let reader=try FileHandle(forReadingFrom:files[0]);openHandle=reader
            let errorPath=work.appendingPathComponent("command-error.json");try? fm.removeItem(at:errorPath)
            var rejected=false
            do {try action("unsync",folder)} catch {rejected=true}
            try NativeFinderCycleProbe.require(rejected)
            let releaseError=try JSONSerialization.jsonObject(with:Data(contentsOf:errorPath)) as? [String:Any]
            try NativeFinderCycleProbe.require(releaseError?["domain"] as? String==NSFileProviderErrorDomain && releaseError?["code"] as? Int==NSFileProviderError.nonEvictableChildren.rawValue)
            try await verify(phase,[false,true,true],[false,false,false])
            try NativeFinderCycleProbe.require(try reader.readToEnd()==payload)
            report["partialReleaseError"]=releaseError
            report["openChildContentPreserved"]=true
            try reader.close();openHandle=nil
            phase="partial-release-retry";try action("unsync",folder)
            try await verify(phase,[true,true,true],[false,false,false])
            phase="preserve-explicit-child";try action("pin",files[0]);try action("unsync",folder)
            try await verify(phase,[false,true,true],[true,false,false])
            phase="pin-folder";try action("pin",folder)
            try await verify(phase,[false,false,false],[true,true,true])
            phase="child-exclusion";try action("unsync",files[1]);try action("pin",folder)
            try await verify(phase,[false,true,false],[true,false,true])
            phase="final-release";try action("unsync",folder);try action("unsync",files[0])
            try await verify(phase,[true,true,true],[false,false,false])
            report["result"]="PASS"
        } catch {report["failedPhase"]=phase;report["errorDomain"]=(error as NSError).domain;report["errorCode"]=(error as NSError).code}
        try? openHandle?.close()
        if let folderID,let writer {
            do {
                let revision=try await writer.revision(folderID)
                _ = try await writer.updateMetadata(folderID,etag:revision.etag,trashed:true)
                report["fixtureFolderTrashed"]=true
            } catch {report["cleanup"]="PENDING";report["result"]="FAIL"}
        } else {report["cleanup"]="PENDING: inspect owned local fixture if created"}
        report["evidenceDirectory"]=work.path;report["visualAcceptance"]="PENDING";report["testedAt"]=ISO8601DateFormatter().string(from:Date())
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8){print(text)}
        if report["result"] as? String != "PASS"{exit(1)}
    }
}
#endif
