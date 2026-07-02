import Foundation

// MARK: - XiaomiCloudAuth
//
// In-app port of token_extractor.py's QR-code login flow (QrCodeXiaomiCloudConnector)
// plus the encrypted device API (get_homes / get_dev_cnt / get_devices / get_beaconkey).
//
// Goal: let the user authenticate with their Xiaomi account by scanning a QR code, then
// pull the band's `beaconkey` — which IS the BLE AuthKey (secretKey) the band handshake needs.
// No password is ever typed into the app; auth happens entirely on Xiaomi's side via the QR.
//
// Flow (mirrors the Python steps):
//   1. GET /longPolling/loginUrl            → qr image url, loginUrl, long-polling url, timeout
//   2. (user scans the QR with the Xiaomi / Mi Home app on another device, or opens loginUrl)
//   3. long-poll until 200                  → userId, ssecurity, location
//   4. GET location                          → serviceToken cookie
//   5. for each region: encrypted API calls → BLE devices + their beaconkey
//
// Status of cloud bits in this project: implemented faithfully from the reference, but the
// Xiaomi endpoints are fragile and region/account-dependent — VALIDATE against a real account.

@MainActor
@Observable
final class XiaomiCloudAuth {

    // A BLE band discovered in the Xiaomi cloud, carrying its beaconkey (= AuthKey).
    struct CloudBand: Identifiable, Hashable {
        let id: String        // did
        let name: String
        let model: String
        let mac: String
        let beaconKey: String // hex — what we save to the Keychain
        let server: String
    }

    enum Phase: Equatable {
        case idle
        case requestingCode      // fetching the QR
        case awaitingScan        // QR shown, waiting for the user to scan/confirm
        case authenticating      // scanned — exchanging for a service token
        case fetchingDevices     // pulling devices + beaconkeys
        case done                // see `bands`
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var qrImageURL: URL?     // image of the QR code to display/scan
    private(set) var loginURL: URL?       // URL encoded in the QR (open in the Xiaomi app)
    private(set) var bands: [CloudBand] = []

    // Servers a Xiaomi account/device may live on (token_extractor SERVERS).
    private static let servers = ["cn", "de", "us", "ru", "tw", "sg", "in", "i2"]

    private let session: URLSession
    private let agent = XiaomiCloudAuth.generateAgent()
    private let deviceId = XiaomiCloudAuth.generateDeviceId()

    private var ssecurity: String?
    private var userId: String?
    private var location: String?
    private var serviceToken: String?
    private var longPollingURL: String?
    // Window the user has to finish the Xiaomi login. The server's `timeout` is in SECONDS
    // (token_extractor uses it as-is), but we floor it generously: the user has to leave to the
    // in-app Xiaomi page, sign in, and come back before any poll can observe success.
    private var pollTimeout: TimeInterval = 300

    private var runTask: Task<Void, Never>?

    init() {
        // Ephemeral config already provides an isolated, in-memory cookie jar (nothing persisted to
        // disk). Do NOT replace it with `HTTPCookieStorage()` — that initializer yields a non-functional
        // storage the session never writes to, leaving the jar empty (the serviceToken was lost there).
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always   // serviceToken is a cross-domain (sts.*) cookie
        config.timeoutIntervalForRequest = 35
        session = URLSession(configuration: config)
    }

    // MARK: - Lifecycle

