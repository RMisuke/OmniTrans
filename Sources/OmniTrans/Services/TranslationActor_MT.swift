import Foundation
import CryptoKit

// MARK: - String Extensions

extension String {
    /// Decodes HTML entities like `"` → `"`, `'` → `'`, etc.
    func htmlEntityDecoded() -> String {
        guard let data = self.data(using: .utf8) else { return self }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil).string) ?? self
    }

    /// Extracts content between `<tag>` and `</tag>` from XML.
    func extractXMLTag(_ tag: String) -> String? {
        guard let start = range(of: "<\(tag)>"),
              let end = range(of: "</\(tag)>")
        else { return nil }
        return String(self[start.upperBound..<end.lowerBound])
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
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应"])
        }

        let body = String(data: data, encoding: .utf8) ?? ""

        guard http.statusCode == 200 else {
            let code = body.extractXMLTag("Code") ?? "Unknown"
            let msg = body.extractXMLTag("Message") ?? body
            print("[\(label)Test] ❌ [\(code)] \(msg)")
            throw NSError(domain: "", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "\(label) [\(code)] \(msg)"])
        }

        print("[\(label)Test] HTTP 200")
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

    static func testConnectivity(accessKeyId: String, accessKeySecret: String) async throws {
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
            endpoint: "https://mt.cn-hangzhou.aliyuncs.com",
            accessKey: accessKeyId, secretKey: accessKeySecret,
            params: params, hash: Insecure.SHA1.self, label: "Alibaba"
        ) { body in
            if let translated = body.extractXMLTag("Translated") {
                print("[AlibabaTest] ✅ hello → \(translated)")
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

        let params: [(String, String)] = [
            ("AccessKeyId", accessKey),
            ("Action", "TranslateText"),
            ("Version", "2020-06-01"),
            ("SourceLanguage", sourceLanguage),
            ("TargetLanguage", targetLanguage),
            ("TextList", "[\(sourceText.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sourceText)]"),
            ("SignatureMethod", "HMAC-SHA256"),
            ("SignatureNonce", nonce),
            ("SignatureVersion", "1.0"),
            ("Timestamp", timestamp),
        ]

        return SignerUtilities.buildSignedQuery(
            params: params, secretKey: secretKey, hash: SHA256.self
        )
    }

    static func testConnectivity(accessKey: String, secretKey: String) async throws {
        let timestamp = SignerUtilities.iso8601Timestamp()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let params: [(String, String)] = [
            ("AccessKeyId", accessKey),
            ("Action", "TranslateText"),
            ("Version", "2020-06-01"),
            ("SourceLanguage", "en"),
            ("TargetLanguage", "zh"),
            ("TextList", "[hello]"),
            ("SignatureMethod", "HMAC-SHA256"),
            ("SignatureNonce", nonce),
            ("SignatureVersion", "1.0"),
            ("Timestamp", timestamp),
        ]
        try await SignerUtilities.testConnectivity(
            endpoint: "https://translate.volcengineapi.com",
            accessKey: accessKey, secretKey: secretKey,
            params: params, hash: SHA256.self, label: "Volcengine"
        ) { body in
            if body.contains("TranslationList") {
                print("[VolcengineTest] ✅ hello translated")
            }
        }
    }
}
