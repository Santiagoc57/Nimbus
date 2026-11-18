#if NATIVE_SAFETY_PROBE
import Foundation
import Darwin

/// Exercises eviction with a live reader and with an unclosed writer. The only
/// content created or edited is this UUID-owned synthetic fixture.
@main struct NativeSafetyProbe {
    static func attemptEviction(_ file:URL,host:URL,work:URL) throws -> [String:Any] {
        let errorFile=work.appendingPathComponent("command-error.json")
        try? FileManager.default.removeItem(at:errorFile)
        do {return try NativeFinderCycleProbe.state("unsync",file:file,host:host,work:work)}
        catch {
            guard let data=try? Data(contentsOf:errorFile),let result=try JSONSerialization.jsonObject(with:data) as? [String:Any],result["result"] as? String=="ERROR" else {throw error}
            return result
        }
    }
    static func dataless(_ file:URL)throws->Bool {
        var info=stat()
        guard lstat(file.path,&info)==0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }
    static func waitChecksum(_ id:String,_ checksum:String,api:DriveAPI) async throws {
        for _ in 0..<60 {
            if try await api.item(id).md5Checksum==checksum{return}
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        throw DriveFailure.unavailable
    }
    static func main() async {
        let fm=FileManager.default,work=URL(fileURLWithPath:"work/nimbo/native-safety-"+UUID().uuidString)
        var report:[String:Any]=["result":"FAIL"],id:String?,writer:DriveWriteAPI?,phase="setup",openHandle:FileHandle?
        do {
            guard CommandLine.arguments.count==4 else{throw DriveFailure.invalidResponse}
            let support=URL(fileURLWithPath:CommandLine.arguments[1]),host=URL(fileURLWithPath:CommandLine.arguments[2]),mount=URL(fileURLWithPath:CommandLine.arguments[3])
            guard mount.lastPathComponent.hasPrefix("Nimbo-GoogleDrive") else{throw DriveFailure.invalidResponse}
            try fm.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let api=DriveAPI(configuration:support.appendingPathComponent(".rclone-runtime.conf"));writer=DriveWriteAPI(api:api)
            let name="Nimbo-safety-probe-"+UUID().uuidString+".txt",file=mount.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject:["path":file.path,"synthetic":true]).write(to:work.appendingPathComponent("cleanup.json"))
            let original=Data(String(repeating:"Nimbo original synthetic content.\n",count:4096).utf8)
            let changed=Data(String(repeating:"Nimbo changed synthetic content retained through eviction.\n",count:4096).utf8)
            let originalReference=work.appendingPathComponent("original.txt"),changedReference=work.appendingPathComponent("changed.txt")
            try original.write(to:originalReference);try changed.write(to:changedReference)
            let originalMD5=try DriveWriteAPI.fingerprint(originalReference).md5,changedMD5=try DriveWriteAPI.fingerprint(changedReference).md5
            phase="create-upload"
            try await NativeFinderCycleProbe.coordinateWrite(file,bytes:original)
            var url=URLComponents(string:"https://www.googleapis.com/drive/v3/files")!
            url.queryItems=[.init(name:"q",value:"'root' in parents and name = '\(name)' and trashed = false"),.init(name:"fields",value:"files(\(DriveAPI.fields))"),.init(name:"pageSize",value:"10")]
            for _ in 0..<60 {
                let (data,response)=try await api.send(url.url!,method:"GET");try DriveAPI.validate(response.statusCode,data:data)
                let files=try JSONDecoder().decode(DrivePage.self,from:data).files
                try NativeFinderCycleProbe.require(files.count<=1)
                if let item=files.first{id=item.id;break}
                try await Task.sleep(nanoseconds:1_000_000_000)
            }
            guard let id else{throw DriveFailure.unavailable}
            try await waitChecksum(id,originalMD5,api:api)
            report["initialUploadVerified"]=true

            phase="open-reader"
            let reader=try FileHandle(forReadingFrom:file);openHandle=reader
            var readerResult=try attemptEviction(file,host:host,work:work);readerResult.removeValue(forKey:"id")
            try reader.seek(toOffset:0)
            try NativeFinderCycleProbe.require(try reader.readToEnd()==original)
            readerResult["openHandleContentPreserved"]=true
            readerResult["datalessAfterAttempt"]=try dataless(file)
            report["openReaderEviction"]=readerResult
            try reader.close();openHandle=nil

            phase="download-before-edit"
            _ = try NativeFinderCycleProbe.state("sync",file:file,host:host,work:work)
            _ = try await NativeFinderCycleProbe.awaitState(dataless:false,pinned:false,file:file,host:host,work:work)
            phase="open-writer-edit"
            let handle=try FileHandle(forWritingTo:file);openHandle=handle
            try handle.truncate(atOffset:0);try handle.write(contentsOf:changed);try handle.synchronize()
            report["editBytes"]=changed.count
            let remoteBefore=try await api.item(id)
            report["remoteHadNewContentBeforeEviction"]=remoteBefore.md5Checksum==changedMD5
            var writeResult=try attemptEviction(file,host:host,work:work);writeResult.removeValue(forKey:"id")
            let wasDataless=try dataless(file)
            writeResult["datalessAfterAttempt"]=wasDataless
            if wasDataless {
                // Check the remote checksum immediately after the command.
                // This and the later round trip prove the content survived;
                // they do not establish atomic upload/eviction ordering.
                try NativeFinderCycleProbe.require(try await api.item(id).md5Checksum==changedMD5)
                writeResult["remoteContentVerifiedAtRelease"]=true
            } else {
                try NativeFinderCycleProbe.require(try Data(contentsOf:file)==changed)
                writeResult["editedLocalContentPreserved"]=true
            }
            report["openWriterEviction"]=writeResult
            try handle.close();openHandle=nil

            phase="wait-edited-upload"
            try await waitChecksum(id,changedMD5,api:api)
            report["editedUploadVerified"]=true
            phase="release-after-close"
            _ = try NativeFinderCycleProbe.state("unsync",file:file,host:host,work:work)
            var released=try await NativeFinderCycleProbe.awaitState(dataless:true,pinned:false,file:file,host:host,work:work)
            released.removeValue(forKey:"id");report["releasedAfterClose"]=released
            phase="edited-roundtrip"
            _ = try NativeFinderCycleProbe.state("sync",file:file,host:host,work:work)
            _ = try await NativeFinderCycleProbe.awaitState(dataless:false,pinned:false,file:file,host:host,work:work)
            try NativeFinderCycleProbe.require(try Data(contentsOf:file)==changed)
            report["editedContentRoundTripVerified"]=true

            // Also separate dirty-content protection from open-descriptor
            // protection: this coordinated atomic save closes every handle
            // before requesting eviction. The larger synthetic payload leaves
            // a practical upload window without throttling the user's network.
            phase="closed-dirty-edit"
            let closedEdit=Data(repeating:0x42,count:16*1024*1024)
            let closedReference=work.appendingPathComponent("closed-edit.txt")
            try closedEdit.write(to:closedReference)
            let closedMD5=try DriveWriteAPI.fingerprint(closedReference).md5
            try await NativeFinderCycleProbe.coordinateWrite(file,bytes:closedEdit)
            let beforeClosedEviction=try await api.item(id)
            report["closedEditAlreadyUploadedBeforeEviction"]=beforeClosedEviction.md5Checksum==closedMD5
            var closedResult=try attemptEviction(file,host:host,work:work);closedResult.removeValue(forKey:"id")
            let closedDataless=try dataless(file)
            closedResult["datalessAfterAttempt"]=closedDataless
            if closedDataless {
                try NativeFinderCycleProbe.require(try await api.item(id).md5Checksum==closedMD5)
                closedResult["remoteContentVerifiedAtRelease"]=true
            } else {
                try NativeFinderCycleProbe.require(try Data(contentsOf:file)==closedEdit)
                closedResult["editedLocalContentPreserved"]=true
            }
            report["closedWriterEviction"]=closedResult
            phase="closed-edit-upload-and-release"
            try await waitChecksum(id,closedMD5,api:api)
            _ = try NativeFinderCycleProbe.state("unsync",file:file,host:host,work:work)
            _ = try await NativeFinderCycleProbe.awaitState(dataless:true,pinned:false,file:file,host:host,work:work)
            _ = try NativeFinderCycleProbe.state("sync",file:file,host:host,work:work)
            _ = try await NativeFinderCycleProbe.awaitState(dataless:false,pinned:false,file:file,host:host,work:work)
            try NativeFinderCycleProbe.require(try Data(contentsOf:file)==closedEdit)
            report["closedEditRoundTripVerified"]=true
            phase="final-release"
            _ = try NativeFinderCycleProbe.state("unsync",file:file,host:host,work:work)
            var finalRelease=try await NativeFinderCycleProbe.awaitState(dataless:true,pinned:false,file:file,host:host,work:work)
            finalRelease.removeValue(forKey:"id");report["finalRelease"]=finalRelease
            report["result"]="PASS"
        } catch {report["failedPhase"]=phase;report["errorDomain"]=(error as NSError).domain;report["errorCode"]=(error as NSError).code}
        try? openHandle?.close()
        if let id,let writer {
            do {
                let revision=try await writer.revision(id)
                _ = try await writer.updateMetadata(id,etag:revision.etag,trashed:true)
                report["fixtureTrashed"]=true
            } catch {report["cleanup"]="PENDING";report["result"]="FAIL"}
        } else {report["cleanup"]="PENDING: inspect owned local fixture if created"}
        report["evidenceDirectory"]=work.path;report["visualAcceptance"]="PENDING";report["testedAt"]=ISO8601DateFormatter().string(from:Date())
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8){print(text)}
        if report["result"] as? String != "PASS"{exit(1)}
    }
}
#endif
