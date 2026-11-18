import Foundation
import Darwin

struct SyncLocalIdentity:Codable,Equatable {
    let volume:String
    let inode:UInt64
    static func read(_ url:URL)throws->Self {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath() else {
            throw SyncFailure.message("No se admiten enlaces simbólicos en la carpeta local ni en su ruta.")
        }
        let values=try url.resourceValues(forKeys:[.isDirectoryKey,.volumeUUIDStringKey,.volumeIsLocalKey,.volumeIsReadOnlyKey])
        var info=stat()
        guard lstat(url.path,&info)==0,values.isDirectory==true,values.volumeIsLocal==true,
              values.volumeIsReadOnly==false,let volume=values.volumeUUIDString,
              FileManager.default.isWritableFile(atPath:url.path) else {
            throw SyncFailure.message("Elegí una carpeta local disponible y con permiso de escritura. Se admiten discos externos locales.")
        }
        return Self(volume:volume,inode:UInt64(info.st_ino))
    }
}
struct SyncInitialMove:Codable,Equatable {
    let from:String
    let to:String
}
struct SyncFolderPlan:Codable {
    let id:UUID
    let remote:String
    let folder:CloudItem
    let localPath:String
    let identity:SyncLocalIdentity
    let local:[CloudItem]
    let cloud:[CloudItem]
    let moves:[SyncInitialMove]
    var localFileCount:Int {local.filter{!$0.IsDir}.count}
    var remoteFileCount:Int {cloud.filter{!$0.IsDir}.count}

    static func key(_ path:String)->String {path.precomposedStringWithCanonicalMapping.lowercased()}
    static func contains(_ parent:String,_ path:String)->Bool {
        let a=key(parent),b=key(path)
        return a==b || b.hasPrefix(a.hasSuffix("/") ? a:a+"/")
    }
    /// Preserve local conflicts under distinct names before the first union.
    /// Missing hashes mean unknown content and therefore a conflict, never equality.
    static func make(id:UUID=UUID(),remote:String,folder:CloudItem,localPath:String,identity:SyncLocalIdentity,local:[CloudItem],cloud:[CloudItem])throws->Self {
        var remoteByKey:[String:CloudItem]=[:],localByKey:[String:CloudItem]=[:]
        for (items,isLocal) in [(cloud,false),(local,true)] {
            for item in items {
                for part in item.Path.split(separator:"/",omittingEmptySubsequences:false){_ = try CloudBackend.safeBasename(String(part))}
                let normalized=key(item.Path)
                if isLocal {
                    guard localByKey.updateValue(item,forKey:normalized)==nil else{throw SyncFailure.message("La carpeta local contiene nombres duplicados o incompatibles.")}
                } else {
                    guard remoteByKey.updateValue(item,forKey:normalized)==nil else{throw SyncFailure.message("Drive contiene nombres duplicados o incompatibles.")}
                }
            }
        }
        var occupied=Set(localByKey.keys).union(remoteByKey.keys),moves:[SyncInitialMove]=[]
        for item in local.sorted(by:{$0.Path < $1.Path}) {
            if moves.contains(where:{contains($0.from,item.Path)}){continue}
            guard let other=remoteByKey[key(item.Path)] else{continue}
            guard item.Path.precomposedStringWithCanonicalMapping==other.Path.precomposedStringWithCanonicalMapping else {
                throw SyncFailure.message("Los nombres «\(item.Path)» y «\(other.Path)» sólo difieren en mayúsculas. Renombrá uno antes de vincular.")
            }
            if item.IsDir && other.IsDir{continue}
            let hash=item.Hashes?.first(where:{$0.key.lowercased()=="md5"})?.value.lowercased()
            let otherHash=other.Hashes?.first(where:{$0.key.lowercased()=="md5"})?.value.lowercased()
            if !item.IsDir && !other.IsDir,item.Size==other.Size,
               let hash,!hash.isEmpty,hash==otherHash{continue}
            let path=NSString(string:item.Path),parent=path.deletingLastPathComponent
            let leaf=path.lastPathComponent as NSString
            let ext=item.IsDir ? "":leaf.pathExtension
            let stem=ext.isEmpty ? String(leaf):leaf.deletingPathExtension
            var suffix=0,destination:String
            repeat {
                suffix+=1
                let tag=" (conflicto Mac \(id.uuidString.prefix(8))-\(suffix))"
                let ending=tag+(ext.isEmpty ? "":"."+ext)
                var shortened=stem
                while (shortened+ending).decomposedStringWithCanonicalMapping.utf8.count>240 && !shortened.isEmpty{shortened.removeLast()}
                guard !shortened.isEmpty else{throw SyncFailure.message("El nombre es demasiado largo para conservar una copia de conflicto.")}
                let name=try CloudBackend.safeBasename(shortened+ending)
                destination=parent.isEmpty ? name:parent+"/"+name
            } while occupied.contains(key(destination))
            occupied.insert(key(destination));moves.append(SyncInitialMove(from:item.Path,to:destination))
        }
        return Self(id:id,remote:remote,folder:folder,localPath:localPath,identity:identity,local:local,cloud:cloud,moves:moves)
    }
    static func sameSnapshot(_ left:[CloudItem],_ right:[CloudItem])->Bool {
        // Folder mtimes change when children change and are not content versions.
        func sorted(_ items:[CloudItem])->[CloudItem] {
            items.map{CloudItem(Path:$0.Path,Name:$0.Name,Size:$0.IsDir ? 0:$0.Size,IsDir:$0.IsDir,ModTime:$0.IsDir ? nil:$0.ModTime,ID:$0.ID,Hashes:$0.IsDir ? nil:$0.Hashes)}.sorted{$0.Path < $1.Path}
        }
        return sorted(left)==sorted(right)
    }
}
