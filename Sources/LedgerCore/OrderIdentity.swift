import Foundation
import CryptoKit

public enum Evidence {
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
    }
    public static func contains(_ quote: String, in text: String) -> Bool {
        let value = normalized(quote)
        return !value.isEmpty && normalized(text).contains(value)
    }
    public static func explicitDate(_ date: String, appearsIn quote: String) -> Bool {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let pattern = "(?<![0-9])\(parts[0])[-/.年]0?\(parts[1])[-/.月]0?\(parts[2])(?:日)?(?![0-9])"
        return normalized(quote).range(of: pattern, options: .regularExpression) != nil
    }
}

public enum DeduplicationMatch: Equatable, Sendable {
    case none
    case exact(String)
    case possible([String])
}

public enum OrderIdentity {
    private static let platformAliases: [String: [String]] = [
        "taobao": ["淘宝", "淘宝网", "TAOBAO"], "tmall": ["天猫", "TMALL"],
        "jd": ["京东", "JD", "JD.COM"], "pinduoduo": ["拼多多", "PINDUODUO"],
        "xiaohongshu": ["小红书", "REDNOTE", "XIAOHONGSHU"],
        "meituan": ["美团", "MEITUAN"], "eleme": ["饿了么", "ELEME"],
        "ctrip": ["携程", "CTRIP", "TRIP.COM"], "fliggy": ["飞猪", "FLIGGY"],
        "booking": ["BOOKING", "BOOKING.COM"], "amazon": ["亚马逊", "AMAZON"]
    ]

    public static func normalize(_ text: String?) -> String? {
        guard let text else { return nil }
        let result = Evidence.normalized(text).uppercased()
        return result.isEmpty ? nil : result
    }

    public static func normalizedOrderID(_ text: String?) -> String? {
        guard let value = normalize(text), value.range(of: #"^[A-Z0-9][A-Z0-9._/-]{5,79}$"#, options: .regularExpression) != nil,
              value.rangeOfCharacter(from: .decimalDigits) != nil,
              value != String(repeating: "0", count: value.count) else { return nil }
        // Never replace O/0, I/1 or remove separators: those can change an order's identity.
        return value
    }

    public static func hasOrderEvidence(_ identifier: String, quote: String?, ocr: String) -> Bool {
        guard let id = normalizedOrderID(identifier) else { return false }
        if let quote {
            guard Evidence.contains(quote, in: ocr), normalize(quote)?.contains(id) == true else { return false }
        }
        let text = (quote ?? ocr).precomposedStringWithCompatibilityMapping.uppercased()
            .filter { !$0.isWhitespace || $0.isNewline }
        let escaped = id.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
        let pattern = "(?:订单号码|订单编号|交易订单号|订单号|订单编码|订单[:：#]|ORDER(?:ID|NUMBER|NO\\.?)?[:：#]?)[:：#-]*\\s*" + escaped + "(?![A-Z0-9._/-])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    public static func canonicalPlatform(_ raw: String?) -> String? {
        guard let value = normalize(raw) else { return nil }
        for (canonical, aliases) in platformAliases {
            if value == canonical.uppercased() || aliases.contains(value) { return canonical }
        }
        return value.lowercased()
    }

    private static func platform(_ bill: BillExtraction, ocr: String, humanConfirmed: Bool) -> String? {
        guard let canonical = canonicalPlatform(bill.platform) else { return nil }
        if humanConfirmed { return canonical }
        let text = normalize(ocr) ?? ""
        let aliases = platformAliases[canonical] ?? [normalize(bill.platform) ?? ""]
        return aliases.contains(where: { !$0.isEmpty && text.contains($0) }) ? canonical : nil
    }

    public static func trustedOrderID(_ entry: LedgerEntry) -> String? {
        guard let bill = entry.extraction, let id = normalizedOrderID(bill.orderID) else { return nil }
        if entry.state == .confirmed || hasOrderEvidence(id, quote: bill.orderIDSourceQuote, ocr: entry.ocrText) { return id }
        return nil
    }

    public static func strongKey(_ entry: LedgerEntry) -> String? {
        guard let bill = entry.extraction, let id = trustedOrderID(entry) else { return nil }
        if let platform = platform(bill, ocr: entry.ocrText, humanConfirmed: entry.state == .confirmed) {
            return fingerprint(["platform", platform, id])
        }
        if let merchant = normalize(bill.merchant) { return fingerprint(["merchant", merchant, id]) }
        return nil
    }

    public static func reviewFingerprint(_ bill: BillExtraction) -> String {
        fingerprint([normalize(bill.platform) ?? "", normalize(bill.merchant) ?? "", normalizedOrderID(bill.orderID) ?? "",
                     bill.decimalAmount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "",
                     normalize(bill.currency) ?? "", bill.transactionDate ?? "", normalize(bill.title) ?? ""])
    }

    public static func distinctToken(_ bill: BillExtraction, candidates: [String]) -> String {
        fingerprint([reviewFingerprint(bill)] + candidates.sorted())
    }

    public static func match(_ incoming: LedgerEntry, against entries: [LedgerEntry]) -> DeduplicationMatch {
        guard let bill = incoming.extraction else { return .none }
        let incomingID = trustedOrderID(incoming)
        let incomingPlatform = platform(bill, ocr: incoming.ocrText, humanConfirmed: incoming.state == .confirmed)
        var possible: [String] = []
        var exact: [String] = []
        let candidates = entries.filter {
            $0.id != incoming.id && $0.duplicateOf == nil && $0.extraction != nil &&
                [.confirmed, .needsReview, .duplicateReview].contains($0.state)
        }.sorted {
            if ($0.state == .confirmed) != ($1.state == .confirmed) { return $0.state == .confirmed }
            return $0.createdAt < $1.createdAt
        }
        for entry in candidates {
            guard let existing = entry.extraction else { continue }
            let existingID = trustedOrderID(entry)
            let existingPlatform = platform(existing, ocr: entry.ocrText, humanConfirmed: entry.state == .confirmed)
            if let a = incomingPlatform, let b = existingPlatform, a != b { continue }
            if let incomingID, let existingID {
                if incomingID != existingID { continue }
                if let a = incomingPlatform, let b = existingPlatform, a == b { exact.append(entry.id); continue }
                if let a = normalize(bill.merchant), let b = normalize(existing.merchant), a == b { exact.append(entry.id); continue }
                possible.append(entry.id)
                continue
            }
            // ID-less similarity never auto-merges recurring equal-price purchases.
            if let merchant = normalize(bill.merchant), merchant == normalize(existing.merchant),
               let amount = bill.decimalAmount, amount == existing.decimalAmount,
               let currency = normalize(bill.currency), currency == normalize(existing.currency),
               let date = bill.transactionDate, BillExtraction.isValidDate(date), date == existing.transactionDate {
                possible.append(entry.id)
            }
        }
        if exact.count == 1 { return .exact(exact[0]) }
        if exact.count > 1 { return .possible(exact + possible) }
        return possible.isEmpty ? .none : .possible(possible)
    }

    private static func fingerprint(_ parts: [String]) -> String {
        let data = try! JSONEncoder().encode(parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
