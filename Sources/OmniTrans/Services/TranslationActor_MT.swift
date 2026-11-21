import Foundation
import CryptoKit

// MARK: - String Extensions

extension String {
    /// Decodes HTML entities like `"` → `"`, `'` → `'`, etc.
    func htmlEntityDecoded() -> String {
        var result = self
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", " "), ("&mdash;", "\u{2014}"), ("&ndash;", "\u{2013}"),
            ("&hellip;", "\u{2026}"), ("&laquo;", "\u{00AB}"), ("&raquo;", "\u{00BB}"),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decimal numeric references: &#123;
        if let decRe = try? NSRegularExpression(pattern: "&#([0-9]+);") {
            let range = NSRange(result.startIndex..., in: result)
            for m in decRe.matches(in: result, range: range).reversed() {
                if let r = Range(m.range(at: 1), in: result),
                   let v = UInt32(result[r]),
                   let s = Unicode.Scalar(v) {
                    result.replaceSubrange(Range(m.range, in: result)!, with: String(s))
                }
            }
        }
        // Hex numeric references: &#x1A;
        if let hexRe = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
            let range = NSRange(result.startIndex..., in: result)
            for m in hexRe.matches(in: result, range: range).reversed() {
                if let r = Range(m.range(at: 1), in: result),
                   let v = UInt32(result[r], radix: 16),
                   let s = Unicode.Scalar(v) {
                    result.replaceSubrange(Range(m.range, in: result)!, with: String(s))
                }
            }
        }
        return result
    }

    /// Redacts sensitive query parameters (AccessKeyId, SecretKey, Signature, key, api_key)
    /// from URL strings for safe logging. (S2)
    func redactSensitiveParams() -> String {
        let patterns: [(String, String)] = [
            ("AccessKeyId=[^&]+", "AccessKeyId=***"),
            ("Signature=[^&]+", "Signature=***"),
            ("key=[^&]+", "key=***"),
            ("api_key=[^&]+", "api_key=***"),
        ]
        var result = self
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    /// Robust XML tag value extraction via `XMLDocument` + XPath. (M6)
    /// Handles namespaces, attributes, extra whitespace, and self-closing tags.
    func xmlTagValue(_ tag: String) -> String? {
        guard let data = self.data(using: .utf8) else { return nil }
        // Suppress XML parser warnings (e.g. DTD loading)
        let doc = try? XMLDocument(data: data, options: [.documentTidyXML, .nodeLoadExternalEntitiesNever])
        return try? doc?.nodes(forXPath: "//\(tag)").first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Shared Signer Utilities

private enum SignerUtilities {
    /// RFC 3986 unreserved characters — NOT percent-encoded.
    static let unreservedChars = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    static func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreservedChars) ?? string
    }

    static func iso8601Timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date())
    }

    static func hmacSign(hash: any HashFunction.Type, key: String, message: String) -> String {
        guard let keyData = key.data(using: .utf8),
              let msgData = message.data(using: .utf8)
        else { return "" }
        let symmetricKey = SymmetricKey(data: keyData)
        // Use runtime hash dispatch via the protocol
        if hash == Insecure.SHA1.self {
            let code = HMAC<Insecure.SHA1>.authenticationCode(for: msgData, using: symmetricKey)
            return Data(code).base64EncodedString()
        } else {
            let code = HMAC<SHA256>.authenticationCode(for: msgData, using: symmetricKey)
            return Data(code).base64EncodedString()
        }
    }

    /// Builds a canonical signed query string: sorts params, builds canonical query,
    /// signs with HMAC, appends Signature param.
    static func buildSignedQuery(
        params: [(String, String)],
        secretKey: String,
        hash: any HashFunction.Type
    ) -> String {
        var sorted = params
        sorted.sort { $0.0 < $1.0 }

        let canonicalQuery = sorted.map { k, v in
            percentEncode(k) + "=" + percentEncode(v)
        }.joined(separator: "&")

        let stringToSign = "GET&" + percentEncode("/") + "&" + percentEncode(canonicalQuery)
        let signature = hmacSign(hash: hash, key: secretKey + "&", message: stringToSign)

        return canonicalQuery + "&Signature=" + percentEncode(signature)
    }

    /// Shared connectivity test: builds a signed query, GETs the URL, checks HTTP 200.
    static func testConnectivity(
        endpoint: String,
        accessKey: String,
        secretKey: String,
        params: [(String, String)],
        hash: any HashFunction.Type,
        label: String,
        parseOK: @escaping (String) -> Void
    ) async throws {
        let query = buildSignedQuery(params: params, secretKey: secretKey, hash: hash)
        guard let url = URL(string: "\(endpoint)?\(query)") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效地址"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = NetworkConfig.mtTimeout

        let (data, resp) = try await sharedURLSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应"])
        }

        let body = String(data: data, encoding: .utf8) ?? ""

        guard http.statusCode == 200 else {
            let code = body.xmlTagValue("Code") ?? "Unknown"
            let msg = body.xmlTagValue("Message") ?? body
            NetworkLogger.log("\(label)Test", "❌ [\(code)] \(msg)")
            throw NSError(domain: "", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "\(label) [\(code)] \(msg)"])
        }

        NetworkLogger.log("\(label)Test", "HTTP 200")
        parseOK(body)
    }
}

