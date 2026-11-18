#if NATIVE_READONLY_PROBE
import Foundation
import Darwin

/// Uses one existing small binary/text file that starts unpinned and dataless.
/// Restores that local state and never calls a cloud mutation API.
@main struct NativeReadOnlyProbe {
    static func main() async {
        let work=URL(fileURLWithPath:"work/nimbo/native-readonly-"+UUID().uuidString)
        var report:[String:Any]=["result":"FAIL"],target:URL?,host:URL?,phase="setup"
        do {
            guard CommandLine.arguments.count==4 else{throw DriveFailure.invalidResponse}
            let support=URL(fileURLWithPath:CommandLine.arguments[1]),executable=URL(fileURLWithPath:CommandLine.arguments[2]),mount=URL(fileURLWithPath:CommandLine.arguments[3]);host=executable
            guard mount.lastPathComponent=="Nimbo-GoogleDrive·Cuenta2" else{throw DriveFailure.invalidResponse}
            try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let api=DriveAPI(configuration:support.appendingPathComponent(".rclone-runtime.conf"),remoteName:"GoogleDrive-2")
            try NativeFinderCycleProbe.require(!(try await api.permitsWrites()))
            var url=URLComponents(string:"https://www.googleapis.com/drive/v3/files")!
            url.queryItems=[.init(name:"q",value:"'root' in parents and trashed = false and mimeType != 'application/vnd.google-apps.folder'"),.init(name:"fields",value:"files(\(DriveAPI.fields))"),.init(name:"pageSize",value:"1000")]
            let (data,response)=try await api.send(url.url!,method:"GET");try DriveAPI.validate(response.statusCode,data:data)
            let candidates=try JSONDecoder().decode(DrivePage.self,from:data).files.filter { item in
                guard let size=item.size.flatMap(Int64.init),size>0,size<=256*1024,item.md5Checksum != nil else{return false}
                return !item.isGoogleDocument && item.capabilities?.canDownload != false && !item.name.contains("/") && !item.name.contains(":") && !item.name.contains("%") && item.name.utf8.count<180
            }.sorted{Int64($0.size ?? "0")! < Int64($1.size ?? "0")!}
            var selected:DriveObject?
            for item in candidates {
                let file=mount.appendingPathComponent(item.name)
                guard FileManager.default.fileExists(atPath:file.path) else{continue}
                guard let state=try? NativeFinderCycleProbe.state("status",file:file,host:executable,work:work),state["domain"] as? String=="google-drive-account-GoogleDrive-2",state["dataless"] as? Bool==true,state["pinned"] as? Bool==false else{continue}
                selected=item;target=file;break
            }
            if let selected,let file=target {
                try JSONSerialization.data(withJSONObject:["path":file.path,"restoreDataless":true,"restorePinned":false,"remoteMutationAllowed":false]).write(to:work.appendingPathComponent("restore.json"))
                report["selectedFileBytes"]=Int64(selected.size ?? "0")!
                report["account"]="Cuenta2";report["writeScope"]=false
                phase="download-readonly"
                _ = try NativeFinderCycleProbe.state("sync",file:file,host:executable,work:work)
                var downloaded=try await NativeFinderCycleProbe.awaitState(dataless:false,pinned:false,file:file,host:executable,work:work)
                downloaded.removeValue(forKey:"id");report["downloaded"]=downloaded
                try NativeFinderCycleProbe.require(try DriveWriteAPI.fingerprint(file).md5==selected.md5Checksum)
                report["downloadMatchesRemoteChecksum"]=true
                phase="pin-readonly"
                _ = try NativeFinderCycleProbe.state("pin",file:file,host:executable,work:work)
                var pinned=try await NativeFinderCycleProbe.awaitState(dataless:false,pinned:true,file:file,host:executable,work:work)
                pinned.removeValue(forKey:"id");report["pinned"]=pinned
                try NativeFinderCycleProbe.require(try await api.item(selected.id).md5Checksum==selected.md5Checksum)
                report["remoteChecksumUnchanged"]=true;report["result"]="PASS"
            } else {
                report["result"]="SKIPPED";report["reason"]="No eligible small unpinned cloud-only file in the first root metadata page."
            }
        } catch {report["failedPhase"]=phase;report["errorDomain"]=(error as NSError).domain;report["errorCode"]=(error as NSError).code}
        if let target,let host {
            do {
                _ = try NativeFinderCycleProbe.state("unsync",file:target,host:host,work:work)
                var restored=try await NativeFinderCycleProbe.awaitState(dataless:true,pinned:false,file:target,host:host,work:work)
                restored.removeValue(forKey:"id");report["restoredCloudOnly"]=restored
            } catch {report["restore"]="PENDING";report["result"]="FAIL"}
        }
        report["remoteMutations"]=0;report["evidenceDirectory"]=work.path;report["visualAcceptance"]="PENDING";report["testedAt"]=ISO8601DateFormatter().string(from:Date())
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8){print(text)}
        if report["result"] as? String=="FAIL"{exit(1)}
    }
}
#endif
