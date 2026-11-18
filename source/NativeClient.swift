import Foundation
import FileProvider
import Darwin

private final class NativeReply<Value>: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<Value,Error>?
    init(_ continuation:CheckedContinuation<Value,Error>) {self.continuation=continuation}
    func finish(_ result:Result<Value,Error>) {
        lock.lock(); let pending=continuation; continuation=nil; lock.unlock()
        pending?.resume(with:result)
    }
}

/// The system can unload an extension between actions. Each operation obtains a
/// fresh restricted service instead of retaining a proxy to a vanished process.
final class NativeClient:NativeAutoUnsyncSource {
    let domain:NSFileProviderDomain
    let rootID:String?
    let remoteName:String
    private func manager() throws -> NSFileProviderManager {
        guard let manager=NSFileProviderManager(for:domain) else {throw NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.providerNotFound.rawValue)}
        return manager
    }
    init(identifier:String="google-drive",name:String="Google Drive",rootID:String?=nil,remoteName:String="GoogleDrive") {
        domain=NSFileProviderDomain(identifier:NSFileProviderDomainIdentifier(identifier),displayName:name)
        self.rootID=rootID; self.remoteName=remoteName
    }
    func register() async throws {
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            NSFileProviderManager.add(domain){e in if let e{c.resume(throwing:e)}else{c.resume()}}
        }
    }
    private func service() async throws -> NSFileProviderService {
        let current=try manager()
        return try await withCheckedThrowingContinuation { c in
            current.getService(named:NSFileProviderServiceName(nimboNativeServiceName),for:.rootContainer){service,error in
                if let service{c.resume(returning:service)}else{c.resume(throwing:error ?? NSError(domain:NSFileProviderErrorDomain,code:-2001))}
            }
        }
    }
    func call<Value>(_ operation:@escaping (NimboNativeConnection,@escaping(Result<Value,Error>)->Void)->Void) async throws -> Value {
        let service=try await service()
        let connection:NSXPCConnection=try await withCheckedThrowingContinuation { c in
            service.getFileProviderConnection {connection,error in
                if let connection{c.resume(returning:connection)}else{c.resume(throwing:error ?? NSError(domain:NSCocoaErrorDomain,code:NSXPCConnectionInvalid))}
            }
        }
        defer{connection.invalidate(); withExtendedLifetime(service){}}
        connection.remoteObjectInterface=NSXPCInterface(with:NimboNativeConnection.self)
        connection.resume()
        return try await withCheckedThrowingContinuation { c in
            let reply=NativeReply(c)
            // Replies and invalidations can race. Resolve the continuation once.
            connection.invalidationHandler={reply.finish(.failure(NSError(domain:NSCocoaErrorDomain,code:NSXPCConnectionInvalid)))}
            connection.interruptionHandler={reply.finish(.failure(NSError(domain:NSCocoaErrorDomain,code:NSXPCConnectionInterrupted)))}
            guard let proxy=connection.remoteObjectProxyWithErrorHandler({reply.finish(.failure($0))}) as? NimboNativeConnection else {
                reply.finish(.failure(NSError(domain:NSCocoaErrorDomain,code:NSXPCConnectionReplyInvalid))); return
            }
            DispatchQueue.global().asyncAfter(deadline:.now()+60){reply.finish(.failure(NSError(domain:NSURLErrorDomain,code:NSURLErrorTimedOut)))}
            operation(proxy){reply.finish($0)}
        }
    }
    func waitUntilReady() async throws {
        var failure:Error=NSError(domain:NSFileProviderErrorDomain,code:-2001)
        for attempt in 0..<20 {
            do {
                // Re-registration also handles replacement of an old plugin UUID.
                try await register()
                let _:String=try await call{proxy,done in proxy.status{value,error in
                    if let error{done(.failure(error))}else{done(.success(value ?? ""))}
                }}
                return
            } catch {
                failure=error; let e=error as NSError
                let transient=(e.domain==NSFileProviderErrorDomain && [-2001,-2013].contains(e.code)) || (e.domain==NSCocoaErrorDomain && [4097,4099,4101].contains(e.code))
                if !transient || attempt==19 {throw error}
                try await Task.sleep(nanoseconds:1_000_000_000)
            }
        }
        throw failure
    }
    func configure(_ data:Data) async throws {
        try await waitUntilReady()
        let _:Bool=try await call{proxy,done in
            let reply: (NSError?) -> Void = { e in done(e.map{.failure($0)} ?? .success(true)) }
            if let rootID=self.rootID { proxy.configureRootAccount(data,rootID:rootID,remoteName:self.remoteName,reply:reply) }
            else { proxy.configureAccount(data,remoteName:self.remoteName,reply:reply) }
        }
    }
    #if NIMBO_TESTING
    func configureFixture() async throws {
        try await waitUntilReady()
        let _:Bool=try await call{proxy,done in proxy.configureFixture{e in done(e.map{.failure($0)} ?? .success(true))}}
    }
    #endif
    func isWritable() async throws->Bool {
        let status:String=try await call{proxy,done in proxy.status{value,error in
            if let error{done(.failure(error))}else{done(.success(value ?? "{}"))}
        }}
        let value=try JSONSerialization.jsonObject(with:Data(status.utf8)) as? [String:Any]
        return value?["writable"] as? Bool == true
    }
    func browserLink(_ id: String) async throws -> URL {
        let value: String = try await call { proxy, done in
            proxy.browserLink(id) { value, error in
                if let error { done(.failure(error)) }
                else if let value { done(.success(value)) }
                else { done(.failure(CocoaError(.fileReadCorruptFile))) }
            }
        }
        return try DriveAPI.validatedBrowserURL(value)
    }
    func pin(_ id:String,_ value:Bool,limit:Int64?=nil) async throws {
        let wireLimit=limit ?? -1
        let _:Bool=try await call{proxy,done in proxy.setPinned(id,value:value,limit:wireLimit){e in done(e.map{.failure($0)} ?? .success(true))}}
        signalChanges()
        // Changing the content policy tells File Provider that the item must
        // be kept, but a dataless item may still wait for a subsequent
        // enumerator pass before it is materialized. Request the download
        // explicitly so a Finder "Conservar sin conexión" action has an
        // observable effect immediately after a prior eviction.
        if value {
            let current=try manager()
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                current.requestDownloadForItem(withIdentifier:NSFileProviderItemIdentifier(id),requestedRange:NSRange(location:NSNotFound,length:0)) { error in
                    if let error { c.resume(throwing:error) } else { c.resume() }
                }
            }
        }
    }
    /// Downloads one placeholder without changing its offline pin preference.
    /// This is the Finder "Sincronizar ahora" action; unlike `pin`, the
    /// item remains eligible for later eviction.
    func downloadNow(_ id:String) async throws {
        let data:Data=try await call{proxy,done in proxy.prepareDownload(id){data,error in
            if let error{done(.failure(error))}else if let data{done(.success(data))}else{done(.failure(CocoaError(.fileReadCorruptFile)))}
        }}
        guard data.count<=16*1024*1024 else{throw CocoaError(.fileReadTooLarge)}
        let ids=try JSONDecoder().decode([String].self,from:data)
        let current=try manager()
        for requestedID in ids {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                current.requestDownloadForItem(withIdentifier:NSFileProviderItemIdentifier(requestedID),requestedRange:NSRange(location:NSNotFound,length:0)) { error in
                    if let error { c.resume(throwing:error) } else { c.resume() }
                }
            }
        }
        signalChanges()
    }
    static func waitingForUnpin(_ error:NSError)->Bool {
        guard error.domain==NSFileProviderErrorDomain else{return false}
        if error.code==NSFileProviderError.nonEvictable.rawValue{return true}
        guard error.code==NSFileProviderError.nonEvictableChildren.rawValue,!error.underlyingErrors.isEmpty else{return false}
        return error.underlyingErrors.allSatisfy{waitingForUnpin($0 as NSError)}
    }
    /// Keep the system's precise cause for one file. For a partial folder
    /// release, preserve every cause under the standard aggregate error key.
    static func evictionFailure(_ failures:[(name:String,error:NSError)],attemptedCount:Int)->NSError? {
        guard !failures.isEmpty else{return nil}
        if attemptedCount==1,failures.count==1{return failures[0].error}
        let names=failures.prefix(5).map{"«\($0.name)»"}.joined(separator:", ")
        return NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.nonEvictableChildren.rawValue,userInfo:[NSLocalizedDescriptionKey:"Liberación parcial: no se pudo liberar \(failures.count) archivo(s): \(names). Sus copias locales se conservan; revisá las causas antes de reintentar.",NSMultipleUnderlyingErrorsKey:failures.map{$0.error}])
    }
    func evict(_ id:String) async throws {
        try await pin(id,false)
        let data:Data=try await call{proxy,done in proxy.evictionCandidates(id){data,error in
            if let error{done(.failure(error))}else if let data{done(.success(data))}else{done(.failure(CocoaError(.fileReadCorruptFile)))}
        }}
        guard data.count<=16*1024*1024 else{throw CocoaError(.fileReadTooLarge)}
        let candidates=try JSONDecoder().decode([NativeEvictionCandidate].self,from:data)
        var failures:[(name:String,error:NSError)]=[]
        for candidate in candidates {
            try Task.checkCancellation()
            do { try await evictFile(candidate.id) }
            catch {
                let error=error as NSError
                if error.domain==NSFileProviderErrorDomain && error.code==NSFileProviderError.noSuchItem.rawValue {continue}
                failures.append((candidate.name,error))
            }
        }
        signalChanges()
        if let failure=Self.evictionFailure(failures,attemptedCount:candidates.count){throw failure}
    }
    private func evictFile(_ id:String) async throws {
        // The unpin update reaches File Provider asynchronously. Retry only its
        // explicit non-evictable response; never bypass dirty/open-file checks.
        for attempt in 0..<12 {
            do {
                let current=try manager()
                try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
                    current.evictItem(identifier:NSFileProviderItemIdentifier(id)){e in if let e{c.resume(throwing:e)}else{c.resume()}}
                }
                signalChanges()
                return
            } catch {
                let e=error as NSError
                guard Self.waitingForUnpin(e),attempt<11 else{throw error}
                try await Task.sleep(nanoseconds:1_000_000_000)
            }
        }
    }
    func availabilityPage(after:String?) async throws->NativeAvailabilityPage {
        let data:Data=try await call{proxy,done in proxy.availabilityPage(after:after){data,error in
            if let error{done(.failure(error))}else if let data{done(.success(data))}else{done(.failure(CocoaError(.fileReadCorruptFile)))}
        }}
        guard data.count<=1024*1024 else{throw CocoaError(.fileReadTooLarge)}
        return try JSONDecoder().decode(NativeAvailabilityPage.self,from:data)
    }
    func conflicts() async throws -> [NativeConflict] {
        let data:Data=try await call{proxy,done in proxy.conflicts{data,error in
            if let error{done(.failure(error))}else if let data{done(.success(data))}else{done(.failure(CocoaError(.fileReadCorruptFile)))}
        }}
        guard data.count<=1024*1024 else{throw CocoaError(.fileReadTooLarge)}
        return try JSONDecoder().decode([NativeConflict].self,from:data)
    }
    func acknowledgeConflict(_ id:String) async throws {
        let _:Bool=try await call{proxy,done in proxy.acknowledgeConflict(id){error in done(error.map{.failure($0)} ?? .success(true))}}
    }
    func resolveConflict(_ id:String,action:String) async throws {
        let _:Bool=try await call{proxy,done in proxy.resolveConflict(id,action:action){error in done(error.map{.failure($0)} ?? .success(true))}}
    }
    func localAvailability(_ id:String) async throws->NativeLocalAvailability? {
        let url=try await location(id)
        let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
        var info=stat()
        guard lstat(url.path,&info)==0 else{if errno==ENOENT{return nil};throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
        guard (info.st_mode & S_IFMT)==S_IFREG,info.st_flags & UInt32(SF_DATALESS)==0 else{return nil}
        func date(_ time:timespec)->Date{Date(timeIntervalSince1970:Double(time.tv_sec)+Double(time.tv_nsec)/1_000_000_000)}
        return NativeLocalAvailability(identity:"\(info.st_dev):\(info.st_ino)",accessed:date(info.st_atimespec),modified:date(info.st_mtimespec),created:date(info.st_birthtimespec))
    }
    func evictAutomatically(_ id:String) async throws {
        let allowed:Bool=try await call{proxy,done in proxy.canAutomaticallyEvict(id){value,error in
            if let error{done(.failure(error))}else{done(.success(value))}
        }}
        guard allowed else{throw NSError(domain:NSFileProviderErrorDomain,code:NSFileProviderError.nonEvictable.rawValue)}
        let current=try manager()
        try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in
            current.evictItem(identifier:NSFileProviderItemIdentifier(id)){error in if let error{c.resume(throwing:error)}else{c.resume()}}
        }
        signalChanges()
    }
    func takeEvictionMessages() async throws -> [String] {
        let data:Data=try await call{proxy,done in proxy.takeEvictionMessages{value,error in
            if let error{done(.failure(error))}else{done(.success(value ?? Data("[]".utf8)))}
        }}
        return try JSONDecoder().decode([String].self,from:data)
    }
    func pendingDownloads() async throws -> [String] {
        let data:Data=try await call{proxy,done in proxy.pendingDownloads{value,error in
            if let error{done(.failure(error))}else{done(.success(value ?? Data("[]".utf8)))}
        }}
        return try JSONDecoder().decode([String].self,from:data)
    }
    func downloadIsPending(_ id:String) async throws -> Bool {
        try await call{proxy,done in proxy.downloadIsPending(id){pending,error in
            if let error{done(.failure(error))}else{done(.success(pending))}
        }}
    }
    /// Forces macOS to download requested items now: a coordinated read of the
    /// user-visible file makes File Provider fetch its contents immediately,
    /// instead of waiting for the background-download scheduler.
    func materializePending() async {
        let ids:[String]
        do { ids=try await pendingDownloads() } catch { NSLog("Nimbo materialize: pending list failed: %@", String(describing:error)); return }
        guard !ids.isEmpty else { return }
        NSLog("Nimbo materialize: %d pending", ids.count)
        for id in ids {
            // Unsync may cancel a queued request while an earlier file is
            // downloading. Re-check before touching each following file.
            guard (try? await downloadIsPending(id)) == true else {continue}
            guard let url=try? await location(id) else { NSLog("Nimbo materialize: no URL for %@", id); continue }
            await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in
                DispatchQueue.global(qos:.userInitiated).async {
                    // Reading through a coordinator makes File Provider fetch
                    // the contents now; reading one byte guarantees it.
                    var error:NSError?
                    NSFileCoordinator().coordinate(readingItemAt:url,options:[],error:&error){ readURL in
                        if let handle=try? FileHandle(forReadingFrom:readURL) { _ = try? handle.read(upToCount:1); try? handle.close() }
                    }
                    if let error { NSLog("Nimbo materialize: %@ failed: %@", url.lastPathComponent, error.localizedDescription) }
                    c.resume()
                }
            }
        }
        signalChanges()
    }
    func location(_ id:String?=nil) async throws -> URL {
        let current=try manager()
        return try await withCheckedThrowingContinuation { c in
            current.getUserVisibleURL(for:id.map{NSFileProviderItemIdentifier($0)} ?? .rootContainer){url,error in
                if let url{c.resume(returning:url)}else{c.resume(throwing:error ?? NSError(domain:NSCocoaErrorDomain,code:NSFileNoSuchFileError))}
            }
        }
    }
    func identifierForUserVisibleFile(_ url: URL) async throws -> (id:String, domain:String) {
        try await withCheckedThrowingContinuation { c in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { identifier, domain, error in
                if let error { c.resume(throwing: error) }
                else if let identifier, let domain { c.resume(returning: (identifier.rawValue, domain.rawValue)) }
                else { c.resume(throwing: NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)) }
            }
        }
    }
    func signalChanges() {NSFileProviderManager(for:domain)?.signalEnumerator(for:.workingSet,completionHandler:{_ in})}
    /// Rebuild the File Provider metadata snapshot so newly declared item
    /// decorations (cloud/check badges) are applied to existing Finder rows.
    func reimportMetadata() async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            manager.reimportItems(below: .rootContainer) { _ in continuation.resume() }
        }
    }
    func remove() async throws {
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            NSFileProviderManager.remove(domain){e in if let e{c.resume(throwing:e)}else{c.resume()}}
        }
    }
}