// MARK: - Alibaba Cloud HMAC-SHA1 Signer

enum AlibabaCloudSigner {
    static func signedQuery(
        accessKeyId: String,
        accessKeySecret: String,
        sourceText: String,
        sourceLanguage: String = "auto",
        targetLanguage: String = "zh"
    ) -> String {
        let timestamp = SignerUtilities.iso8601Timestamp()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let params: [(String, String)] = [
            ("AccessKeyId", accessKeyId),
            ("Action", "TranslateGeneral"),
            ("FormatType", "text"),
            ("Scene", "general"),
            ("SignatureMethod", "HMAC-SHA1"),
            ("SignatureNonce", nonce),
            ("SignatureVersion", "1.0"),
            ("SourceLanguage", sourceLanguage),
            ("SourceText", sourceText),
            ("TargetLanguage", targetLanguage),
            ("Timestamp", timestamp),
            ("Version", "2018-10-12"),
        ]

        return SignerUtilities.buildSignedQuery(
            params: params, secretKey: accessKeySecret, hash: Insecure.SHA1.self
        )
    }

    static func testConnectivity(accessKeyId: String, accessKeySecret: String,
                                 endpoint: String = "https://mt.cn-hangzhou.aliyuncs.com") async throws {
        let timestamp = SignerUtilities.iso8601Timestamp()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let params: [(String, String)] = [
            ("AccessKeyId", accessKeyId),
            ("Action", "TranslateGeneral"),
            ("FormatType", "text"),
            ("Scene", "general"),
            ("SignatureMethod", "HMAC-SHA1"),
            ("SignatureNonce", nonce),
            ("SignatureVersion", "1.0"),
            ("SourceLanguage", "en"),
            ("SourceText", "hello"),
            ("TargetLanguage", "zh"),
            ("Timestamp", timestamp),
            ("Version", "2018-10-12"),
        ]
        try await SignerUtilities.testConnectivity(
            endpoint: endpoint,
            accessKey: accessKeyId, secretKey: accessKeySecret,
            params: params, hash: Insecure.SHA1.self, label: "Alibaba"
        ) { body in
            if let translated = body.xmlTagValue("Translated") {
                NetworkLogger.log("AlibabaTest", "✅ hello → \(translated)")
            }
        }
    }
}

// MARK: - Volcengine (火山翻译) HMAC-SHA256 Signer

enum VolcengineSigner {
    static func signedQuery(
        accessKey: String,
        secretKey: String,
        sourceText: String,
        sourceLanguage: String = "auto",
        targetLanguage: String = "zh"
    ) -> String {
        let timestamp = SignerUtilities.iso8601Timestamp()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        // TextList 必须是合法 JSON 数组（如 ["hello"]）—— 用 JSONSerialization
        // 生成，自动处理引号/转义/中文；裸拼接 "[\(text)]" 非法（审计 H2）。
        let textList = (try? JSONSerialization.data(withJSONObject: [sourceText]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let params: [(String, String)] = [
            ("AccessKeyId", accessKey),
            ("Action", "TranslateText"),
            ("Version", "2020-06-01"),
            ("SourceLanguage", sourceLanguage),
            ("TargetLanguage", targetLanguage),
            // 由 `buildSignedQuery` 统一做一次 RFC 3986 百分号编码。
            // 禁止在此预编码 —— 否则 `%` 会被二次编码成 `%25`（审计 C2）。
            ("TextList", textList),
            ("SignatureMethod", "HMAC-SHA256"),
            ("SignatureNonce", nonce),
            ("SignatureVersion", "1.0"),
            ("Timestamp", timestamp),
        ]

        return SignerUtilities.buildSignedQuery(
            params: params, secretKey: secretKey, hash: SHA256.self
        )
    }

    static func testConnectivity(accessKey: String, secretKey: String,
                                 endpoint: String = "https://translate.volcengineapi.com") async throws {
        let timestamp = SignerUtilities.iso8601Timestamp()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let params: [(String, String)] = [
            ("AccessKeyId", accessKey),
            ("Action", "TranslateText"),
            ("Version", "2020-06-01"),
            ("SourceLanguage", "en"),
            ("TargetLanguage", "zh"),
            // 合法 JSON 数组（H2 遗漏的测试分支：旧 "[hello]" 非法必错）
            ("TextList", "[\"hello\"]"),
            ("SignatureMethod", "HMAC-SHA256"),
            ("SignatureNonce", nonce),
            ("SignatureVersion", "1.0"),
            ("Timestamp", timestamp),
        ]
        try await SignerUtilities.testConnectivity(
            endpoint: endpoint,
            accessKey: accessKey, secretKey: secretKey,
            params: params, hash: SHA256.self, label: "Volcengine"
        ) { body in
            if body.contains("TranslationList") {
                NetworkLogger.log("VolcengineTest", "✅ hello translated")
            }
        }
    }
}
