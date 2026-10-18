import Foundation

public struct ModelConfiguration: Decodable, Sendable {
    public struct Credential: Decodable, Sendable {
        public let store: String
        public let service: String
        public let account: String
    }
    public struct RequestDefaults: Decodable, Sendable {
        public let stream: Bool
        public let streamOptions: StreamOptions?
        enum CodingKeys: String, CodingKey { case stream, streamOptions = "stream_options" }
    }
    public struct StreamOptions: Codable, Sendable {
        public let includeUsage: Bool
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }
    public let endpoint: URL
    public let model: String
    public let authorizationHeader: String
    public let authorizationValuePrefix: String
    public let applicationID: String
    public let applicationIDField: String
    public let applicationIDLocation: String
    public let credential: Credential
    public let requestDefaults: RequestDefaults
    enum CodingKeys: String, CodingKey {
        case endpoint = "chat_completions_url", model, credential
        case authorizationHeader = "authorization_header", authorizationValuePrefix = "authorization_value_prefix"
        case applicationID = "application_id", applicationIDField = "application_id_field"
        case applicationIDLocation = "application_id_location", requestDefaults = "request_defaults"
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/promise-ledger/model.json")
    }

    public static func load(from url: URL = defaultURL) throws -> ModelConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LedgerError.message("未找到本机模型配置。请先配置 ~/.config/promise-ledger/model.json。")
        }
        let configuration: ModelConfiguration
        do { configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch { throw LedgerError.message("本机模型配置格式不完整，请检查 model.json。") }
        guard configuration.endpoint.scheme == "https", configuration.endpoint.user == nil,
              configuration.endpoint.password == nil,
              configuration.applicationIDLocation == "header",
              !configuration.applicationID.isEmpty,
              configuration.credential.store == "macos-keychain" else {
            throw LedgerError.message("模型配置必须使用 HTTPS、有效的应用标识请求头和 macOS 钥匙串。")
        }
        return configuration
    }
}

public enum KeychainCredential {
    /// Keep stdout private: the existing item grants access to /usr/bin/security.
    public static func read(configuration: ModelConfiguration) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", configuration.credential.service,
                             "-a", configuration.credential.account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw LedgerError.message("无法读取钥匙串中的模型密钥。请确认钥匙串已解锁并允许本机访问。")
        }
        return key
    }
}
