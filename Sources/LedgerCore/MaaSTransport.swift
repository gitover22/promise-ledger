import Foundation

/// Uses the system curl's verified TLS path. No secrets appear in argv or files.
/// A request is sent once: there is no automatic fallback/replay after failure.
enum MaaSTransport {
    static func send(_ request: URLRequest) throws -> (data: Data, status: Int) {
        guard let url = request.url, url.scheme == "https", let body = request.httpBody,
              let bodyText = String(data: body, encoding: .utf8) else {
            throw LedgerError.message("模型请求格式无效。")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func quote(_ value: String) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var options = [("url", url.absoluteString), ("request", "POST")]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            options.append(("header", name + ": " + value))
        }
        options.append(("data-binary", bodyText))
        options.append(("write-out", "\n__PROMISE_LEDGER_HTTP__:%{http_code}\n"))
        let configuration = try options.map { name, value in name + " = " + (try quote(value)) }.joined(separator: "\n") + "\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // --disable ignores user .curlrc; never use insecure TLS or follow redirects.
        process.arguments = ["--disable", "--silent", "--show-error", "--connect-timeout", "10",
                             "--max-time", "90", "--proto", "=https", "--config", "-"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw LedgerError.message("无法启动 macOS 自带的网络客户端。") }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(configuration.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw LedgerError.message("无法发送模型请求，请重试。")
        }
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            switch process.terminationStatus {
            case 28: throw LedgerError.message("模型请求超时；原图已保留，请稍后手动重试。")
            case 35, 60: throw LedgerError.message("模型服务的 TLS 连接或证书验证失败；未绕过安全校验，请检查网络环境。")
            default: throw LedgerError.message("无法连接模型服务，请检查网络或 VPN 后重试。（网络代码 \(process.terminationStatus)）")
            }
        }
        let marker = Data("\n__PROMISE_LEDGER_HTTP__:".utf8)
        guard let range = response.range(of: marker, options: .backwards),
              let statusText = String(data: response[range.upperBound...], encoding: .utf8),
              let status = Int(statusText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (100...599).contains(status) else {
            throw LedgerError.message("模型服务未返回有效 HTTP 响应。")
        }
        return (Data(response[..<range.lowerBound]), status)
    }
}
