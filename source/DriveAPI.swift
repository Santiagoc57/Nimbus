import Foundation
import CryptoKit

struct DriveObject: Codable, Equatable {
    let id: String
    let name: String
    var mimeType: String
    var size: String?
    var modifiedTime: String?
    var createdTime: String?
    var version: String?
    var md5Checksum: String?
    var parents: [String]?
    var trashed: Bool?
    var capabilities: Capabilities?
    var webViewLink: String?
    var resourceKey: String?
    var properties: [String: String]?
    var projectedSplit: Bool?
    struct Capabilities: Codable, Equatable {
        var canDownload: Bool?
        var canEdit: Bool?
        var canTrash: Bool?
        var canAddChildren: Bool?
        var canRename: Bool?
    }
    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    var isGoogleDocument: Bool { mimeType.hasPrefix("application/vnd.google-apps.") && !isFolder }
}
/// Public Drive metadata travels with the folder, including when shared with a
/// second OAuth client. A normal folder with the same name stays a folder.
struct DriveSplitLayout: Equatable {
    let size: Int64
    let partBytes: Int64
    let md5: String
    let generation: String?
    var count: Int { size == 0 ? 0 : Int((size - 1) / partBytes + 1) }

    init?(size: Int64, partBytes: Int64, md5: String, editing: Bool = false, generation: String? = nil) {
        guard [100_000_000, 500_000_000, 1_000_000_000, 2_000_000_000].contains(partBytes),
              size >= 0, (editing || size > partBytes), (size - 1) / partBytes < 100_000,
              md5.utf8.count == 32, md5.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        if let generation {
            guard generation.utf8.count <= 100, (try? DriveAPI.validateID(generation)) != nil else { return nil }
        }
        self.size = size
        self.partBytes = partBytes
        self.md5 = md5
        self.generation = generation
    }
    init?(_ properties: [String: String]?) {
        guard let p = properties, let version = p["nimboSplit"], ["1", "2"].contains(version),
              let size = Int64(p["nimboBytes"] ?? ""), let part = Int64(p["nimboPartBytes"] ?? ""),
              let hash = p["nimboMD5"], version == "2" || p["nimboRevision"] == nil else { return nil }
        self.init(size: size, partBytes: part, md5: hash, editing: version == "2", generation: p["nimboRevision"])
    }
    var properties: [String: String] {
        var value = ["nimboSplit": generation == nil && size > partBytes ? "1" : "2",
                     "nimboBytes": String(size), "nimboPartBytes": String(partBytes), "nimboMD5": md5]
        value["nimboRevision"] = generation
        return value
    }
    func name(_ index: Int) -> String { String(format: "part-%06d", index + 1) }
    func length(_ index: Int) -> Int64 { min(partBytes, size - Int64(index) * partBytes) }
}

extension DriveObject {
    var splitLayout: DriveSplitLayout? { isFolder || projectedSplit == true ? DriveSplitLayout(properties) : nil }
    var splitPending: Bool { splitLayout != nil && name == ".nimbo-upload-" + id }

    func projected() -> Self {
        guard mimeType == "application/vnd.google-apps.folder", let layout = splitLayout, !splitPending else { return self }
        var result = self
        result.projectedSplit = true
        result.mimeType = "application/octet-stream"
        result.size = String(layout.size)
        result.md5Checksum = layout.md5
        return result
    }
}

struct DriveStorageQuota: Codable, Equatable {
    let limit: String?
    let usage: String?
    let usageInDrive: String?
    private func bytes(_ value: String?) -> Int64? {
        guard let value, let parsed = Int64(value), parsed >= 0 else { return nil }
        return parsed
    }
    var limitBytes: Int64? { bytes(limit) }
    var usageBytes: Int64? { bytes(usage) }
    var driveBytes: Int64? { bytes(usageInDrive) }
    var freeBytes: Int64? {
        guard let limit = limitBytes, let usage = usageBytes else { return nil }
        return max(0, limit - usage)
    }
    var fraction: Double? {
        guard let limit = limitBytes, limit > 0, let usage = usageBytes else { return nil }
        return min(1, Double(usage) / Double(limit))
    }
}
struct DriveAccountOverview: Codable { let storageQuota: DriveStorageQuota? }

