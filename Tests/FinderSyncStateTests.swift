import Foundation

@main
struct FinderSyncStateTests {
    static func main() {
        check(NimboFinderSync.primaryAction(materialized: [false]) == .pin, "placeholder offers Conservar sin conexión")
        check(NimboFinderSync.primaryAction(materialized: [true]) == .evict, "materialized file offers Desincronizar / liberar espacio")
        check(NimboFinderSync.primaryAction(materialized: [true, true]) == .evict, "fully materialized selection offers eviction")
        check(NimboFinderSync.primaryAction(materialized: [false, true]) == .pin, "mixed selection offers monotonic pinning")
        check(NimboFinderSync.primaryAction(materialized: []) == .pin, "empty defensive selection defaults to pin")
        print("PASS: 5 Finder context state checks")
    }

    private static func check(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        print("PASS: \(message)")
    }
}