    func start() {
        cancel()
        bands = []
        qrImageURL = nil
        loginURL = nil
        phase = .requestingCode
        runTask = Task { await run() }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    private func run() async {
        do {
            try await requestLoginCode()
            phase = .awaitingScan
            try await pollUntilScanned()
            phase = .authenticating
            try await fetchServiceToken()
            phase = .fetchingDevices
            bands = try await fetchBandDevices()
            phase = .done
        } catch is CancellationError {
            // user dismissed — leave phase as-is
        } catch let error as CloudError {
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Step 1: request the QR / login URL

    private func requestLoginCode() async throws {
        var comps = URLComponents(string: "https://account.xiaomi.com/longPolling/loginUrl")!
        comps.queryItems = [
            .init(name: "_qrsize", value: "480"),
            .init(name: "qs", value: "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
            .init(name: "callback", value: "https://sts.api.io.mi.com/sts"),
            .init(name: "_hasLogo", value: "false"),
            .init(name: "sid", value: "xiaomiio"),
            .init(name: "serviceParam", value: ""),
            .init(name: "_locale", value: "en_GB"),
            .init(name: "_dc", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]

        let (data, _) = try await get(comps.url!)
        guard let json = Self.toJSON(data),
              let qr = json["qr"] as? String,
              let login = json["loginUrl"] as? String,
              let lp = json["lp"] as? String
        else { throw CloudError.noLoginCode }

        qrImageURL = URL(string: qr)
        loginURL = URL(string: login)
        longPollingURL = lp
        if let timeout = json["timeout"] as? Double { pollTimeout = timeout }   // seconds
        Self.log("login code ready; pollTimeout=\(Int(pollTimeout))s")
    }

    // MARK: - Step 3: long-poll until the user confirms the scan

    private func pollUntilScanned() async throws {
        guard let lp = longPollingURL, let url = URL(string: lp) else { throw CloudError.noLoginCode }
        let deadline = Date().addingTimeInterval(max(pollTimeout, 300))

        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let (data, response) = try await get(url)
                let json = Self.toJSON(data)
                Self.log("poll status=\(response.statusCode) code=\(json?["code"] ?? "?") hasLocation=\(json?["location"] != nil)")

                // Success: the long-poll returns the login result with a `location` to exchange
                // for the service token. `ssecurity`/`userId` come alongside on completion.
                if response.statusCode == 200, let json, let loc = json["location"] as? String {
                    ssecurity = json["ssecurity"] as? String
                    userId = Self.stringy(json["userId"])
                    location = loc
                    Self.log("scan confirmed; have ssecurity=\(ssecurity != nil)")
                    return
                }
                // Still waiting (Xiaomi holds the request or returns a non-final code) — poll again.
            } catch let urlError as URLError {
                if urlError.code == .cancelled { throw CancellationError() }
                // Long-poll naturally times out while waiting, and the request can be dropped when
                // the app briefly backgrounds; retry until our deadline either way.
                Self.log("poll retry after URLError \(urlError.code.rawValue)")
            }
        }
        throw CloudError.scanTimedOut
    }

    // MARK: - Step 4: exchange the login location for a service token

    private func fetchServiceToken() async throws {
        guard let loc = location, let url = URL(string: loc) else { throw CloudError.noServiceToken }
        let (_, response) = try await get(url, headers: ["content-type": "application/x-www-form-urlencoded"])

        // Primary: the serviceToken is a Set-Cookie on this response (Python reads response.cookies).
        if let fields = response.allHeaderFields as? [String: String], let responseURL = response.url {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: responseURL)
            serviceToken = cookies.first { $0.name == "serviceToken" }?.value
        }
        // Fallback: pick it up from the session jar (covers cookies set on intermediate redirects).
        if serviceToken == nil {
            let jar = session.configuration.httpCookieStorage?.cookies ?? []
            serviceToken = jar.first { $0.name == "serviceToken" }?.value
            Self.log("serviceToken via jar; jar cookies=\(jar.map(\.name))")
        }
        Self.log("serviceToken present=\(serviceToken != nil)")
        if serviceToken == nil { throw CloudError.noServiceToken }
    }

    // MARK: - Step 5: discover BLE bands and their beaconkeys across regions

    private func fetchBandDevices() async throws -> [CloudBand] {
        guard ssecurity != nil else { throw CloudError.noServiceToken }
        var found: [String: CloudBand] = [:]   // dedupe by did across regions

        for server in Self.servers {
            try Task.checkCancellation()

            var homes: [(homeId: String, ownerId: String)] = []
            if let homesResp = try await getHomes(server: server),
               let result = homesResp["result"] as? [String: Any],
               let list = result["homelist"] as? [[String: Any]] {
                for h in list {
                    if let id = Self.stringy(h["id"]), let owner = userId {
                        homes.append((id, owner))
                    }
                }
            }
            if let cntResp = try await getDeviceCount(server: server),
               let result = cntResp["result"] as? [String: Any],
               let share = result["share"] as? [String: Any],
               let family = share["share_family"] as? [[String: Any]] {
                for h in family {
                    if let id = Self.stringy(h["home_id"]), let owner = Self.stringy(h["home_owner"]) {
                        homes.append((id, owner))
                    }
                }
            }
            Self.log("server=\(server) homes=\(homes.count)")

            for home in homes {
                try Task.checkCancellation()
                guard let devicesResp = try await getDevices(server: server, homeId: home.homeId, ownerId: home.ownerId),
                      let result = devicesResp["result"] as? [String: Any],
                      let info = result["device_info"] as? [[String: Any]]
                else { continue }

                let bltCount = info.filter { (Self.stringy($0["did"]) ?? "").contains("blt") }.count
                Self.log("server=\(server) home=\(home.homeId) devices=\(info.count) blt=\(bltCount)")

                for device in info {
                    guard let did = Self.stringy(device["did"]) else { continue }
                    let model = device["model"] as? String ?? ""
                    let name = device["name"] as? String ?? ""
                    Self.log("device did=\(did) model=\(model) name=\(name)")

                    // The Mi Band 10 is a `miwear.watch.*` device with a NUMERIC did — it does NOT
                    // carry "blt" like older BLE devices, so the token_extractor filter misses it.
                    guard Self.isWearable(did: did, model: model, name: name) else { continue }

                    // The device's `token` IS the BLE pairing AuthKey (token_extractor prints it as
                    // TOKEN; confirmed on hardware = dd33411e… for the Mi Band 10). This is the key
                    // the handshake needs — NOT the beaconkey, which is the separate MiBeacon key
                    // (different secret, rejected by the HMAC). Fall back to the beaconkey endpoint
                    // only for legacy blt.* devices that don't carry a token inline.
                    var key = (device["token"] as? String) ?? ""
                    if key.isEmpty {
                        let beaconResp = try await getBeaconKey(server: server, did: did)
                        key = (beaconResp?["result"] as? [String: Any])?["beaconkey"] as? String ?? ""
                    }
                    Self.log("key for did=\(did): found=\(!key.isEmpty) len=\(key.count) fromToken=\(device["token"] != nil)")
                    guard !key.isEmpty else { continue }

                    found[did] = CloudBand(
                        id: did,
                        name: name.isEmpty ? "Mi Band" : name,
                        model: model,
                        mac: (device["mac"] as? String) ?? "",
                        beaconKey: key,
                        server: server
                    )
                }
            }
        }

        let result = Array(found.values).sorted { $0.name < $1.name }
        if result.isEmpty { throw CloudError.noBandFound }
        return result
    }

    // MARK: - Encrypted API endpoints

    private func getHomes(server: String) async throws -> [String: Any]? {
        try await apiCall(server: server, path: "/v2/homeroom/gethome",
                          data: #"{"fg": true, "fetch_share": true, "fetch_share_dev": true, "limit": 300, "app_ver": 7}"#)
    }

    private func getDeviceCount(server: String) async throws -> [String: Any]? {
        try await apiCall(server: server, path: "/v2/user/get_device_cnt",
                          data: #"{ "fetch_own": true, "fetch_share": true}"#)
    }

    private func getDevices(server: String, homeId: String, ownerId: String) async throws -> [String: Any]? {
        let data = "{\"home_owner\": \(ownerId),\"home_id\": \(homeId),  \"limit\": 200,  \"get_split_device\": true, \"support_smart_home\": true}"
        return try await apiCall(server: server, path: "/v2/home/home_device_list", data: data)
    }

    private func getBeaconKey(server: String, did: String) async throws -> [String: Any]? {
        try await apiCall(server: server, path: "/v2/device/blt_get_beaconkey",
                          data: "{\"did\":\"\(did)\",\"pdid\":1}")
    }

    // MARK: - Encrypted API plumbing (execute_api_call_encrypted)

    private func apiCall(server: String, path: String, data: String) async throws -> [String: Any]? {
        guard let ssecurity else { throw CloudError.noServiceToken }
        let url = Self.apiURL(server: server) + path

        let millis = Int(Date().timeIntervalSince1970 * 1000)
        let nonce = Self.generateNonce(millis: millis)
        let signed = signedNonce(nonce: nonce, ssecurity: ssecurity)
        let params = encParams(url: url, method: "POST", signedNonce: signed, nonce: nonce,
                               params: [("data", data)], ssecurity: ssecurity)

        // Params travel as a percent-encoded query string (quote_plus semantics), like requests.
        let query = params.map { "\($0.0)=\(Self.quotePlus($0.1))" }.joined(separator: "&")
        guard let requestURL = URL(string: url + "?" + query) else { return nil }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("PROTOCAL-HTTP2", forHTTPHeaderField: "x-xiaomi-protocal-flag-cli")
        request.setValue("ENCRYPT-RC4", forHTTPHeaderField: "MIOT-ENCRYPT-ALGORITHM")
        request.setValue(apiCookieHeader(), forHTTPHeaderField: "Cookie")

        let (body, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let rawText = String(decoding: body, as: UTF8.self)
        guard status == 200 else {
            Self.log("apiCall \(path)@\(server) status=\(status) body=\(rawText.prefix(160))")
            return nil
        }

        // Body is base64(RC4(json)); decrypt with the same signed nonce.
        guard let cipher = Data(base64Encoded: rawText), let keyData = Data(base64Encoded: signed) else {
            // Not encrypted base64 — usually a plaintext error envelope (e.g. bad signature/token).
            Self.log("apiCall \(path)@\(server) not-encrypted body=\(rawText.prefix(160))")
            return nil
        }
        let plain = XiaomiCloudCrypto.rc4(key: keyData, data: cipher)
        let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
        Self.log("apiCall \(path)@\(server) code=\(json?["code"] ?? "?") msg=\(json?["message"] ?? "?")")
        return json
    }

    private func apiCookieHeader() -> String {
        let pairs = [
            "userId": userId ?? "",
            "yetAnotherServiceToken": serviceToken ?? "",
            "serviceToken": serviceToken ?? "",
            "locale": "en_GB",
            "timezone": "GMT+02:00",
            "is_daylight": "1",
            "dst_offset": "3600000",
            "channel": "MI_APP_STORE",
        ]
        return pairs.map { "\($0)=\($1)" }.joined(separator: "; ")
    }

    // MARK: - Signature / nonce (generate_enc_params, generate_enc_signature, signed_nonce)

    private func signedNonce(nonce: String, ssecurity: String) -> String {
        let sec = Data(base64Encoded: ssecurity) ?? Data()
        let non = Data(base64Encoded: nonce) ?? Data()
        return XiaomiCloudCrypto.sha256(sec + non).base64EncodedString()
    }

    /// Builds the ordered, RC4-encrypted param list with its trailing signature/ssecurity/_nonce.
    private func encParams(url: String, method: String, signedNonce: String, nonce: String,
                           params: [(String, String)], ssecurity: String) -> [(String, String)] {
        var p = params
        // 1) hash over the PLAINTEXT params
        p.append(("rc4_hash__", encSignature(url: url, method: method, signedNonce: signedNonce, params: p)))
        // 2) encrypt every value
        let key = Data(base64Encoded: signedNonce) ?? Data()
        p = p.map { ($0.0, XiaomiCloudCrypto.rc4(key: key, data: Data($0.1.utf8)).base64EncodedString()) }
        // 3) signature over the ENCRYPTED params, then the untouched trailers
        p.append(("signature", encSignature(url: url, method: method, signedNonce: signedNonce, params: p)))
        p.append(("ssecurity", ssecurity))
        p.append(("_nonce", nonce))
        return p
    }

    private func encSignature(url: String, method: String, signedNonce: String, params: [(String, String)]) -> String {
        // path = everything after the first "com", with the "/app/" prefix stripped.
        let afterCom = url.components(separatedBy: "com").count > 1
            ? url.components(separatedBy: "com")[1].replacingOccurrences(of: "/app/", with: "/")
            : url
        var parts = [method.uppercased(), afterCom]
        parts.append(contentsOf: params.map { "\($0.0)=\($0.1)" })
        parts.append(signedNonce)
        let signatureString = parts.joined(separator: "&")
        return XiaomiCloudCrypto.sha1(Data(signatureString.utf8)).base64EncodedString()
    }

    // MARK: - HTTP helper

    @discardableResult
    private func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.network }
        return (data, http)
    }

    // MARK: - Static helpers (mirror the Python module functions)

    private static func apiURL(server: String) -> String {
        "https://" + (server == "cn" ? "" : server + ".") + "api.io.mi.com/app"
    }

    private static func generateNonce(millis ms: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &bytes)
        let minutes = UInt32(ms / 60000)
        bytes.append(UInt8((minutes >> 24) & 0xFF))
        bytes.append(UInt8((minutes >> 16) & 0xFF))
        bytes.append(UInt8((minutes >> 8) & 0xFF))
        bytes.append(UInt8(minutes & 0xFF))
        return Data(bytes).base64EncodedString()
    }

    private static func generateAgent() -> String {
        let agentId = String((0..<13).map { _ in Character(UnicodeScalar(UInt8.random(in: 65...69))) })
        let randomText = String((0..<18).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
        return "\(randomText)-\(agentId) APP/com.xiaomi.mihome APPV/10.5.201"
    }

    private static func generateDeviceId() -> String {
        String((0..<6).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
    }

    /// Strips Xiaomi's "&&&START&&&" guard prefix and parses JSON.
    private static func toJSON(_ data: Data) -> [String: Any]? {
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "&&&START&&&", with: "")
        guard let clean = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: clean)) as? [String: Any]
    }

    /// Coerces a JSON number-or-string id into a String (Xiaomi mixes the two).
    private static func stringy(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? Int { return String(n) }
        if let n = value as? Int64 { return String(n) }
        if let n = value as? Double { return String(Int64(n)) }
        return nil
    }

    /// Whether a Mi Home device is a wearable whose BLE pairing key we can try to fetch.
    /// Covers legacy "blt.*" devices and the Mi Band 8/9/10 family (`miwear.watch.*`, numeric did).
    private static func isWearable(did: String, model: String, name: String) -> Bool {
        let m = model.lowercased(), n = name.lowercased()
        return did.contains("blt")
            || m.hasPrefix("miwear") || m.contains("watch") || m.contains("band") || m.contains("mibfs")
            || n.contains("band") || n.contains("watch")
    }

    /// Debug-only tracing of the cloud handshake. Never logs the serviceToken or beaconkey values —
    /// only their presence and non-sensitive structure (status codes, cookie names, response codes).
    private static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[XiaomiCloud] \(message())")
        #endif
    }

    /// urlencode/quote_plus-equivalent: keep unreserved chars, percent-encode the rest.
    private static func quotePlus(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "_.-")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Errors

    enum CloudError: LocalizedError {
        case network
        case noLoginCode
        case scanTimedOut
        case noServiceToken
        case noBandFound

        var errorDescription: String? {
            switch self {
            case .network:        return "Falha de rede ao falar com a Xiaomi."
            case .noLoginCode:    return "Não foi possível gerar o código QR. Tente novamente."
            case .scanTimedOut:   return "Tempo esgotado aguardando a leitura do QR."
            case .noServiceToken: return "Login não concluído. Confirme a leitura no app da Xiaomi."
            case .noBandFound:    return "Nenhuma pulseira encontrada nesta conta Xiaomi."
            }
        }
    }
}
