#if NATIVE_COMMAND_TESTS
import Foundation

// No File Provider or cloud calls are permitted in these boundary tests.
final class NativeClient {
    init(identifier: String = "google-drive") {}
    func identifierForUserVisibleFile(_ url: URL) async throws -> (id: String, domain: String) { fatalError("Unexpected provider call") }
    func availabilityPage(after: String?) async throws -> NativeAvailabilityPage { fatalError("Unexpected provider call") }
    func downloadNow(_ id: String) async throws { fatalError("Unexpected provider call") }
    func pin(_ id: String, _ value: Bool) async throws { fatalError("Unexpected provider call") }
    func evict(_ id: String) async throws { fatalError("Unexpected provider call") }
}
@main struct NativeCommandTests {
    static func main() throws {
        let fm = FileManager.default, home = fm.temporaryDirectory.appendingPathComponent("NimboCommandTests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let mount = home.appendingPathComponent("Library/CloudStorage/Nimbo-GoogleDrive·Trabajo")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let file = mount.appendingPathComponent("Prueba.txt"), outside = home.appendingPathComponent("other.txt")
        try Data().write(to: file); try Data().write(to: outside)
        let link = mount.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        var checks = 0
        func check(_ ok: Bool) throws { guard ok else { throw CocoaError(.coderInvalidValue) }; checks += 1 }
        for action in ["status", "sync", "pin", "unsync"] {
            let request = try NativeFileCommand.Request(["--native-file-action", action, "--path", file.path], home: home)
            try check(request.action == action && request.url.path == file.path)
        }
        for path in [outside.path, mount.path, link.path, "relative/path"] {
            var rejected = false
            do { _ = try NativeFileCommand.Request(["--native-file-action", "unsync", "--path", path], home: home) } catch { rejected = true }
            try check(rejected)
        }
        let folder=mount.appendingPathComponent("Nested")
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        let directoryRequest=try NativeFileCommand.Request(["--native-file-action","unsync","--path",folder.path],home:home)
        try check(directoryRequest.isDirectory)
        for domain in ["google-drive", "google-drive-account-Q3VlbnRhMg", "google-drive-shared-fixture"] { try check(NativeFileCommand.supports(domain)) }
        for domain in ["other-provider", "google-drive-invalid", "prefix-google-drive"] { try check(!NativeFileCommand.supports(domain)) }
        for label in ["local.nimbo.evict", "local.nimbo.unsync", "Desincronizar", "Desincronizar / liberar espacio con Nimbo", " 'local.nimbo.evict' "] { try check(NativeFileAction.resolve(label) == .evict) }
        for label in ["local.nimbo.sync", "Sincronizar", "Sincronizar ahora con Nimbo"] { try check(NativeFileAction.resolve(label) == .sync) }
        for label in ["local.nimbo.pin", "Conservar sin conexión con Nimbo"] { try check(NativeFileAction.resolve(label) == .pin) }
        for label in ["local.nimbo.refresh", "Refresh", "Actualizar desde Google Drive"] { try check(NativeFileAction.resolve(label) == .refresh) }
        for label in ["untrusted.sync", "garbage local.nimbo.evict", "", "desincronizar inesperado"] { try check(NativeFileAction.resolve(label) == nil) }
        print("PASS: \(checks) native command/action boundary checks; no provider or cloud calls")
    }
}
#endif