struct DrivePage: Codable { let files: [DriveObject]; let nextPageToken: String? }
struct SharedDriveInfo: Codable, Equatable {
    let id: String
    let name: String
    var createdTime: String?
    var hidden: Bool?
}
struct SharedDrivePage: Codable { let drives: [SharedDriveInfo]; let nextPageToken: String? }
struct DriveChanges: Codable {
    struct Change: Codable { let fileId: String?; let removed: Bool?; let file: DriveObject? }
    let changes: [Change]
    let nextPageToken: String?
    let newStartPageToken: String?
}
enum DriveFailure: Error, LocalizedError {
    case notAuthenticated, denied, notFound, quota, invalidResponse, unavailable, unsupportedCredentials, conflict, anchorExpired
    case inheritedPublicAccess
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Volvé a autorizar Google Drive desde Nimbo."
        case .denied: return "Google Drive no permite acceder a este archivo."
        case .notFound: return "El archivo ya no está disponible en Google Drive."
        case .quota: return "Google Drive alcanzó una cuota. La operación podrá reintentarse."
        case .invalidResponse: return "Google Drive devolvió una respuesta que Nimbo no pudo validar."
        case .unavailable: return "Google Drive no está disponible. Comprobá la conexión a internet."
        case .unsupportedCredentials: return "Esta configuración necesita renovarse desde Nimbo."
        case .conflict: return "El archivo cambió en Google Drive. Se conservan los cambios locales para resolver el conflicto."
        case .anchorExpired: return "Google Drive descartó el cursor de cambios. Nimbo volverá a enumerar la carpeta."
        case .inheritedPublicAccess: return "El acceso público se hereda de una carpeta. Cambialo en la carpeta de origen desde Google Drive; Nimbo no modificó estos permisos."
        case .http(let code): return "Google Drive rechazó la operación (HTTP \(code))."
        }
    }
}

struct DrivePublicRevocationFailure: Error, LocalizedError {
    let removed: Int
    let underlying: Error
    var errorDescription: String? {
        "Se quitaron \(removed) permisos públicos, pero la operación quedó incompleta. Revisá los accesos en Google Drive. " + underlying.localizedDescription
    }
}

