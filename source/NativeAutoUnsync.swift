import Foundation

struct NativeLocalAvailability {
    let identity:String
    let accessed:Date
    let modified:Date
    let created:Date
}
protocol NativeAutoUnsyncSource {
    func availabilityPage(after:String?) async throws->NativeAvailabilityPage
    /// nil means absent, dataless, or not a regular file. Never read contents.
    func localAvailability(_ id:String) async throws->NativeLocalAvailability?
    /// Must not change pin preferences; the system still enforces dirty/open safety.
    func evictAutomatically(_ id:String) async throws
}
struct NativeAutoUnsyncSettings:Codable,Equatable {
    var enabled=false
    var days=7
}
struct NativeAutoUnsyncReport:Codable {
    var checked=0,evicted=0,protected=0,deferred=0
    var disabled=false,busy=false
    var date=Date()
    var message:String {
        if disabled{return "Liberación automática desactivada."}
        if busy{return "Ya hay una revisión automática en curso."}
        return "Revisados: \(checked). Liberados: \(evicted). Conservados: \(protected). Pendientes: \(deferred)."
    }
}

/// Conservative aging: a file must be old by every observed clock, including
/// our first observation and the extension's latest download. macOS performs the
/// actual eviction; no path is unlinked and manual offline rules are never reset.
actor NativeAutoUnsync {
    private struct Observation:Codable {let identity:String;let firstSeen:Date}
    private struct State:Codable {
        var settings=NativeAutoUnsyncSettings()
        var cursor:String?
        var observations:[String:Observation]=[:]
        var lastReport:NativeAutoUnsyncReport?
    }
    private let file:URL,source:any NativeAutoUnsyncSource
    private var state:State?
    private var running=false
    init(file:URL,source:any NativeAutoUnsyncSource){self.file=file;self.source=source}
    private func load()throws {
        guard state==nil else{return}
        if FileManager.default.fileExists(atPath:file.path) {
            let data=try Data(contentsOf:file)
            guard data.count<=64*1024*1024 else{throw CocoaError(.fileReadTooLarge)}
            let decoded=try JSONDecoder().decode(State.self,from:data)
            guard [1,7,30].contains(decoded.settings.days) else{throw CocoaError(.fileReadCorruptFile)}
            state=decoded
        } else {state=State()}
    }
    private func save()throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(state!).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func settings()throws->NativeAutoUnsyncSettings {try load();return state!.settings}
    func lastReport()throws->NativeAutoUnsyncReport? {try load();return state!.lastReport}
    func configure(enabled:Bool,days:Int)throws {
        guard [1,7,30].contains(days) else{throw NSError(domain:"NimboAvailability",code:1,userInfo:[NSLocalizedDescriptionKey:"El plazo debe ser 1, 7 o 30 días."])}
        try load();state!.settings=NativeAutoUnsyncSettings(enabled:enabled,days:days);try save()
    }
    func run(now:Date=Date()) async throws->NativeAutoUnsyncReport {
        try load()
        guard state!.settings.enabled else{return NativeAutoUnsyncReport(disabled:true,date:now)}
        guard !running else{return NativeAutoUnsyncReport(busy:true,date:now)}
        running=true;defer{running=false}
        var report=NativeAutoUnsyncReport(date:now)
        let page=try await source.availabilityPage(after:state!.cursor)
        let started=ProcessInfo.processInfo.systemUptime
        var lastVisited:String?
        for candidate in page.items {
            try Task.checkCancellation()
            guard state!.settings.enabled else{break}
            if lastVisited != nil,ProcessInfo.processInfo.systemUptime-started>30{break}
            lastVisited=candidate.id
            report.checked+=1
            if candidate.pinned{report.protected+=1;continue}
            do {
                guard let local=try await source.localAvailability(candidate.id) else {
                    state!.observations.removeValue(forKey:candidate.id);continue
                }
                let observation:Observation
                if let old=state!.observations[candidate.id],old.identity==local.identity{observation=old}
                else{observation=Observation(identity:local.identity,firstSeen:now);state!.observations[candidate.id]=observation}
                let latest=[observation.firstSeen,local.accessed,local.modified,local.created,candidate.downloadedAt ?? .distantPast].max()!
                let age=now.timeIntervalSince(latest)
                // Re-read settings after await: disabling or increasing the age
                // while a scan is in progress takes effect before eviction.
                guard state!.settings.enabled,age>=TimeInterval(state!.settings.days)*86400 else{continue}
                try Task.checkCancellation()
                try await source.evictAutomatically(candidate.id)
                state!.observations.removeValue(forKey:candidate.id);report.evicted+=1
            } catch is CancellationError {throw CancellationError()}
            catch {report.deferred+=1}
        }
        state!.cursor=lastVisited==page.items.last?.id ? page.next : (lastVisited ?? state!.cursor)
        report.disabled = !state!.settings.enabled
        state!.lastReport=report;try save()
        return report
    }
}
