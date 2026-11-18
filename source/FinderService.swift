import Foundation
import NetFS
import Darwin

// Separate worker keeps NetFS and network waits off the app's UI thread.
// The loopback password is generated here and is never persisted or placed in argv.
@main struct FinderService {
    struct Request: Decodable {
        let binary: String
        let config: String
        let source: String
        let parent: Int32
        let testing: Bool
    }
    static func event(_ state: String, _ message: String = "", path: String? = nil) {
        var value = ["state":state, "message":message]
        if let path { value["path"] = path }
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain:"socket",code:Int(errno)) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to:&address) { ptr in
            ptr.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw NSError(domain:"bind",code:Int(errno)) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to:&address) { ptr in
            ptr.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) }
        }
        guard got == 0 else { throw NSError(domain:"port",code:Int(errno)) }
        return UInt16(bigEndian:address.sin_port)
    }
    static func response(_ url: URL, password: String?) -> Int? {
        var request = URLRequest(url:url, cachePolicy:.reloadIgnoringLocalCacheData, timeoutInterval:3)
        if let password {
            request.setValue("Basic " + Data(("nimbo:" + password).utf8).base64EncodedString(), forHTTPHeaderField:"Authorization")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration:configuration)
        let done = DispatchSemaphore(value:0)
        var result: Int?
        let task = session.dataTask(with:request) { _, response, _ in
            result = (response as? HTTPURLResponse)?.statusCode; done.signal()
        }
        task.resume()
        if done.wait(timeout:.now()+4) == .timedOut { task.cancel() }
        session.invalidateAndCancel()
        return result
    }
    static func mounted(_ path: String) -> Bool {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return false }
        for i in 0..<Int(count) {
            var value = buffer[i].f_mntonname
            let size = MemoryLayout.size(ofValue:value)
            let name = withUnsafePointer(to:&value) { $0.withMemoryRebound(to:CChar.self,capacity:size) { String(cString:$0) } }
            if name == path { return true }
        }
        return false
    }
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        guard let line = readLine(), line.utf8.count < 16384,
              let request = try? JSONDecoder().decode(Request.self, from:Data(line.utf8)),
              request.parent == getppid(), request.binary.hasPrefix("/"),
              request.config.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/"),
              request.source == "GoogleDrive:" || (request.testing && request.source.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/")) else {
            event("failed","No se pudo validar la configuración de Finder."); exit(64)
        }
        let server = Process()
        var mountPath: String?
        defer {
            if let path = mountPath, mounted(path), unmount(path,0) != 0, getppid() != request.parent {
                // After an app crash the read-only volume has no writer to preserve.
                _ = unmount(path,MNT_FORCE)
            }
            if server.isRunning { server.terminate(); server.waitUntilExit() }
        }
        do {
            let port = try freePort()
            let password = UUID().uuidString + UUID().uuidString
            let label = request.testing ? "Nimbo - Prueba Finder" : "Google Drive - Nimbo"
            let url = URL(string:"http://127.0.0.1:\(port)/")!.appendingPathComponent(label, isDirectory:true)
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("RCLONE_") }
            environment["RCLONE_USER"] = "nimbo"; environment["RCLONE_PASS"] = password
            server.environment = environment
            server.executableURL = URL(fileURLWithPath:request.binary)
            server.arguments = ["serve","webdav",request.source,"--config",request.config,
                "--addr","127.0.0.1:\(port)","--baseurl",label,"--read-only",
                "--vfs-cache-mode","off","--vfs-block-norm-dupes","--dir-cache-time","30s",
                "--poll-interval","15s","--disable-zip","--log-level","ERROR"]
            server.standardInput = FileHandle.nullDevice
            server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
            try server.run()
            event("connecting","Conectando Google Drive con Finder…")
            var ready = false
            for _ in 0..<12 {
                guard server.isRunning, getppid() == request.parent else { break }
                if response(url,password:nil) == 401, response(url,password:password) == 200 { ready = true; break }
                Thread.sleep(forTimeInterval:0.25)
            }
            guard ready else {
                event("failed","No se pudo acceder a Drive. Comprobá internet y la autorización de Google."); return
            }
            let openOptions = NSMutableDictionary(dictionary:[
                kNAUIOptionKey:kNAUIOptionNoUI, kNetFSAllowLoopbackKey:true,
                kNetFSNoUserPreferencesKey:true, kNetFSForceNewSessionKey:true])
            let mountOptions = NSMutableDictionary(dictionary:[
                kNetFSMountFlagsKey:MNT_RDONLY | MNT_NOSUID | MNT_NODEV, kNetFSSoftMountKey:true])
            var mounts: Unmanaged<CFArray>?
            let result = NetFSMountURLSync(url as CFURL, nil, "nimbo" as CFString, password as CFString,
                                          openOptions, mountOptions, &mounts)
            let paths = mounts?.takeRetainedValue() as? [String] ?? []
            guard result == 0, let path = paths.first, path.hasPrefix("/Volumes/"), mounted(path) else {
                event("failed","macOS no pudo conectar el volumen (\(result)). Volvé a intentar."); return
            }
            mountPath = path
            guard getppid() == request.parent else { return }
            event("connected","Drive disponible en Finder · sólo lectura",path:path)
            _ = fcntl(STDIN_FILENO,F_SETFL,O_NONBLOCK)
            var input = ""
            while getppid() == request.parent && server.isRunning && mounted(path) {
                var bytes = [UInt8](repeating:0,count:256)
                let count = read(STDIN_FILENO,&bytes,bytes.count)
                if count == 0 { break }
                if count > 0 { input += String(decoding:bytes.prefix(count),as:UTF8.self) }
                if input.contains("stop\n") {
                    input = ""
                    if unmount(path,0) == 0 { mountPath = nil; event("disconnected"); return }
                    event("busy","Finder está usando archivos de Drive. Cerrá esos archivos y volvé a desconectar.",path:path)
                }
                Thread.sleep(forTimeInterval:0.25)
            }
            if getppid() == request.parent {
                event("disconnected","El volumen se desconectó. Podés volver a conectarlo desde Nimbo.")
            }
        } catch { event("failed","No se pudo iniciar la conexión de Finder.") }
    }
}
