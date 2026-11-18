import Foundation

final class FinderController {
    enum State { case disconnected, connecting, connected, failed }
    private(set) var state = State.disconnected
    private(set) var mountURL: URL?
    var onChange: ((State,String) -> Void)?
    private var worker: Process?
    private var commands: Pipe?
    private var stopCompletion: ((Bool) -> Void)?
    private var buffer = Data()
    private var favorite: UnsafeMutableRawPointer?
    private let streamQueue = DispatchQueue(label:"Nimbo.Finder.events")

    func start(config: URL, binary: URL, testSource: String?) {
        guard worker == nil else { return }
        state = .connecting; onChange?(state,"Conectando Google Drive con Finder…")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.resourceURL?.appendingPathComponent("NimboDriveService")
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let request: [String:Any] = ["binary":binary.path,"config":config.path,
            "source":testSource ?? "GoogleDrive:","parent":ProcessInfo.processInfo.processIdentifier,"testing":testSource != nil]
        buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.streamQueue.async { [weak self] in
                guard let self else { return }
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of:10) {
                    let line = self.buffer.prefix(upTo:end); self.buffer.removeSubrange(...end)
                    guard let event = try? JSONSerialization.jsonObject(with:line) as? [String:String] else { continue }
                    DispatchQueue.main.async { [weak self] in self?.receive(event, from:process) }
                }
            }
        }
        process.terminationHandler = { [weak self] process in DispatchQueue.main.async {
            guard let self, self.worker === process else { return }
            self.worker = nil; self.commands = nil; self.mountURL = nil
            self.removeFavorite()
            if self.state == .connecting || self.state == .connected {
                self.state = .failed; self.onChange?(self.state,"La conexión con Finder terminó. Podés volver a conectarla.")
            }
            let completion = self.stopCompletion; self.stopCompletion = nil; completion?(true)
        } }
        do {
            let data = try JSONSerialization.data(withJSONObject:request)
            worker = process; commands = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf:data + Data([10]))
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            worker = nil; commands = nil; state = .failed
            onChange?(state,"No se pudo iniciar Finder. Volvé a abrir Nimbo.")
        }
    }
    private func receive(_ event: [String:String], from process: Process) {
        guard worker === process else { return }
        let message = event["message"] ?? ""
        switch event["state"] {
        case "connected":
            guard let path = event["path"], path.hasPrefix("/Volumes/") else { return }
            mountURL = URL(fileURLWithPath:path); state = .connected
            addFavorite()
        case "busy":
            state = .connected
            let completion = stopCompletion; stopCompletion = nil; completion?(false)
        case "disconnected": state = .disconnected; mountURL = nil; removeFavorite()
        case "failed": state = .failed; mountURL = nil; removeFavorite()
        default: state = .connecting
        }
        onChange?(state,message)
    }
    func stop(completion: @escaping (Bool) -> Void) {
        guard let worker, worker.isRunning, let commands else { completion(true); return }
        guard stopCompletion == nil else { completion(false); return }
        stopCompletion = completion
        do { try commands.fileHandleForWriting.write(contentsOf:Data("stop\n".utf8)) }
        catch { stopCompletion = nil; completion(false) }
    }
    private func addFavorite() {
        guard favorite == nil, let url = mountURL else { return }
        // Best effort through the legacy Finder API. Failure leaves the
        // standard network volume and the app's Open in Finder action usable.
        favorite = NimboAddFinderFavorite(url as CFURL,url.lastPathComponent as CFString)
    }
    private func removeFavorite() {
        NimboRemoveFinderFavorite(favorite)
        favorite = nil
    }
}
