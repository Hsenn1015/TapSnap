import Foundation

public enum PrivacyMode: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic, review, off

    public var title: String {
        switch self {
        case .automatic: return "自动遮盖"
        case .review: return "仅提示"
        case .off: return "关闭"
        }
    }
}

public enum PrivacyRule: String, CaseIterable, Hashable, Sendable {
    case mobile, landline, identity, bankCard, email, name, employeeID, address
    case credentials, verificationCode, token, cookie, privateIP, internalDomain
    case barcode, face

    public var title: String {
        switch self {
        case .mobile: return "大陆手机号"
        case .landline: return "座机号码"
        case .identity: return "身份证号"
        case .bankCard: return "银行卡号"
        case .email: return "邮箱"
        case .name: return "姓名"
        case .employeeID: return "工号"
        case .address: return "详细地址"
        case .credentials: return "账号和密码"
        case .verificationCode: return "验证码"
        case .token: return "Token、API Key 和密钥"
        case .cookie: return "Cookie"
        case .privateIP: return "内网 IP 和端口"
        case .internalDomain: return "内部域名"
        case .barcode: return "二维码和条形码"
        case .face: return "人脸"
        }
    }

    public var defaultMode: PrivacyMode {
        switch self {
        case .name, .employeeID, .address: return .review
        case .barcode, .face: return .off
        default: return .automatic
        }
    }

    var isVisual: Bool { self == .barcode || self == .face }
}

public struct CustomPrivacyRule: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name = ""
    public var pattern = ""
    public var mode: PrivacyMode = .review

    public init() {}

    public var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入规则名称" }
        if pattern.isEmpty { return "请输入正则表达式" }
        if pattern.utf16.count > 512 { return "正则表达式最多 512 个字符" }
        if (try? NSRegularExpression(pattern: pattern)) == nil { return "正则表达式语法有误" }
        return nil
    }
}

public struct PrivacySettings: Codable, Hashable, Sendable {
    public var enabled = false
    private var modes: [String: String] = [:]
    public var internalDomains = ""
    public var customRules: [CustomPrivacyRule] = []
    private var maskAppearance: PrivacyMaskAppearance?
    public var ai: PrivacyAIConfiguration?
    private var aiProfiles: [String: PrivacyAIConfiguration]?

    public init() {}

    /// 读取上次保存的某服务商配置，切回时不必重新填写地址和模型名。
    public func savedAI(for provider: PrivacyAIProvider) -> PrivacyAIConfiguration {
        if let ai, ai.provider == provider { return ai }
        if let profile = aiProfiles?[provider.rawValue] { return profile }
        return PrivacyAIConfiguration(provider: provider)
    }

    public mutating func saveAIProfile(_ configuration: PrivacyAIConfiguration) {
        var profiles = aiProfiles ?? [:]
        profiles[configuration.provider.rawValue] = configuration
        aiProfiles = profiles
    }

    public var appearance: PrivacyMaskAppearance {
        get { maskAppearance ?? PrivacyMaskAppearance() }
        set { maskAppearance = newValue }
    }

    public subscript(rule: PrivacyRule) -> PrivacyMode {
        get { modes[rule.rawValue].flatMap(PrivacyMode.init(rawValue:)) ?? rule.defaultMode }
        set { modes[rule.rawValue] = newValue == rule.defaultMode ? nil : newValue.rawValue }
    }

    var domainSuffixes: [String] {
        internalDomains.lowercased().split { $0.isWhitespace || ",，;；".contains($0) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") } }
    }
}

public struct PrivacyFinding: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let label: String
    /// 图像像素坐标，原点左上。
    public let bounds: CGRect
    public var isCovered: Bool

    public init(label: String, bounds: CGRect, isCovered: Bool) {
        self.label = label
        self.bounds = bounds
        self.isCovered = isCovered
    }

}

public enum PrivacyScanError: Error {
    case imageProcessingFailed
    case invalidCustomRule
    case customRuleTimedOut
}