/// Stable Google IDs and bounded metadata pages for the native File Provider.
/// Credentials are never returned through errors or included in request URLs.
actor DriveAPI {
    static let fields = "id,name,mimeType,size,modifiedTime,createdTime,version,md5Checksum,parents,properties,trashed,webViewLink,resourceKey,capabilities(canDownload,canEdit,canTrash,canAddChildren,canRename)"
    private static let configWriteLock = NSLock()
    private let configuration: URL
    let remoteName: String
    private let session: URLSession
    private var refresh: Task<String,Error>?
    init(configuration: URL, remoteName: String = "GoogleDrive", session: URLSession = .shared) { self.configuration = configuration; self.remoteName = remoteName; self.session = session }

    func transferRate(_ direction: TransferDirection) -> Int {
        SyncSettings.read(at: SyncSettings.file(for: configuration))[direction]
    }

    private struct Token: Codable {
        var access_token: String
        var token_type: String?
        var refresh_token: String?
        var expiry: String?
        var expires_in: Int?
        var scope: String?
    }
    static func configurationSection(_ text: String, remoteName: String) -> [String: String] {
        var current = false, values:[String:String] = [:]
        for line in text.components(separatedBy:.newlines) {
            let value = line.trimmingCharacters(in:.whitespaces)
            if value.hasPrefix("[") { current = value == "[\(remoteName)]"; continue }
            if current, let split = value.firstIndex(of:"=") {
                values[value[..<split].trimmingCharacters(in:.whitespaces)] = value[value.index(after:split)...].trimmingCharacters(in:.whitespaces)
            }
        }
        return values
    }
    func permitsWrites() throws -> Bool {
        NimboSecureConfig.ensureRuntime(configuration)
        let values=Self.configurationSection(try String(contentsOf:configuration,encoding:.utf8), remoteName: remoteName)
        return (values["scope"] ?? "").split(whereSeparator:{$0=="," || $0.isWhitespace}).contains("drive")
    }
    private func token(forceRefresh:Bool = false) async throws -> String {
        if let refresh { return try await refresh.value }
        NimboSecureConfig.ensureRuntime(configuration)
        guard let text = try? String(contentsOf:configuration,encoding:.utf8) else { throw DriveFailure.notAuthenticated }
        let values = Self.configurationSection(text, remoteName: remoteName)
        guard let encoded = values["token"]?.data(using:.utf8), let existing = try? JSONDecoder().decode(Token.self,from:encoded) else { throw DriveFailure.notAuthenticated }
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let fractional = existing.expiry.flatMap{format.date(from:$0)}
        format.formatOptions = [.withInternetDateTime]
        let expiration = fractional ?? existing.expiry.flatMap{format.date(from:$0)} ?? .distantPast
        if !forceRefresh, expiration.timeIntervalSinceNow > 90, !existing.access_token.isEmpty { return existing.access_token }
        guard let refreshToken = existing.refresh_token, let clientID = values["client_id"], let secret = values["client_secret"], !refreshToken.isEmpty, !clientID.isEmpty, !secret.isEmpty else { throw DriveFailure.notAuthenticated }
        // Nimbo's own desktop OAuth client is stored in this format. Obscured
        // third-party rclone secrets are not silently treated as clear text.
        guard secret.hasPrefix("GOCSPX-") else { throw DriveFailure.unsupportedCredentials }
        let task = Task<String,Error> {
            var request = URLRequest(url:URL(string:"https://oauth2.googleapis.com/token")!)
            request.httpMethod = "POST"; request.timeoutInterval = 60
            request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
            var form = URLComponents(); form.queryItems = [URLQueryItem(name:"grant_type",value:"refresh_token"),URLQueryItem(name:"refresh_token",value:refreshToken),URLQueryItem(name:"client_id",value:clientID),URLQueryItem(name:"client_secret",value:secret)]
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B").data(using:.utf8)
            let (data,response) = try await self.session.data(for:request)
            guard let http = response as? HTTPURLResponse else { throw DriveFailure.invalidResponse }
            guard http.statusCode == 200 else { throw DriveFailure.notAuthenticated }
            guard data.count < 64*1024, var result = try? JSONDecoder().decode(Token.self,from:data), !result.access_token.isEmpty else { throw DriveFailure.invalidResponse }
            result.refresh_token = result.refresh_token ?? refreshToken
            let formatter = ISO8601DateFormatter(); result.expiry = formatter.string(from:Date().addingTimeInterval(TimeInterval(result.expires_in ?? 3600)))
            try self.persist(result,originalRefreshToken:refreshToken)
            return result.access_token
        }
        refresh = task
        defer { refresh = nil }
        return try await task.value
    }
    private func persist(_ token:Token, originalRefreshToken:String) throws {
        // Multiple account-specific DriveAPI actors share Nimbo's one runtime
        // rclone file. Serialize the read/modify/write so a refresh for one
        // account cannot discard a token written by another account.
        Self.configWriteLock.lock(); defer { Self.configWriteLock.unlock() }
        // Re-read after the network call so an interactive reauthorization is
        // not overwritten with an older account's token.
        NimboSecureConfig.ensureRuntime(configuration)
        let latest = try String(contentsOf:configuration,encoding:.utf8)
        guard let encoded = Self.configurationSection(latest, remoteName: remoteName)["token"]?.data(using:.utf8), let current = try? JSONDecoder().decode(Token.self,from:encoded), current.refresh_token == originalRefreshToken else { throw DriveFailure.notAuthenticated }
        let replacement = String(data:try JSONEncoder().encode(token),encoding:.utf8)!
        var currentSection = false, found = false
        let lines = latest.components(separatedBy:.newlines).map { line -> String in
            let value = line.trimmingCharacters(in:.whitespaces)
            if value.hasPrefix("[") { currentSection = value == "[\(remoteName)]" }
            if currentSection, let equal = value.firstIndex(of:"="), value[..<equal].trimmingCharacters(in:.whitespaces) == "token" { found = true; return "token = " + replacement }
            return line
        }
        guard found else { throw DriveFailure.notAuthenticated }
        try Data(lines.joined(separator:"\n").utf8).write(to:configuration,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configuration.path)
    }
    private func url(_ path:String,_ query:[URLQueryItem]) throws -> URL {
        var components = URLComponents(); components.scheme = "https"; components.host = "www.googleapis.com"; components.path = "/drive/v3/" + path; components.queryItems = query
        guard let url = components.url else { throw DriveFailure.invalidResponse }; return url
    }
    /// Shared authenticated transport for bounded upload chunks. Never sends a
    /// bearer token to a session URL outside Google's API origin.
    func send(_ target:URL,method:String,headers:[String:String]=[:],body:Data?=nil) async throws -> (Data,HTTPURLResponse) {
        guard target.scheme=="https", target.host=="www.googleapis.com", target.user==nil, target.password==nil, target.port==nil || target.port==443 else {throw DriveFailure.denied}
        var retries = 0, refreshed = false
        while retries < 3 {
            try Task.checkCancellation()
            var request=URLRequest(url:target); request.httpMethod=method; request.httpBody=body; request.timeoutInterval=120
            for (key,value) in headers {request.setValue(value,forHTTPHeaderField:key)}
            request.setValue("Bearer "+(try await token(forceRefresh:refreshed)),forHTTPHeaderField:"Authorization")
            let (data,response)=try await session.data(for:request)
            guard let response=response as? HTTPURLResponse, data.count<=64*1024*1024 else{throw DriveFailure.invalidResponse}
            if response.statusCode==401 && !refreshed { refreshed=true; continue }
            if Self.retryable(response.statusCode) && retries < 2 {
                retries += 1
                try await Self.retryDelay(retries)
                continue
            }
            return (data,response)
        }
        throw DriveFailure.unavailable
    }
    static func validateID(_ id:String) throws {
        guard !id.isEmpty, id.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else { throw DriveFailure.invalidResponse }
    }
    private func request(_ url:URL,retryAuthentication:Bool = true) async throws -> Data {
        var retries=0, refreshed=false
        while retries < 3 {
            var request = URLRequest(url:url); request.timeoutInterval = 90
            request.setValue("Bearer " + (try await token(forceRefresh:refreshed)),forHTTPHeaderField:"Authorization")
            let (data,response) = try await session.data(for:request)
            guard let http = response as? HTTPURLResponse else { throw DriveFailure.invalidResponse }
            if http.statusCode == 401, retryAuthentication, !refreshed { refreshed=true; continue }
            if Self.retryable(http.statusCode) && retries < 2 {
                retries += 1
                try await Self.retryDelay(retries)
                continue
            }
            try Self.validate(http.statusCode,data:data)
            guard data.count <= 64*1024*1024 else { throw DriveFailure.invalidResponse }
            return data
        }
        throw DriveFailure.unavailable
    }
    private static func retryable(_ status:Int) -> Bool { status == 408 || status == 429 || (500...599).contains(status) }
    private static func retryDelay(_ attempt:Int) async throws {
        let seconds = UInt64(200_000_000 * max(1, min(attempt, 2)))
        try await Task.sleep(nanoseconds: seconds)
    }
    static func validate(_ status:Int,data:Data) throws {
        guard (200..<300).contains(status) else {
            switch status {
            case 401: throw DriveFailure.notAuthenticated
            case 403:
                let message = (String(data:data.prefix(65536),encoding:.utf8) ?? "").lowercased()
                if message.contains("ratelimitexceeded") || message.contains("dailylimitexceeded") || message.contains("quotaexceeded") { throw DriveFailure.quota }
                throw DriveFailure.denied
            case 404: throw DriveFailure.notFound
            case 410: throw DriveFailure.anchorExpired
            case 412: throw DriveFailure.conflict
            case 429: throw DriveFailure.quota
            case 500...599: throw DriveFailure.unavailable
            default: throw DriveFailure.http(status)
            }
        }
    }
    /// About reports account storage (including other Google services, and
    /// potentially an organization's pool). Never sum this across identities.
    func accountOverview() async throws -> DriveAccountOverview {
        let endpoint = try url("about", [URLQueryItem(name: "fields", value: "storageQuota(limit,usage,usageInDrive)")])
        return try JSONDecoder().decode(DriveAccountOverview.self, from: await request(endpoint))
    }
    func item(_ id:String) async throws -> DriveObject {
        try Self.validateID(id)
        return try JSONDecoder().decode(DriveObject.self,from:await request(url("files/" + id,[URLQueryItem(name:"fields",value:Self.fields),URLQueryItem(name:"supportsAllDrives",value:"true")]))).projected()
    }
    /// Resolve metadata with this remote's credentials. Browser cookies are
    /// independent; never force the first browser account with /u/0/.
    func browserLink(_ id: String) async throws -> URL {
        let object = try await item(id)
        guard object.id == id || id == "root" else { throw DriveFailure.invalidResponse }
        guard object.trashed != true else { throw DriveFailure.notFound }
        return try Self.browserLink(for: object)
    }
    static func browserLink(for object: DriveObject) throws -> URL {
        try validateID(object.id)
        if let link = object.webViewLink, !link.isEmpty {
            return try validatedBrowserURL(link) // Keep official resource keys.
        }
        var parts = URLComponents(string: "https://drive.google.com/open")!
        parts.queryItems = [URLQueryItem(name: "id", value: object.id)]
        if let key = object.resourceKey, !key.isEmpty { parts.queryItems?.append(URLQueryItem(name: "resourcekey", value: key)) }
        guard let url = parts.url else { throw DriveFailure.invalidResponse }
        return url
    }
    static func validatedBrowserURL(_ link: String) throws -> URL {
        guard let url = URL(string: link), url.scheme == "https",
              ["drive.google.com", "docs.google.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw DriveFailure.invalidResponse
        }
        return url
    }
    /// Fetch Google's preview, never alt=media or an export of the original.
    func thumbnail(_ id: String) async throws -> Data? {
        try Self.validateID(id)
        struct Preview: Decodable {
            let id: String
            let mimeType: String
            var thumbnailLink: String?
            var capabilities: DriveObject.Capabilities?
        }
        let metadata = try await request(url("files/" + id, [
            URLQueryItem(name: "fields", value: "id,mimeType,thumbnailLink,capabilities(canDownload)"),
            URLQueryItem(name: "supportsAllDrives", value: "true")]))
        let preview = try JSONDecoder().decode(Preview.self, from: metadata)
        guard preview.id == id else { throw DriveFailure.invalidResponse }
        guard preview.mimeType != "application/vnd.google-apps.folder", preview.capabilities?.canDownload != false,
              let link = preview.thumbnailLink else { return nil }
        guard let target = URL(string: link), Self.isThumbnailURL(target) else { throw DriveFailure.denied }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var request = URLRequest(url: target)
            request.timeoutInterval = 20
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            request.setValue("Bearer " + (try await token(forceRefresh: attempt > 0)), forHTTPHeaderField: "Authorization")
            do { return try await DriveThumbnailLoader.fetch(request, configuration: session.configuration) }
            catch DriveFailure.notAuthenticated where attempt == 0 { continue }
        }
        throw DriveFailure.notAuthenticated
    }

    static func isThumbnailURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "drive.google.com" || host == "lh3.google.com" || host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com")
    }
    private struct Permission: Decodable {
        struct Detail: Decodable { let inherited: Bool? }
        let id: String?
        let type: String?
        let role: String?
        let permissionDetails: [Detail]?
        let view: String?
        var inherited: Bool { permissionDetails?.contains { $0.inherited == true } == true }
    }
    private struct PermissionPage:Decodable { let permissions:[Permission]?; let nextPageToken:String? }
    private func permissions(_ id:String) async throws -> [Permission] {
        try Self.validateID(id)
        var all:[Permission]=[]
        var page:String?
        var seen=Set<String>()
        repeat {
            var query=[URLQueryItem(name:"fields",value:"permissions(id,type,role,view,permissionDetails(inherited)),nextPageToken"),URLQueryItem(name:"supportsAllDrives",value:"true"),URLQueryItem(name:"pageSize",value:"100")]
            if let page { query.append(URLQueryItem(name:"pageToken",value:page)) }
            let response=try JSONDecoder().decode(PermissionPage.self,from:await request(url("files/"+id+"/permissions",query)))
            all.append(contentsOf:response.permissions ?? [])
            guard all.count <= 1000 else { throw DriveFailure.invalidResponse }
            guard let next=response.nextPageToken else { break }
            guard seen.insert(next).inserted else { throw DriveFailure.invalidResponse }
            page=next
        } while page != nil
        return all
    }
    /// This is a permission-changing action, distinct from browserLink().
    /// Validate the destination before publishing and preserve existing roles.
    func createPublicLink(_ id: String) async throws -> String {
        try Self.validateID(id)
        try Task.checkCancellation()
        guard try permitsWrites() else { throw DriveFailure.denied }
        let link = try await browserLink(id).absoluteString
        let publicPermissions = try await permissions(id).filter { $0.type == "anyone" }
        // Unknown/view-only grants must not silently become full public access.
        guard publicPermissions.allSatisfy({ $0.view == nil && ["reader", "commenter", "writer"].contains($0.role ?? "") }) else {
            throw DriveFailure.invalidResponse
        }
        try Task.checkCancellation()
        if publicPermissions.isEmpty {
            let body = Data("{\"type\":\"anyone\",\"role\":\"reader\",\"allowFileDiscovery\":false}".utf8)
            let response = try await send(url("files/" + id + "/permissions", [URLQueryItem(name: "supportsAllDrives", value: "true"), URLQueryItem(name: "fields", value: "id,type,role")]), method: "POST", headers: ["Content-Type": "application/json"], body: body)
            try Self.validate(response.1.statusCode, data: response.0)
        }
        return link
    }
    /// Preflight the entire public ACL before deleting anything. Never edit a
    /// parent to remove inherited access or touch user/group/domain grants.
    func revokePublicLinks(_ id: String) async throws -> Int {
        try Self.validateID(id)
        try Task.checkCancellation()
        guard try permitsWrites() else { throw DriveFailure.denied }
        let publicPermissions = try await permissions(id).filter { $0.type == "anyone" }
        guard !publicPermissions.contains(where: { $0.inherited }) else { throw DriveFailure.inheritedPublicAccess }
        var identifiers: [String] = [], seen = Set<String>()
        for permission in publicPermissions {
            guard permission.view == nil, let identifier = permission.id else { throw DriveFailure.invalidResponse }
            try Self.validateID(identifier)
            if seen.insert(identifier).inserted { identifiers.append(identifier) }
        }
        var removed = 0
        do {
            for identifier in identifiers {
                try Task.checkCancellation()
                let response = try await send(url("files/" + id + "/permissions/" + identifier, [URLQueryItem(name: "supportsAllDrives", value: "true")]), method: "DELETE")
                try Self.validate(response.1.statusCode, data: response.0)
                removed += 1
            }
        } catch {
            guard removed > 0 else { throw error }
            throw DrivePublicRevocationFailure(removed: removed, underlying: error)
        }
        return removed
    }
    func children(_ parent:String,page:String? = nil) async throws -> DrivePage {
        let result = try await rawChildren(parent, page: page)
        return DrivePage(files: result.files.filter { !$0.splitPending }.map { $0.projected() }, nextPageToken: result.nextPageToken)
    }

    func rawChildren(_ parent: String, page: String? = nil) async throws -> DrivePage {
        try Self.validateID(parent)
        var query = [URLQueryItem(name:"q",value:"'\(parent)' in parents and trashed = false"),URLQueryItem(name:"fields",value:"nextPageToken,files(\(Self.fields))"),URLQueryItem(name:"pageSize",value:"1000"),URLQueryItem(name:"spaces",value:"drive"),URLQueryItem(name:"supportsAllDrives",value:"true"),URLQueryItem(name:"includeItemsFromAllDrives",value:"true")]
        if let page { query.append(URLQueryItem(name:"pageToken",value:page)) }
        return try JSONDecoder().decode(DrivePage.self,from:await request(url("files",query)))
    }
    /// Lists items currently in the authenticated user's Drive trash. The
    /// caller owns pagination so a UI can stay bounded and responsive.
    func trashPage(page:String? = nil) async throws -> DrivePage {
        var query = [URLQueryItem(name:"q",value:"trashed = true"),URLQueryItem(name:"fields",value:"nextPageToken,files(\(Self.fields))"),URLQueryItem(name:"pageSize",value:"1000"),URLQueryItem(name:"spaces",value:"drive"),URLQueryItem(name:"supportsAllDrives",value:"true"),URLQueryItem(name:"includeItemsFromAllDrives",value:"true"),URLQueryItem(name:"orderBy",value:"modifiedTime desc")]
        if let page { query.append(URLQueryItem(name:"pageToken",value:page)) }
        return try JSONDecoder().decode(DrivePage.self,from:await request(url("files",query)))
    }
    /// Reads a bounded snapshot of Drive trash and rejects a repeated page
    /// token instead of looping or silently returning an incomplete list.
    func allTrash(limit:Int = 2000) async throws -> [DriveObject] {
        guard limit > 0 else { return [] }
        var values:[DriveObject]=[], page:String?, seen=Set<String>()
        repeat {
            let result=try await trashPage(page:page)
            values.append(contentsOf:result.files)
            if values.count >= limit { return Array(values.prefix(limit)) }
            guard let next=result.nextPageToken else { return values }
            guard seen.insert(next).inserted else { throw DriveFailure.invalidResponse }
            page=next
        } while true
    }
    func sharedDrives(page:String? = nil) async throws -> SharedDrivePage {
        var query = [URLQueryItem(name:"pageSize",value:"100"),URLQueryItem(name:"fields",value:"nextPageToken,drives(id,name,createdTime,hidden)"),URLQueryItem(name:"useDomainAdminAccess",value:"false")]
        if let page { query.append(URLQueryItem(name:"pageToken",value:page)) }
        return try JSONDecoder().decode(SharedDrivePage.self,from:await request(url("drives",query)))
    }
    /// Resolves every shared-drive page up to a bounded result count. A
    /// repeated token is treated as a provider pagination fault so the call
    /// cannot loop forever on a stale response.
    func allSharedDrives(limit:Int = 500) async throws -> [SharedDriveInfo] {
        guard limit > 0 else { return [] }
        var values:[SharedDriveInfo] = [], page:String?, seen=Set<String>()
        repeat {
            let result=try await sharedDrives(page:page)
            values.append(contentsOf:result.drives)
            if values.count >= limit { return Array(values.prefix(limit)) }
            guard let next=result.nextPageToken else { return values }
            guard seen.insert(next).inserted else { throw DriveFailure.invalidResponse }
            page=next
        } while true
    }
    /// Restores exactly one item from Drive trash. No descendants or other
    /// trash entries are touched implicitly.
    func restoreFromTrash(_ id:String) async throws -> DriveObject {
        try Self.validateID(id)
        let body = Data("{\"trashed\":false}".utf8)
        let response = try await send(url("files/" + id,[URLQueryItem(name:"supportsAllDrives",value:"true"),URLQueryItem(name:"fields",value:Self.fields)]), method:"PATCH", headers:["Content-Type":"application/json"], body:body)
        try Self.validate(response.1.statusCode,data:response.0)
        return try JSONDecoder().decode(DriveObject.self,from:response.0)
    }
    /// Permanently deletes exactly one item already in Drive trash. The caller
    /// must obtain explicit confirmation before invoking this method.
    func permanentlyDeleteFromTrash(_ id:String) async throws {
        try Self.validateID(id)
        let response = try await send(url("files/" + id,[URLQueryItem(name:"supportsAllDrives",value:"true")]), method:"DELETE")
        try Self.validate(response.1.statusCode,data:response.0)
    }
    func currentAnchor() async throws -> String {
        struct Anchor:Decodable { let startPageToken:String }
        return try JSONDecoder().decode(Anchor.self,from:await request(url("changes/startPageToken",[URLQueryItem(name:"supportsAllDrives",value:"true")]))).startPageToken
    }
    func changes(since anchor:String) async throws -> DriveChanges {
        let result=try JSONDecoder().decode(DriveChanges.self,from:await request(url("changes",[URLQueryItem(name:"pageToken",value:anchor),URLQueryItem(name:"fields",value:"nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fields)))"),URLQueryItem(name:"pageSize",value:"1000"),URLQueryItem(name:"spaces",value:"drive"),URLQueryItem(name:"supportsAllDrives",value:"true"),URLQueryItem(name:"includeItemsFromAllDrives",value:"true")])) )
        if result.nextPageToken == anchor { throw DriveFailure.invalidResponse }
        let visible = result.changes.compactMap { change -> DriveChanges.Change? in
            guard change.file?.splitPending != true else { return nil }
            return DriveChanges.Change(fileId: change.fileId, removed: change.removed, file: change.file?.projected())
        }
        return DriveChanges(changes: visible, nextPageToken: result.nextPageToken, newStartPageToken: result.newStartPageToken)
    }
    func downloadSplit(_ object: DriveObject, to destination: URL, rate: Int? = nil, progress: @escaping (Int64) -> Void = { _ in }) async throws {
        guard let layout = object.splitLayout, !object.splitPending, object.trashed != true else { throw DriveFailure.invalidResponse }
        let partParent = layout.generation ?? object.id
        if let generation = layout.generation {
            let version = try await item(generation)
            guard version.parents == [object.id], version.name == ".nimbo-version-" + generation,
                  version.trashed != true, let inner = version.splitLayout, inner.generation == nil,
                  inner.size == layout.size, inner.partBytes == layout.partBytes, inner.md5 == layout.md5 else { throw DriveFailure.conflict }
        }
        var parts: [String: DriveObject] = [:], tokens = Set<String>(), page: String?
        repeat {
            try Task.checkCancellation()
            let result = try await rawChildren(partParent, page: page)
            for part in result.files {
                // A writer can prepare the next immutable version while an
                // existing reader is assembling the original direct parts.
                if layout.generation == nil, part.isFolder, part.parents == [object.id], part.splitLayout != nil,
                   part.splitPending || part.name == ".nimbo-version-" + part.id { continue }
                guard !part.isFolder, !part.isGoogleDocument, part.splitLayout == nil,
                      part.parents == [partParent], part.trashed != true,
                      parts.updateValue(part, forKey: part.name) == nil, parts.count <= layout.count else { throw DriveFailure.invalidResponse }
            }
            page = result.nextPageToken
            if let page, !tokens.insert(page).inserted { throw DriveFailure.invalidResponse }
        } while page != nil
        guard parts.count == layout.count else { throw DriveFailure.invalidResponse }
        let fm = FileManager.default
        let work = destination.deletingLastPathComponent().appendingPathComponent(".nimbo-read-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let assembled = work.appendingPathComponent("complete")
        guard fm.createFile(atPath: assembled.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DriveFailure.unavailable }
        let output = try FileHandle(forWritingTo: assembled)
        defer { try? output.close() }
        var hash = Insecure.MD5()
        for index in 0..<layout.count {
            guard let part = parts[layout.name(index)], let expected = part.md5Checksum,
                  part.size == String(layout.length(index)) else { throw DriveFailure.invalidResponse }
            let file = work.appendingPathComponent("part")
            try await download(part.id, to: file, expectedSize: layout.length(index), rateOverride: rate) { bytes in
                progress(Int64(index) * layout.partBytes + bytes)
            }
            let input = try FileHandle(forReadingFrom: file)
            var partHash = Insecure.MD5()
            do {
                while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty {
                    try Task.checkCancellation()
                    partHash.update(data: block); hash.update(data: block)
                    try output.write(contentsOf: block)
                }
                try input.close()
            } catch { try? input.close(); throw error }
            guard partHash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw DriveFailure.invalidResponse }
            try fm.removeItem(at: file)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == layout.md5 else { throw DriveFailure.invalidResponse }
        let current = try await item(object.id)
        guard current.splitLayout == layout, !current.splitPending, current.trashed != true else { throw DriveFailure.conflict }
        try output.close()
        try fm.moveItem(at: assembled, to: destination)
    }

    /// Downloads media in bounded HTTP ranges. A sibling `.nimbo.part` is
    /// retained when a transfer fails so the next request resumes from the
    /// acknowledged byte offset instead of discarding a large partial file.
    /// File Provider callers pass the expected metadata size when available;
    /// the final length is always checked before publication.
    func download(_ id:String,to destination:URL,expectedSize:Int64? = nil, rateOverride: Int? = nil, progress: (Int64) -> Void = { _ in }) async throws {
        try Self.validateID(id)
        let fileManager = FileManager.default
        let partial = destination.appendingPathExtension("nimbo.part")
        if let expectedSize, expectedSize < 0 { throw DriveFailure.invalidResponse }
        var offset:Int64 = 0
        if fileManager.fileExists(atPath:partial.path) {
            let attrs = try fileManager.attributesOfItem(atPath:partial.path)
            if attrs[.type] as? FileAttributeType != .typeRegular ||
               (attrs[.size] as? NSNumber)?.int64Value ?? -1 < 0 {
                try? fileManager.removeItem(at:partial)
            } else if let size = attrs[.size] as? NSNumber {
                offset=size.int64Value
            }
        }
        if let expectedSize, offset > expectedSize {
            try? fileManager.removeItem(at:partial)
            offset = 0
        }
        if !fileManager.fileExists(atPath:partial.path) {
            guard fileManager.createFile(atPath:partial.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw DriveFailure.unavailable }
        }
        var total = expectedSize
        let rate = rateOverride ?? transferRate(.download)
        let chunk = NativeBandwidthClock.chunkBytes(rate: rate)
        while total == nil || offset < total! {
            try Task.checkCancellation()
            let bytes = min(chunk, total.map { $0 - offset } ?? chunk)
            try await NativeBandwidthClock.shared.reserve(bytes: bytes, rate: rate, direction: .download)
            let end = offset + bytes - 1
            let target = try url("files/" + id,[URLQueryItem(name:"alt",value:"media"),URLQueryItem(name:"supportsAllDrives",value:"true")])
            let (body,response) = try await send(target,method:"GET",headers:["Range":"bytes=\(offset)-\(end)"])
            if response.statusCode == 416 {
                guard let total, offset == total else { throw DriveFailure.invalidResponse }
                break
            }
            try Self.validate(response.statusCode,data:body)
            guard !body.isEmpty || (expectedSize == 0 && offset == 0) else { throw DriveFailure.invalidResponse }
            var writeOffset = offset
            var reportedTotal: Int64?
            if response.statusCode == 206 {
                guard let range = response.value(forHTTPHeaderField:"Content-Range"),
                      let parsed = Self.parseContentRange(range),
                      parsed.start == offset,
                      parsed.end >= parsed.start,
                      parsed.end - parsed.start + 1 == Int64(body.count) else { throw DriveFailure.invalidResponse }
                reportedTotal = parsed.total
            } else if response.statusCode == 200 {
                // Some compatible endpoints ignore Range. If resuming against
                // one, restart from the complete response rather than append
                // a second copy of the file.
                if offset != 0 {
                    let handle = try FileHandle(forWritingTo:partial); try handle.truncate(atOffset:0); try handle.close()
                    writeOffset = 0
                }
                reportedTotal = response.value(forHTTPHeaderField:"Content-Length").flatMap(Int64.init) ?? Int64(body.count)
            } else { throw DriveFailure.invalidResponse }
            let handle = try FileHandle(forWritingTo:partial)
            try handle.seek(toOffset:UInt64(writeOffset)); try handle.write(contentsOf:body); try handle.close()
            offset = writeOffset + Int64(body.count)
            progress(offset)
            if let reportedTotal { total = reportedTotal }
            if let expectedSize, total == nil { total = expectedSize }
            if body.count < Int(chunk), total == nil { total = offset }
        }
        guard let total, offset == total else { throw DriveFailure.invalidResponse }
        if let expectedSize, total != expectedSize { throw DriveFailure.invalidResponse }
        if fileManager.fileExists(atPath:destination.path) { try fileManager.removeItem(at:destination) }
        try fileManager.moveItem(at:partial,to:destination)
    }

    private static func parseContentRange(_ value:String)->(start:Int64,end:Int64,total:Int64?)? {
        guard value.hasPrefix("bytes "), let slash=value.firstIndex(of:"/") else { return nil }
        let bounds=value.index(value.startIndex,offsetBy:6)..<slash
        guard let dash=value[bounds].firstIndex(of:"-") else { return nil }
        let start=Int64(value[bounds].prefix(upTo:dash))
        let end=Int64(value[bounds].suffix(from:value[bounds].index(after:dash)))
        let totalText=String(value[value.index(after:slash)...])
        let total=totalText == "*" ? nil : Int64(totalText)
        guard let start, let end, start >= 0, end >= start, total == nil || total! > end else { return nil }
        return (start,end,total)
    }
}


