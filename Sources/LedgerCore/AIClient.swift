import Foundation

public enum CompletionParser {
    public static func text(from data: Data, isStream: Bool) throws -> String {
        if !isStream {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let choice = choices.first, let message = choice["message"] as? [String: Any],
                  let text = message["content"] as? String, !text.isEmpty,
                  choice["finish_reason"] as? String == "stop" else {
                throw LedgerError.message("模型回复不完整，请重试。")
            }
            return text
        }
        guard let stream = String(data: data, encoding: .utf8) else { throw LedgerError.message("模型响应编码无效。") }
        var text = ""
        var finished = false
        var stopped = false
        for line in stream.components(separatedBy: .newlines) where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { finished = true; continue }
            guard let event = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if event["error"] != nil { throw LedgerError.message("模型流式响应发生错误，请重试。") }
            guard let choices = event["choices"] as? [[String: Any]] else { continue }
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String { text += content }
                if let reason = choice["finish_reason"] as? String {
                    guard reason == "stop" else { throw LedgerError.message("模型回复被截断或过滤，请重试。") }
                    stopped = true
                }
            }
        }
        guard finished, stopped, !text.isEmpty else { throw LedgerError.message("模型响应中断，未保存不完整的识别结果，请重试。") }
        return text
    }
}

public struct AIClient: Sendable {
    public let configuration: ModelConfiguration
    public init(configuration: ModelConfiguration) { self.configuration = configuration }

    public func extract(ocrText: String) async throws -> BillExtraction {
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.message("图片中没有识别到可读文字，请使用更清晰的订单图片。")
        }
        guard ocrText.count <= 24_000 else {
            throw LedgerError.message("图片包含的文字过多。请导入只包含目标订单的图片，避免账单混淆。")
        }
        let key = try await Task.detached(priority: .userInitiated) {
            try KeychainCredential.read(configuration: configuration)
        }.value
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.authorizationValuePrefix + key, forHTTPHeaderField: configuration.authorizationHeader)
        request.setValue(configuration.applicationID, forHTTPHeaderField: configuration.applicationIDField)
        request.setValue("bill-extraction", forHTTPHeaderField: "x-maas-scenario")
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [["role": "system", "content": Self.prompt],
                         ["role": "user", "content": try LedgerSystemPrompt.userMessage(ocrText: ocrText)]],
            "stream": configuration.requestDefaults.stream,
            "max_tokens": 3_072
        ]
        if configuration.requestDefaults.stream, let options = configuration.requestDefaults.streamOptions {
            body["stream_options"] = ["include_usage": options.includeUsage]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let preparedRequest = request
        let (data, status) = try await Task.detached(priority: .userInitiated) {
            try MaaSTransport.send(preparedRequest)
        }.value
        guard (200..<300).contains(status) else {
            let error = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let trace = (error?["traceId"] as? String).map { "（traceId: \($0)）" } ?? ""
            let description: String
            switch status {
            case 401, 403: description = "模型认证失败或模型未授权，请检查本机接入配置。"
            case 402: description = "模型服务额度不足，请检查 MaaS 预算。"
            case 429: description = "模型服务请求受限，请稍后手动重试。"
            default: description = "模型服务返回 HTTP \(status)，请稍后重试。"
            }
            throw LedgerError.message(description + trace)
        }
        let content = try CompletionParser.text(from: data, isStream: configuration.requestDefaults.stream)
        return try ExtractionDecoder.decode(content, ocrText: ocrText)
    }

    public static let prompt = LedgerSystemPrompt.text
}
