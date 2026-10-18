import Foundation

public enum LedgerError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public enum EntryState: String, Codable, Sendable {
    case queued, processing, needsReview, confirmed, failed

    public var label: String {
        switch self {
        case .queued: return "等待识别"
        case .processing: return "正在识别"
        case .needsReview: return "待确认"
        case .confirmed: return "已入账"
        case .failed: return "识别未完成"
        }
    }
}

public enum EntrySource: String, Codable, Sendable {
    case screenshot, image
    public var label: String { self == .screenshot ? "屏幕截图" : "图片导入" }
    public var symbol: String { self == .screenshot ? "viewfinder" : "photo" }
}

public struct LedgerPromise: Codable, Equatable, Sendable {
    public var text: String
    public var sourceQuote: String
    public var deadline: String?
    enum CodingKeys: String, CodingKey { case text, sourceQuote = "source_quote", deadline }
    public init(text: String, sourceQuote: String, deadline: String? = nil) {
        self.text = text; self.sourceQuote = sourceQuote; self.deadline = deadline
    }
}

public struct BillExtraction: Codable, Equatable, Sendable {
    public var isBill: Bool
    public var title: String
    public var merchant: String?
    public var amount: String?
    public var currency: String?
    public var transactionDate: String?
    public var orderID: String?
    public var category: String
    public var paymentStatus: String
    public var summary: String
    public var confidence: Double
    public var warnings: [String]
    public var promises: [LedgerPromise]

    public static let categories = ["餐饮美食", "购物消费", "交通出行", "生活缴费", "旅行住宿", "数码家电", "医疗健康", "文化娱乐", "其他", "未分类"]

    enum CodingKeys: String, CodingKey {
        case isBill = "is_bill", title, merchant, amount, currency
        case transactionDate = "transaction_date", orderID = "order_id"
        case category, paymentStatus = "payment_status", summary, confidence, warnings, promises
    }

    public init(isBill: Bool = true, title: String = "待核对账单", merchant: String? = nil,
                amount: String? = nil, currency: String? = nil, transactionDate: String? = nil,
                orderID: String? = nil, category: String = "未分类", paymentStatus: String = "未知",
                summary: String = "", confidence: Double = 0, warnings: [String] = [], promises: [LedgerPromise] = []) {
        self.isBill = isBill; self.title = title; self.merchant = merchant; self.amount = amount
        self.currency = currency; self.transactionDate = transactionDate; self.orderID = orderID
        self.category = category; self.paymentStatus = paymentStatus; self.summary = summary
        self.confidence = confidence; self.warnings = warnings; self.promises = promises
    }

    public var decimalAmount: Decimal? {
        guard let amount, amount.range(of: #"^\d+(\.\d{1,4})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))
    }

    public var formattedAmount: String {
        guard let value = decimalAmount else { return "金额待核对" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = currency == nil ? .decimal : .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = currency == "JPY" ? 0 : 2
        return formatter.string(from: value as NSDecimalNumber) ?? amount ?? "—"
    }

    public func validated(ocrText: String) throws -> BillExtraction {
        guard isBill else { throw LedgerError.message("这张图片没有识别到订单、收据或账单。请换一张包含商品和金额的图片。") }
        guard confidence.isFinite && (0...1).contains(confidence) else {
            throw LedgerError.message("模型返回了无效的可信度，请重试。")
        }
        var result = self
        if amount != nil && decimalAmount == nil {
            result.amount = nil
            result.warnings.append("金额格式不明确，请对照原图填写。")
        }
        if let currency, currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) == nil {
            result.currency = nil
            result.warnings.append("币种不明确，请手动核对。")
        }
        if let date = transactionDate, !Self.isValidDate(date) {
            result.transactionDate = nil
            result.warnings.append("交易日期不明确，请手动核对。")
        }
        if !Self.categories.contains(category) { result.category = "未分类" }
        if result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.title = "待核对账单" }
        let evidence = ocrText.filter { !$0.isWhitespace }
        result.promises = promises.filter { promise in
            let quote = promise.sourceQuote.filter { !$0.isWhitespace }
            return !quote.isEmpty && evidence.contains(quote)
        }.map { promise in
            var verified = promise
            if let deadline = verified.deadline, !Self.isValidDate(deadline) { verified.deadline = nil }
            return verified
        }
        if result.promises.count != promises.count { result.warnings.append("缺少原文依据的承诺已被过滤。") }
        return result
    }

    public static func isValidDate(_ text: String) -> Bool {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }
}

public struct LedgerEntry: Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var source: EntrySource
    public var imageFilename: String
    public var imageHash: String
    public var state: EntryState
    public var ocrText: String
    public var extraction: BillExtraction?
    public var error: String?
    public var model: String?

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), source: EntrySource,
                imageFilename: String, imageHash: String, state: EntryState = .queued,
                ocrText: String = "", extraction: BillExtraction? = nil, error: String? = nil, model: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.source = source
        self.imageFilename = imageFilename; self.imageHash = imageHash; self.state = state
        self.ocrText = ocrText; self.extraction = extraction; self.error = error; self.model = model
    }
    public var title: String { extraction?.title ?? (source == .screenshot ? "一张新的屏幕截图" : "一张新的订单图片") }
}

public enum ExtractionDecoder {
    public static func decode(_ text: String, ocrText: String) throws -> BillExtraction {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            let lines = json.components(separatedBy: "\n")
            json = lines.dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        guard let data = json.data(using: .utf8) else { throw LedgerError.message("模型返回的内容无法读取。") }
        do {
            return try JSONDecoder().decode(BillExtraction.self, from: data).validated(ocrText: ocrText)
        } catch let error as LedgerError { throw error }
        catch { throw LedgerError.message("模型没有返回完整的账单数据，请重试。原图已在本机保留。") }
    }
}