/// Dedicated thumbnail transport: bounded streaming, no cookies/disk URL cache,
/// and no redirects (including redirects that might forward authorization).
private final class DriveThumbnailLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let limit = 2 * 1024 * 1024
    private let lock = NSLock()
    private var session: URLSession?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var finished = false
    private var cancelled = false
    private var bytes = Data()

    static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        let loader = DriveThumbnailLoader()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                loader.start(request, configuration: configuration) { continuation.resume(with: $0) }
            }
        }, onCancel: { loader.cancel() })
    }

    private func start(_ request: URLRequest, configuration: URLSessionConfiguration, completion: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); completion(.failure(CancellationError())); return }
        self.completion = completion
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock(); cancelled = true; let active = completion != nil; lock.unlock()
        if active { finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = completion; completion = nil
        let current = session; session = nil
        lock.unlock()
        current?.invalidateAndCancel()
        callback?(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw DriveFailure.invalidResponse }
            try DriveAPI.validate(http.statusCode, data: Data())
            guard http.statusCode == 200, http.mimeType?.hasPrefix("image/") == true,
                  http.expectedContentLength <= Int64(Self.limit) else { throw DriveFailure.invalidResponse }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel); finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let exceedsLimit = data.count > Self.limit || bytes.count > Self.limit - data.count
        if !exceedsLimit { bytes.append(data) }
        lock.unlock()
        if exceedsLimit { finish(.failure(DriveFailure.invalidResponse)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let result = bytes; lock.unlock()
        finish(result.isEmpty ? .failure(DriveFailure.invalidResponse) : .success(result))
    }
}
