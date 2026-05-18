import CommonCrypto
import Foundation
import Security
import SQLite3

// MARK: - Models

struct UsageData {
    let fiveHour: UsagePeriod?
    let sevenDay: UsagePeriod?
    let sevenDayOmelette: UsagePeriod?
    /// Set only in JSONL fallback — raw 7-day cache_creation tokens, no denominator known.
    let sevenDayTokensApproximate: Int?
}

extension UsageData: Decodable {
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOmelette = "seven_day_omelette"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour              = try c.decodeIfPresent(UsagePeriod.self, forKey: .fiveHour)
        sevenDay              = try c.decodeIfPresent(UsagePeriod.self, forKey: .sevenDay)
        sevenDayOmelette      = try c.decodeIfPresent(UsagePeriod.self, forKey: .sevenDayOmelette)
        sevenDayTokensApproximate = nil
    }
}

struct UsagePeriod: Decodable {
    let utilization: Double
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

// MARK: - Errors

enum UsageServiceError: LocalizedError {
    case keychainItemNotFound
    case keychainAccessFailed
    case keyDerivationFailed
    case cookieDBNotFound
    case cookieNotFound
    case invalidCookieFormat
    case decryptionFailed
    case sessionKeyNotFound
    case orgUUIDNotFound
    case apiError(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .keychainItemNotFound:  return "Claude session not found in Keychain"
        case .keychainAccessFailed:  return "Keychain access failed"
        case .keyDerivationFailed:   return "Key derivation failed"
        case .cookieDBNotFound:      return "Claude Desktop not found — is it installed?"
        case .cookieNotFound:        return "Session cookie not found"
        case .invalidCookieFormat:   return "Unexpected cookie format"
        case .decryptionFailed:      return "Cookie decryption failed"
        case .sessionKeyNotFound:    return "Session key not found in decrypted data"
        case .orgUUIDNotFound:       return "Organization UUID not found in ~/.claude.json"
        case .apiError(let code):    return "API returned HTTP \(code)"
        case .decodingFailed:        return "Could not parse API response"
        }
    }
}

// MARK: - Service

struct UsageService {

    // MARK: Public

    /// Tries the live API first; falls back to local JSONL files if the session
    /// cookie is expired or the API is unreachable.
    /// Returns the data and a flag indicating whether it came from the fallback.
    func fetch() async throws -> (data: UsageData, isApproximate: Bool) {
        do {
            let sessionKey = try getSessionKey()
            let orgUUID    = try getOrgUUID()
            let data       = try await callAPI(sessionKey: sessionKey, orgUUID: orgUUID)
            return (data, false)
        } catch {
            // API failed — fall back to local JSONL
            let data = try await fetchFromJSONL()
            return (data, true)
        }
    }

    // MARK: JSONL fallback

    private func fetchFromJSONL() async throws -> UsageData {
        // Run file I/O off the main thread
        return try await Task.detached(priority: .userInitiated) {
            try Self.buildUsageFromJSONL()
        }.value
    }

    private static func buildUsageFromJSONL() throws -> UsageData {
        // 1. Read block limit from ~/.claude.json
        let limit = readBlockLimit()

        // 2. Collect + deduplicate turns from all JSONL files (last 30 days)
        let turns = collectTurns()
        guard !turns.isEmpty else { throw UsageServiceError.sessionKeyNotFound }

        // 3. Find current block: greedy 5-hour walk backwards from most recent turn
        var block = [turns.last!]
        for turn in turns.dropLast().reversed() {
            let gapHours = block.last!.ts.timeIntervalSince(turn.ts) / 3600
            if gapHours > 5 { break }
            block.insert(turn, at: 0)
        }

        // 4. Compute utilization and reset time for current block
        let usageTokens = block.reduce(0) { $0 + $1.cacheCreate }
        let utilization = limit > 0
            ? min(Double(usageTokens) / Double(limit) * 100.0, 100.0)
            : 0.0
        let resetsAt = block[0].ts.addingTimeInterval(5 * 3600)

        // 5. 7-day token sum (no weekly limit available from JSONL; shown as raw count)
        let sevenDayAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let weeklyTokens = turns
            .filter { $0.ts > sevenDayAgo }
            .reduce(0) { $0 + $1.cacheCreate }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        return UsageData(
            fiveHour: UsagePeriod(
                utilization: utilization,
                resetsAt: fmt.string(from: resetsAt)
            ),
            sevenDay: nil,
            sevenDayOmelette: nil,
            sevenDayTokensApproximate: weeklyTokens
        )
    }

    // MARK: JSONL helpers

    private struct JSONLTurn {
        let ts:          Date
        let cacheCreate: Int
    }

