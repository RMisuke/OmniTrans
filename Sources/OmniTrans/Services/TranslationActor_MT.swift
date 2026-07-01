import Foundation
import CryptoKit

// MARK: - HTML Entity Decoder

extension String {
    /// Decodes HTML entities like `&quot;` → `"`, `&#39;` → `'`, etc.
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

// MARK: - Alibaba Cloud HMAC-SHA1 Signer

enum AlibabaCloudSigner {
    /// RFC 3986 unreserved characters — NOT percent-encoded.
    private static let unreservedRFC3986 = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    /// ISO 8601 timestamp WITHOUT fractional seconds — Alibaba Cloud requirement.
    private static func aliyunTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date())
    }

    /// Generates a signed query string for the Alibaba Cloud MT API (TranslateGeneral).
    /// Uses HTTPS via `mt.cn-hangzhou.aliyuncs.com` (the official V3 HTTPS endpoint).
    static func signedQuery(
        accessKeyId: String,
        accessKeySecret: String,
        sourceText: String,
        sourceLanguage: String = "auto",
        targetLanguage: String = "zh"
    ) -> String {
        let timestamp = aliyunTimestamp()
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        var params: [(String, String)] = [
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

        // Sort by key (ASCII)
        params.sort { $0.0 < $1.0 }

        // Build canonical query string
        let canonicalQuery = params.map { key, value in
            percentEncode(key) + "=" + percentEncode(value)
        }.joined(separator: "&")

        // String to sign: GET&%2F&<encoded canonical query>
        let stringToSign = "GET&" + percentEncode("/") + "&" + percentEncode(canonicalQuery)

        // HMAC-SHA1 with key = AccessKeySecret + "&" using CryptoKit
        let signature = hmacSHA1Base64(key: accessKeySecret + "&", message: stringToSign)

        // Final query
        let finalQuery = canonicalQuery + "&Signature=" + percentEncode(signature)
        return finalQuery
    }

    /// Test connectivity with a minimal signed request via HTTPS.
    static func testConnectivity(accessKeyId: String, accessKeySecret: String) async throws {
        let query = signedQuery(
            accessKeyId: accessKeyId,
            accessKeySecret: accessKeySecret,
            sourceText: "hello",
            sourceLanguage: "en",
            targetLanguage: "zh"
        )
        guard let url = URL(string: "https://mt.cn-hangzhou.aliyuncs.com/?\(query)") else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效地址"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无响应"])
        }

        let body = String(data: data, encoding: .utf8) ?? ""

        guard http.statusCode == 200 else {
            let code = body.extractXMLTag("Code") ?? "Unknown"
            let msg = body.extractXMLTag("Message") ?? body
            print("[AlibabaTest] ❌ [\(code)] \(msg)")
            throw NSError(domain: "", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "阿里云 [\(code)] \(msg)"])
        }

        print("[AlibabaTest] HTTP 200")
        if let translated = body.extractXMLTag("Translated") {
            print("[AlibabaTest] ✅ hello → \(translated)")
        }
    }

    // MARK: - Private helpers

    private static func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreservedRFC3986) ?? string
    }

    private static func hmacSHA1Base64(key: String, message: String) -> String {
        guard let keyData = key.data(using: .utf8),
              let msgData = message.data(using: .utf8)
        else { return "" }
        let symmetricKey = SymmetricKey(data: keyData)
        let authCode = HMAC<Insecure.SHA1>.authenticationCode(for: msgData, using: symmetricKey)
        return Data(authCode).base64EncodedString()
    }
}
