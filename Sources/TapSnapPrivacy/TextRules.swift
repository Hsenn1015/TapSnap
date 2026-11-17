import Foundation
import Darwin

/// OCR 文本及其在截图中的位置。位置用于把表头与同列值关联起来。
struct PrivacyTextLine {
    let text: String
    let rect: CGRect
    let confidence: Float

    var normalized: String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            if (0xFF01...0xFF5E).contains(scalar.value) { return UnicodeScalar(scalar.value - 0xFEE0)! }
            if scalar.value == 0x3000 { return " " }
            return scalar
        }))
    }
}

struct PrivacyTextMatch: Equatable {
    let label: String
    let line: Int
    let range: NSRange
    let covered: Bool
}

struct TextRules {
    private struct FieldRule {
        let rule: PrivacyRule
        let labels: String
        let value: NSRegularExpression
        var consumesLine = false
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Built-in patterns are fixed and exercised by the rules tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let email = regex(#"[A-Z0-9._%+\-]+[ \t]*@[ \t]*[A-Z0-9\-]+(?:[ \t]*\.[ \t]*[A-Z0-9\-]+)*[ \t]*\.[ \t]*[A-Z]{2,}(?![A-Z0-9\-])"#)
    private static let numbers = regex(#"(?<![A-Z0-9_.])(?:\+86[ \t\-]*)?(?:[0-9][ \t\u00a0\u2009\-‐–]?){5,}[0-9X](?![A-Z0-9_]|\.[0-9])"#)
    private static let maskedNumber = regex(#"^[ \t]*(?:\+86[ \t\-]*)?[0-9*•●xX][0-9*•●xX \t\-‐–]{4,30}[0-9*•●xX](?![A-Z0-9*•●])"#)
    private static let landline = regex(#"(?<![A-Z0-9_.])(?:\+86[ \t\-]*)?(?:\(0[1-9][0-9]{1,2}\)|0[1-9][0-9]{1,2})[ \t\-]*[2-9][0-9]{6,7}(?:[ \t]*(?:转|分机|ext\.?)[ \t]*[0-9]{1,6})?(?![A-Z0-9_]|\.[0-9])"#)
    private static let ip = regex(#"(?<![A-Z0-9_.])(?:[0-9]{1,3}[ \t]*\.[ \t]*){3}[0-9]{1,3}(?:[ \t]*:[ \t]*[0-9]{1,5})?(?![A-Z0-9_.])"#)
    private static let ipv6 = regex(#"(?<![0-9A-F:])(?:\[(?:[0-9A-F]{0,4}:){2,}[0-9A-F:.]*\](?::[0-9]{1,5})?|(?:[0-9A-F]{0,4}:){2,}[0-9A-F:.]*)(?![0-9A-F:])"#)
    private static let host = regex(#"(?<![A-Z0-9_\-])(?:[A-Z0-9](?:[A-Z0-9\-]*[A-Z0-9])?\.)+[A-Z][A-Z0-9\-]*(?::[0-9]{1,5})?(?![A-Z0-9_\-])"#)
    private static let jwt = regex(#"(?<![A-Z0-9_-])eyJ[A-Z0-9_-]{5,}\.[A-Z0-9_-]{6,}\.[A-Z0-9_-]+(?![A-Z0-9_-])"#)
    private static let providerToken = regex(#"(?<![A-Z0-9_])(?:gh[pousr]_[A-Z0-9]{20,}|github_pat_[A-Z0-9_]{20,}|sk-[A-Z0-9_-]{20,}|xox[baprs]-[A-Z0-9-]{10,})(?![A-Z0-9_])"#)
    private static let maskedProviderToken = regex(#"(?<![A-Z0-9_-])(?:sk-|gh[pousr]_|github_pat_|xox[baprs]-)[A-Z0-9_-]{2,32}[ \t]*[*•●·⋅…]{3,}[ \t]*[A-Z0-9]{3,16}(?![A-Z0-9_-])"#)
    private static let tokenLike = regex(#"^[A-Z0-9_+./=*•●·⋅…-]{6,}$"#)
    private static let bareBearer = regex(#"(?<![A-Z0-9_])Bearer[ \t]+([A-Z0-9_.+/=\-]{8,})(?![A-Z0-9_])"#)
    private static let unlabelledToken = regex(#"(?<![A-Z0-9_])[A-Z0-9_-]{24,128}(?![A-Z0-9_-])"#)
    private static let keyBoundary = regex(#"-----\s*(BEGIN|END)\s+(?:[A-Z0-9]+[ \t]+)*PRIVATE[ \t]+KEY\s*-----"#)
    private static let connectionCredentials = regex(#"\b(?:https?|postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://([^/\s@]+:[^/\s@]+)@"#)
    private static let urlCredential = regex(#"[?&](access_token|refresh_token|id_token|auth_token|token|api[_-]?key|client[_-]?secret|password|passwd|pwd|signature|code|otp)=([^&#\s]+)"#)
    private static let urls = regex(#"\bhttps?://[^\s<>"，；。]+"#)
    private static let numericValue = regex(#"^(?:(?:\+86)[ \t\-]*)?[0-9OIilSXx](?:[0-9OIilSXx \t\u00a0\u2009\-‐–]*[0-9OIilSXx])?"#)
    private static let wordValue = regex(#"^[^\s，,；;。|｜<>{}\[\]"']+"#)
    private static let secretValue = regex(#"^[^ \t\r\n，,；;。|｜<>{}\[\]"']+"#)
    private static let credentialValue = regex(#"^[^\s，,；;。|｜"']+"#)
    private static let lineValue = regex(#"^\S[^\r\n|｜]*"#)
    private static let longValue = regex(#"^[A-Z0-9_+./=\-]{10,}$"#)
    private static let continuationLabel = regex(#"^(?:[A-Z][A-Z0-9_-]{0,22}|[\p{Han}]{2,8})[ \t]*[:=]"#)
    private static let fieldStart = #"(?<![A-Z0-9_?&./-])"#
    private static let fieldSeparator = #"["']?(?:[ \t]*[:=][ \t]*|[ \t]+)["']?"#
    private static let fields: [FieldRule] = [
        .init(rule: .credentials, labels: #"账号[ \t]*/?[ \t]*密码|账户[ \t]*/?[ \t]*密码|登录账号|登录名|账户名|用户名|账号|帐号|账户|口令|密码|user[ _-]?name|login[ _-]?id|account|pass(?:word|wd)|pwd"#, value: credentialValue),
        .init(rule: .verificationCode, labels: #"短信验证码|动态验证码|验证码|动态口令|one[ _-]time[ _-]code|verification[ _-]code|otp"#, value: regex(#"^[0-9OIlS]{4,8}(?![A-Z0-9])"#)),
        .init(rule: .token, labels: #"访问令牌|刷新令牌|访问密钥|签名密钥|私钥|密钥|authorization|proxy-authorization|access[_ -]?token|refresh[_ -]?token|id[_ -]?token|auth[_ -]?token|token|x-api-key|api[_ -]?key|client[_ -]?secret|secret[_ -]?key|access[_ -]?key|secret"#, value: secretValue),
        .init(rule: .cookie, labels: #"set-cookie|cookie"#, value: lineValue, consumesLine: true),
        .init(rule: .name, labels: #"持卡人姓名|收件人姓名|联系人姓名|客户姓名|收货人|收件人|寄件人|联系人|申请人|姓名|full[ _-]?name|recipient|name"#, value: regex(#"^(?:[A-Z][A-Z'’-]*(?:[ \t]+[A-Z][A-Z'’-]*){0,4}(?![A-Z0-9])|[\p{Han}·]{2,12})"#)),
        .init(rule: .employeeID, labels: #"员工编号|员工号|工号|employee[_ -]?(?:id|number|no\.?)"#, value: wordValue),
        .init(rule: .address, labels: #"收货地址|收件地址|寄件地址|详细地址|家庭住址|联系地址|住址|地址|shipping[ _-]?address|mailing[ _-]?address|address"#, value: lineValue, consumesLine: true)
    ]
    private static let numberLabels: [(PrivacyRule, String)] = [
        (.mobile, #"手机号(?:码)?|手机|移动电话|mobile(?:[ _-]?number)?|cell(?:[ _-]?phone)?"#),
        (.landline, #"固定电话|座机(?:号码)?|办公电话|联系电话|联系方式|联系号码|电话(?:号码)?|telephone|phone(?:[ _-]?number)?"#),
        (.identity, #"公民身份号码|公民身份号|身份证(?:号(?:码)?)?|证件号码|证件号|identity[ _-]?(?:number|no\.?)|id[ _-]?(?:number|no\.?)"#),
        (.bankCard, #"银行卡(?:号(?:码)?)?|信用卡(?:号(?:码)?)?|借记卡(?:号(?:码)?)?|卡号|card[ _-]?(?:number|no\.?)|pan"#)
    ]
    private static let nonSensitiveLabel = #"订单(?:号|编号)|流水(?:号|编号)|运单号|快递单号|单据号|跟踪号|order[ _-]?(?:id|number|no\.?)|tracking[ _-]?(?:id|number)"#
    private static let labelAlternatives = (fields.map(\.labels) + numberLabels.map(\.1) + [nonSensitiveLabel]).joined(separator: "|")
    private static let nextLabel = regex(fieldStart + "(?:" + labelAlternatives + ")" + fieldSeparator)
    private static let nonSensitive = regex(fieldStart + "(?:" + nonSensitiveLabel + #")["']?[ \t]*(?:[:=]|$)"#)
    private static let fieldPatterns = fields.map { field in
        regex(fieldStart + "(?:" + field.labels + ")" + fieldSeparator)
    }
    private static let fieldHeaders = fields.map { regex("^(?:" + $0.labels + #")[ \t]*[:=]?[ \t]*$"#) }
    private static let numberLabelPatterns = numberLabels.map { entry in
        regex(fieldStart + "(?:" + entry.1 + #")["']?[ \t]*(?:[:=][ \t]*["']?|[ \t]+|$)"#)
    }
    private static let numberHeaders = numberLabels.map { regex("^(?:" + $0.1 + #")[ \t]*[:=]?[ \t]*$"#) }
    private static let nonSensitiveHeader = regex("^(?:" + nonSensitiveLabel + #")[ \t]*[:=]?[ \t]*$"#)
    private static let wrapSeparator = regex(#"^[ \t]*(?:[，,；;。|｜]|$)"#)
    private static let networkAddress = regex(#"(?:(?:服务器|服务|接口|网络|访问|监听|IP)[ _-]*地址|server[ _-]*address|ip[ _-]*address)$"#)

    private struct Header {
        let line: Int
        let rule: PrivacyRule?
    }

    private let settings: PrivacySettings
    private let custom: [(CustomPrivacyRule, NSRegularExpression)]

    init(settings: PrivacySettings) throws {
        self.settings = settings
        self.custom = try settings.customRules.filter { $0.mode != .off }.map { rule in
            guard rule.validationMessage == nil, let regex = try? NSRegularExpression(pattern: rule.pattern) else {
                throw PrivacyScanError.invalidCustomRule
            }
            return (rule, regex)
        }
    }

    func matches(in lines: [PrivacyTextLine], includeCustom: Bool = true,
                 cancelled: () -> Bool = { false }) throws -> [PrivacyTextMatch] {
        let normalized = lines.map(\.normalized)
        let headers = normalized.enumerated().compactMap { index, text -> Header? in
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.nonSensitiveHeader.hasMatch(in: title) { return Header(line: index, rule: nil) }
            if let field = Self.fieldHeaders.firstIndex(where: { $0.hasMatch(in: title) }) {
                return Header(line: index, rule: Self.fields[field].rule)
            }
            if let field = Self.numberHeaders.firstIndex(where: { $0.hasMatch(in: title) }) {
                return Header(line: index, rule: Self.numberLabels[field].0)
            }
            return nil
        }
        let suffixes = settings[.internalDomain] == .off ? [] : settings.domainSuffixes
        var result: [PrivacyTextMatch] = []
        var keyOpen = false
        var wrap: (line: Int, rule: PrivacyRule, covered: Bool)?
        let ordered = lines.indices.sorted {
            if lines[$0].rect.minY != lines[$1].rect.minY { return lines[$0].rect.minY < lines[$1].rect.minY }
            return lines[$0].rect.minX < lines[$1].rect.minX
        }
        var remainingCustomTime = Duration.milliseconds(300)
        for (position, index) in ordered.enumerated() {
            if cancelled() { throw CancellationError() }
            let text = normalized[index]
            let value = text as NSString
            guard value.length > 0 else { continue }
            let full = NSRange(location: 0, length: value.length)
            func add(_ rule: PrivacyRule, _ range: NSRange, strong: Bool = true) {
                let mode = settings[rule]
                guard mode != .off, range.length > 0 else { return }
                result.append(.init(label: rule.title, line: index, range: range,
                                    covered: mode == .automatic && strong && lines[index].confidence >= 0.5))
            }

            if settings[.token] != .off {
                let boundaries = Self.keyBoundary.matches(in: text, range: full)
                if keyOpen || !boundaries.isEmpty { add(.token, full) }
                for boundary in boundaries { keyOpen = value.substring(with: boundary.range(at: 1)).uppercased() == "BEGIN" }
            }
            let matchedLabels = Self.nextLabel.matches(in: text, range: full)
            let header = Self.associatedHeader(for: index, headers: headers, lines: lines)
            var newWrap: (line: Int, rule: PrivacyRule, covered: Bool)?

            if let previous = wrap, matchedLabels.isEmpty,
               (previous.rule == .cookie || !Self.continuationLabel.hasMatch(in: text)),
               Self.isContinuation(of: lines[previous.line], line: lines[index]),
               Self.acceptsContinuation(text, rule: previous.rule) {
                add(previous.rule, full, strong: previous.covered)
                newWrap = (index, previous.rule, previous.covered)
            }
            for (fieldIndex, field) in Self.fields.enumerated() where settings[field.rule] != .off {
                for match in Self.fieldPatterns[fieldIndex].matches(in: text, range: full) {
                    if field.rule == .address {
                        let labelEnd = NSMaxRange(match.range)
                        let prefix = value.substring(to: labelEnd)
                            .trimmingCharacters(in: CharacterSet(charactersIn: " \t:=\"'"))
                        if Self.networkAddress.hasMatch(in: prefix) { continue }
                    }
                    let start = NSMaxRange(match.range)
                    let end = matchedLabels.first(where: { $0.range.location >= start })?.range.location ?? value.length
                    guard let range = Self.fieldValue(in: value, start: start, end: end, field: field) else { continue }
                    let separator = value.substring(with: match.range)
                    if field.rule == .token, !separator.contains(":"), !separator.contains("="),
                       !Self.looksLikeToken(value.substring(with: range)) { continue }
                    let strong = separator.contains(":") || separator.contains("=") || separator.contains { !$0.isASCII }
                    add(field.rule, range, strong: strong)
                    if (field.rule == .token || field.rule == .cookie || field.rule == .address),
                       end == value.length, Self.reachesLineEnd(range, in: value) {
                        newWrap = (index, field.rule, strong && lines[index].confidence >= 0.5)
                    }
                }
                if header?.rule == field.rule, matchedLabels.isEmpty,
                   let range = Self.fieldValue(in: value, start: 0, end: value.length, field: field),
                   field.rule != .token || Self.looksLikeToken(value.substring(with: range)) {
                    add(field.rule, range)
                    if (field.rule == .token || field.rule == .cookie || field.rule == .address),
                       Self.reachesLineEnd(range, in: value) {
                        newWrap = (index, field.rule, lines[index].confidence >= 0.5)
                    }
                }
            }
            wrap = newWrap

            let localNumberLabels = Self.numberLabelPatterns.enumerated().flatMap { index, pattern in
                pattern.matches(in: text, range: full).map { (Self.numberLabels[index].0, $0.range) }
            }
            let otherLabels = Self.nonSensitive.matches(in: text, range: full)
            for match in Self.numbers.matches(in: text, range: full) {
                let number = value.substring(with: match.range)
                let compact = Self.compactNumber(number)
                let digits = compact.hasPrefix("+86") ? String(compact.dropFirst(3)) : compact
                let offset = match.range.location
                let prefix = localNumberLabels.filter { rangeEnd($0.1, before: offset, within: 14) }
                    .max(by: { NSMaxRange($0.1) < NSMaxRange($1.1) })
                let other = otherLabels.filter { rangeEnd($0.range, before: offset, within: 14) }
                    .map { NSMaxRange($0.range) }.max()
                let order = other.map { $0 > (prefix.map { NSMaxRange($0.1) } ?? -1) }
                    ?? (prefix == nil && header != nil && header?.rule == nil)
                let context = prefix?.0 ?? header?.rule
                if Self.isIdentity(digits) {
                    add(.identity, match.range, strong: !order)
                } else if Self.isMobile(digits) {
                    add(.mobile, match.range, strong: !order && (context == nil || context == .mobile || context == .landline))
                } else if context == .identity, digits.count == 18 {
                    add(.identity, match.range, strong: false)
                } else if (13...19).contains(digits.count), Self.passesLuhn(digits) {
                    add(.bankCard, match.range, strong: context == .bankCard && !order)
                } else if context == .bankCard, (13...19).contains(digits.count) {
                    add(.bankCard, match.range, strong: false)
                } else if context == .landline, (7...8).contains(digits.count) {
                    add(.landline, match.range, strong: !order)
                }
            }
            let numberFields = localNumberLabels.map { ($0.0, NSMaxRange($0.1)) }
            let candidates: [(PrivacyRule, Int)]
            if numberFields.isEmpty, let rule = header?.rule, Self.numberLabels.contains(where: { $0.0 == rule }) {
                candidates = [(rule, 0)]
            } else {
                candidates = numberFields
            }
            for (rule, start) in candidates where settings[rule] != .off {
                guard start < value.length else { continue }
                let rest = value.substring(from: start)
                let tail = NSRange(location: 0, length: rest.utf16.count)
                if let partial = Self.maskedNumber.firstMatch(in: rest, range: tail) {
                    let raw = (rest as NSString).substring(with: partial.range)
                    let compact = Self.compactNumber(raw)
                    let digits = compact.hasPrefix("+86") ? String(compact.dropFirst(3)) : compact
                    let count = digits.count
                    if digits.contains(where: { "*•●X".contains($0) }), digits.filter(\.isNumber).count >= 2,
                       (rule == .identity && count == 18 || rule == .bankCard && (13...19).contains(count)
                        || rule == .mobile && count == 11 || rule == .landline && (7...12).contains(count)) {
                        add(rule, NSRange(location: start + partial.range.location, length: partial.range.length))
                        continue
                    }
                }
                guard let match = Self.numericValue.firstMatch(in: rest, range: tail) else { continue }
                let raw = (rest as NSString).substring(with: match.range)
                let compact = Self.compactNumber(raw)
                let digits = compact.hasPrefix("+86") ? String(compact.dropFirst(3)) : compact
                let count = digits.count
                let candidate = NSRange(location: start, length: match.range.length)
                switch rule {
                case .mobile where (10...12).contains(count): add(rule, candidate, strong: Self.isMobile(digits))
                case .landline where (7...8).contains(count): add(rule, candidate, strong: digits.allSatisfy(\.isNumber))
                case .identity where count == 18: add(rule, candidate, strong: Self.isIdentity(digits))
                case .bankCard where (13...19).contains(count): add(rule, candidate, strong: Self.passesLuhn(digits))
                default: break
                }
            }
            if let (rule, label) = localNumberLabels.last, position + 1 < ordered.count {
                let next = ordered[position + 1]
                let start = NSMaxRange(label)
                let tail = value.substring(from: start).trimmingCharacters(in: .whitespaces)
                let nextText = normalized[next].trimmingCharacters(in: .whitespaces)
                let compact = Self.compactNumber(tail + nextText)
                let digits = compact.hasPrefix("+86") ? String(compact.dropFirst(3)) : compact
                let valid: Bool
                switch rule {
                case .mobile: valid = Self.isMobile(digits)
                case .identity: valid = Self.isIdentity(digits)
                case .bankCard: valid = Self.passesLuhn(digits)
                default: valid = false
                }
                if valid, tail.count >= 3, nextText.count >= 3, settings[rule] != .off,
                   Self.isContinuation(of: lines[index], line: lines[next]) {
                    let covered = settings[rule] == .automatic && min(lines[index].confidence, lines[next].confidence) >= 0.5
                    result.append(.init(label: rule.title, line: index, range: NSRange(location: start, length: value.length - start), covered: covered))
                    result.append(.init(label: rule.title, line: next, range: NSRange(location: 0, length: normalized[next].utf16.count), covered: covered))
                }
            }
            if settings[.landline] != .off {
                for match in Self.landline.matches(in: text, range: full) {
                    let precededByOrder = otherLabels.contains { rangeEnd($0.range, before: match.range.location, within: 14) }
                    add(.landline, match.range, strong: !precededByOrder && !(header != nil && header?.rule == nil))
                }
            }
            if settings[.email] != .off {
                for match in Self.email.matches(in: text, range: full) { add(.email, match.range) }
            }
            if settings[.privateIP] != .off {
                for match in Self.ip.matches(in: text, range: full)
                    where Self.isPrivateIPv4(value.substring(with: match.range).filter { !$0.isWhitespace }) {
                    add(.privateIP, match.range)
                }
                for match in Self.ipv6.matches(in: text, range: full) where Self.isPrivateIPv6(value.substring(with: match.range)) {
                    add(.privateIP, match.range)
                }
            }
            if !suffixes.isEmpty {
                for match in Self.host.matches(in: text, range: full) {
                    let name = value.substring(with: match.range).lowercased().split(separator: ":").first.map(String.init) ?? ""
                    if suffixes.contains(where: { name == $0 || name.hasSuffix("." + $0) }) { add(.internalDomain, match.range) }
                }
            }
            if settings[.token] != .off {
                for pattern in [Self.jwt, Self.providerToken, Self.maskedProviderToken] {
                    for match in pattern.matches(in: text, range: full) { add(.token, match.range) }
                }
                for match in Self.bareBearer.matches(in: text, range: full) { add(.token, match.range(at: 1)) }
                if matchedLabels.isEmpty && !Self.urls.hasMatch(in: text) {
                    for match in Self.unlabelledToken.matches(in: text, range: full) {
                        let value = value.substring(with: match.range)
                        if value.contains(where: \.isLetter) && value.contains(where: \.isNumber) {
                            add(.token, match.range, strong: false)
                        }
                    }
                }
            }
            if settings[.credentials] != .off {
                for match in Self.connectionCredentials.matches(in: text, range: full) { add(.credentials, match.range(at: 1)) }
            }
            if settings[.token] != .off || settings[.credentials] != .off || settings[.verificationCode] != .off {
                for url in Self.urls.matches(in: text, range: full) {
                    for match in Self.urlCredential.matches(in: text, range: url.range) {
                        let key = value.substring(with: match.range(at: 1)).lowercased()
                        let rule: PrivacyRule
                        switch key {
                        case "password", "passwd", "pwd": rule = .credentials
                        case "code", "otp": rule = .verificationCode
                        default: rule = .token
                        }
                        add(rule, match.range(at: 2))
                    }
                }
            }
            for (rule, expression) in custom where includeCustom {
                let start = ContinuousClock.now
                let customDeadline = start.advanced(by: remainingCustomTime)
                guard ContinuousClock.now < customDeadline else { throw PrivacyScanError.customRuleTimedOut }
                var timedOut = false
                expression.enumerateMatches(in: lines[index].text, options: [.reportProgress], range: full) { match, _, stop in
                    if cancelled() || ContinuousClock.now >= customDeadline {
                        timedOut = true
                        stop.pointee = true
                    } else if let match, match.range.length > 0 {
                        result.append(.init(label: rule.name, line: index, range: match.range,
                                            covered: rule.mode == .automatic && lines[index].confidence >= 0.5))
                    }
                }
                if cancelled() { throw CancellationError() }
                if timedOut { throw PrivacyScanError.customRuleTimedOut }
                remainingCustomTime -= start.duration(to: .now)
            }
        }
        return Self.deduplicated(result)
    }

    private static func fieldValue(in text: NSString, start: Int, end: Int, field: FieldRule) -> NSRange? {
        guard end > start else { return nil }
        let tail = text.substring(with: NSRange(location: start, length: end - start))
        let trimmed = tail.trimmingCharacters(in: .whitespaces)
        let leading = (tail as NSString).range(of: trimmed).location
        guard !trimmed.isEmpty, leading != NSNotFound,
              let match = field.value.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) else { return nil }
        var range = match.range
        if (field.rule == .credentials || field.rule == .token),
           start > 0, let quote = UnicodeScalar(text.character(at: start - 1)), quote == "\"" || quote == "'",
           let endQuote = closingQuote(in: trimmed, quote: Character(quote)) {
            range = NSRange(trimmed.startIndex..<endQuote, in: trimmed)
        } else if field.consumesLine {
            let content = (trimmed as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
            range.length = content.utf16.count
        } else if field.rule == .token,
                  let masked = maskedProviderToken.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
                  masked.range.location == 0 {
            range = masked.range
        }
        if field.rule == .token {
            let part = (trimmed as NSString).substring(with: range).lowercased()
            if part == "bearer" || part == "basic" {
                let after = (trimmed as NSString).substring(from: NSMaxRange(range))
                let token = after.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty, let word = secretValue.firstMatch(in: token, range: NSRange(location: 0, length: token.utf16.count)) else { return nil }
                let offset = (after as NSString).range(of: token).location
                range = NSRange(location: NSMaxRange(range) + offset, length: word.range.length)
            }
        }
        return NSRange(location: start + leading + range.location, length: range.length)
    }

    private static func looksLikeToken(_ value: String) -> Bool {
        maskedProviderToken.hasMatch(in: value) || (tokenLike.hasMatch(in: value)
            && value.contains { $0.isNumber || "_+./=*•●·⋅…-".contains($0) })
    }

    static func isMaskedProviderToken(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return maskedProviderToken.firstMatch(in: value, range: range)?.range == range
    }

    private static func closingQuote(in text: String, quote: Character) -> String.Index? {
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if character == quote && !escaped { return index }
            escaped = character == "\\" && !escaped
        }
        return nil
    }

    private static func reachesLineEnd(_ range: NSRange, in text: NSString) -> Bool {
        text.substring(from: NSMaxRange(range)).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func associatedHeader(for index: Int, headers: [Header], lines: [PrivacyTextLine]) -> Header? {
        if headers.contains(where: { $0.line == index }) { return nil }
        let target = lines[index].rect
        return headers.filter { header in
            let label = lines[header.line].rect
            let distance = target.minY - label.minY
            let height = max(target.height, label.height, 1)
            // Same column below a header, or the value immediately to its right.
            let column = distance > height * 0.6 && distance < 360
                && abs(target.minX - label.minX) <= max(18, label.width * 0.24)
            let row = abs(target.midY - label.midY) <= height * 0.4
                && target.minX >= label.maxX - 2 && target.minX - label.maxX <= max(40, height * 5)
            return column || row
        }.min { lhs, rhs in
            func distance(_ header: Header) -> CGFloat {
                let rect = lines[header.line].rect
                return abs(target.midY - rect.midY) + max(0, target.minX - rect.maxX)
            }
            return distance(lhs) < distance(rhs)
        }
    }

    private static func isContinuation(of previous: PrivacyTextLine, line: PrivacyTextLine) -> Bool {
        let distance = line.rect.minY - previous.rect.minY
        let height = max(line.rect.height, previous.rect.height, 1)
        return distance >= height * 0.55 && distance <= height * 2.3
            && abs(line.rect.minX - previous.rect.minX) <= max(18, height)
    }

    private static func acceptsContinuation(_ text: String, rule: PrivacyRule) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch rule {
        case .token: return longValue.hasMatch(in: text)
        case .cookie: return text.contains("=") && !text.contains(":") && !text.contains(where: \.isNewline)
        case .address: return !text.isEmpty && !wrapSeparator.hasMatch(in: text)
            && text.contains(where: \.isNumber)
            && ["栋", "室", "楼", "路", "街", "号", "单元", "门牌", "区", "巷"].contains { text.contains($0) }
        default: return false
        }
    }

    private static func compactNumber(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !"-‐–".contains($0) }.uppercased()
    }

    static func isMobile(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 11 && bytes[0] == 49 && (51...57).contains(bytes[1]) && bytes.allSatisfy { (48...57).contains($0) }
    }

    static func isIdentity(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 18, bytes.prefix(17).allSatisfy({ (48...57).contains($0) }), bytes[0] != 48 else { return false }
        let digits = bytes.prefix(17).map { Int($0) - 48 }
        func number(_ indices: Range<Int>) -> Int { digits[indices].reduce(0) { $0 * 10 + $1 } }
        let year = number(6..<10), month = number(10..<12), day = number(12..<14)
        guard year >= 1800, year <= Calendar(identifier: .gregorian).component(.year, from: .now),
              (1...12).contains(month) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...monthDays[month - 1]).contains(day) else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checksum = Array("10X98765432".utf8)
        let sum = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
        return bytes[17] == checksum[sum % 11]
    }

    static func passesLuhn(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (13...19).contains(bytes.count), Set(bytes).count > 1, bytes.allSatisfy({ (48...57).contains($0) }) else { return false }
        var sum = 0
        for (index, byte) in bytes.reversed().enumerated() {
            let digit = Int(byte) - 48
            let value = index.isMultiple(of: 2) ? digit : digit * 2
            sum += value > 9 ? value - 9 : value
        }
        return sum.isMultiple(of: 10)
    }

    static func isPrivateIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        if parts.count == 2, !(1...65_535).contains(Int(parts[1]) ?? 0) { return false }
        guard let ip = parts.first else { return false }
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        let first = octets[0], second = octets[1]
        return first == 10 || first == 127 || (first == 192 && second == 168)
            || (first == 172 && (16...31).contains(second)) || (first == 169 && second == 254)
    }

    static func isPrivateIPv6(_ text: String) -> Bool {
        let address: String
        if text.hasPrefix("[") {
            guard let end = text.firstIndex(of: "]") else { return false }
            let port = text[text.index(after: end)...]
            if !port.isEmpty, !(1...65_535).contains(Int(port.dropFirst()) ?? 0) { return false }
            address = String(text[text.index(after: text.startIndex)..<end])
        } else {
            address = text
        }
        var bytes = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &bytes) }) == 1 else { return false }
        return withUnsafeBytes(of: bytes) { octets in
            octets[0] & 0xfe == 0xfc || (octets[0] == 0xfe && octets[1] & 0xc0 == 0x80)
                || (octets.prefix(15).allSatisfy { $0 == 0 } && octets[15] == 1)
        }
    }

    private static func deduplicated(_ matches: [PrivacyTextMatch]) -> [PrivacyTextMatch] {
        var result: [PrivacyTextMatch] = []
        for group in Dictionary(grouping: matches, by: \.line).values {
            let sorted = group.sorted {
                if $0.covered != $1.covered { return $0.covered && !$1.covered }
                return $0.range.length > $1.range.length
            }
            var accepted: [PrivacyTextMatch] = []
            for match in sorted where !accepted.contains(where: { NSIntersectionRange($0.range, match.range) == match.range }) {
                accepted.append(match)
            }
            result += accepted
        }
        return result.sorted { $0.line == $1.line ? $0.range.location < $1.range.location : $0.line < $1.line }
    }
}

private extension NSRegularExpression {
    func hasMatch(in string: String) -> Bool {
        firstMatch(in: string, range: NSRange(location: 0, length: string.utf16.count)) != nil
    }
}

private func rangeEnd(_ range: NSRange, before offset: Int, within distance: Int) -> Bool {
    (0...distance).contains(offset - NSMaxRange(range))
}