    private static func readBlockLimit() -> Int {
        guard
            let data  = try? Data(contentsOf: FileManager.default
                .homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")),
            let root  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cache = root["clientDataCache"] as? [String: Any],
            let raw   = cache["kelp_forest_sonnet"],
            let limit = Int("\(raw)")
        else { return 1_000_000 }
        return limit
    }

    private static func collectTurns() -> [JSONLTurn] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        var seen: [String: JSONLTurn] = [:]

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let content = try? String(contentsOf: url, encoding: .utf8)
            else { continue }

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard
                    let data   = String(line).data(using: .utf8),
                    let obj    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tsStr  = obj["timestamp"] as? String,
                    let ts     = parseISO(tsStr),
                    ts > cutoff,
                    let msg    = obj["message"] as? [String: Any],
                    msg["role"] as? String == "assistant",
                    let usage  = msg["usage"] as? [String: Any]
                else { continue }

                let key = "\(obj["requestId"] as? String ?? ""):\(msg["id"] as? String ?? "")"
                let cc  = usage["cache_creation_input_tokens"] as? Int ?? 0
                let turn = JSONLTurn(ts: ts, cacheCreate: cc)

                if let existing = seen[key] {
                    if ts >= existing.ts { seen[key] = turn }
                } else {
                    seen[key] = turn
                }
            }
        }

        return seen.values.sorted { $0.ts < $1.ts }
    }

    private static func parseISO(_ s: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: s) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: s)
    }

    // MARK: Auth — Step 1: Keychain password

    private func readKeychainPassword() throws -> String {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "Claude Safe Storage",
            kSecAttrAccount: "Claude",
            kSecReturnData:  kCFBooleanTrue as Any,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { throw UsageServiceError.keychainItemNotFound }
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8)
        else { throw UsageServiceError.keychainAccessFailed }

        return password
    }

    // MARK: Auth — Step 2: PBKDF2-HMAC-SHA1 key derivation

    private func deriveKey(from password: String) throws -> Data {
        let saltBytes = Array("saltysalt".utf8)
        var derived   = [UInt8](repeating: 0, count: 16)

        let rc = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &derived, 16
        )
        guard rc == kCCSuccess else { throw UsageServiceError.keyDerivationFailed }
        return Data(derived)
    }

    // MARK: Auth — Step 3: Read encrypted cookie from Claude Desktop's SQLite

    private func readEncryptedCookie() throws -> Data {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Cookies").path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw UsageServiceError.cookieDBNotFound
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK
        else { throw UsageServiceError.cookieDBNotFound }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT encrypted_value FROM cookies WHERE name='sessionKey' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageServiceError.cookieNotFound
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(stmt, 0)
        else { throw UsageServiceError.cookieNotFound }

        let count = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: bytes, count: count)
    }

    // MARK: Auth — Step 4: AES-128-CBC decrypt, extract session key

    private func decryptSessionKey(_ data: Data, key: Data) throws -> String {
        // Cookie format: "v10" (3 bytes) | random IV (16 bytes) | AES-128-CBC ciphertext
        guard data.count > 19, data.prefix(3) == Data("v10".utf8) else {
            throw UsageServiceError.invalidCookieFormat
        }

        let iv         = data.subdata(in: 3..<19)
        let ciphertext = data.subdata(in: 19..<data.count)
        var plaintext     = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let plaintextSize = plaintext.count
        var bytesOut      = 0

        let status: CCCryptorStatus = plaintext.withUnsafeMutableBytes { pt in
            ciphertext.withUnsafeBytes { ct in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { i in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count,
                            i.baseAddress,
                            ct.baseAddress, ciphertext.count,
                            pt.baseAddress, plaintextSize,
                            &bytesOut
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw UsageServiceError.decryptionFailed }
        plaintext = plaintext.prefix(bytesOut)

        // The session key follows 16 bytes of AES block metadata
        let raw = String(data: plaintext, encoding: .isoLatin1) ?? ""
        guard let range = raw.range(
            of: #"sk-ant-sid\d+-[\w_\-]+"#,
            options: String.CompareOptions.regularExpression
        ) else {
            throw UsageServiceError.sessionKeyNotFound
        }
        return String(raw[range])
    }

    // MARK: Auth — combined

    private func getSessionKey() throws -> String {
        let password = try readKeychainPassword()
        let key      = try deriveKey(from: password)
        let cookie   = try readEncryptedCookie()
        return try decryptSessionKey(cookie, key: key)
    }

    // MARK: Org UUID

    private func getOrgUUID() throws -> String {
        let claudeJSON = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")

        let data = try Data(contentsOf: claudeJSON)
        guard let root   = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth  = root["oauthAccount"] as? [String: Any],
              let uuid   = oauth["organizationUuid"] as? String
        else { throw UsageServiceError.orgUUIDNotFound }

        return uuid
    }

    // MARK: API call

    private func callAPI(sessionKey: String, orgUUID: String) async throws -> UsageData {
        let url = URL(string: "https://api.anthropic.com/api/organizations/\(orgUUID)/usage")!
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(
            "ClaudeUsage/0.1 (+https://github.com/wstaszczyk/ClaudeUsage)",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(
            "sessionKey=\(sessionKey); lastActiveOrg=\(orgUUID)",
            forHTTPHeaderField: "Cookie"
        )

        // One retry with 2s backoff for transient failures (5xx, network error).
        // Auth failures (401/403) skip retry — they mean the cookie expired, fall through to JSONL.
        let (data, http) = try await sendWithRetry(req)

        guard http.statusCode == 200 else {
            throw UsageServiceError.apiError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(UsageData.self, from: data)
        } catch {
            throw UsageServiceError.decodingFailed
        }
    }

    private func sendWithRetry(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw UsageServiceError.apiError(0)
                }
                if (500...599).contains(http.statusCode), attempt == 0 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                return (data, http)
            } catch {
                if attempt == 0 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                throw error
            }
        }
        throw UsageServiceError.apiError(0)
    }
}
