import Foundation

/// Canonical action IDs plus exact compatibility labels. In particular,
/// "desincronizar" must never match "sincronizar" by substring.
enum NativeFileAction {
    case sync, pin, evict, refresh
    static func resolve(_ raw: String) -> Self? {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t()"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
        switch value {
        case "local.nimbo.sync", "sync", "sincronizar", "sincronizar ahora con nimbo": return .sync
        case "local.nimbo.pin", "pin", "conservar sin conexion", "conservar sin conexion con nimbo": return .pin
        case "local.nimbo.refresh", "refresh", "actualizar desde google drive": return .refresh
        case "local.nimbo.evict", "local.nimbo.unsync", "unsync", "desincronizar", "liberar espacio", "desincronizar / liberar espacio con nimbo": return .evict
        default: return nil
        }
    }
}
