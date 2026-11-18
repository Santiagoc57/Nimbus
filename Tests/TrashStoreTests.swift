#if TRASH_STORE_TESTS
import Foundation

actor DelayedTrash: TrashAccess {
    var list: [DriveObject] = [DriveObject(id:"A",name:"A.txt",mimeType:"text/plain",trashed:true), DriveObject(id:"B",name:"B.txt",mimeType:"text/plain",trashed:true)]
    var loads = 0
    var restores: [String] = []
    var gate: CheckedContinuation<Void, Never>?
    var hold = false, writable = true, failing = false, wrongReply = false
    func settings(hold: Bool = false, writable: Bool = true, failing: Bool = false, wrongReply: Bool = false) {
        self.hold=hold; self.writable=writable; self.failing=failing; self.wrongReply=wrongReply
    }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate=nil }
    private func delay() async { if hold { await withCheckedContinuation { gate=$0 } } }
    func allTrash(limit: Int) async throws -> [DriveObject] { loads+=1; await delay(); if failing { throw DriveFailure.denied }; return list }
    func permitsWrites() async throws -> Bool { writable }
    func restoreFromTrash(_ id: String) async throws -> DriveObject {
        restores.append(id); await delay()
        if failing { throw DriveFailure.denied }
        let result = DriveObject(id:wrongReply ? "OTHER" : id,name:id+".txt",mimeType:"text/plain",trashed:false)
        if !wrongReply { list.removeAll { $0.id==id } }
        return result
    }
}

@main struct TrashStoreTests {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ ok: Bool, _ message: String) { precondition(ok,message); checks+=1 }
        func wait(_ fake: DelayedTrash) async {
            for _ in 0..<5000 { if await fake.waiting() { return }; try? await Task.sleep(nanoseconds:1_000_000) }
            fatalError("mock did not reach delayed request")
        }
        let fake=DelayedTrash(), store=TrashStore(service:DelayedTrash())
        _ = store // A second independent store has no shared busy state.
        let state=TrashStore(service:fake)
        await fake.settings(hold:true)
        let load=Task { try await state.load() }; await wait(fake)
        check(state.isBusy,"load must reserve before yielding")
        check(try await state.load() == false,"duplicate loads must not start")
        check(try await state.restore(id:"A") == false,"restore blocked during initial load")
        check(await fake.loads == 1,"one API read")
        await fake.release(); _ = try await load.value
        check(!state.isBusy && Set(state.items.map(\.id)) == Set(["A","B"]),"load completes")
        let restore=Task { try await state.restore(id:"A") }; await wait(fake)
        check(state.isBusy,"restore reserves before remote call")
        check(try await state.restore(id:"B") == false,"selection change cannot start second restore")
        check(try await state.load() == false,"reopening cannot reload during restore")
        check(await fake.restores == ["A"],"only selected identity reaches API")
        await fake.release(); check(try await restore.value,"first restore succeeds")
        check(!state.isBusy && state.items.map(\.id) == ["B"],"completion removes only restored ID")
        await fake.settings(writable:false)
        do { _ = try await state.restore(id:"B"); fatalError("read-only accepted") } catch {}
        check(!state.isBusy && state.items.map(\.id) == ["B"],"denial preserves state and unlocks")
        check(await fake.restores == ["A"],"read-only never calls mutation")
        await fake.settings(failing:true)
        do { _ = try await state.restore(id:"B"); fatalError("error accepted") } catch {}
        check(!state.isBusy && state.items.count == 1,"network failure preserves row")
        await fake.settings(wrongReply:true)
        do { _ = try await state.restore(id:"B"); fatalError("wrong ID accepted") } catch {}
        check(state.items.map(\.id) == ["B"],"unrelated server reply cannot remove selected item")
        await fake.settings()
        check(try await state.restore(id:"B"),"retry after errors succeeds")
        check(state.items.isEmpty && !state.isBusy,"retry removes correct identity")
        check(try await state.restore(id:"missing") == false,"unknown ID is not sent")
        let primary = DelayedTrash(), secondary = DelayedTrash()
        let primaryStore = TrashStore(service: primary), secondaryStore = TrashStore(service: secondary)
        await secondary.settings(writable: false)
        _ = try await primaryStore.load(); _ = try await secondaryStore.load()
        check(primaryStore.permitsRestoration && !secondaryStore.permitsRestoration, "permission state is account scoped")
        _ = try await primaryStore.restore(id: "A")
        check(secondaryStore.items.contains { $0.id == "A" }, "same ID in another account is not removed")
        check(await secondary.restores.isEmpty, "other account credentials never receive restoration")
        await primary.settings(hold: true)
        let primaryLoad = Task { try await primaryStore.load() }; await wait(primary)
        check(try await secondaryStore.load(), "one busy account cannot block another")
        check(primaryStore.isBusy && !secondaryStore.isBusy, "busy state is independent")
        await primary.release(); _ = try await primaryLoad.value
        await primary.settings(failing: true)
        do { _ = try await primaryStore.load(); fatalError("failed reload accepted") } catch {}
        check(!primaryStore.permitsRestoration, "failed reload cannot leave restoration enabled")
        check(secondaryStore.items.count == 2 && !secondaryStore.permitsRestoration, "failed request cannot alter another account")
        let legacy = CloudAccountScope.sharedDomainIdentifier(remote: "GoogleDrive", driveID: "team")
        check(legacy == "google-drive-shared-team", "existing primary Finder domain stays stable")
        let separate = CloudAccountScope.sharedDomainIdentifier(remote: "GoogleDrive-2", driveID: "team")
        check(separate != legacy, "same shared drive uses separate account domain")
        check(separate == CloudAccountScope.sharedDomainIdentifier(remote: "GoogleDrive-2", driveID: "team"), "domain is stable across restarts")
        check(separate != CloudAccountScope.sharedDomainIdentifier(remote: "GoogleDrive-2", driveID: "other"), "different shared drives remain distinct")
        check(CloudAccountScope.sharedDomainIdentifier(remote: "a", driveID: "bc") != CloudAccountScope.sharedDomainIdentifier(remote: "ab", driveID: "c"), "account/root boundaries cannot collide")
        print("PASS: \(checks) trash concurrency, identity, permission and recovery checks; no network")
    }
}
#endif
