import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 模型配置

struct ModelConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var provider: String          // openai / deepseek / anthropic / custom
    var apiProtocol: String       // OpenAI Chat Completions / OpenAI Responses / Anthropic / Custom
    var baseURL: String           // https://api.openai.com/v1
    /// 2026-11-03：备用接口地址——「在外面」时自动改用它。
    ///
    /// 用户诉求原话：「第一个填写在家时候的接口，第二个填写在外面时候的接口，
    /// 然后能自动判定咱们在家还是在外面，在家就用接口地址，在外就用备用接口地址」。
    ///
    /// 空串 = 未启用双通道（老配置全部是这个值，行为与改前完全一致）。
    /// 判定逻辑见 BaseURLRouter：网段 → 后台探测 → 失败回切，三层。
    var backupBaseURL: String = ""
    /// 2026-11-03：备用模型名称——和 backupBaseURL 配成一对。
    ///
    /// 用户诉求原话：「模型名称下方再添加一个备用模型，接口地址对应模型名称，
    /// 备用地址对应备用模型，这样我在家可以选择指定的模型，在外我也可以选择指定的模型」。
    ///
    /// 空串 = 在外时沿用主模型名（只是换地址，不换模型）。
    var backupModel: String = ""
    var apiKey: String
    var model: String             // gpt-4o-mini
    var authMethod: String        // Bearer / API Key / Body api_key / Body token / Query token / None
    var isDefault: Bool = false
    var temperature: Double = 0.2   // v6.1.5-14bj：执行任务型AI标准(参考Claude Agent SDK默认0/代码工具类0.1-0.3)，原0.7偏高输出飘
    var maxTokens: Int = 16384      // v6.1.5-14bj：Agent场景需大输出(BytePlus官方推荐≥128000, 手机端取16384平衡; 原2048会截断长任务)
    /// 2026-11-03：**真正该用的接口地址**——双通道自动切换的落点。
    ///
    /// 所有「发请求 / 拼端点 / 拉模型列表」的地方都必须读这个，
    /// 不能读 `baseURL`（那是配置里填的「在家地址」原值）。
    ///
    /// 没填备用地址时它就是 `baseURL`，行为与改前完全一致。
    var effectiveBaseURL: String {
        BaseURLRouter.shared.base(for: self)
    }

    /// 2026-11-03：**真正该用的模型名**——和 `effectiveBaseURL` 严格配对。
    ///
    /// 在家 → `model`（配 baseURL）；在外 → `backupModel`（配 backupBaseURL）。
    /// 备用模型名没填时沿用主模型名（只换地址、不换模型），
    /// 这样只想换地址不想换模型的用户什么都不用多填。
    ///
    /// 走哪一条由 BaseURLRouter 统一决定，模型名和地址必须同源 ——
    /// 否则会出现「用在家地址 + 在外模型名」这种上游必定 404 的组合。
    var effectiveModel: String {
        let bm = backupModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bm.isEmpty else { return model }
        // 只有真的切到备用地址时才用备用模型名
        return BaseURLRouter.shared.isUsingBackup(for: self) ? bm : model
    }

    /// v7.1.107：备用模型组（fallback 链）——主模型请求失败（网络/超时/鉴权/熔断/5xx，
    /// 且未产出任何内容）时，OpenAIClient 自动按序切换到备用模型重发同一请求
    /// （对齐 OpenMinis ModelGroupRouter fallback 思想，自实现不搬码）。空数组=不启用。
    var fallbackIDs: [UUID] = []
    /// v2.9.11：输入上下文预算 (token 估算）。发送前按预算自动裁剪最旧消息，
    /// 避免长会话请求体无限增长导致"一直请求中"。
    /// v7.1.109-peers：默认值 16000 → 128000（2026 主流模型最小窗口档；16k 会让
    /// 未匹配模型掉进 <32K 硬停档，是历史遗留坑）。
    var contextTokens: Int = 128000
    /// v7.1.107：模型能力表匹配后的实际压缩预算——命中已知模型用真实 context window
    /// （大窗口多留历史、小窗口不撑爆）。
    /// v7.1.109-peers：兜底链升级——显式后缀 > 实测记录 > 静态表 > 代际推断 > 128k 安全默认。
    /// contextTokens 默认值（128000/老默认 16000）视为"未配置"→ 用智能窗口；
    /// 用户显式设置过 → 作为上限尊重（防止小窗口模型被撑爆）。
    var effectiveContextTokens: Int {
        let resolved = ModelCapability.resolvedWindow(for: model)
        if contextTokens == 128_000 || contextTokens == 16_000 { return resolved }
        return min(resolved, contextTokens)
    }
    /// v7.1.109-peers：OpenMinis ContextPolicy 分档阈值借鉴——按窗口大小分档自动压缩触发线：
    /// <32K 不自动压缩（压不起，超限硬停）；32K–128K 剩 10K 触发；≥128K 剩 20K 触发。
    /// 相比旧"70%×窗口"一刀切：小窗口不硬压、大窗口多留历史余量。
    static func contextCompactLine(for window: Int) -> Int {
        if window < 32_000 { return 0 }              // 硬停档
        if window < 128_000 { return window - 10_000 }
        return window - 20_000
    }
    /// v2.8.4：中转站兼容级别 (由 OpenAIClient 自适应降级时写入并持久化）
    /// 0=完整载荷 1=互换token参数名 2=去掉tool_choice 3=去掉tools纯对话 4=最小载荷
    var compatLevel: Int = 0
    /// v7.1.280-fix：老手固定模式——协议自动修正开关（false=尊重手动选择的协议，失败按所选
    /// 协议报错不再自动改；true=按模型自动纠偏+持久化）。默认 true（新手自适应）。
    var protocolAutoFixEnabled: Bool = true
    /// v7.1.280-fix：降级链上限（0-5，默认 5=全链自适应；配 0=固定 L0 完整载荷，失败直接
    /// 报错不降级——老手要可预测/可控时用，避免"不知道请求以什么载荷发出"）。
    var compatMaxLevel: Int = 5
    /// v7.1.281-fix：该中转/模型已确认不支持流式（首字节超时切非流式时持久化 true）——
    /// 下次请求直接非流式不再白等首字节；配置页"流式传输"开关可恢复（对齐 BackgroundLLM
    /// allowsNonStreaming 能力缓存思路，主链路落地）。
    var streamUnsupported: Bool = false
    /// v2.9.107：分组名 (供应商分组管理，对齐 cc-switch provider groups）
    var group: String = "default"
    /// v3.5.13：可配置的参数名别名映射（标准键 → 该供应商认的键），如
    /// {"max_tokens":"max_completion_tokens", "reasoning_effort":"reasoning"}。
    /// 覆盖"不同中转对同一参数名接受度不同"的场景，不只内置 max_tokens 互换。
    var paramAliases: [String: String] = [:]
    /// v3.1.1：是否支持视觉 (VLM）——v7.1.109-peers 动态监测优先
    /// （对齐 OpenMinis models.dev 能力表思路，本地学习版）：发图请求成功 → 标记支持，
    /// 模型非视觉错误 → 标记不支持（持久化）；未知才走静态模型名规则。
    var supportsVision: Bool {
        if let learned = VisionTracker.shared.learned(for: model) { return learned }
        let m = model.lowercased()
        // 明确支持视觉的模型
        if m.contains("gpt-4o") || m.contains("gpt-4-vision") || m.contains("gpt-4v") { return true }
        if m.contains("claude-3") || m.contains("claude 3") { return true }
        if m.contains("gemini") { return true }
        if m.contains("qwen-vl") || m.contains("qwen2-vl") { return true }
        if m.contains("glm-4v") || m.contains("glm4v") { return true }
        if m.contains("vision") || m.contains("vl-") { return true }
        // 明确不支持的
        if m.contains("deepseek") { return false }
        if m.contains("gpt-3.5") || m.contains("gpt-35") { return false }
        // 默认：不支持 (保守策略，避免 API 报错）
        return false
    }

    /// v7.4.0-fix73d：按模型名判断视觉能力（上游模型列表/选择弹窗 UI 用——无 config 对象时
    /// 用临时 config 走同一套 supportsVision 判定：VisionTracker 学习优先 + 静态规则兜底）
    static func modelSupportsVision(_ model: String) -> Bool {
        let cfg = ModelConfig(name: model, provider: "preview",
                              baseURL: "", apiKey: "", model: model)
        return cfg.supportsVision
    }

    init(id: UUID = UUID(), name: String, provider: String, apiProtocol: String = "OpenAI Chat Completions",
         baseURL: String, backupBaseURL: String = "", backupModel: String = "", apiKey: String, model: String,
         authMethod: String = "Bearer",
         isDefault: Bool = false, temperature: Double = 0.2, maxTokens: Int = 16384, compatLevel: Int = 0,
         contextTokens: Int = 128000, group: String = "default", paramAliases: [String: String] = [:],
         fallbackIDs: [UUID] = [], protocolAutoFixEnabled: Bool = true, compatMaxLevel: Int = 5,
         streamUnsupported: Bool = false) {
        self.id = id
        self.name = name
        self.provider = provider
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.backupBaseURL = backupBaseURL
        self.backupModel = backupModel
        self.apiKey = apiKey
        self.model = model
        self.authMethod = authMethod
        self.isDefault = isDefault
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.compatLevel = compatLevel
        self.contextTokens = contextTokens
        self.group = group
        self.paramAliases = paramAliases
        self.fallbackIDs = fallbackIDs
        self.protocolAutoFixEnabled = protocolAutoFixEnabled
        self.compatMaxLevel = compatMaxLevel
        self.streamUnsupported = streamUnsupported
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        let decodedProtocol = (try? c.decode(String.self, forKey: .apiProtocol)) ?? "OpenAI Chat Completions"
        // v2.9.2：OpenAI Completions (旧版文本补全）已移除，旧配置迁移到 Chat Completions
        apiProtocol = decodedProtocol == "OpenAI Completions" ? "OpenAI Chat Completions" : decodedProtocol
        baseURL = try c.decode(String.self, forKey: .baseURL)
        // 2026-11-03：旧配置没有这个键 → 默认空串（= 不启用双通道）
        backupBaseURL = (try? c.decode(String.self, forKey: .backupBaseURL)) ?? ""
        // 2026-11-03：旧配置没有这个键 → 默认空串（在外时沿用主模型名）
        backupModel = (try? c.decode(String.self, forKey: .backupModel)) ?? ""
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        let decodedAuthMethod = (try? c.decode(String.self, forKey: .authMethod)) ?? "Bearer"
        authMethod = decodedAuthMethod.trimmingCharacters(in: .whitespaces).isEmpty ? "Bearer" : decodedAuthMethod
        isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? 0.2
        maxTokens = (try? c.decode(Int.self, forKey: .maxTokens)) ?? 16384
        contextTokens = (try? c.decode(Int.self, forKey: .contextTokens)) ?? 128000
        compatLevel = (try? c.decode(Int.self, forKey: .compatLevel)) ?? 0
        group = (try? c.decode(String.self, forKey: .group)) ?? "default"
        paramAliases = (try? c.decode([String: String].self, forKey: .paramAliases)) ?? [:]
        fallbackIDs = (try? c.decode([UUID].self, forKey: .fallbackIDs)) ?? []   // v7.1.107：旧配置缺失时默认无备用
        protocolAutoFixEnabled = (try? c.decode(Bool.self, forKey: .protocolAutoFixEnabled)) ?? true
        compatMaxLevel = (try? c.decode(Int.self, forKey: .compatMaxLevel)) ?? 5
        streamUnsupported = (try? c.decode(Bool.self, forKey: .streamUnsupported)) ?? false
    }
}

// MARK: - 模型协议与鉴权方式

/// v7.1.109-peers：模型能力表（2026-10 全量核对）——覆盖 20+ 厂商主流模型真实 context window，
/// 用于压缩预算自动匹配。数值按各厂商公开文档/Azure/Bedrock 模型卡核对；
/// 未收录模型返回 nil → 走 ModelConfig.contextTokens 兜底。
/// 对齐 OpenMinis models.dev 能力表的思路（本地静态版，不依赖网络注册表）。
enum ModelCapability {
    static func contextWindow(for model: String) -> Int? {
        let m = model.lowercased()
        // Anthropic Claude：全系 200k（3.5/3.7/4.x/4.5/5 系列维持 200k 窗口）
        if m.contains("claude") {
            return 200_000
        }
        // OpenAI GPT-6 系（sol/astra/luna）：API 原生 1.05M / 产品默认 500k~1M，取保守 1M
        if m.contains("gpt-6.1") || m.contains("gpt-6") { return 1_000_000 }
        // GPT-5.6 系（sol/terra/luna）：1M（Azure 1050k / Bedrock 1M / API 1.05M）
        if m.contains("gpt-5.6") { return 1_000_000 }
        // GPT-5 系：400k；GPT-4.1：1M；GPT-4o/o1/o3/o4：200k；GPT-4：128k
        if m.contains("gpt-5") { return 400_000 }
        if m.contains("gpt-4.1") { return 1_000_000 }
        if m.contains("gpt-4o") || m.contains("o1") || m.contains("o3") || m.contains("o4") { return 200_000 }
        if m.contains("gpt-4") { return 128_000 }
        // GPT-OSS 开源系：128k
        if m.contains("gpt-oss") { return 128_000 }
        // DeepSeek：V3/R1/V4 及 chat(reasoner API 名)=128k，其余（老 chat 类）64k
        if m.contains("deepseek") {
            if m.contains("v3") || m.contains("r1") || m.contains("v4") || m.contains("chat") { return 128_000 }
            return 64_000
        }
        // 智谱 GLM：GLM-4.6 200k，其余（4.5/4.7/5 系）128k
        if m.contains("glm") {
            if m.contains("4.6") { return 200_000 }
            return 128_000
        }
        // Kimi / Moonshot：K3 系列 1,048,576（官方确认），K2/带256 256k，其余 128k
        if m.contains("kimi") || m.contains("moonshot") {
            if m.contains("k3") { return 1_048_576 }
            if m.contains("k2") || m.contains("256") { return 256_000 }
            return 128_000
        }
        // 通义 Qwen：3-Max/3.7/3.8-Max 262144（256k），其余 131072（128k）
        if m.contains("qwen") {
            if m.contains("3-max") || m.contains("3.7") || m.contains("3.8") { return 262_144 }
            return 131_072
        }
        // MiniMax：M2 204800（官方/Bedrock 205k），Text-01/M1 1M，其余 131072
        if m.contains("minimax") {
            if m.contains("m2") { return 204_800 }
            if m.contains("text-01") || m.contains("m1") { return 1_000_000 }
            return 131_072
        }
        // 豆包 / 火山 Ark：Seed 全系 256k（1.6/1.8/2.x），pro 按型号后缀 32k/128k/256k，默认 128k
        if m.contains("doubao") || m.contains("ark") || m.contains("volc") {
            if m.contains("seed") { return 256_000 }
            if m.contains("32k") { return 32_000 }
            if m.contains("128k") { return 128_000 }
            if m.contains("256k") { return 256_000 }
            return 128_000
        }
        // Gemini：1M（Pro/Flash 系）
        if m.contains("gemini") { return 1_000_000 }
        // Grok：Fast/4.20 2M，4.7 500k，4.6 200k，其余（grok-3/4 标准）256k
        if m.contains("grok") {
            if m.contains("fast") || m.contains("4.20") { return 2_000_000 }
            if m.contains("4.7") { return 500_000 }
            if m.contains("4.6") { return 200_000 }
            return 256_000
        }
        // Mistral：Large-3 / Medium-3.5 256k，其余 128k
        if m.contains("mistral") {
            if m.contains("large-3") || m.contains("medium-3") || m.contains("256") { return 256_000 }
            return 128_000
        }
        // 阶跃 Step：带16k 变体 16384，preview/5 系 1M，3 系 256k，其余（step-2 系）128k
        if m.contains("step") || m.contains("stepfun") {
            if m.contains("16k") { return 16_384 }
            if m.contains("preview") || m.contains("step-5") { return 1_000_000 }
            if m.contains("3.") || m.contains("3-") { return 262_144 }
            return 128_000
        }
        // 开源 / 国产系固定档
        if m.contains("llama") { return 128_000 }
        if m.contains("ernie") || m.contains("文心") { return 128_000 }
        if m.contains("hunyuan") || m.contains("混元") { return 128_000 }
        if m.contains("spark") || m.contains("星火") { return 128_000 }
        if m.contains("baichuan") || m.contains("百川") { return 128_000 }
        if m.contains("yi-") || m.contains("01-ai") || m.contains("zero-one") { return 200_000 }
        if m.contains("internlm") || m.contains("书生") { return 128_000 }
        if m.contains("command") { return 128_000 }
        if m.contains("phi") { return 128_000 }
        if m.contains("nemotron") { return 128_000 }
        if m.contains("sensechat") || m.contains("商量") { return 128_000 }
        return nil
    }

    /// v7.1.109-peers：显式长度后缀解析——模型名自带窗口（128k/256k/32k/16k/1m 等），
    /// 比静态表更可靠（模型名是厂商自己标的），优先级最高。
    static func explicitSuffix(for model: String) -> Int? {
        let m = model.lowercased()
        let patterns: [(String, Int)] = [
            ("1048576", 1_048_576), ("1.048m", 1_048_576), ("1.05m", 1_050_000),
            ("2m", 2_000_000), ("1m", 1_000_000), ("512k", 512_000), ("256k", 256_000),
            ("200k", 200_000), ("131072", 131_072), ("128k", 128_000), ("64k", 64_000),
            ("32k", 32_000), ("16k", 16_384), ("8k", 8_192)
        ]
        for (pat, val) in patterns where m.contains(pat) { return val }
        return nil
    }

    /// v7.1.109-peers：代际推断——静态表未收录时按家族+版本号规律估窗口（保守档）。
    /// 规律基于各厂公开历史：GPT-N 4→128k 5→400k 6+→1M；Claude 3+→200k；
    /// Qwen 2→128k 3+→256k；GLM 4.5→128k 5+→256k；DeepSeek 2+→128k；
    /// Kimi K2→256k K3+→1M；Gemini→1M；Llama/Mistral/Phi→128k
    static func inferGeneration(for model: String) -> Int? {
        let m = model.lowercased()
        if let g = modelGenNumber(m, prefix: "gpt") {
            if g >= 6 { return 1_000_000 }
            if g >= 5 { return 400_000 }
            if g >= 4 { return 128_000 }
        }
        if let g = modelGenNumber(m, prefix: "claude") { return g >= 3 ? 200_000 : 100_000 }
        if let g = modelGenNumber(m, prefix: "qwen") { return g >= 3 ? 256_000 : 131_072 }
        if let g = modelGenNumber(m, prefix: "glm") { return g >= 5 ? 256_000 : 128_000 }
        if let g = modelGenNumber(m, prefix: "deepseek") { return g >= 2 ? 128_000 : 64_000 }
        if m.contains("gemini") { return 1_000_000 }
        if m.contains("llama") || m.contains("mistral") || m.contains("phi") || m.contains("ernie") { return 128_000 }
        // Kimi K 系列（k2/k3…，字母+数字命名）
        if let r = m.range(of: "k[0-9]", options: .regularExpression) {
            let g = Int(String(m[r]).suffix(1)) ?? 0
            if g >= 3 { return 1_000_000 }
            if g >= 2 { return 256_000 }
            return 128_000
        }
        return nil
    }
    private static func modelGenNumber(_ m: String, prefix: String) -> Int? {
        guard let r = m.range(of: prefix + "-?[0-9]+", options: .regularExpression) else { return nil }
        let digits = String(m[r]).filter { $0.isNumber }
        return Int(digits)
    }

    /// v7.1.109-peers：最终兜底链——显式后缀 > 实测记录 > 静态表 > 代际推断 > 128k 安全默认。
    /// 模型迭代太快静态表追不上：实测自适应（成功上调/超限下调）保证新模型逐步收敛真实窗口。
    static func resolvedWindow(for model: String) -> Int {
        if let explicit = explicitSuffix(for: model) { return explicit }
        if let measured = RuntimeWindowTracker.shared.measuredWindow(for: model) { return measured }
        if let known = contextWindow(for: model) { return known }
        if let inferred = inferGeneration(for: model) { return inferred }
        return 128_000
    }
}

/// v7.1.109-peers：实测窗口自适应——模型迭代太快静态表追不上：
/// 成功请求把窗口上调到实际用量以上（留 10k 余量），超限错误把窗口下调到实际用量以下，
/// 持久化 UserDefaults（按模型名），未收录/新迭代模型也能逐步收敛到真实窗口。
final class RuntimeWindowTracker {
    static let shared = RuntimeWindowTracker()
    private let key = "trollagent_measured_windows_v1"   // [String: Int]

    func measuredWindow(for model: String) -> Int? {
        UserDefaults.standard.dictionary(forKey: key)?[model.lowercased()] as? Int
    }
    func recordSuccess(model: String, promptTokens: Int) {
        let m = model.lowercased()
        let p = promptTokens + 10_000   // 成功 = 窗口至少这么大，留余量
        guard p > 8_000 else { return }
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        if (d[m] ?? 0) < p { d[m] = p; UserDefaults.standard.set(d, forKey: key) }
    }
    func recordExceeded(model: String, promptTokens: Int) {
        let m = model.lowercased()
        let p = max(4_000, promptTokens - 5_000)   // 超限 = 窗口没这么大，下调并留余量
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        if (d[m] ?? Int.max) > p { d[m] = p; UserDefaults.standard.set(d, forKey: key) }
    }
}

/// v7.1.109-peers：视觉能力动态监测（对齐 OpenMinis models.dev 能力表思路，本地学习版）——
/// 发图请求成功 → 标记支持；模型非视觉错误 → 标记不支持。持久化 UserDefaults 按模型名，
/// 优先于静态规则：新迭代模型/自建模型自动收敛真实视觉能力，不靠猜。
final class VisionTracker {
    static let shared = VisionTracker()
    private let key = "trollagent_vision_caps_v1"   // [String: Bool]

    func learned(for model: String) -> Bool? {
        UserDefaults.standard.dictionary(forKey: key)?[model.lowercased()] as? Bool
    }
    func record(model: String, supports: Bool) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
        d[model.lowercased()] = supports
        UserDefaults.standard.set(d, forKey: key)
    }
}

extension ModelConfig {
    /// v7.1.109-peers：协议面扩充——OpenRouter（OpenAI 兼容+专用 header/vendor 命名）、
    /// Gemini（原生 generateContent，覆盖 Google 官方与 Gemini 中转）
    static let apiProtocols = [
        "OpenAI Chat Completions",
        "OpenAI Responses",
        "Anthropic Messages",
        "OpenRouter",
        "Gemini",
        "Custom Endpoint"
    ]

    static let authMethods = ["Bearer", "API Key", "Body api_key", "Body token", "Query token", "None"]

    /// 2026-11-05 **快速配置项改成结构体（原来是不带标签的 6 元组）**。
    ///
    /// 起因：用户要在「供应商快速配置」里加自己的中转站，而且一条要带 **4 样东西**——
    /// 名字、内网地址、备用域名、Key。原来的元组只有
    /// `(name, provider, protocol, baseURL, model, auth)` 六项，
    /// `backupBaseURL` 和 `apiKey` 根本无处安放，点一下只能填一半，
    /// 用户还得自己回头补两栏，等于没做。
    ///
    /// 改成结构体后新增这两个字段，其余字段语义完全不变；
    /// 老行的写法用 `p(...)` 简写保持原样，不引入无谓 diff。
    struct ProviderPreset: Identifiable {
        var name: String
        var provider: String
        var apiProtocol: String
        var baseURL: String
        var model: String
        var auth: String
        /// 备用接口（在外时用）。空串 = 这条预设不涉及双通道。
        var backupBaseURL: String = ""
        /// 一键带上的 Key。空串 = 需要用户自己填。
        var apiKey: String = ""
        var id: String { name }
    }

    /// 简写构造器：让原有 16 条预设保持「一行一条」的可读性。
    private static func p(_ name: String, _ provider: String, _ proto: String,
                          _ baseURL: String, _ model: String, _ auth: String,
                          backup: String = "", key: String = "") -> ProviderPreset {
        ProviderPreset(name: name, provider: provider, apiProtocol: proto,
                       baseURL: baseURL, model: model, auth: auth,
                       backupBaseURL: backup, apiKey: key)
    }

    /// 2026-11-05：家里那台中转站的内网地址。全项目只此一处定义，
    /// 避免「改了预设忘了 RelayAdminView」。
    static let relayHomeURL = "http://192.168.1.88:8080/v1"
    /// 中转站公网域名（Cloudflare 隧道）。**必须复用 RouterControl.wanHost**，
    /// 那是全项目唯一的域名来源；写死一份副本就等着哪天改域名漏掉这里。
    static var relayAwayURL: String { "https://" + RouterControl.wanHost + "/v1" }

    static var providerPresets: [ProviderPreset] {
        [
        // 2026-11-05 **用户自己的中转站，排第一位**。
        //   点一下就把「内网地址 + 备用域名 + Key」三样一次填好，
        //   在家自动走 192.168.1.88，出门自动走域名（判定见 BaseURLRouter）。
        //   模型名故意留空 —— 用户明确说「剩下的我自己选择就行了」，
        //   留空时模型选择器会去上游拉真实清单，比猜一个写死的名字稳。
        p("中转站", "relay", "OpenAI Chat Completions",
          relayHomeURL, "", "Bearer",
          backup: relayAwayURL,
          key: "sk-relay-c89baf204eab9fad9af69749"),
        p("OpenAI", "openai", "OpenAI Chat Completions", "https://api.openai.com/v1", "gpt-4o-mini", "Bearer"),
        p("DeepSeek", "deepseek", "OpenAI Chat Completions", "https://api.deepseek.com", "deepseek-chat", "Bearer"),
        p("Anthropic", "anthropic", "Anthropic Messages", "https://api.anthropic.com/v1", "claude-3-5-sonnet-20240620", "API Key"),
        // 2026-11-02 按用户要求：移除 Botcf 预设项（作者自用中转站，与推荐横幅一并删除）
        // v4.4.17：扩充主流 OpenAI 兼容预设 (GLM/Kimi/Qwen/MiniMax/阶跃/豆包)。模型名可在模型管理页改。
        p("智谱GLM", "zhipu", "OpenAI Chat Completions", "https://open.bigmodel.cn/api/paas/v4", "glm-4.5", "Bearer"),
        p("Kimi(Moonshot)", "moonshot", "OpenAI Chat Completions", "https://api.moonshot.cn/v1", "kimi-k3", "Bearer"),
        p("通义千问(Qwen)", "qwen", "OpenAI Chat Completions", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen3.8-max", "Bearer"),
        p("MiniMax", "minimax", "OpenAI Chat Completions", "https://api.minimax.chat/v1", "MiniMax-Text-01", "Bearer"),
        p("阶跃星辰(Step)", "step", "OpenAI Chat Completions", "https://api.stepfun.com/v1", "step-2-mini", "Bearer"),
        p("豆包(火山)", "doubao", "OpenAI Chat Completions", "https://ark.cn-beijing.volces.com/api/v3", "doubao-pro-32k", "Bearer"),
        // v7.1.109-peers：协议面扩充预设——OpenRouter / xAI / Groq / Mistral / Ollama / Azure / Gemini
        // (OpenAI 兼容的配 Chat Completions 即用；Gemini 原生协议走 generateContent)
        p("OpenRouter", "openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "deepseek/deepseek-chat", "Bearer"),
        p("xAI", "xai", "OpenAI Chat Completions", "https://api.x.ai/v1", "grok-4", "Bearer"),
        p("Groq", "groq", "OpenAI Chat Completions", "https://api.groq.com/openai/v1", "llama-4-70b", "Bearer"),
        p("Mistral", "mistral", "OpenAI Chat Completions", "https://api.mistral.ai/v1", "mistral-large-latest", "Bearer"),
        p("Ollama(本地)", "ollama", "OpenAI Chat Completions", "http://127.0.0.1:11434/v1", "llama3", "None"),
        p("Azure OpenAI", "azure", "OpenAI Chat Completions", "https://YOUR-RESOURCE.openai.azure.com/openai/deployments/YOUR-DEPLOYMENT", "gpt-4o", "API Key"),
        p("Gemini", "google", "Gemini", "https://generativelanguage.googleapis.com/v1beta", "gemini-2.5-pro", "Query key")
        ]
    }

    /// 中转站的显示名（列表标题、供应商行都用它）
    static let relayDisplayName = "中转站"

    /// 2026-11-03：provider 内部代号 → 用户看得懂的供应商名。
    ///
    /// 为什么必须有这张表：用户新建配置时 `name` 默认是空的，或直接沿用了模型名，
    /// 于是「选择模型供应商」页里每一行的主标题都显示成 `deepseek-v4.1-flash`，
    /// 副标题也是 `deepseek-v4.1-flash · custom` —— 整页一个供应商名都看不到，
    /// 用户的原话就是「你显示的不是供应商而是模型」。
    /// 主标题改为按 provider 代号查友好名，查不到再退回 name / provider 原文。
    static func providerDisplayName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "openai":      return "OpenAI"
        case "deepseek":    return "DeepSeek"
        case "anthropic":   return "Anthropic"
        case "zhipu":       return "智谱 GLM"
        case "moonshot":    return "Kimi (Moonshot)"
        case "qwen":        return "通义千问 (Qwen)"
        case "minimax":     return "MiniMax"
        case "step":        return "阶跃星辰 (Step)"
        case "doubao":      return "豆包 (火山)"
        case "openrouter":  return "OpenRouter"
        case "xai":         return "xAI"
        case "groq":        return "Groq"
        case "mistral":     return "Mistral"
        case "ollama":      return "Ollama (本地)"
        case "azure":       return "Azure OpenAI"
        case "google":      return "Gemini"
        case "relay":       return "中转站"
        case "custom":      return "自定义接口"
        default:
            let p = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? "自定义接口" : p
        }
    }

    /// 这条配置在列表里该用哪个当「供应商」标题。
    ///
    /// 优先用 provider 友好名；但用户明确改过 name（跟模型名/供应商名都不同）时
    /// 尊重用户自己起的名字——那才是他认得出来的标识。
    var supplierTitle: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = ModelConfig.providerDisplayName(provider)
        guard !n.isEmpty else { return base }
        // name 只是模型名或供应商代号的复制品 → 说明没被有意义地改过，用友好名
        if n.caseInsensitiveCompare(model) == .orderedSame { return base }
        if n.caseInsensitiveCompare(provider) == .orderedSame { return base }
        if n.caseInsensitiveCompare(base) == .orderedSame { return base }
        return n
    }

    /// 接口地址的主机名部分（只用于列表里的一行小字，方便区分「同一个模型名的两个环境」）。
    /// 解析失败就返回空，调用方据此不显示这一行——宁可没有，也不显示一串看不懂的东西。
    var endpointHost: String? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var s = raw
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        guard let u = URL(string: s), let h = u.host, !h.isEmpty else { return nil }
        if let port = u.port { return "\(h):\(port)" }
        return h
    }

    /// v4.4.17：Base URL 规范化——OpenAI 格式端点 (Chat/Responses) 自动补 /v1，
    /// 用户已填 v1/含版本路径(如 /api/paas/v4、/compatible-mode/v1) 则不重复补。
    /// Anthropic(/anthropic) 与自定义端点不自动补。
    static func normalizeBaseURL(_ base: String) -> String {
        // 2026-11-02 通用接口：用户已填完整端点（…/chat/completions 等）→ 一律不动
        if hasExplicitEndpoint(base) { return base }
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed) else { return base }
        let path = url.path
        // 纯主机级 (path 空 或 "/") → 补 /v1；已含路径段则尊重用户
        if path.isEmpty || path == "/" {
            return trimmed + "/v1"
        }
        return base
    }

    // MARK: - 2026-11-02 通用接口解析（不强制 /v1 结尾，也允许直接填完整端点）

    /// 已知的协议端点后缀。用户 baseURL 以这些结尾时视为「完整端点」，原样使用不再拼接。
    static let knownEndpointSuffixes = ["/chat/completions", "/completions", "/responses", "/messages"]

    /// 归一化用于判定的字符串：去空白、去末尾斜杠、转小写。
    /// 用户手打时经常多一个尾部 "/"（…/chat/completions/），不处理会被判成「非完整端点」
    /// 再被二次拼接成 …/chat/completions/chat/completions。
    private static func endpointKey(_ base: String) -> String {
        base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    /// baseURL 是否已是完整端点（决定了「拼接」还是「原样用」）
    static func hasExplicitEndpoint(_ base: String) -> Bool {
        let key = endpointKey(base)
        guard !key.isEmpty else { return false }
        if knownEndpointSuffixes.contains(where: { key.hasSuffix($0) }) { return true }
        if key.contains(":generatecontent") { return true }        // Gemini 原生
        return false
    }

    /// 从完整端点反推协议——用户既然填了 /responses，就按 Responses 发，不再按下拉框猜。
    /// 返回 nil 表示「看不出来」，尊重用户当前选择。
    static func impliedProtocol(from base: String) -> String? {
        let key = endpointKey(base)
        guard hasExplicitEndpoint(key) else { return nil }
        if key.hasSuffix("/chat/completions") || key.hasSuffix("/completions") { return "OpenAI Chat Completions" }
        if key.hasSuffix("/responses") { return "OpenAI Responses" }
        if key.hasSuffix("/messages") { return "Anthropic Messages" }
        if key.contains(":generatecontent") { return "Gemini" }
        return nil
    }

    /// 剥掉端点后缀，得到「接口基址」——用于拼 /models、或在协议变更后重拼端点。
    static func endpointBase(_ base: String) -> String {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !s.isEmpty else { return s }
        let low = s.lowercased()
        for suf in knownEndpointSuffixes where low.hasSuffix(suf) {
            s = String(s.dropLast(suf.count))
            break
        }
        // Gemini 原生：…/v1beta/models/gemini-2.5-pro:generateContent → …/v1beta
        if s.lowercased().contains(":generatecontent"),
           let r = s.range(of: "/models/", options: .backwards) {
            s = String(s[..<r.lowerBound])
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 解析最终请求 URL——三种写法全部兼容：
    ///   http://host:8080                          → …/v1/chat/completions（纯主机补 /v1）
    ///   http://host:8080/v1 或 …/api/v3           → 直接拼协议端点（尊重自定义前缀）
    ///   http://host:8080/v1/chat/completions      → 原样使用，不再二次拼接
    /// 注意：Gemini 原生端点含模型名（/models/{model}:generateContent），由 performGemini 自行构造，
    /// 这里只服务于「测试连接/内部轻调用」这类通用路径（Gemini 走默认 chat/completions 探测，与改前一致）。
    static func resolveEndpoint(_ base: String, apiProtocol: String) -> String {
        let raw = base.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空串 → 返回空，由调用方 URL(string:) 判失败（避免拼出 "v1/chat/completions" 这种脏串）
        guard !raw.isEmpty else { return "" }
        // 1) 已含完整端点 → 原样用（顺手去掉用户多打的尾部斜杠）
        if hasExplicitEndpoint(raw) {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        // 2) 未含 → 先按老规则补 /v1（纯主机），再拼协议端点
        let b = normalizeBaseURL(raw).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch apiProtocol {
        case "Anthropic Messages":      return b + "/messages"
        case "OpenAI Responses":        return b + "/responses"
        default:                        return b + "/chat/completions"
        }
    }

    /// 拉模型列表用的 URL——自动剥掉端点后缀再拼 /models
    static func modelsEndpoint(_ base: String) -> String {
        let stripped = endpointBase(base)
        guard !stripped.isEmpty else { return "" }
        let trimmed = stripped.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed) else { return trimmed + "/models" }
        let path = url.path
        if path.isEmpty || path == "/" { return trimmed + "/v1/models" }   // 纯主机 → /v1/models
        return trimmed + "/models"
    }

    /// 推理系列模型 (GPT-5.x / o1 / o3 / o4）不接受 temperature 参数，
    /// 中转站会返回 "Invalid request parameter"。
    var sendsTemperature: Bool { !isReasoningModel && !model.lowercased().contains("reasoning") }

    /// v7.1.290-fix：GPT 推理系统一识别——gpt-N (N≥5) 及其全部命名变体走 Responses + 推理。
    /// 兼容 gpt-5 / gpt-5-pro / gpt-5.6-terra / gpt-6 / gpt-6-sol / gpt-6.1-terra / openai/gpt-5-pro。
    /// 修复：硬编码前缀 "gpt-6."(带点) vs "gpt-6"(不带点) 不一致——gpt-6-sol 等连字符命名被误判为
    /// Chat Completions；且前缀表每次出新模型(gpt-7...)都要加、易漏。改为按版本号 ≥5 判定，一次覆盖全部。
    static func isGPTReasoning(_ model: String) -> Bool {
        let m = model.lowercased()
        guard let r = m.range(of: "gpt-") else { return false }
        var numStr = ""
        for ch in m[r.upperBound...] {
            if ch.isNumber { numStr.append(ch) } else { break }
        }
        guard let ver = Int(numStr) else { return false }
        return ver >= 5
    }

    /// v2.8.5：是否推理系列模型 (GPT-5.x / GPT-6.x / o1 / o3 / o4）。
    /// 这类模型默认 reasoning_effort=medium，回复前会长时间思考 (聊天转圈半天的主因），
    /// 请求时显式携带 reasoning_effort=none 提速。
    var isReasoningModel: Bool {
        let m = model.lowercased()
        if Self.isGPTReasoning(m) { return true }
        let prefixes = ["o1", "o3", "o4", "o1-", "o3-", "o4-"]
        return prefixes.contains(where: { m.hasPrefix($0) }) || m.contains("reasoning")
    }

    /// 推理系列模型使用 max_completion_tokens 而非 max_tokens
    var maxTokensKey: String {
        let m = model.lowercased()
        if Self.isGPTReasoning(m) { return "max_completion_tokens" }
        let reasoningPrefixes = ["o1", "o3", "o4", "o1-", "o3-", "o4-"]
        if reasoningPrefixes.contains(where: { m.hasPrefix($0) }) { return "max_completion_tokens" }
        return "max_tokens"
    }

    /// v4.4.16：API 协议自动纠偏——用户配错协议(如把 deepseek 配成 OpenAI Responses)时，
    /// 请求前自动纠正到正确协议，无需用户手动调整(大部分用户不会去改配置)。
    /// 规则参考 Codex 端点分配：
    ///  - claude/anthropic → Anthropic Messages
    ///  - gpt-5.x / o1/o3/o4 (推理系列, Codex 走 responses) → OpenAI Responses
    ///  - deepseek → OpenAI Chat Completions (deepseek 在 chat/completions 就能用 tools, 走 responses 反而慢)
    ///  - Custom Endpoint 一律尊重用户, 不自动改
    static func autoCorrectProtocol(model: String, provider: String, current: String) -> String {
        let m = model.lowercased()
        let p = provider.lowercased()
        // 显式选的自定义端点尊重用户, 不自动纠正
        if current == "Custom Endpoint" { return current }
        // 2026-11-05 **家中的中转站必须先拦在前面**。
        //
        // 它是 OpenAI 兼容的聚合中转，模型清单里什么都有（deepseek / gpt-5 / claude 都可能出现）。
        // 而下面的自动纠正是按**模型名**猜协议的：
        //   · 用户选中转站里的 claude 模型 → 被纠成 Anthropic Messages
        //   · 选中转站里的 gpt-5 模型   → 被纠成 OpenAI Responses
        // 中转站只有 /v1/chat/completions 一个口子，纠过去必然 404/400。
        // 所以供应商是 relay 时钉死 Chat Completions，不让后面的规则改写。
        if p == "relay" || p.contains("中转") { return "OpenAI Chat Completions" }
        // Anthropic 模型
        if p.contains("anthropic") || m.hasPrefix("claude") || m.contains("claude") { return "Anthropic Messages" }
        // Gemini 模型（原生 generateContent 协议）
        if p.contains("google") || p.contains("gemini") || m.hasPrefix("gemini") || m.contains("gemini") { return "Gemini" }
        // OpenRouter（vendor/model 命名 + 专用 header）——仅限供应商匹配，避免误伤
        // 普通中转站的 vendor/model 命名模型
        if p.contains("openrouter") { return "OpenRouter" }
        // 推理系列 (Codex 同款 responses 端点)
        // v7.1.290-fix：GPT 推理系用版本号统一识别 (gpt-N, N≥5)——覆盖 gpt-5-pro / gpt-6-sol 等连字符命名
        let oPrefixes = ["o1", "o3", "o4", "o1-", "o3-", "o4-"]
        if Self.isGPTReasoning(m) || oPrefixes.contains(where: { m.hasPrefix($0) }) || m.contains("reasoning") { return "OpenAI Responses" }
        // v7.1.109-peers：智能匹配全覆盖——以下 OpenAI 兼容系一律 Chat Completions
        let chatPrefixes = [
            "deepseek", "grok-", "llama", "mixtral", "mistral", "codestral",
            "qwen", "glm", "chatglm", "kimi", "moonshot", "minimax",
            "step-", "doubao", "ernie", "hunyuan", "spark", "baichuan",
            "yi-", "internlm", "command", "phi-", "nemotron", "sensechat",
            "gpt-4", "gpt-4o", "gpt-4.1"
        ]
        if chatPrefixes.contains(where: { m.hasPrefix($0) }) { return "OpenAI Chat Completions" }
        let chatProviders = ["deepseek", "xai", "groq", "mistral", "ollama", "azure",
                             "moonshot", "kimi", "zhipu", "glm", "minimax", "stepfun",
                             "doubao", "ark", "baidu", "qwen", "aliyun", "volcengine",
                             "openai", "together", "fireworks", "novita", "siliconflow"]
        if chatProviders.contains(where: { p.contains($0) }) { return "OpenAI Chat Completions" }
        // 其余尊重当前
        return current
    }
}

final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published var configs: [ModelConfig] = []
    private let key = "trollmcp2.model_configs"    // v2.9.97：记住最近一次使用的模型，顶栏立即显示用户上次用的配置，不再回退到第一个 (旧 gpt4o）
    private let lastUsedKey = "trollmcp2.last_used_config_id"

    // v7.1.40：模型配置双写 App Group（group.com.ai.iosxcode）——HUD 是独立进程
    // （bundle ch.xxtou.hudapp），读 standardUserDefaults 只能拿到进程自己的域，拿不到
    // 主 App 写入的 model_configs → _askAI 兜底到 deepseek 但 apiKey 为空 → 401 静默无回复。
    // 两侧 entitlements 都含 application-groups，suite 通道可用；读优先 suite，回退 standard（兼容老版本）。
    // v7.1.47 修正：实测两侧都是 no-sandbox 进程——UserDefaults(suiteName:) 的 suite 文件
    // 落在各自 data 容器的 Library/Preferences/group.com.ai.iosxcode.plist（物理隔离，互不可见），
    // HUD 读 suite 一直是 cfgData=NO。改 App Group 容器【文件】通道。
    // v7.1.49 再修正：containerURLForSecurityApplicationGroupIdentifier 在 no-sandbox + no-container
    // 进程返回 nil/不可写（实测 sharedFile=NO，主 App 写入静默失败）——App Group 容器通道不可用。
    // 最终通道：绝对路径共享文件 /var/mobile/Documents/trollmcp2_model_configs.json
    // （主 App 有 absolute-path read-write "/" + no-sandbox 可写；HUD no-sandbox 可读，实证可写 tts_debug.log）。
    private var suitePrefs: UserDefaults? { UserDefaults(suiteName: "group.com.ai.iosxcode") }

    /// v7.1.49：绝对路径共享配置文件（App Group 容器不可用时的可靠通道）
    private var sharedConfigFileURL: URL? {
        URL(fileURLWithPath: "/var/mobile/Documents/trollmcp2_model_configs.json")
    }

    private struct SharedConfigPayload: Codable {
        var configs: [ModelConfig]
        var last_used_config_id: String?
    }

    /// v7.1.47/49：把当前配置同步到共享文件（HUD 独立进程可靠读取通道）
    /// v7.1.50：后台异步写——主线程同步磁盘 IO 会卡死 UI（用户实测 7.1.49：开关 HUD/关于页假死黑屏，
    /// 根因即 load/save/markUsed 每次同步写文件 + 关于页同步读大日志，主线程被 IO 阻塞）
    private func syncSharedConfigFile() {
        guard let url = sharedConfigFileURL else { return }
        let payload = SharedConfigPayload(configs: configs, last_used_config_id: lastUsedConfigId)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // v7.1.51：atomic（临时文件+rename）在 /var/mobile/Documents 可能被拒 → 直接写兜底
                try? data.write(to: url)
            }
        }
    }

    init() { load() }

    var lastUsedConfigId: String? {
        get { suitePrefs?.string(forKey: lastUsedKey) ?? UserDefaults.standard.string(forKey: lastUsedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: lastUsedKey)
            suitePrefs?.set(newValue, forKey: lastUsedKey)
            syncSharedConfigFile()   // v7.1.47：切换模型立即同步共享文件（HUD 下次语音即用新配置）
        }
    }

    func markUsed(_ id: String) {
        lastUsedConfigId = id
    }

    /// v7.1.107：模型组 fallback 链——主模型 + fallbackIDs 按序展开。
    /// credential gate（对齐 OpenMinis）：过滤掉 apiKey 为空（未配凭据）的项，避免
    /// 空凭据配置抢跑导致 401 空转；去重防循环；链长上限 8 防极端配置。
    func fallbackChain(from config: ModelConfig) -> [ModelConfig] {
        var ids = [config.id]
        ids.append(contentsOf: config.fallbackIDs)
        var seen: Set<UUID> = []
        var chain: [ModelConfig] = []
        for id in ids {
            guard seen.count < 8 else { break }
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            guard let c = configs.first(where: { $0.id == id }) else { continue }
            if c.apiKey.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            chain.append(c)
        }
        return chain
    }

    func load() {
        let suite = suitePrefs
        let std = UserDefaults.standard
        let suiteData = suite?.data(forKey: key)
        // suite 主数据（HUD 同源）优先；缺失时回退 standard（老版本主 App 写入）
        let data = suiteData ?? std.data(forKey: key)
        if let d = data, let decoded = try? JSONDecoder().decode([ModelConfig].self, from: d) {
            configs = decoded
            // v7.1.43：老用户升级场景——数据此前只在 standard 域（主 App 进程级），App Group 域是空的，
            // HUD 独立进程读 suite 读不到（要等下次改配置 save 才双写）→ HUD 长按语音无回复。
            // 启动时一次性把 standard 数据补写进 suite（幂等；后续 save() 继续双写）。
            if suiteData == nil { suite?.set(d, forKey: key) }
            migrateLegacyPrefs(suite: suite, std: std)
            syncSharedConfigFile()   // v7.1.47：启动即同步共享文件（老用户升级后 HUD 立即可用，不等下次 save）
            return
        }
        // v2.9.107：主数据损坏时从备份restored (最多试 4 份）——suite 优先，standard 兜底
        for i in 0...3 {
            let bak = suite?.data(forKey: "\(key).bak.\(i)") ?? std.data(forKey: "\(key).bak.\(i)")
            if let bak, let decoded = try? JSONDecoder().decode([ModelConfig].self, from: bak) {
                configs = decoded
                if suiteData == nil { suite?.set(bak, forKey: key) }
                migrateLegacyPrefs(suite: suite, std: std)
                syncSharedConfigFile()
                break
            }
        }
    }

    /// v7.1.43：老配置迁移——standard 域有而 suite 域无的 lastUsedConfigId 一次性补写（HUD 读 suite 侧）
    private func migrateLegacyPrefs(suite: UserDefaults?, std: UserDefaults) {
        if suite?.string(forKey: lastUsedKey) == nil, let oldId = std.string(forKey: lastUsedKey) {
            suite?.set(oldId, forKey: lastUsedKey)
        }
    }

    /// v2.9.107：原子写前备份轮换 (保留最近 4 份）——备份域与 save 写入域一致（suite）
    private func rotateBackup() {
        let suite = suitePrefs
        let std = UserDefaults.standard
        guard let current = suite?.data(forKey: key) ?? std.data(forKey: key) else { return }
        for i in stride(from: 2, through: 0, by: -1) {
            let old = suite?.data(forKey: "\(key).bak.\(i)") ?? std.data(forKey: "\(key).bak.\(i)")
            if let old { suite?.set(old, forKey: "\(key).bak.\(i + 1)") }
        }
        suite?.set(current, forKey: "\(key).bak.0")
    }

    func save() {
        if let data = try? JSONEncoder().encode(configs) {
            rotateBackup()
            UserDefaults.standard.set(data, forKey: key)
            suitePrefs?.set(data, forKey: key)   // v7.1.40：双写 App Group 供 HUD 独立进程读取
            syncSharedConfigFile()               // v7.1.47：同步 App Group 容器文件（HUD 可靠通道）
        }
    }

    // MARK: v2.9.107 —— 熔断器注册表 (运行时，不持久化；对齐 cc-switch circuit_breaker）

    private(set) var breakers: [UUID: CircuitBreaker] = [:]
    // v2.9.150：熔断器字典锁——ModelRow 渲染(主线程)与 AI 请求回调(后台线程)
    // 并发调 breaker(for:) 写同一字典 → 字典并发修改 SIGSEGV ("模型 API 页闪退"根因）
    private let breakerLock = NSLock()

    func breaker(for id: UUID) -> CircuitBreaker {
        breakerLock.lock()
        defer { breakerLock.unlock() }
        if let b = breakers[id] { return b }
        let b = CircuitBreaker(name: configs.first { $0.id == id }?.name ?? "model")
        breakers[id] = b
        return b
    }

    // MARK: v2.9.107 —— 配置导入 / 导出 (对齐 cc-switch import/export）

    func exportJSON() -> String {
        var items: [Any] = []
        for c in configs {
            if let d = try? JSONEncoder().encode(c),
               let obj = try? JSONSerialization.jsonObject(with: d) {
                items.append(obj)
            }
        }
        let payload: [String: Any] = [
            "app": "All-in-One AI Assistant", "type": "model_configs", "version": 1,
            "exportedAt": Int(Date().timeIntervalSince1970),
            "configs": items
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return ""
    }

    @discardableResult
    func importJSON(_ text: String) -> (ok: Int, failed: Int) {
        guard let data = text.data(using: .utf8) else { return (0, 0) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["configs"] as? [[String: Any]] {
            var ok = 0, failed = 0
            for item in arr {
                if let d = try? JSONSerialization.data(withJSONObject: item),
                   let c = try? JSONDecoder().decode(ModelConfig.self, from: d) {
                    add(c); ok += 1
                } else { failed += 1 }
            }
            return (ok, failed)
        }
        // 兼容纯数组
        if let arr = try? JSONDecoder().decode([ModelConfig].self, from: data) {
            for c in arr { add(c) }
            return (arr.count, 0)
        }
        return (0, 0)
    }

    var defaultConfig: ModelConfig? {
        if let d = configs.first(where: { $0.isDefault }) { return d }
        // v2.9.97：其次取最近使用，最后回退第一个
        if let last = lastUsedConfigId, let m = configs.first(where: { $0.id.uuidString == last }) {
            return m
        }
        return configs.first
    }

    func add(_ config: ModelConfig) {
        var c = config
        if c.isDefault {
            for i in configs.indices { configs[i].isDefault = false }
        }
        if configs.isEmpty { c.isDefault = true }
        configs.append(c)
        save()
    }

    /// v2.9.126：深链导入专用——同 baseURL+model 去重 (重复导入不再堆积配置）
    func importFromDeepLink(_ config: ModelConfig) -> Bool {
        let dup = configs.contains { $0.baseURL == config.baseURL && $0.model == config.model }
        guard !dup else { return false }
        add(config)
        markUsed(config.id.uuidString)
        return true
    }

    func update(_ config: ModelConfig) {
        if config.isDefault {
            for i in configs.indices { configs[i].isDefault = (configs[i].id == config.id) }
        }
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        configs.remove(atOffsets: offsets)
        if !configs.contains(where: { $0.isDefault }) && !configs.isEmpty {
            configs[0].isDefault = true
        }
        save()
    }
}

// MARK: - 模型列表获取与连接测试

enum ModelListResult {
    case success([String])
    case failure(String)
}

final class ModelAPIClient {
    static let shared = ModelAPIClient()

    func fetchModelList(config: ModelConfig, completion: @escaping (ModelListResult) -> Void) {
        // 2026-11-02 通用接口：自动剥端点后缀 + 纯主机补 /v1，用户填什么形式都能拉列表
        // 2026-11-03：改用 effectiveBaseURL —— 在家/在外自动选接口，测试连接和真实请求走同一条
        let urlStr = ModelConfig.modelsEndpoint(config.effectiveBaseURL)
        guard let url = URL(string: urlStr) else {
            completion(.failure("Invalid Base URL"))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        applyAuth(config: config, to: &request)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error.localizedDescription))
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["data"] as? [[String: Any]] else {
                    let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
                    completion(.failure("parse failed: \(raw.prefix(200))"))
                    return
                }
                let ids = models.compactMap { $0["id"] as? String }.sorted()
                completion(.success(ids))
            }
        }.resume()
    }

    func testConnection(config: ModelConfig, completion: @escaping (Result<String, Error>) -> Void) {
        // 2026-11-02 通用接口：填完整端点则原样用；否则按协议拼接（纯主机自动补 /v1）
        // 协议以「端点能看出来的」为准——用户填 /responses 就按 Responses 发体
        let proto = ModelConfig.impliedProtocol(from: config.effectiveBaseURL) ?? config.apiProtocol
        let urlStr = ModelConfig.resolveEndpoint(config.effectiveBaseURL, apiProtocol: proto)
        guard let url = URL(string: urlStr) else {
            completion(.failure(NSError(domain: "ModelAPIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        // v2.8.4：测试连接使用最小载荷 (仅 model + messages）。
        // 旧版发送 max_completion_tokens=8，推理模型 (gpt-5.x 默认 medium 推理）
        // 的推理 token 预算远超 8，会直接报参数错误，导致误判为连接failed。
        let body: [String: Any]
        if proto == "Anthropic Messages" {
            // Anthropic 协议要求必须传 max_tokens
            body = [
                "model": config.effectiveModel,
                "max_tokens": 64,
                "messages": [["role": "user", "content": "hi"]]
            ]
        } else if proto == "OpenAI Responses" {
            body = [
                "model": config.effectiveModel,
                "input": [["role": "user", "content": "hi"]]
            ]
        } else {
            body = [
                "model": config.effectiveModel,
                "messages": [["role": "user", "content": "hi"]]
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                if let http = response as? HTTPURLResponse {
                    if (200...299).contains(http.statusCode) {
                        completion(.success("Connection OK (HTTP \(http.statusCode))"))
                    } else {
                        let raw = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        completion(.failure(NSError(domain: "ModelAPIClient", code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw.prefix(200))"])))
                    }
                } else {
                    completion(.success("Response received"))
                }
            }
        }.resume()
    }


    // v2.9.100：通用轻量 chat 调用 (AI 分析引擎等内部工具用）。
    // 按 apiProtocol 自动选端点 (chat/completions / responses / messages），不触发工具循环。
    func sendChat(config: ModelConfig, messages: [[String: Any]],
                  timeout: TimeInterval = 90,
                  completion: @escaping (Result<String, Error>) -> Void) {
        // 2026-11-02 通用接口：与 testConnection 同一套端点解析
        let proto = ModelConfig.impliedProtocol(from: config.effectiveBaseURL) ?? config.apiProtocol
        let urlStr = ModelConfig.resolveEndpoint(config.effectiveBaseURL, apiProtocol: proto)
        guard let url = URL(string: urlStr) else {
            completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        let body: [String: Any]
        if proto == "Anthropic Messages" {
            body = ["model": config.effectiveModel, "max_tokens": 4096, "messages": messages]
        } else if proto == "OpenAI Responses" {
            var msgs: [[String: Any]] = []
            for m in messages {
                msgs.append([
                    "role": (m["role"] as? String) ?? "user",
                    "content": [[ "type": "input_text", "text": (m["content"] as? String) ?? "" ]]
                ])
            }
            body = ["model": config.effectiveModel, "input": msgs]
        } else {
            body = ["model": config.effectiveModel, "messages": messages, "temperature": 0.3]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                                userInfo: [NSLocalizedDescriptionKey: "no response data"])))
                    return
                }
                var text = ""
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let msg = first["message"] as? [String: Any],
                       let content = msg["content"] as? String {
                        text = content
                    } else if let output = json["output"] as? [[String: Any]] {
                        for item in output {
                            if let content = item["content"] as? [[String: Any]] {
                                for cc in content {
                                    if let t = cc["text"] as? String { text += t }
                                }
                            }
                        }
                    } else if let content = json["content"] as? [[String: Any]] {
                        for cc in content {
                            if let t = cc["text"] as? String { text += t }
                        }
                    }
                }
                if !text.isEmpty {
                    completion(.success(text))
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "(no data)"
                    completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                                userInfo: [NSLocalizedDescriptionKey: "parse failed: \(raw.prefix(200))"])))
                }
            }
        }.resume()
    }

    private func applyAuth(config: ModelConfig, to request: inout URLRequest) {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = config.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case "Bearer":
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case "API Key":
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case "None":
            break
        default:
            // 空/未知鉴权方式但填了 key 时，默认按 Bearer 发送 (兼容旧配置或 UI 异常）
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}

// MARK: - 聊天消息

struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var arguments: String
    /// v7.2.3-fix19：模型输出的 tool_title（5-10 字行为摘要，对齐 OpenMinis）——
    /// 工具卡主标题优先用它；旧消息无该字段时 fallback 工具名
    var toolTitle: String? = nil

    /// v7.2.3-fix19：从 arguments JSON 提取 tool_title（模型每次调用输出）
    static func extractTitle(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["tool_title"] as? String else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var role: String         // user / assistant / system / tool
    var content: String
    var timestamp: Date = Date()
    var isError: Bool = false
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var toolName: String?
    /// v7.2.3-fix19：模型输出的 tool_title——工具卡主标题优先用（fallback toolName）
    var toolTitle: String? = nil
    /// v3.1.26：工具调用参数摘要 (tool 消息专用），UI 里用特殊颜色显示
    var toolArgs: String? = nil
    /// v3.3.4：工具执行耗时（秒），UI 气泡显示 (如 0.3s）
    var toolDuration: Double? = nil
    /// v2.9.9：多模态附件。存 data URL (如 "data:image/jpeg;base64,..."）。
    /// 发送时若非空，OpenAIClient 把 content 序列化为多模态数组。
    var imageDataURLs: [String]? = nil
    /// v2.9.20：思考记录 (reasoning）。Responses API 返回的 reasoning 摘要，气泡内可展开。
    var thinking: String? = nil
    /// v7.1.109-peers：思考耗时（秒）——从首个思考 delta 到首个正文 delta，DeepSeek 式"已深度思考（用时 X 秒）"
    var thinkingSeconds: Double? = nil
    /// v2.9.127：执行轨迹 (对齐豆包工作任务/Codex turn 流）——AI 本次回复的
    /// 思考→工具调用→工具结果 全过程，随消息持久化，可展开回看。
    var trail: [TrailStep]? = nil
    /// v3.5.8：工具解说（模型写的"先解说后执行"正文）——Minis 式工具卡把它当步骤标题，
    /// 单独存在 tool 消息上，避免解说既出现在 assistant 气泡又出现在卡片里导致重复。
    var toolNarration: String? = nil
    /// v3.5.10：工具是否仍在执行中——true 表示这是一张"启动即上屏"的 running 步骤卡，
    /// 结果回来后置 false 并填内容。UI 据此在徽章处显示"执行中…/转圈"而非"✓完成/✗出错"。
    var isRunning: Bool = false

    var isTool: Bool { role == "tool" }
}

/// v2.9.127：执行轨迹单步 (思考/工具调用/工具结果/备注）
struct TrailStep: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: Kind
    var name: String
    var status: Status
    var detail: String
    var ts: Date = Date()

    enum Kind: String, Codable { case think, tool, result, note }
    enum Status: String, Codable { case running, success, failed }

    static func running(_ kind: Kind, _ name: String, detail: String = "") -> TrailStep {
        TrailStep(kind: kind, name: name, status: .running, detail: detail)
    }
    static func done(_ kind: Kind, _ name: String, detail: String = "", ok: Bool = true) -> TrailStep {
        TrailStep(kind: kind, name: name, status: ok ? .success : .failed, detail: detail)
    }
}

// MARK: - 单个会话

struct ChatConversation: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
}

// MARK: - 会话管理

final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()
    /// fix73j-P1：主会话任务判定纪律（英文，追加于稳定基础系统块）——
    /// 对齐大厂：无独立"长任务判定器"，判定即模型自判（≥2 步工具/依赖链/目标模糊 →
    /// 先输出短计划再调工具；平凡任务直接做）。只影响工具模式，语音角色模式不注入。
    static let taskPlanningDiscipline = """
    TASK PLANNING: judge each user request once before acting. If it needs ≥2 tool calls, a dependency \
    chain, or an ambiguous goal — first state a short plain-text plan (numbered steps with the expected \
    tool for each) before calling tools, then execute step by step and revise the plan as evidence \
    changes. For trivial single-step requests, skip the plan and just answer or do it directly.
    """

    @Published var conversations: [ChatConversation] = []
    @Published var selectedId: UUID?
    @Published var isLoading = false
    /// 2026-11-05：本轮结束时是否出过错——底部状态条据此决定收尾播报的语气
    /// （「✓ 完成」还是「⚠️ 已停止」）。由完成回调写入，新一轮开始时复位。
    /// 加 @Published 没问题：它只在一轮结束那一瞬翻一次，不是高频值。
    @Published var lastTurnHadError = false
    /// v2.8.5：当前请求的实时状态文案 (等待响应/降级重试中），展示在输入指示器旁
    @Published var statusText: String?
    /// v2.9.34：请求过程可视化——当前第几轮 (v4.3.71 起无轮次上限)
    @Published var requestRound = 0
    /// v4.3.71：0 = 无轮次上限（已移除 60 轮机制），UI 只显示"第 N 轮"
    @Published var requestRounds = 0
    /// v2.9.34：正在执行的工具名 (展示"正在执行工具 xxx…"）
    @Published var runningTool: String?
    /// v3.5.10：正在上屏的"工具启动即显示 running 步骤卡"的消息 id——
    /// 工具启动先 append 一张 isRunning=true 的占位卡（真实工具名+命令，机制保证每步可见，
    /// 不依赖模型解说），结果回来后在 handleDispatchResult 原地更新成完成/出错卡。
    /// v7.1.106：单槽改多槽（toolCallId → 消息 id）——真并行批会同时有多张 running 卡，
    /// 串行路径同样用此字典（每批一个 toolCallId 唯一），resolvePendingTool 按 callId 定位。
    var pendingToolMsgIDs: [String: UUID] = [:]
    // fix73j-p5b：callId → 占位卡所在会话（append 时锚定）——resolve 不依赖 activeConvIndex
    //（UI 会话切换会漂移，漂移时找不到占位卡 → 不落盘 → 重启误判失败，p3e 失效的候选根因）。
    private var pendingToolConvIDs: [String: UUID] = [:]

    /// fix73j-p5b：真机诊断日志（Documents/Workspace/store/diagnostic.log）——
    /// 记录 resolve 执行/找到与否/崩溃恢复改写，用户重开后导出日志即可定位落盘断点。
    private func diag(_ s: String) {
        let p = storeDir + "/diagnostic.log"
        let line = "[\(Date())] " + s + "\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: p)) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: p), options: .atomic)
        }
    }
    /// v2.9.127：执行轨迹 (实时）——当前请求的 思考→工具调用→工具结果 步骤流，
    /// 请求结束时随最后一条 assistant 消息持久化 (message.trail）。
    @Published var liveTrail: [TrailStep] = []

    // v3.0.3：保存当前请求的思考内容 (onThinking 流式累加），
    // toolCalls 时传到 tool 消息，前端在 toolBubble 顶部显示
    private var thinkBuffer: String = ""
    /// v7.1.109-peers：思考计时起点（首个 onThinking delta 时间），首个正文 delta 时结算 thinkingSeconds
    private var thinkingStartAt: Date? = nil

    // v2.9.87：网络恢复自动重试 ("切后台回来网络中断"补偿）——
    // 网络类错误且当前确认为断网时，等 AppLifecycleMonitor 广播 networkRestored 后自动重发一次。
    private var retryObserver: NSObjectProtocol?
    private var retriedNetworkOnce = false
    /// v2.9.13：当前正在进行的 OpenAIClient (支持取消）
    private var currentClient: OpenAIClient?
    /// v2.9.53：当前流式输出的消息 ID (逐字显示时跟踪，done后更新或清理）
    /// v3.4.5：改为 internal（ChatView 用它标记打字机效果的消息）
    var streamingMessageId: UUID?
    /// v3.4.9：本轮刚"生成完成"的 assistant 消息 ID（工具解说/整段到达的回复）。
    /// ChatView 用它给这些消息开打字机——它们 isStreaming=false 且内容在出现前已定好，
    /// 只能靠"本轮刚产出"这一信号触发逐字显示。请求整体结束后清空。
    var liveProducedID: UUID?
    /// v3.5.6：工具参数 schema 预校验——模型调工具但缺必填参数时，不执行，注入纠正消息重跑
    /// 一轮逼它补齐再调（对齐 harness "机制决定行为"，治"invalid params required 盲试"老毛病）。
    private var pendingParamCorrection: String? = nil
    /// v3.5.6：参数纠正连续次数——同一 tool 决策最多纠正 2 次仍缺参就放行执行，避免死循环。
    private var paramCorrectionCount = 0
    /// v4.3.25：空回复纠正——工具结果回来、模型最终却输出空文本时，注入"请给结论"纠正
    /// 重跑一轮，不再静默结束（用户实测"空结果会卡死，AI 不进行下一步，必须重新发消息"）。
    private var pendingEmptyReplyCorrection: String? = nil
    /// v4.3.25：空回复纠正连续次数——最多 2 次仍空就停止，避免无限重跑。
    private var emptyReplyCorrectionCount = 0
    /// 文本式工具调用自动纠正次数——模型把 DSML/XML 调用当正文打印时，
    /// 代码层直接反解成 ToolCall 执行。连续 8 次仍反复同样写法就停手（防死循环烧 token）。
    private var textualToolCallCorrections = 0
    /// 2026-11-05：上一次「文本式工具调用」的签名（工具名+参数）。
    ///
    /// 用来区分「真的卡死了」和「模型只是习惯用文本写调用」——
    /// 用户诊断报告 13:00:40～13:02:04 连着四轮，每轮都成功解析并真跑了工具
    /// （user.mcp_probe / tools.audit / skills_list / tool_describe…），
    /// 每次调用的内容都不一样、活儿在推进，可计数照样涨到 8 被整轮砍掉。
    /// 那是「这个模型不会发结构化 tool_calls」，不是「它卡住了」。
    ///
    /// 判据改成：**同样的调用重复出现才算卡死**。只要签名在变，就允许一直兜底下去，
    /// 不管兜了多少轮（模型本来就这脾气，兜底是我们的能力，不该被当成错误累计）。
    private var lastTextualCallSignature: String = ""
    /// 2026-11-06 **工具连续失败熔断**。
    ///
    /// 用户实测（原话「现在有二个出错了，但是他还没停止工作呢」）：
    /// 界面连出两张红色错误卡（`tool_describe` 传 `system`、`web.fetch` 超时），
    /// AI 却继续往下跑，越跑越偏 —— 因为 `processToolCalls` 里**根本没有失败计数**，
    /// 失败只是变成一条 error tool 消息回给模型，模型于是换个写法接着试。
    /// 已有的 `CircuitBreaker`（failureThreshold=4）只管**网络请求**，管不到工具调用。
    ///
    /// 设计（刻意保守，避免重演 1.0.34 那种「活儿在正常推进却被整轮砍掉」的误停）：
    ///   · 只在**同一个工具 + 同一份参数**上计数（签名相同才算一次「同样的失败」）；
    ///   · 换个工具 / 换个参数 / 成功一次 → 立刻清零。正常干活不受任何影响。
    ///   · 连续 3 次同样失败才停手，并且**明说卡在哪 + 建议下一步**，不静默停。
    private var lastFailedToolSignature: String = ""
    /// 同一个「工具名 + 参数」连续失败的次数（成功/换目标即清零）。
    private var consecutiveSameToolFailures = 0
    /// 最近一次失败的工具名 / 参数摘要 / 错误文本——熔断收尾时要用。
    /// 单独存而不是靠传参：并行批要等所有结果合并后才统一判断。
    private var lastFailedToolName: String = ""
    private var lastFailedToolArgs: String = ""
    private var lastFailedToolError: String = ""
    /// 本轮累计失败数（不分工具）——只用来在提示词里提醒模型「你已经错很多次了」，
    /// 不据此停手（停手只看上面的同签名连续失败）。
    private var toolFailuresThisTurn = 0
    /// v3.1.70：活动请求绑定的会话 ID——请求由哪个会话发起就写回哪个会话。
    /// 修复"请求进行中切换会话，AI 输出错位/写错会话" (用户实测：老会话未暂停，切换新会话后输出仍乱）。
    private var activeConvId: UUID?
    /// v4.5.8：永不清除的"发起请求的会话"锁定——activeConvId 会在停止/请求结束时清 nil，
    /// 若此刻流式仍在回调，activeConvIndex 兜底 selectedIndex 就会把 AI 输出写进切换后的会话 (用户实测)。
    /// requestSessionId 只在下一次 send() 时覆盖，不受停止/切换影响，保证流式始终写回发起会话。
    private var requestSessionId: UUID?
    /// v3.5.16：用户点了「停止」——设 true 后 runLoop 每轮开头检查，若已停止则不再继续递归
    /// (修复"点了暂停/停止还在继续发消息"：此前进度只取消当前 client，递归会新建 client 接着跑)。
    private(set) var stopRequested = false  // v4.3.77：工具批量循环需读（停止后跳出，不再装剩余包）

    private let key = "trollmcp2.conversations"

    // v7.4.0-sessionstore：中间修改标记（主线程独占——UI 事件线程）。
    // 尾部追加走增量路径；删除/编辑消息标记 dirty → save() 时整会话重写 JSONL（保序保真）。
    private var dirtySessions = Set<UUID>()
    // v7.4.0-fix71：会话异步加载中（加载完成前 UI 显示加载中、发送按钮禁用）
    @Published var isLoadingData = true
    // v7.4.0-fix73：当前在途请求上下文快照（切后台 handoff 用）——runLoop 每次发送前更新
    private var lastRequestContext: (messages: [ChatMessage], tools: [[String: Any]]?, config: ModelConfig)?
    // v7.4.0-fix73b-audit：后台代传发起时的会话 ID（consume 校验归属，防污染新会话）
    private var handoffConvId: UUID?

    init() {
        // v7.4.0-fix71：会话异步加载——loadAll 逐会话 JSONL 全量解码（含大图 base64）
        // 在 init 同步执行会阻塞主线程数百 ms~数秒 → 侧边栏列表延迟出现（"等一会儿才加载出来"）。
        // 后台解码，主线程 applyLoaded；isLoadingData 期间 UI 显示加载中并禁用发送。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            var decoded: [ChatConversation]?
            if !fm.fileExists(atPath: self.storeDir + "/.fallback_flag"),
               SessionStore.shared.hasData() {
                decoded = SessionStore.shared.loadAll()
            }
            if let d = decoded, !d.isEmpty {
                DispatchQueue.main.async {
                    // 2026-11-03 崩溃循环自救：
                    // 若本次是「安全模式」（连续闪退过），不自动打开上次会话。
                    // 因为上次的会话内容很可能就是崩溃源——自动打开它 = 再崩一次，
                    // 用户永远进不去。这里只放弃"自动选中"，不删任何数据：
                    // 会话列表照常显示，用户能自己点开、处理有问题的消息。
                    if CrashBreadcrumb.safeModeThisLaunch {
                        self.diag("SAFE-MODE: 跳过自动打开上次会话（连续启动失败）")
                        self.applyLoaded(d, autoSelect: false)
                    } else {
                        self.applyLoaded(d)
                    }
                    self.isLoadingData = false
                    CrashBreadcrumb.shared.markLaunchSucceeded()
                }
                return
            }
            DispatchQueue.main.async {
                self.diag("LOADED-LEGACY-JSON (JSONL 加载失败或 fallback_flag 存在)")
                self.loadLegacy()
                self.isLoadingData = false
                CrashBreadcrumb.shared.markLaunchSucceeded()
            }
        }
    }

    var selectedIndex: Int? {
        conversations.firstIndex { $0.id == selectedId }
    }

    /// v3.1.70：活动请求的会话 index (优先活动会话，兜底当前选中会话）
    ///
    /// 2026-11-05 **加一道「请求真的还在跑」的闸**：
    /// `requestSessionId` 永不清空的设计初衷是防流式回调写错会话，
    /// 但它同时意味着**只要不发新消息，它就永久停在旧会话**。
    /// 于是 `activeConvId ?? requestSessionId` 这个兜底在「请求已结束」时
    /// 依然返回旧会话 —— 用户在会话 2 里做事，写入/上下文却全落到会话 1。
    ///
    /// 修法：`requestSessionId` 只有在 `isLoading == true`（本轮确实在跑）时才参与兜底。
    /// 请求已结束 → 它只是个历史值，不该再影响归属判断。
    /// 流式回调的防错写另有 isRunning + 消息 id 精确匹配兜着，不依赖它。
    private var activeConvIndex: Int? {
        if isLoading, let id = activeConvId ?? requestSessionId,
           let i = conversations.firstIndex(where: { $0.id == id }) {
            return i
        }
        if let id = activeConvId, let i = conversations.firstIndex(where: { $0.id == id }) {
            return i
        }
        return selectedIndex
    }

    var currentMessages: [ChatMessage] {
        guard let idx = selectedIndex else { return [] }
        return conversations[idx].messages
    }

    var currentTitle: String {
        guard let idx = selectedIndex else { return "Conversation" }
        return conversations[idx].title
    }

    /// v4.5.8：当前选中会话是否正在请求——右下角"停止"按钮据此显示。
    /// 此前用全局 isLoading：请求中切到别的会话，新会话右下角也显示红色"停止"(该会话并无请求)，困惑。
    var selectedIsRequesting: Bool {
        isLoading && selectedIndex == activeConvIndex
    }

    func newConversation(title: String? = nil) {
        let conv = ChatConversation(title: title ?? L10n.t("i18n_1059"), createdAt: Date(), updatedAt: Date(), messages: [])
        conversations.insert(conv, at: 0)
        selectedId = conv.id
        // v2.9.22：新会话清空工具会话授权 (AI 需重新搜索/决定）
        ToolRegistry.shared.clearSessionApproval()
        // v6.0.28：新会话清空TTS队列，不要读上一段的内容
        TTSService.shared.stop()
        save()
    }

    func select(_ id: UUID) {
        // v2.9.12：打开会话即视为"最近使用"，刷新 updatedAt 并重排到最前
        let switching = selectedId != id
        if switching, let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].updatedAt = Date()
        }
        selectedId = id
        // fix73k-P3（A）：真正切换会话时清空工具会话状态（approved+unloaded）——
        // 每会话工具集独立（describe/卸载不跨会话污染），KV 前缀各自稳定；
        // 切回原会话需重新 describe，但模型记忆仍可调（dispatch isEnabled 放行）。
        if switching { ToolRegistry.shared.clearSessionApproval() }
        // v6.0.28：切换会话清空TTS队列，不要读上一段的内容
        TTSService.shared.stop()
        sortAndSave()
    }

    /// v3.1.70：写入活动请求的会话 (无活动请求时写入当前选中会话）
    /// v7.1.267-fix：返回 Bool——渲染确认（完成音播放条件）；guard 失败打日志（可观测的静默失败）。
    @discardableResult
    func appendToCurrent(_ message: ChatMessage) -> Bool {
        guard let idx = activeConvIndex else {
            diag("APPEND-FAIL: activeConvIndex nil — message \(message.role) not appended (session switched?)")
            // v7.1.267-audit：失败写 NetworkLog——"看不到的根本测不出来"，用户在
            // 网络兼容日志页可直接截图反馈（diag 只进控制台，用户不可见）
            NetworkLog.shared.log("[render] APPEND-FAIL activeConvIndex nil — \(message.role) not appended (session switched?)")
            return false
        }
        var conv = conversations[idx]
        if conv.messages.isEmpty {
            conv.title = title(from: message.content)
        }
        conv.messages.append(message)
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
        return true
    }

    /// fix73j：当前会话上下文 id（子代理派发时记录，完成回传写回该会话——
    /// appendToCurrent 的 activeConvIndex 会随用户切换会话漂移，后台完成的子代理
    /// 回传可能写错会话，跨会话污染）。
    func currentSessionID() -> UUID? {
        if let id = activeConvId ?? requestSessionId { return id }
        return selectedId
    }

    /// fix73j：按会话 id 追加消息（子代理状态卡/回传用）。
    /// generateTitle=false 时状态卡不触发会话标题生成（否则新会话首条是
    /// "[SUBAGENT-RUNNING]..." 会把标题污染成 JSON）。
    func appendToSession(id: UUID, message: ChatMessage, generateTitle: Bool = true) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conv = conversations[idx]
        if generateTitle, conv.messages.isEmpty {
            conv.title = title(from: message.content)
        }
        conv.messages.append(message)
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
    }

    /// v3.1.70：更新活动请求会话内消息内容 (无活动请求时用当前选中会话）
    /// v7.1.267-fix：返回 Bool——渲染确认（完成音播放条件；UPDATE-FAIL 静默失败时不再误播"完成"音）。
    @discardableResult
    func updateMessageContent(id: UUID, content: String) -> Bool {
        // fix73j-p5：走统一变更入口——自动标 dirty + 同步落盘（编辑属数据安全关键点，
        // 异步 save 杀后台会丢编辑内容）。
        guard let idx = activeConvIndex else {
            diag("UPDATE-FAIL: activeConvIndex nil — content not applied (session switched?)")
            // v7.1.267-audit：失败写 NetworkLog——用户在网络兼容日志页可截图反馈
            NetworkLog.shared.log("[render] UPDATE-FAIL activeConvIndex nil — content not applied (session switched?)")
            return false
        }
        let ok = updateMessage(in: conversations[idx].id, msgId: id) { msg in
            msg.content = content
        }
        if ok { conversations[idx].updatedAt = Date() }
        return ok
    }

    /// fix73j-p5：统一消息变更入口（治本——解决"改消息忘了标 dirty/save"的隐性错误模式）。
    /// 任何对已有消息的修改都必须经此方法：内部自动标 dirtySessions + 同步 flush()，
    /// 保证 isRunning/content/error 等状态变更立即落盘（杀后台不丢、重启不误判）。
    /// 注意：实时流式更新（打字机增量，每秒多次）**不走此入口**——由 attachTrail 结束兜底，
    /// 避免高频同步写盘卡顿；此处只服务低频、语义完整的状态变更。
    @discardableResult
    func updateMessage(in convId: UUID, msgId: UUID, _ transform: (inout ChatMessage) -> Void) -> Bool {
        guard let ci = conversations.firstIndex(where: { $0.id == convId }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == msgId }) else {
            diag("UPDATE-FAIL: conv=\(convId.uuidString) msg=\(msgId.uuidString) not found")
            return false
        }
        transform(&conversations[ci].messages[mi])
        diag("UPDATE: conv=\(convId.uuidString) msg=\(msgId.uuidString) isRunning=\(conversations[ci].messages[mi].isRunning) contentLen=\(conversations[ci].messages[mi].content.count)")
        dirtySessions.insert(convId)
        flush()
        return true
    }

    /// 2026-11-02：撤回某条用户消息——删除该条及其之后的全部消息，返回被撤回的原文（供回填输入框）。
    /// 关键约束（用户明确要求）：撤回**不触发任何重新生成**，仅做删除 + 回填，
    /// 必须等用户下一条指令才会再次请求模型。若撤回时仍有请求在跑，先 cancelCurrent() 强停，
    /// 避免流式回调把内容写回已删除的消息。
    @discardableResult
    func withdrawMessage(id: UUID) -> String? {
        // ⚠️ 必须用 selectedIndex（用户当前看的会话），不能用 activeConvIndex——
        // 后者指向"上次发起请求的会话"且 requestSessionId 不清空，用户切换会话后
        // 它仍停在旧会话，拿它删消息会删错会话（而且是删到底，破坏性极大）。
        guard let idx = selectedIndex,
              let ci = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return nil }
        // 撤回即意味着不想再要这一轮的回复——先停掉在途请求
        if isLoading && requestSessionId == conversations[idx].id { cancelCurrent() }
        let convId = conversations[idx].id
        let text = conversations[idx].messages[ci].content
        // 连同该条之后的所有消息一起删除（工具卡/助手回复/后续问答都属这一轮下游）
        conversations[idx].messages.removeSubrange(ci..<conversations[idx].messages.count)
        conversations[idx].updatedAt = Date()
        // 整会话重写落盘（removeSubrange 属中间修改，不能走尾部追加增量）
        dirtySessions.insert(convId)
        flush()
        return text
    }

    /// v3.1.70：删除活动请求会话内的消息 (无活动请求时用当前选中会话）
    func removeMessage(id: UUID) {
        guard let idx = activeConvIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.remove(at: mi)
        // v7.4.0-sessionstore：中间修改 → dirty（save() 时整会话重写）
        if let i = activeConvIndex { dirtySessions.insert(conversations[i].id) }
    }

    /// v2.9.13：取消当前进行中的请求 (ChatView 停止按钮）
    func cancelCurrent() {
        stopRequested = true          // v3.5.16：设停止标志，runLoop 递归到下一轮即停
        // v4.3.77：立即中断正在跑的 Alpine 命令/安装（否则 apkAdd 会闷头跑到 240s 且占着串行锁）
        TrollRuntimeEngine.interruptCurrent()
        cancelNetworkRetry()
        currentClient?.cancel()
        currentClient = nil
        isLoading = false
        statusText = nil
        // v2.9.82：回收后台任务
        TaskNotify.shared.endBackground()
        // v3.1.70：停止——解除活动会话绑定
        activeConvId = nil
        // 2026-11-05 **这里必须连 requestSessionId 一起清**。
        //
        // 它的注释写着「只在下一次 send() 时覆盖，不受停止影响」——本意是防
        // 「停止时流式还在回调，写错会话」。但代价是：**停止之后到下一次 send 之间的
        // 任何读取都会拿到旧会话 id**，而 `activeConvIndex` / `messagesForAPI` /
        // `currentSessionID()` 全都是 `activeConvId ?? requestSessionId` 兜底。
        // 用户实测「第二个会话去干第一个会话的活」正是这条路径：
        // 会话 1 停掉 → requestSessionId 还停在会话 1 → 在会话 2 里做任何事，
        // 兜底全部落到会话 1 上。
        //
        // 停止的语义是「这一轮不要了」，不是「继续绑着旧会话」。
        // 流式回调的错写问题由 isRunning / 消息 id 精确匹配来防，不靠一个陈旧的会话 id。
        requestSessionId = nil
    }

    /// 2026-11-03 新增：一轮请求「非正常收尾」时的统一复位。
    ///
    /// 为什么放在类内部而不是 ChatDiagnostics.swift 里：
    /// `currentClient` / `thinkBuffer` / `activeConvId` 等都是 `private`，
    /// 外部扩展访问不到。放在这里才合法。
    ///
    /// 为什么需要它：以前每个提前 `return` 的收尾分支都要自己抄一遍复位代码，
    /// 抄漏一个就会出现「停止了但按钮还在转」或「下一轮串到上一轮」。
    /// 现在统一走这里，只写一份。
    func finishTurnInternal() {
        isLoading = false
        statusText = nil
        requestRound = 0
        runningTool = nil
        currentClient?.cancel()
        currentClient = nil
        streamingMessageId = nil
        liveProducedID = nil
        thinkBuffer = ""
        thinkingStartAt = nil
        activeConvId = nil
        // 2026-11-05：本轮正式收尾 → 会话绑定彻底解除。
        // isLoading 已经变 false，activeConvIndex 的那道闸会拦住它；
        // 这里再清一次，让 messagesForAPI / currentSessionID 这些直接读它的地方
        // 也立刻回到「当前选中会话」，不留一个过期的旧值。
        requestSessionId = nil
        TaskNotify.shared.endBackground()
    }

    func clearCurrent() {
        guard let idx = selectedIndex else { return }
        var conv = conversations[idx]
        conv.messages.removeAll()
        conv.title = L10n.t("i18n_1059")
        conv.updatedAt = Date()
        conversations[idx] = conv
        // v7.4.0-sessionstore：清空 = 中间修改 → dirty（save() 时整会话重写为空）
        dirtySessions.insert(conv.id)
        sortAndSave()
    }

    /// v7.1.72：清空全部会话——设置→会话记录"清空"同时清掉聊天框侧边栏全部会话（同一数据源）
    func clearAll() {
        conversations.removeAll()
        selectedId = nil
        dirtySessions.removeAll()
        // v7.4.0-sessionstore：先排空保存队列再清双层——防异步旧快照把已删文件写回（竞态）
        saveQueue.sync {}
        SessionStore.shared.clearAll()
        // v6.0.28：清空会话同样停掉 TTS 队列，避免残留音频读旧内容
        TTSService.shared.stop()
    }

    func delete(at offsets: IndexSet) {
        let removedIDs = offsets.map { conversations[$0].id }
        conversations.remove(atOffsets: offsets)
        if selectedId != nil && !conversations.contains(where: { $0.id == selectedId }) {
            selectedId = conversations.first?.id
        }
        // v7.4.0-fix65：删除会话必须同步清双层（JSONL 文件 + 索引行），否则重启复活；
        // 先排空保存队列防旧快照把已删会话写回（与 clearAll 同款竞态）。
        saveQueue.sync {}
        for id in removedIDs {
            SessionStore.shared.removeConversation(id: id)
        }
        sortAndSave()
    }

    func send(_ text: String, using config: ModelConfig, imageDataURLs: [String]? = nil,
              reasoningLevel: Int = 0, smartSearch: Bool = true, personaPrompt: String? = nil) {
        // 2026-11-03：崩溃现场留痕——用户反馈「点发送就闪退」，闪退瞬间进程直接死，
        // 只有崩之前 fsync 落盘的面包屑能事后看出崩在哪一步。
        CrashBreadcrumb.shared.markTurn("发送", text: text)
        CrashBreadcrumb.shared.mark("模型:\(config.model) 地址:\(config.effectiveBaseURL)")
        // v7.4.0-fix73b：请求进行中用户发新消息 → 取消当前请求（-999 静默不弹错）再发新，
        // 根治并发请求导致的双流式 ID 竞争、结果丢失/错乱（用户实测"请求完成无结果"）
        if isLoading {
            cancelCurrent()
        }
        // v7.4.0-fix73b：用户主动发新消息 → 放弃后台代传等待（防旧 background 请求完成后
        // 结果写入/污染新会话；background session 也一并重建）
        BackgroundLLM.shared.cancelHandoff()
        // v7.4.0-fix73b：后台代传结果主动推送接线——App 前台或被系统唤醒完成时直接收，
        // 根治"回前台太早 → 结果无人消费 → 永久请求中"
        BackgroundLLM.shared.onResultAvailable = { [weak self] _ in
            self?.consumeBackgroundResult()
        }
        // v7.2.3：personaPrompt 非空 = 语音角色对话模式——系统提示词替换为角色人设，且不带任何工具调用

        // v2.9.97：记住最近使用的模型，顶栏/下次启动立即恢复
        ModelStore.shared.markUsed(config.id.uuidString)
        // v2.9.82：请求开始——首次要通知权限 + 开启后台任务延长
        TaskNotify.shared.requestPermissionIfNeeded()
        TaskNotify.shared.beginBackground()
        // v2.9.87：新一轮请求重置网络重试状态
        retriedNetworkOnce = false
        // v7.4.0-fix72：后台挂起重试标记同周期重置（每轮请求一次机会，防跨轮失效）
        retriedBackgroundOnce = false
        cancelNetworkRetry()
        // v3.1.70：请求绑定到发起时的会话——中途切换会话，输出仍写回该会话 (修复输出错位）
        activeConvId = selectedId
        requestSessionId = selectedId   // v4.5.8：永不清除的锁定兜底 (防 activeConvId 清 nil 后写错会话）
        // v3.4.9：新请求开始，清掉上一轮的"刚产出"标记（避免旧消息被重新打字）
        liveProducedID = nil
        // v3.5.16：新请求开始，清除上次的停止标志（让 runLoop 可继续）
        stopRequested = false
        // v3.5.6：重置工具参数预校验纠正状态
        paramCorrectionCount = 0
        pendingParamCorrection = nil
        // v4.3.25：重置空回复纠正状态（跨任务不残留）
        emptyReplyCorrectionCount = 0
        pendingEmptyReplyCorrection = nil
        // 2026-11-03：重置文本式工具调用自动纠正计数（新任务从零计，别被上轮计数拦住）
        textualToolCallCorrections = 0
        // 2026-11-06：重置工具失败熔断状态（新任务从零计）
        lastFailedToolSignature = ""
        consecutiveSameToolFailures = 0
        lastFailedToolName = ""
        lastFailedToolArgs = ""
        lastFailedToolError = ""
        toolFailuresThisTurn = 0
        var msg = ChatMessage(role: "user", content: text)
        if let imgs = imageDataURLs, !imgs.isEmpty {
            msg.imageDataURLs = imgs
        }
        appendToCurrent(msg)
        isLoading = true

        // v3.1.66：全量加载所有工具 (tool_search 已删除，不再渐进式披露）
        // fix73k-5：catalog 化——baseTools = 核心常驻 + 会话已授权（describe 过）工具；
        // 其余工具经"工具目录"（runLoop 内注入系统提示词）对模型可见，tool.describe 后注入。
        // 收益：请求变小 + 工具集会话内只增不减 → 前缀稳定 → KV 缓存命中率升。
        var baseTools: [[String: Any]]? = config.apiProtocol == "Anthropic Messages" ? nil : ToolRegistry.shared.catalogOpenAIToolSchema()
        // v7.2.3：语音角色模式不带工具（人设对话，无 schema 注入）
        if personaPrompt != nil {
            baseTools = nil
        }
        // v2.9.20：智能搜索开关真实生效——关闭时从工具集移除 web.search / knowledge.search / web.fetch
        if !smartSearch {
            let exclude = Set(["web.search", "knowledge.search", "web.fetch"])
            baseTools = baseTools?.filter { t in
                if let fn = t["function"] as? [String: Any], let n = fn["name"] as? String {
                    return !exclude.contains(n)
                }
                return true
            }
        }
        // v3.1.66：全量加载，disclosed 机制已不再新增工具 (tool_search 已删），
        // 保留仅为兼容会话内已授权工具 schema 的持久注入。
        let preDisclosed: [String] = personaPrompt == nil ? ToolRegistry.shared.approvedToolNames() : []
        runLoop(config: config, tools: baseTools, disclosed: preDisclosed, depth: 0, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
    }

    // MARK: - v2.9.87 网络恢复自动重试

    private func shouldRetryOnNetworkRestore(_ err: NSError) -> Bool {
        guard !retriedNetworkOnce, err.code != -999 else { return false }
        // 网络类错误码：断网/找不到主机/网络连接丢失/连接重置
        let networkCodes: Set<Int> = [-1009, -1003, -1005, -1004, -1001]
        let isNetworkError = err.domain == NSURLErrorDomain && networkCodes.contains(err.code)
        // 只对"当前确实断网"的情况等待重试 (确认不是中转站问题）
        return isNetworkError && !AppLifecycleMonitor.shared.isNetworkAvailable
    }

    private func scheduleRetryAfterNetworkRestore(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int, personaPrompt: String? = nil) {
        retriedNetworkOnce = true
        retryObserver = NotificationCenter.default.addObserver(
            forName: AppLifecycleMonitor.networkRestored,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let o = self.retryObserver {
                NotificationCenter.default.removeObserver(o)
                self.retryObserver = nil
            }
            self.statusText = L10n.t("status_network_restored")
            self.isLoading = true
            self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
        }
    }

    private func cancelNetworkRetry() {
        if let o = retryObserver {
            NotificationCenter.default.removeObserver(o)
            retryObserver = nil
        }
        cancelForegroundRetry()
    }

    // MARK: - v7.4.0-fix72 后台挂起自动重试

    /// 切后台被系统挂起导致的请求失败（非真断网）——回前台自动重试一次。
    /// 判定：失败时 App 仍在后台，或刚回前台（5s 窗口内）→ URLSession 后台挂起/恢复抖动，
    /// 不是网络故障，不应弹"网络连接已中断"错误气泡。
    private var retriedBackgroundOnce = false
    private var foregroundRetryObserver: NSObjectProtocol?

    private func isBackgroundSuspensionFailure() -> Bool {
        guard !retriedBackgroundOnce else { return false }
        if UIApplication.shared.applicationState != .active { return true }
        let sinceForeground = Date().timeIntervalSince(AppLifecycleMonitor.lastForegroundAt)
        return sinceForeground >= 0 && sinceForeground < 5
    }

    private func scheduleRetryOnForeground(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int, personaPrompt: String? = nil) {
        retriedBackgroundOnce = true
        // v7.4.0-fix73b：若失败时已在前台（或刚回前台 5s 内）→ willEnterForeground 事件已经发出，
        // 注册监听永远等不到下一次（用户实测"一直请求中"卡死根因）→ 直接立即重试一次
        let sinceForeground = Date().timeIntervalSince(AppLifecycleMonitor.lastForegroundAt)
        if UIApplication.shared.applicationState == .active || (sinceForeground >= 0 && sinceForeground < 5) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // fix73b-audit：排队期间用户已发新请求/停止 → 放弃本次自动重试，防双 runLoop 竞态
                if self.isLoading { return }
                self.statusText = L10n.t("status_foreground_restored")
                self.isLoading = true
                self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
            }
            return
        }
        // 仍确认在后台 → 注册监听等真正回前台
        foregroundRetryObserver = NotificationCenter.default.addObserver(
            forName: AppLifecycleMonitor.willEnterForeground,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let o = self.foregroundRetryObserver {
                NotificationCenter.default.removeObserver(o)
                self.foregroundRetryObserver = nil
            }
            self.statusText = L10n.t("status_foreground_restored")
            self.isLoading = true
            self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
        }
    }

    private func cancelForegroundRetry() {
        if let o = foregroundRetryObserver {
            NotificationCenter.default.removeObserver(o)
            foregroundRetryObserver = nil
        }
    }

    // MARK: - v7.4.0-fix73 后台非流式代传（BackgroundLLM）

    /// 切后台：在途流式请求转交 background session 系统代传。
    /// 成功接管 → cancel 原流式（-999 静默，不弹错误气泡）；不支持（协议/中转）→ 不动，靠 fix72 前台重试。
    func handoffActiveRequestToBackground() {
        guard isLoading, currentClient != nil,
              let ctx = lastRequestContext else { return }
        // v7.4.0-fix73c：只有流式请求才值得代传——cancel+非流式重发的参数形态真的变了
        // （stream:true → stream:false）。非流式请求（chat 路径）重发 = 同参数 = 纯 token 浪费
        // （OpenMinis 原则：retry only when the new shape actually changes the request）。
        // 注：不设"活跃检测"——本方法在 backgroundTask 窗口耗尽时刻被调（AppMain expirationHandler），
        // 此刻系统即将冻结，请求无论是否活跃都会死，代传保住剩余部分；窗口内原请求一直活着由系统传输。
        guard currentClient?.isStreamingInFlight == true else { return }
        guard BackgroundLLM.shared.handoff(messages: ctx.messages, tools: ctx.tools, config: ctx.config) else { return }
        handoffConvId = requestSessionId ?? activeConvId
        currentClient?.cancel()
        currentClient = nil
        statusText = L10n.t("status_handoff")
    }
    /// 回前台：收取后台代传结果并展示/继续执行。
    func consumeBackgroundResult() {
        guard let result = BackgroundLLM.shared.consumeResult() else { return }
        guard isLoading else { return }
        // v7.4.0-fix73e：竞态修复——若当前有活跃新请求（currentClient != nil，用户回前台后
        // 又发了新消息），旧后台代传结果必须丢弃：否则会在新请求流式期间整段插入旧结果，
        // 打字机被打断/结果错乱（用户实测"前台打字机效果没出现"的根因之一）。
        // 注意：纯回前台场景（handoff 后 currentClient 已置 nil）不受影响，正常消费。
        guard currentClient == nil else {
            NetworkLog.shared.log("background handoff result dropped — a new live request is in flight")
            return
        }
        // v7.4.0-fix73b-audit：会话归属校验——后台结果只写回发起会话。
        // 若期间用户发了新请求（requestSessionId 已更新）或切了会话，旧后台结果直接丢弃，
        // 防止污染新会话（cancelHandoff 异步竞态下旧任务仍可能完成回调）。
        if let h = handoffConvId, requestSessionId != h, activeConvId != h {
            return
        }
        if let err = result.error, !err.isEmpty {
            let errMsg = ChatMessage(role: "assistant", content: "⚠️ \(err)", isError: true)
            appendToCurrent(errMsg)
            isLoading = false
            currentClient = nil
            activeConvId = nil
            statusText = nil
            TaskNotify.shared.endBackground()
            return
        }
        if result.toolCalls.isEmpty {
            var msg = ChatMessage(role: "assistant", content: result.text)
            msg.thinking = result.thinking
            let appended = appendToCurrent(msg)
            TaskNotify.shared.endBackground()
            TaskNotify.shared.notifyIfBackground(title: "✅ AI replied", body: String(result.text.prefix(60)))
            // v7.4.0-fix73d：后台代传结果回前台 → 前台播放所选提示音
            // v7.1.267-fix：渲染确认（appendToCurrent 成功）且非空文本才播——否则"音响无结果"
            if appended && !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TaskNotify.shared.playCompletionSoundIfForeground()
            }
            isLoading = false
            currentClient = nil
            activeConvId = nil
            statusText = nil
            // v7.4.0-fix73c：后台代传一次性语义固化——结果已消费，后台状态已清空，
            // 下一轮 send() 走正常流式（用户发下一条消息即恢复流式）
            NetworkLog.shared.log("background handoff result consumed — next request returns to streaming")
            trailStep(.done(.note, "AI 回复完成（后台）", detail: String(result.text.prefix(80))))
            attachTrail(to: msg.id)
            return
        }
        // 后台请求返回工具调用 → 继续执行工具链（复用 runLoop 递归）
        guard let ctx = lastRequestContext else {
            let asst = ChatMessage(role: "assistant", content: result.text, toolCalls: result.toolCalls)
            appendToCurrent(asst)
            isLoading = false
            currentClient = nil
            activeConvId = nil
            statusText = nil
            return
        }
        let asst = ChatMessage(role: "assistant", content: result.text, toolCalls: result.toolCalls)
        appendToCurrent(asst)
        isLoading = false
        currentClient = nil
        processToolCalls(result.toolCalls, index: 0, toolMessages: [], newlyDisclosed: [],
                         config: ctx.config, tools: ctx.tools, disclosed: [], depth: 0,
                         reasoningLevel: 0, thinkText: result.text)
    }

    /// v2.9.127：新一轮请求开始——清空实时轨迹
    func beginTrail() {
        DispatchQueue.main.async {
            self.liveTrail = []
        }
    }

    /// v2.9.127：追加一条实时轨迹步骤
    func trailStep(_ step: TrailStep) {
        DispatchQueue.main.async {
            self.liveTrail.append(step)
        }
    }

    /// v2.9.127：把实时轨迹持久化到最后一条 assistant 消息 (AI 回复done后调用）
    /// thinking 非空时把"已思考"插到轨迹最前 (对齐豆包流程第一步）。
    /// 收尾：残留 running 步骤统一标OK/failed (消息报错则标failed）。
    func attachTrail(to messageId: UUID?, thinking: String? = nil) {
        guard let sid = messageId, !liveTrail.isEmpty else { return }
        DispatchQueue.main.async {
            if let idx = self.activeConvIndex,
               let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }) {
                var trail = self.liveTrail
                let isErr = self.conversations[idx].messages[mi].isError
                for i in 0..<trail.count where trail[i].status == .running {
                    var s = trail[i]
                    s.status = isErr ? .failed : .success
                    trail[i] = s
                }
                // 思考去重：实时流已产生 think 步骤则不重复插入
                if let th = thinking, !th.isEmpty, !trail.contains(where: { $0.kind == .think }) {
                    trail.insert(TrailStep.done(.think, "Thought", detail: String(th.prefix(300))), at: 0)
                }
                self.conversations[idx].messages[mi].trail = trail
                // v7.4.0-fix68：trail 变更 = 中间修改 → dirty（否则 count 不变、persist 不重写，轨迹不落盘）
                self.dirtySessions.insert(self.conversations[idx].id)
                // fix73j-p5：AI 回复完成是数据安全关键点——异步 save 杀后台会丢完成的回复文本/
                // 轨迹（工具结果已 resolve 落盘但文本回复可能丢）。改同步 flush 保完整。
                self.flush()
            }
        }
    }

    private func runLoop(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int = 0, personaPrompt: String? = nil) {
        // v3.5.16：用户点了「停止」——立即停，不再继续递归 (修复"停止后还在发消息")
        if stopRequested {
            isLoading = false
            statusText = nil
            requestRound = 0
            runningTool = nil
            currentClient?.cancel()
            currentClient = nil
            TaskNotify.shared.endBackground()
            activeConvId = nil
            self.liveTrail = []
            return
        }
        // v2.9.25：不再限制工具调用轮次 (用户可手动点「停止」）。
        // v4.3.71：移除 60 轮极端安全上限——长会话已由 LLM Compaction 控制上下文体积，
        // 不再需要轮次硬停（用户仍可随时点「停止」按钮中断；工具死循环仍由 _loop_hint 提示）。
        // v2.9.34：请求过程可视化
        DispatchQueue.main.async {
            self.requestRound = depth + 1
            self.requestRounds = 0   // v4.3.71：无轮次上限
            self.statusText = L10n.t("status_preparing")
            self.liveTrail = []   // v2.9.127：新一轮清空实时轨迹
        }

        // 动态合并：白名单 schema + 已披露工具的 schema (去重）
        // v2.9.175：tools 为 nil (Anthropic 协议）时也走空数组合并——Anthropic 通道
        // 现在同样能拿到 coreTools + 已披露工具的 schema (OpenAIClient 已支持转换）。
        var effectiveTools = tools ?? []
        if !disclosed.isEmpty {
            var existing = Set<String>()
            for t in effectiveTools {
                if let fn = t["function"] as? [String: Any], let n = fn["name"] as? String {
                    existing.insert(n)
                }
            }
            for name in disclosed {
                let apiName = name.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").inverted).joined(separator: "_")
                if existing.contains(apiName) { continue }
                if let schema = ToolRegistry.shared.openAISchema(for: name) {
                    effectiveTools.append(schema)
                    existing.insert(apiName)
                }
            }
        }

        let client = OpenAIClient(config)
        // v7.2.3-fix6：鉴权智能试探成功 → 持久化纠正（对齐 OpenMinis BYOK 智能匹配）
        client.onAuthCorrected = { [weak self] method in
            guard let self = self else { return }
            let cfg = config
            var corrected = cfg
            corrected.authMethod = method
            ModelStore.shared.update(corrected)
            self.statusText = L10n.t("status_auth_corrected", method)
        }
        client.currentReasoningLevel = reasoningLevel
        currentClient = client
        let prepared = messagesForAPI(budget: config.effectiveContextTokens)
        // v7.1.109-peers：硬停不适配 Agent 长任务（OpenMinis 是消费级对话可卡住，
        // 我们长任务/工具链会被硬停打断）——改为极限压缩后的非阻断提示：
        // 即便仍超窗也继续发送（API 兜底 + 用户可见错误），不再 return 卡住。
        let window = config.effectiveContextTokens
        if window > 0 {
            let finalTotal = prepared.messages.reduce(0) { $0 + Self.estimateTokens($1) }
            if finalTotal > window {
                self.statusText = "⚠️ 上下文已极限压缩仍接近窗口上限(≈\(finalTotal)/\(window))，已继续发送——若失败请新建会话"
            }
        }
        var history = prepared.messages
        // v2.9.138：模块化 system prompt 组装 (稳定前缀工程）——
        // 稳定块 (系统指令→开发者指令）在前、动态状态块 (设备/App/工作区/会话）在后，
        // 稳定前缀保持字节一致 → 官方 API 前缀缓存可直接matched (Anthropic/OpenAI）。
        // v7.2.3：语音角色模式用 persona 替换主系统提示词（角色人设 + 轻量环境 facts，无工具说明）
        if let persona = personaPrompt, !persona.isEmpty {
            history.insert(ChatMessage(role: "system", content: persona), at: 0)
        } else {
            // fix73j-P1：主会话任务判定纪律（英文）——大厂无独立"长任务判定器"，
            // 判定即模型自判：≥2 步工具/依赖链/目标模糊 → 先输出短计划再调工具；
            // 平凡任务直接做。追加在稳定基础块内，保持稳定前缀缓存语义。
            let base = SystemPrompts.shared.selected.content + "\n\n" + Self.taskPlanningDiscipline
            // fix73k-5：catalog 工具目录注入稳定前缀——全部已启用工具名+一句话用途；
            // 不在当前 schema 的工具标 [describe to load]，模型先 tool.describe 再调（动态注入）。
            // 目录保证"模型始终知道有什么工具"（不会找不到），非核心 schema 不常驻省 token。
            history.insert(ChatMessage(role: "system", content: base + "\n\nTOOL CATALOG (tools not in your schema are marked [describe to load] — call tool.describe to load them; to enumerate ALL registered tool names call tools.audit, it returns tool_names):\n" + ToolRegistry.shared.toolCatalogText()), at: 0)
            if let devInstr = DeveloperInstructionStore.shared.defaultInjectionContent(), !devInstr.isEmpty {
                history.insert(ChatMessage(role: "system", content: "Developer instructions below, always follow:\n" + devInstr), at: 0)
            }
        }
        // fix73k：KV 缓存前缀稳定（对齐 DeepSeek 硬盘缓存/GLM 上下文缓存/Kimi Context Caching/
        // GPT prompt caching 四家"开头逐字匹配"规则）——动态状态块（设备/App/工作区/当前会话
        // 标题/自动提取 hint，随会话内容变化）从 system 前缀移到请求末尾的 user 消息
        // （DSH user-role 快照追加：易变信息不进稳定前缀）——system 前缀（persona/devInstr/base）
        // 保持字节完全稳定 → 四家上游缓存都命中整段 system。旧实现 insert(at:0) 把动态块插在
        // system 序列中间、对话之前——标题/hint 一变即前缀失效。
        // fix73k-2：标注从"do not respond"改为"可引用"——实测原标注导致模型把 env 快照当
        // 背景勿扰，用户问设备/工作区时答"一半是"且不补查；现明确允许引用 + 缺细节可查 device.info。
        // 2026-11-05：传**请求所属会话**（requestSessionId ?? activeConvId），
        // 不是 selectedIndex —— 用户切窗口期间 selectedIndex 已经飘到别的会话，
        // 用它就会把「另一个会话的标题 + 另一个会话的上下文」塞进本次请求。
        history.append(ChatMessage(role: "user", content: Self.dynamicStatePrompt(sessionId: requestSessionId ?? activeConvId) + "\n(Environment snapshot — reference it to answer device/workspace/environment questions; query device.info for more detail if needed. Do not echo it unless asked.)"))
        // Tool-param prevalidation correction injection: missing required params blocked last round, append likewise.
        if let pcorr = self.pendingParamCorrection, !pcorr.isEmpty {
            history.append(ChatMessage(role: "user", content: pcorr))
            self.pendingParamCorrection = nil
        }
        // Empty-reply correction injection: if the model output blank after running tools last round, append this to force a conclusion.
        if let ecorr = self.pendingEmptyReplyCorrection, !ecorr.isEmpty {
            history.append(ChatMessage(role: "user", content: ecorr))
            self.pendingEmptyReplyCorrection = nil
        }

        // v7.4.0-fix73：记录在途请求上下文（切后台 handoff 用；含已组装 system 前缀与压缩结果）
        lastRequestContext = (history, effectiveTools, config)
        client.send(messages: history, compactSource: prepared.compactSource, tools: effectiveTools, onStatus: { status in
            DispatchQueue.main.async {
                // v2.9.34：带轮次前缀；v4.3.71 无上限 (requestRounds==0) 时不显示 "/0"
                if self.requestRound > 0 && !status.contains("Round ") {
                    if self.requestRounds > 0 {
                        self.statusText = L10n.t("status_requesting_model_rounds", self.requestRound, self.requestRounds) + " · " + status
                    } else {
                        self.statusText = L10n.t("status_requesting_model_round", self.requestRound) + " · " + status
                    }
                } else {
                    self.statusText = status
                }
            }
        }, onDelta: { delta in
            // v2.9.53：流式逐字显示
            DispatchQueue.main.async {
                if let sid = self.streamingMessageId {
                    // 追加到已有流式消息 (v3.1.70：按活动会话定位，切换会话不丢增量）
                    guard let idx = self.activeConvIndex,
                          let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }) else { return }
                    self.conversations[idx].messages[mi].content += delta
                } else {
                    // 第一次 delta：创建流式消息
                    var msg = ChatMessage(role: "assistant", content: delta)
                    // v7.1.109-peers：思考计时结算——首个正文 delta 到达，思考结束
                    if let st = self.thinkingStartAt {
                        msg.thinkingSeconds = Date().timeIntervalSince(st)
                        self.thinkingStartAt = nil
                    }
                    self.streamingMessageId = msg.id
                    self.liveProducedID = msg.id
                    self.appendToCurrent(msg)
                }
            }
        }, onThinking: { delta in
            // v3.5.4：思考只进黄泡(message.thinking) + thinkBuffer(供 toolCalls 装配)，
            // 不再写 liveTrail——否则实时轨迹卡也渲染思考，导致同一思考出现两次 (用户实测截图)。
            // 实时轨迹卡(liveTrail)只显示"工具执行步骤"：工具名/命令/结果，绝不显示思考文字。
            DispatchQueue.main.async {
                // v7.1.109-peers：思考计时——首个思考 delta 记起点
                if self.thinkingStartAt == nil { self.thinkingStartAt = Date() }
                self.thinkBuffer += delta
                // v3.5.4：思考实时写入流式消息的 thinking(黄色气泡)，随模型思考逐段填充、不打字机。
                // 若无流式消息(思考先于正文到达)，先建一条空 assistant 消息，把思考挂上去。
                if let sid = self.streamingMessageId {
                    if let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        let existing = self.conversations[ci].messages[mi].thinking ?? ""
                        self.conversations[ci].messages[mi].thinking = existing + delta
                    }
                } else {
                    // v3.5.16：防"思考重复两次"——.text 最终化(streamingMessageId=nil)后又来一段 onThinking 时，
                    // 会在这里再建一条空正文+思考消息，与上一条已含相同思考的 assistant 消息重复
                    // (顶部"已深度思考"+ 底部"思考中…"两遍)。新建前先查上一条是否已含这段思考，是则跳过。
                    var skipDup = false
                    if let ci = self.activeConvIndex, let li = self.conversations[ci].messages.indices.last {
                        let last = self.conversations[ci].messages[li]
                        if last.role == "assistant", let ex = last.thinking, !ex.isEmpty {
                            if ex == delta || ex.contains(delta) || delta.contains(ex) {
                                skipDup = true
                            }
                        }
                    }
                    if !skipDup {
                        var msg = ChatMessage(role: "assistant", content: "")
                        msg.thinking = delta
                        self.streamingMessageId = msg.id
                        self.liveProducedID = msg.id
                        self.appendToCurrent(msg)
                    }
                }
            }
        }, onCompacted: { summary in
            // v7.1.41：LLM Compaction 持久化——摘要写回会话历史（对齐 Claude Code /compact 的破坏性替换），
            // 下次请求不再重复压缩同一堆旧消息，而是增量合并
            // v7.1.267-audit：绑定压缩发起时会话（requestSessionId 快照）——回调异步，防切会话后删错会话
            DispatchQueue.main.async {
                self.applyCompaction(summary: summary, droppedCount: prepared.droppedCount,
                                     conversationID: self.requestSessionId ?? self.activeConvId ?? self.selectedId)
            }
        }) { result in
            DispatchQueue.main.async {
                self.statusText = nil
                switch result {
                case .success(.text(let text, let thinking)):
                    // 2026-11-03：崩溃现场留痕——用户反馈「回复完直接卡闪退」，
                    // 崩点就在这段收尾渲染里。记下正文长度，崩了能对上。
                    CrashBreadcrumb.shared.mark("收尾 正文:\(text.count)字 流式ID:\(self.streamingMessageId == nil ? "无" : "有")")
                    // 2026-11-05：本轮干净结束 → 底部状态条播「✓ 完成」
                    self.lastTurnHadError = false
                    self.isLoading = false
                    self.currentClient = nil
                    self.requestRound = 0
                    self.runningTool = nil
                    self.thinkBuffer = "" // 重置缓冲区
                    self.thinkingStartAt = nil // v7.1.109-peers：思考计时重置
                    // v2.9.138：自动会话记忆——一轮完整回复后落库 (供下会话 BM25 检索）
                    if let idx = self.activeConvIndex {
                        let msgs = self.conversations[idx].messages
                        let lastUser = msgs.last { $0.role == "user" }?.content ?? ""
                        let usedTools = msgs.compactMap { $0.toolName }
                        KnowledgeStore.shared.appendSessionMemory(
                            user: String(lastUser.prefix(80)),
                            reply: String(text.prefix(150)),
                            tools: Array(Set(usedTools)).sorted().suffix(8))
                    }
                    // v2.9.127：轨迹——回复done，附到消息持久化
                    self.trailStep(.done(.note, "AI 回复完成", detail: String(text.prefix(80))))
                    // v2.9.82：done通知 (后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "✅ AI replied", body: String(text.prefix(60)))
                    // v7.4.0-fix73d：任务完成提示音——v7.1.267-fix 移到渲染确认之后（见 1846 行），
                    // 渲染失败（UPDATE-FAIL/APPEND-FAIL）或空回复不再误播"完成"音（用户实测"音响无结果"根因）
                    var rendered = false
                    if let sid = self.streamingMessageId {
                        // 流式已显示，更新最终文本 + thinking
                        rendered = self.updateMessageContent(id: sid, content: text)
                        if rendered {
                            if let idx = self.activeConvIndex,
                               let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }),
                               let th = thinking, !th.isEmpty {
                                self.conversations[idx].messages[mi].thinking = th
                            }
                            self.attachTrail(to: sid, thinking: thinking)
                        } else {
                            // v7.1.267-fix：流式消息丢失兜底——UPDATE-FAIL（消息被清理/会话漂移/
                            // sid 生命周期错乱）时追加新消息，保证最终回答一定上屏（"音响无结果"根治——
                            // 结果不再因消息找不到而静默丢失）。
                            NetworkLog.shared.log("[render] UPDATE-FAIL — streaming message lost, appending fresh reply instead")
                            var am = ChatMessage(role: "assistant", content: text)
                            if let th = thinking, !th.isEmpty { am.thinking = th }
                            rendered = self.appendToCurrent(am)
                            self.attachTrail(to: am.id, thinking: thinking)
                        }
                        self.streamingMessageId = nil
                    } else {
                        // v3.5.16：修复"思考显示两次"——流式中 onThinking 可能已建了一条"空正文+思考"消息
                        // (思考先于正文到、且正文没进它），此时若直接 appendToCurrent 会再建第二条
                        // (顶部"已深度思考" + 底部"思考中"重复)。改为复用那条空思考消息填正文。
                        var reused = false
                        if let ci = self.activeConvIndex {
                            var msgs = self.conversations[ci].messages
                            if let li = msgs.indices.last,
                               msgs[li].role == "assistant",
                               msgs[li].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               msgs[li].thinking?.isEmpty == false {
                                // v7.1.267-audit：走统一变更入口（dirty+flush）——此前裸改不标 dirty，
                                // 杀后台瞬间丢最终回答（fix73j-p5 原则在此路径被绕过）
                                let mid = msgs[li].id
                                let ok = self.updateMessage(in: self.conversations[ci].id, msgId: mid) { m in
                                    m.content = text
                                    if let th = thinking, !th.isEmpty { m.thinking = th }
                                }
                                if ok {
                                    self.streamingMessageId = nil
                                    self.liveProducedID = nil
                                    self.attachTrail(to: mid, thinking: thinking)
                                    reused = true
                                }
                            }
                        }
                        if !reused {
                            var am = ChatMessage(role: "assistant", content: text)
                            if let th = thinking, !th.isEmpty { am.thinking = th }
                            rendered = self.appendToCurrent(am)
                            self.liveProducedID = am.id
                            self.attachTrail(to: am.id, thinking: thinking)
                        } else {
                            rendered = true
                        }
                    }
                    // v7.1.267-fix：完成音——渲染确认且非空文本才播（空回复走下方纠错机制，不响"完成"音；
                    // 渲染失败不打 误导 的完成音——声音 = "回答已上屏"的语义）
                    if rendered && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TaskNotify.shared.playCompletionSoundIfForeground()
                    }
                    // v4.3.25：空回复兜底——工具结果回来、模型最终却输出空文本时，
                    // 不再静默结束（用户实测"空结果会卡死，AI 不进行下一步，必须重新发消息"）。
                    // 若会话末尾是 tool 结果消息且本条回复为空白，注入纠正重跑一轮逼模型给结论；
                    // 最多 2 次仍空就停止，避免无限重跑。
                    let trimmedFinal = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    var lastMsgIsTool = false
                    if let ci = self.activeConvIndex {
                        if let last = self.conversations[ci].messages.last {
                            lastMsgIsTool = (last.role == "tool")
                        }
                    }
                    if trimmedFinal.isEmpty && lastMsgIsTool && self.emptyReplyCorrectionCount < 2 {
                        self.emptyReplyCorrectionCount += 1
                        self.pendingEmptyReplyCorrection = "You just ran tools but your reply body is empty. Based on the returned tool results, give the user a clear 1-2 sentence conclusion (or say what to do next) — don't reply blank or just 'Done'."
                        self.trailStep(.done(.note, "空回复已纠正", detail: "模型这轮没写正文，已自动补一轮让它给结论", ok: false))
                        // 清掉刚渲染的空 assistant 消息，避免界面残留空白气泡
                        if let sid = self.streamingMessageId {
                            self.removeMessage(id: sid)
                        } else if let ci = self.activeConvIndex {
                            var msgs = self.conversations[ci].messages
                            if let li = msgs.indices.last,
                               msgs[li].role == "assistant",
                               msgs[li].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                // v7.1.267-audit：走 removeMessage（标 dirty）——裸删不落盘重启残留空气泡
                                self.removeMessage(id: msgs[li].id)
                            }
                        }
                        self.streamingMessageId = nil
                        self.liveProducedID = nil
                        self.thinkBuffer = ""
                        self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth + 1, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
                        return
                    }
                    // 2026-11-03 静默停止修复（第 2 处）：
                    // 空回复纠错已经用满 2 次，模型还是不给正文 —— 以前这里直接往下走，
                    // 用户看到的就是「工具跑完了，然后什么都没有，也不说为什么」。
                    if trimmedFinal.isEmpty && lastMsgIsTool && self.emptyReplyCorrectionCount >= 2 {
                        self.emptyReplyCorrectionCount = 0
                        Self.reportStop(
                            to: self,
                            title: "AI 停下了：只跑了工具，没给结论",
                            body: """
                            模型把工具都执行完了，但连续两次都没写正文（只回了个空的）。\
                            这通常是模型端的问题，不是你的操作有误。

                            建议这样：直接回一句「把上面的结果总结一下」，或者换个模型再试。

                            工具的执行结果都在上面的卡片里，没有丢。
                            """,
                            reason: "空回复纠错达上限（2 次）")
                        return
                    }
                    self.emptyReplyCorrectionCount = 0
                    // 2026-11-03 核心修复（用户连续反馈「底部全是英文」「罢工，得再发继续」）：
                    //
                    // 模型把工具调用**当正文打印**（DSML 特殊 token 原样输出，截图形态为
                    // <｜｜DSML｜｜ calls><｜｜DSML｜｜ invoke name="shell.exec">…），
                    // 客户端只认结构化 tool_calls → 这段就成了「一屏英文」，工具根本没跑
                    // → 本轮结束 → 停工。光注入提示词纠正治不住（实测连续纠正照样这么写）。
                    //
                    // 现在：直接把这段文本**反解成 ToolCall 并执行**，模型用什么格式写都能
                    // 接着干下去，不需要用户再说「继续」。
                    let textualCalls = Self.parseTextualToolCalls(text)
                    // 防死循环：真正要防的是「模型反复吐同一个调用、活儿一点没推进」。
                    // 2026-11-05 改判据（用户诊断报告 13:00:40～13:02:04）：
                    //
                    // 旧判据是「兜底次数 < 8」，可它连一次都没判断过进展——
                    // 那四轮每轮的工具都真跑了、每次调用内容都不一样（mcp_probe → tools.audit →
                    // skills_list → tool_describe），活儿明明在往前走，
                    // 光因为「这个模型只会用文本写调用」就数到 8 直接砍掉整轮。
                    //
                    // 新判据：拿「工具名 + 参数」的签名去比上一轮。
                    //   · 签名变了 → 活儿在推进，无论兜多少轮都继续（兜底是我们的能力，不是错误）
                    //   · 签名一模一样 → 这是真的在原地打转：允许重复 3 次（stuckCount 1→3），
                    //     第 4 次（stuckCount 4 > 3）判定卡死并停手。
                    // 逐个落成带类型标注的常量再拼，别写成一行长链——
                    // 1.0.34 已经栽过一次「unable to type-check this expression in reasonable time」。
                    var sigParts: [String] = []
                    sigParts.reserveCapacity(textualCalls.count)
                    for c0 in textualCalls {
                        let n0: String = c0.name
                        let a0: String = c0.arguments
                        sigParts.append(n0 + "|" + a0)
                    }
                    let signature: String = sigParts.joined(separator: "&&")
                    let sameAsLast: Bool = !signature.isEmpty && signature == self.lastTextualCallSignature
                    let stuckCount: Int = sameAsLast ? (self.textualToolCallCorrections + 1) : 1
                    self.lastTextualCallSignature = signature

                    if !textualCalls.isEmpty && stuckCount <= 3 {
                        self.textualToolCallCorrections = stuckCount
                        self.trailStep(.done(.note, "自动解析文本形式的工具调用",
                                             detail: "模型把调用写成了正文，已解析出 \(textualCalls.count) 个并直接执行",
                                             ok: true))
                        // 把这段 XML 从可见正文里抹掉，换成正常的工具卡（避免再看到一屏英文）
                        let cleaned = Self.stripTextualToolCalls(text)
                        if let sid = self.streamingMessageId,
                           let ci = self.activeConvIndex,
                           ci < self.conversations.count {
                            _ = self.updateMessage(in: self.conversations[ci].id, msgId: sid) { m in
                                m.content = Self.stripTextualToolCalls(m.content)
                            }
                        }
                        // 纯 XML 时 strip 会给占位文案，别把它当解说塞进工具卡
                        let narration = cleaned.hasPrefix("（已自动执行") ? "" : cleaned
                        self.thinkBuffer = ""
                        // 走与结构化调用完全相同的执行链路
                        self.processToolCalls(textualCalls, index: 0, toolMessages: [],
                                              newlyDisclosed: [], config: config, tools: tools,
                                              disclosed: disclosed, depth: depth,
                                              reasoningLevel: reasoningLevel,
                                              thinkText: narration,
                                              personaPrompt: personaPrompt)
                        return
                    }
                    // 2026-11-03 静默停止修复（用户原话「不知道怎么就停止了，也没有原因」）。
                    // 2026-11-05：这里现在只在「确实原地打转」时才走到——
                    // 同一个调用连续重复 4 次，说明模型陷在循环里，再转只会烧 token。
                    if !textualCalls.isEmpty {
                        self.trailStep(.done(.note, "已停止自动重试",
                                             detail: "同一个工具调用连续重复 \(stuckCount) 次，没有进展",
                                             ok: false))
                        Self.reportStop(
                            to: self,
                            title: "AI 停下了：在重复同一个动作",
                            body: """
                            这个模型连续 \(stuckCount) 次发出**完全相同**的工具调用，\
                            每次结果都一样，活儿没有往前走，所以停在这里。

                            这种情况通常是：
                            1. 工具返回的内容它没看懂，于是又调了一遍（可以让它先总结再决定下一步）
                            2. 或者它想做的事本机做不到，一直在试同一个办法

                            建议直接说一句「别重复了，说说你卡在哪」，它会把卡点讲出来。
                            换个模型也行（DeepSeek、GLM-4、GPT 系列的结构化调用更稳）。

                            原始内容已保留在下面的气泡里，没有丢。
                            """,
                            reason: "同一工具调用连续重复 \(stuckCount) 次无进展")
                        self.textualToolCallCorrections = 0
                        self.lastTextualCallSignature = ""
                        self.activeConvId = nil
                        return
                    }
                    self.textualToolCallCorrections = 0
                    self.lastTextualCallSignature = ""
                    // 2026-11-03：一轮正常收尾 → 记进诊断日志。
                    // 有了这条，诊断页才能区分「正常完成」和「一句话没说完就没了」。
                    CrashBreadcrumb.shared.mark("完成 正文:\(text.count)字 轮次:\(depth)")
                    ChatDiagnostics.shared.log(
                        model: config.model,
                        outcome: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyReply : .success,
                        reason: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "模型返回空正文" : "",
                        detail: "轮次 \(depth + 1)",
                        durationMs: 0,
                        rounds: depth + 1)
                    // v3.5.3：文本工具调用兜底——模型把 shell.exec("...")/shell_exec(...) 写成文本
                    // (而非结构化 tool_call) 时，系统本不执行、任务卡死。这里检测最终文本里的文本式
                    // shell 调用，提取命令并真正执行，继续 agent 循环（提示词兜底不住，代码兜底保证）。
                    //
                    // 2026-11-05 **「未执行」卡片的兜底清洗**：
                    // 走到这里说明 textualCalls 是空的（解析不出可执行的调用），
                    // 但 containsTextualToolCall(text) 可能仍是 true —— 也就是正文里
                    // 确实有 XML 残留，但解析器认不出来（标签残缺、名字不规范等）。
                    // 这段残留在渲染侧会被 ContentBlocks 画成工具卡，卡片上写死「未执行」，
                    // 而且**永远不会变成「已执行」**——因为执行侧确实没执行它，
                    // 之后也没有任何事件会重绘它。用户看到的就是「总是这样提示」。
                    //
                    // 既然它解析不出可执行调用，那它对用户就只剩噪音。这里直接清掉，
                    // 至少不留一张骗人的卡片。
                    if Self.containsTextualToolCall(text) {
                        self.cleanupResidualToolXml()
                    }
                    self.runTextualShellIfNeeded(text: text, config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
                    // v3.1.70：整条请求链 (含工具递归）结束——解除活动会话绑定
                    self.activeConvId = nil
                case .success(.toolCalls(let calls, let thinking, let narrationContent)):
                    // 2026-11-05 修「明明一直在正常干活，却报『文本工具调用连续失败 8 次』」：
                    //
                    // 这个计数器原本只在**模型最终返回纯文本**那条路上复位（第 2290 行）。
                    // 而结构性调用成功走的是本分支——它从头到尾没碰过计数器。
                    // 于是一轮对话里只要模型偶尔把调用写成正文（哪怕中间成功跑了 7 次真实工具），
                    // 计数只会一路累加，到第 8 次就整轮被掐断。
                    // 用户看到的就是「干到一半突然停了，还说格式不对」。
                    //
                    // 语义本来就是「**连续**失败」：只要这一次模型用的是正确的结构化调用，
                    // 序列就断了，计数必须归零。
                    //
                    // 2026-11-05：签名也要一起清。否则模型「文本兜底一轮 → 结构化一轮 →
                    // 又文本兜底」时，第三个文本轮会跟第一个文本轮签名相同，
                    // 被误判成「原地打转」。中间插了正常调用，就说明它没卡住。
                    self.textualToolCallCorrections = 0
                    self.lastTextualCallSignature = ""
                    // v3.5.2：系统级"一次一个工具"硬约束——模型一次批几个 toolCalls，
                    // 都裁成第一个：assistant 消息与执行只带这一个，执行完回模型让它看到
                    // 结果再决定下一步（一个接一个）。依赖调用必须等前一个结果才能决定下一步，
                    // 合批执行会让模型猜结果(违规)；提示词不可靠，代码兜底强制一次一个。
                    // v7.1.99：按工具分类放开——只读/查询类（system_overview/tools_audit/verify、
                    // shell_exec 只读命令、browser 只读子命令）可一次多条依次执行（省 N-1 轮往返，
                    // 用户实测效率慢）；副作用/写类（inject/app/control/artifact 等）保持一次一条
                    // 回模型等结果（依赖安全）。判断见 Self.isParallelSafeTool。
                    // v7.1.108-minis：废除批截断（prefix 1/4 会静默丢弃模型已生成的调用——
                    // 只读批>4 丢剩余造成漏检、混合批只做第一个造成 N 轮往返重发）。
                    // 对齐 OpenMinis：全批执行，并发上限用分波(≤4 一波自动续，等价 in-flight
                    // 排队)，混合批 writer(副作用)依次 + reader(只读)并发(读后写天然满足)。
                    // 分流见 processToolCalls 内 index==0 处。
                    // v3.1.72：思考(reasoning)与可见输出(content)分开存放——
                    // 旧逻辑把流式可见文本+思考合并成 thinkText 塞进 assistant.content，
                    // 又把同一 thinkText 塞进 tool 消息 thinking，导致 UI 上"回复内容"和
                    // "思考内容"显示一模一样、每轮工具调用重复一次 (用户实测反馈）。
                    var visibleText = ""
                    var reasoningText = self.thinkBuffer
                    if let th = thinking, !th.isEmpty {
                        reasoningText = reasoningText.isEmpty ? th : "\(reasoningText)\n\(th)"
                    }
                    // 先取流式可见文本（模型若已发解说则以其为准）
                    if let sid = self.streamingMessageId,
                       let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        visibleText = self.conversations[ci].messages[mi].content
                    }
                    // v3.5.15：兜底——非流式 chat/completions 没有 streamingMessageId，
                    // 但模型写的正文解说已由 .toolCalls 的 content 透传出来，直接用当 visibleText。
                    if visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let nc = narrationContent, !nc.isEmpty {
                        visibleText = nc
                    }
                    // 2026-11-05 **「未执行」卡片反复出现的第三个根因（结构性调用分支完全没清洗）**：
                    //
                    // 上文那条文本兜底路径（第 2285 行）确实调了 stripTextualToolCalls，
                    // 但**只在那条路径上调**。而模型最常见的实际行为是「结构化 tool_calls
                    // ＋ 正文里还顺手抄一遍 XML」——走的正是本分支，从头到尾一次都没清洗过。
                    //
                    // 用户截图就是这个组合：底部「运行了 1 个工具 0.1s」= 结构化调用真的跑了，
                    // 气泡里两张 `shell.exec` 「未执行」卡 = 同一段输出里被抄进正文的 XML 残片。
                    // 渲染侧把它画成卡（ContentBlocks 认得），执行侧没解析它（本来也不需要，
                    // 结构化那条已经执行了），于是卡片永远停在「未执行」。
                    //
                    // 这里补上清洗。注意用 `stripTextualToolCallBlocks`（不塞占位文案）——
                    // 本轮是真的执行了工具，不需要再补一句「已自动执行上面的工具调用」，
                    // 那句话在这个场景里反而会误导。
                    visibleText = Self.stripTextualToolCallBlocks(visibleText)
                    // v4.5.x：去掉"解说纠正"硬门槛（对齐大厂事件流方案）——
                    // 旧实现(v3.5.5/v3.5.10)：模型发 tool_calls 但没写正文解说时，不执行工具，
                    // 注入纠正消息重跑一轮，上限 4 次。实测模型(L0 chat/completions)工具轮
                    // content 为空是 API 层常态 → 永远重跑到上限 → 每次请求固定 5 轮、token 烧 5 倍。
                    // 大厂(Claude Code/Codex)不惩罚：模型说什么就做什么，工具照常执行，
                    // 解说由 thinking 黄泡 + 工具步骤卡片事件流呈现。这里直接放行。
                    // v3.5.4：正文解说只取模型自己写在 content 里的文本；模型若光思考没写正文解说，
                    // 正文就保持空(6.A)——不再用 reasoning 自动合成解说（用户明确：▶ 开始执行那种
                    // 机械合成是误解；思考归思考进黄泡，正文只放 AI 自己说的话，空就空着）。
                    if let sid = self.streamingMessageId,
                       let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        // 保留流式可见文本作为回复内容，思考进 thinking 字段，toolCalls 挂上 (不删除重建）
                        // 模型没写正文解说时 visibleText 为空 → content 保持空，只显示思考黄泡 + 工具步骤 (6.A)
                        if self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.conversations[ci].messages[mi].content = visibleText
                        }
                        self.conversations[ci].messages[mi].toolCalls = calls
                        // v3.5.4：思考始终写入黄色气泡(message.thinking)，不再要求 content 为空——
                        // 此前 reasoning 被 v3.5.1 打进正文使 content 非空，导致 thinking 永不写入、黄泡为空。
                        // 与正文去重：部分中转把完整回答写进 reasoning_content，与 content 相同则不展示思考。
                        let cText = self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rTrim.isEmpty, !(cText == rTrim || rTrim.contains(cText) || cText.contains(rTrim)) {
                            self.conversations[ci].messages[mi].thinking = reasoningText
                        } else if !rTrim.isEmpty {
                            // 思考与正文重复(中转把完整回答写进 reasoning_content) → 清掉黄泡，避免重复展示
                            self.conversations[ci].messages[mi].thinking = nil
                        }
                    } else {
                        // 无流式消息 (流式未开始就被 toolCalls 打断）：新建 assistant 消息
                        var am = ChatMessage(role: "assistant", content: visibleText, toolCalls: calls)
                        let vTrim = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim2 = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rTrim2.isEmpty, !(vTrim == rTrim2 || rTrim2.contains(vTrim) || vTrim.contains(rTrim2)) {
                            am.thinking = reasoningText
                        }
                        self.appendToCurrent(am)
                        self.liveProducedID = am.id
                    }
                    self.thinkBuffer = "" // 重置缓冲区
                    self.thinkingStartAt = nil // v7.1.109-peers：思考计时重置
                    self.streamingMessageId = nil
                    // v2.9.127：轨迹——AI 决定调用一批工具
                    self.trailStep(.done(.tool, "准备调用 \(calls.count) 个工具",
                                         detail: calls.map { $0.name }.joined(separator: "、")))
                    // v2.9.31：递归处理一批工具调用 (后台执行，无授权弹窗）
                    // v3.1.72：thinkText 传可见文本 (工具调用前的说明），不再写入 tool 消息 thinking
                    self.processToolCalls(calls, index: 0, toolMessages: [], newlyDisclosed: [],
                                          config: config, tools: tools, disclosed: disclosed, depth: depth,
                                          reasoningLevel: reasoningLevel, thinkText: visibleText)
                case .failure(let error):
                    // fix73j-审计 M-7：后台代传（handoff）会 cancel 主请求，其 -999 取消回调
                    // 无条件清 isLoading，而 consumeBackgroundResult 的 guard isLoading 依赖它
                    // → 后台代传结果被静默丢弃（破坏性读取/长分析结果丢失）。修复：handoff
                    // 在途（有 pending 结果待消费）时保留 isLoading，回前台正常消费。
                    // 2026-11-05：本轮以错误结束 → 底部状态条播「⚠️ 已停止」。
                    // 用户主动点停止（-999）也走这条：他知道自己按了停止，
                    // 显示"已停止"比静默消失更符合直觉。
                    self.lastTurnHadError = true
                    if !BackgroundLLM.shared.hasPendingHandoff() {
                        self.isLoading = false
                    }
                    self.currentClient = nil
                    self.requestRound = 0
                    self.runningTool = nil
                    self.thinkBuffer = "" // 重置缓冲区
                    self.thinkingStartAt = nil // v7.1.109-peers：思考计时重置
                    self.liveProducedID = nil
                    // v2.9.13：用户主动取消 (-999）不追加错误气泡
                    let nsErr = error as NSError
                    if nsErr.code == -999 {
                        self.statusText = nil
                        // v7.4.0-fix73b：若已有新请求接管（currentClient 非 nil / 新一轮 isLoading），
                        // 不清流式状态——否则旧请求的 -999 回调会把新请求的流式消息 ID 清掉，
                        // 新请求的流式文本全部丢失（用户实测"请求完成无结果"）
                        if self.currentClient == nil {
                            self.streamingMessageId = nil
                        }
                        // v2.9.82：取消也算结束，回收后台任务但不通知
                        TaskNotify.shared.endBackground()
                        // v3.1.70：用户取消——解除活动会话绑定
                        self.activeConvId = nil
                        // 2026-11-03：手动停止也记一条，诊断页才能把「自己停的」和「自己停的以外」分开
                        CrashBreadcrumb.shared.mark("用户手动停止 @轮次\(depth)")
                        ChatDiagnostics.shared.log(model: config.model, outcome: .stopped,
                                                   reason: "用户点了停止", rounds: depth + 1)
                        return
                    }
                    // v2.9.87：网络类错误 + 当前确认断网 → 等网络恢复自动重试一次
                    if self.shouldRetryOnNetworkRestore(nsErr) {
                        self.statusText = L10n.t("status_network_unavailable")
                        self.scheduleRetryAfterNetworkRestore(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
                        return
                    }
                    // v7.4.0-fix72：后台挂起失败（非真断网）——不弹"网络连接已中断"，
                    // 回前台自动重试（仅一次防死循环；cancelNetworkRetry 一并清理）
                    if self.isBackgroundSuspensionFailure() {
                        self.statusText = L10n.t("status_background_suspended")
                        self.scheduleRetryOnForeground(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
                        return
                    }
                    // v2.9.82：failed通知 (后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "⚠️ Task error", body: String(error.localizedDescription.prefix(60)))
                    // 流式failed时保留已输出的部分文本，追加错误提示
                    if self.streamingMessageId != nil {
                        self.streamingMessageId = nil
                    }
                    let errMsg = ChatMessage(role: "assistant", content: "⚠️ \(error.localizedDescription)", isError: true)
                    self.appendToCurrent(errMsg)
                    self.trailStep(.done(.note, "请求失败", detail: String(error.localizedDescription.prefix(200)), ok: false))
                    self.attachTrail(to: errMsg.id)
                    // v3.1.70：请求链结束——解除活动会话绑定
                    self.activeConvId = nil
                }
            }
        }
    }

    /// v2.9.127：轨迹摘要——取 JSON 里 ok/message/status 等关键字段，超长截断
    static func trailSummary(_ json: String) -> String {
        let trimmed = json.count > 300 ? String(json.prefix(300)) : json
        // 去掉换行压扁，便于步骤行内展示
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    /// v3.1.26：把参数 JSON 转成简短摘要 (比如 "url: https://xxx"）
    /// UI 里用特殊颜色显示，太长就截断
    static func summarizeArgs(_ argsString: String) -> String? {
        guard let data = argsString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 只取前 2 个参数，每个值截断到 50 字符
        let entries = json.prefix(2).map { key, value -> String in
            let val: String
            if let s = value as? String {
                val = s
            } else {
                val = "\(value)"
            }
            let truncated = val.count > 50 ? String(val.prefix(50)) + "..." : val
            return "\(key): \(truncated)"
        }
        return entries.joined(separator: ", ")
    }

    // MARK: - 2026-11-03 DSML 特殊 token 归一化 + 文本式工具调用解析
    //
    // 背景（用户连续多次反馈「底部全是英文」「罢工，得再发继续」）：
    // DeepSeek 系模型把工具调用以**特殊 token 的原始文本**吐出来，而不是结构化
    // tool_calls。真机截图里的形态是（全角竖线 U+FF5C，且渲染时竖线之间看着有空格）：
    //
    //   <｜｜DSML｜｜ calls>
    //   <｜｜DSML｜｜ invoke name="shell.exec">
    //   <｜｜DSML｜｜ parameter name="command" string="true">ls -la</｜｜DSML｜｜ parameter>
    //   </｜｜DSML｜｜ invoke>
    //   </｜｜DSML｜｜ calls>
    //
    // 所有解析器的基准形态都是半角单竖线 `<|DSML|`，所以这里先做一次归一化，
    // 把全角/双竖线/零宽字符/夹空格等所有变体统一成 `<|DSML|`，后续只处理一种形态。

    /// 把模型输出的各种 DSML 特殊 token 变体统一成半角单竖线 `<|DSML|` 形态。
    static func normalizeDSML(_ s: String) -> String {
        var t = s
        // ① 零宽字符会夹在竖线之间（截图里"｜ ｜"的视觉效果一部分来自它），先清掉
        for zw in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}"] {
            t = t.replacingOccurrences(of: zw, with: "")
        }
        // ② 全角竖线 → 半角；全角尖括号也一并归一
        t = t.replacingOccurrences(of: "\u{FF5C}", with: "|")
        t = t.replacingOccurrences(of: "\u{FF1C}", with: "<")
        t = t.replacingOccurrences(of: "\u{FF1E}", with: ">")
        // ③ 关键：真机是**双竖线** "||DSML||"，而解析基准是单竖线 "|DSML|"。
        //    只做全角→半角会得到 "||DSML||"，依旧匹配不上（实测确认）——
        //    必须在这里折叠成单竖线。
        for pair in [("||DSML||", "|DSML|"), ("||DSML|", "|DSML|"),
                     ("|DSML||", "|DSML|"),
                     ("</||DSML||", "</|DSML|"), ("</||DSML|", "</|DSML|"),
                     ("</|DSML||", "</|DSML|")] {
            t = t.replacingOccurrences(of: pair.0, with: pair.1)
        }
        // ④ 再收一遍残余（前面的替换顺序可能留下新的双竖线）
        t = t.replacingOccurrences(of: "||DSML||", with: "|DSML|")
        // ⑤ 竖线之间夹空格："| DSML |"、"< | | DSML | |" 这类渲染形态
        if let re = try? NSRegularExpression(pattern: #"<\s*\|\s*\|?\s*DSML\s*\|?\s*\|?\s*"#) {
            let ns = t as NSString
            t = re.stringByReplacingMatches(in: t,
                                            range: NSRange(location: 0, length: ns.length),
                                            withTemplate: "<|DSML|")
        }
        // ⑥ 闭合形态同理：</ | | DSML | | → </|DSML|
        if let re = try? NSRegularExpression(pattern: #"<\s*/\s*\|\s*\|?\s*DSML\s*\|?\s*\|?\s*"#) {
            let ns = t as NSString
            t = re.stringByReplacingMatches(in: t,
                                            range: NSRange(location: 0, length: ns.length),
                                            withTemplate: "</|DSML|")
        }
        return t
    }

    /// 2026-11-05 **「未执行」卡片反复出现的第二个根因**：
    ///
    /// 渲染侧（`ContentBlocks.matchStartTag` 第 ④ 条）认的是
    /// `tool.xxx` **或者** `任意小写名.xxx`——所以 `shell.exec` 这种
    /// **不带 tool. 前缀**的自闭合标签会被画成一张工具卡。
    ///
    /// 而执行侧（本文件 `containsTextualToolCall` / `parseTextualToolCalls` /
    /// `firstSelfClosingRange` / `stripTextualToolCalls`）全部只认
    /// `tool[.:]…` 或 `call`——`shell.exec` 一条都不命中。
    ///
    /// 于是同一段文本在两侧得到完全相反的结论：
    ///   · 渲染侧：是个调用 → 画卡 → 卡上写死「未执行」
    ///   · 执行侧：不是调用 → return [] → 真的没执行 → strip 也不清
    /// 用户截图里那两张叠在一起的 `shell.exec`「未执行」卡就是这么来的：
    /// 底部同时写着「运行了 1 个工具 0.1s」——真执行的那个是结构化 tool_call，
    /// 气泡里这两张是同一次输出里被当成正文的 XML 残片。
    ///
    /// 根治办法是**只留一份正则**：两侧都从这里取。改一处两边同时生效，
    /// 不会再出现「补一个漏一个」。
    ///
    /// 形态覆盖：`<tool.describe name="app" />`（带 tool. 前缀）、
    /// `<shell.exec command="ls" />`（工具名自带点号，本 App 的真实工具名就是这个形状）、
    /// `<call name="app" />`。
    /// 不误伤 HTML：`<br />`、`<div />` 这类纯单词标签不含点号/冒号，匹配不上。
    static let selfClosingTagPattern =
        #"<\s*(tool[.:][A-Za-z0-9_.\-]+|[a-z][a-z0-9_\-]*[.:][A-Za-z0-9_.\-]+|call)\b([^>]*?)/\s*>"#

    /// 是否包含文本形态的工具调用（DSML / antml / invoke / 自闭合短标签）
    static func containsTextualToolCall(_ text: String) -> Bool {
        let t = normalizeDSML(text)
        if t.contains("<|DSML|") || t.contains("<antml:invoke") || t.contains("<invoke") {
            return true
        }
        // 2026-11-03：自闭合短标签也算（`<tool.describe name="app" />`）。
        // 少这一条的话，stripTextualToolCalls 会直接原样返回，
        // 屏幕上那行 XML 永远清不掉——用户截图里就横在正文中间。
        // 2026-11-05：改取共享常量，`shell.exec` 这类不带 tool. 前缀的形态也认了。
        return t.range(of: Self.selfClosingTagPattern, options: .regularExpression) != nil
    }

    /// 2026-11-03 核心修复：把正文里的**文本形态工具调用**解析成真正的 ToolCall 数组。
    ///
    /// 为什么非做不可：客户端只认结构化 tool_calls，模型把调用写成正文时，
    /// 这段就成了「一屏英文 XML」，工具根本没跑，模型以为已经调用了 → 本轮结束
    /// → 用户看到的就是「罢工，得再发一次继续」。光靠提示词纠正治不住（实测确认），
    /// 这里直接在代码层反解成 ToolCall 去执行，模型用什么格式写都能跑下去。
    ///
    /// 返回空数组 = 没有可解析的文本调用。
    static func parseTextualToolCalls(_ text: String) -> [ToolCall] {
        let t = normalizeDSML(text)
        // 2026-11-03 重要修复（用户截图：工具卡显示「未执行」，模型说"现在实际执行"却什么都没跑）：
        //
        // 原来的开场判断只有 <|DSML| / <antml:invoke / <invoke 三种，
        // 而真机上模型大量使用的是**自闭合短标签** `<tool.describe name="app" />`。
        // 它不含任何 invoke 字样 → 这里直接 return [] → 一个都不执行。
        // 渲染侧（ContentBlocks）已经能把它画成工具卡了，但执行侧不认，
        // 于是卡片停在「未执行」，模型那边以为已经调过了，任务就这么断掉。
        //
        // 判断条件补上自闭合形态的两种写法。
        let hasSelfClosing = t.range(
            of: Self.selfClosingTagPattern,
            options: .regularExpression) != nil
        guard t.contains("<|DSML|") || t.contains("<antml:invoke")
                || t.contains("<invoke") || hasSelfClosing else {
            return []
        }
        var out: [ToolCall] = []
        let invokeOpen = #"<\|DSML\|\s*invoke\s+name=["']([^"']+)["'][^>]*>"#
        let antmlOpen  = #"<antml:invoke\s+name=["']([^"']+)["'][^>]*>"#
        let plainOpen  = #"<invoke\s+name=["']([^"']+)["'][^>]*>"#
        var remaining = t
        // 最多解析 32 个，防病态输入把主线程卡住
        var guardCount = 0
        while guardCount < 32 {
            guardCount += 1
            // 找最早出现的 invoke 起始
            var bestRange: Range<String.Index>?
            var bestName = ""
            for p in [invokeOpen, antmlOpen, plainOpen] {
                guard let re = try? NSRegularExpression(pattern: p) else { continue }
                let ns = remaining as NSString
                guard let m = re.firstMatch(in: remaining, range: NSRange(location: 0, length: ns.length)),
                      m.numberOfRanges > 1,
                      let full = Range(m.range, in: remaining),
                      let nameR = Range(m.range(at: 1), in: remaining) else { continue }
                if bestRange == nil || full.lowerBound < bestRange!.lowerBound {
                    bestRange = full
                    bestName = String(remaining[nameR])
                }
            }
            // 2026-11-03：自闭合短标签分支。
            // `<tool.describe name="app" />` / `<call name="app" />` / `<tool:describe name="app" />`
            // 没有闭合标签、没有 parameter 段，参数只能从标签属性里抠。
            // 必须和上面那些 invoke 形态比"谁出现得更早"，否则同一段文本里
            // 混用两种写法时会打乱顺序（模型是按顺序表达的意图）。
            // 注意：这个函数的参数是**无标签**的（定义处是 `_ s: String`），
            // 不能写 firstSelfClosingRange(in: ...)——CI 已实测报
            // error: extraneous argument label 'in:' in call
            if let selfRange = firstSelfClosingRange(remaining) {
                if bestRange == nil || selfRange.full.lowerBound < bestRange!.lowerBound {
                    // 自闭合优先于 invoke
                    let tagName = selfRange.name
                    let attrs = selfRange.attrs
                    if let call = makeSelfClosingCall(name: tagName, attrs: attrs) {
                        out.append(call)
                    }
                    if selfRange.full.upperBound >= remaining.endIndex { break }
                    remaining = String(remaining[selfRange.full.upperBound...])
                    if remaining.isEmpty { break }
                    continue
                }
            }
            guard let open = bestRange else { break }
            let afterOpen = remaining[open.upperBound...]
            // 找对应闭合标签
            var closeRange: Range<String.Index>?
            for close in ["</|DSML| invoke>", "</|DSML|invoke>",
                          "</antml:invoke>", "</invoke>"] {
                if let r = afterOpen.range(of: close) {
                    if closeRange == nil || r.lowerBound < closeRange!.lowerBound {
                        closeRange = r
                    }
                }
            }
            let body: String
            let nextStart: String.Index
            if let close = closeRange {
                body = String(afterOpen[..<close.lowerBound])
                nextStart = close.upperBound
            } else {
                // 没闭合（流式截断/模型漏写）：吃到文本结尾
                body = String(afterOpen)
                nextStart = remaining.endIndex
            }
            // 解析 body 里的 parameter
            var params: [String: String] = [:]
            let paramPat = #"parameter\s+name=["']([^"']+)["'][^>]*>([\s\S]*?)</(?:\|DSML\||antml:)?\s*parameter>"#
            if let re = try? NSRegularExpression(pattern: paramPat, options: [.dotMatchesLineSeparators]) {
                let ns = body as NSString
                let matches = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
                for m in matches where m.numberOfRanges > 2 {
                    let k = ns.substring(with: m.range(at: 1))
                    var v = ns.substring(with: m.range(at: 2))
                    for junk in ["</|DSML| parameter>", "</|DSML|parameter>",
                                 "</antml:parameter>", "</parameter>"] {
                        v = v.replacingOccurrences(of: junk, with: "")
                    }
                    params[k] = v.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if !bestName.isEmpty {
                // 参数还原成 JSON（与结构化 tool_calls 完全同构，后续链路零改动）
                let argsJSON: String
                if let d = try? JSONSerialization.data(withJSONObject: params as [String: Any],
                                                       options: [.sortedKeys]),
                   let s = String(data: d, encoding: .utf8) {
                    argsJSON = s
                } else {
                    argsJSON = "{}"
                }
                out.append(ToolCall(id: "textual-" + UUID().uuidString,
                                    name: bestName,
                                    arguments: argsJSON,
                                    toolTitle: ToolCall.extractTitle(from: argsJSON)))
            }
            if nextStart >= remaining.endIndex { break }
            remaining = String(remaining[nextStart...])
            if remaining.isEmpty { break }
        }
        return out
    }

    /// 2026-11-03 新增：找最早出现的「自闭合工具标签」。
    ///
    /// 需要它的原因见 parseTextualToolCalls 里的注释——模型大量使用
    /// `<tool.describe name="app" />` 这种写法，它没有闭合标签也没有
    /// parameter 段，用 invoke 那套正则永远匹配不到，工具就停在「未执行」。
    ///
    /// 返回：完整匹配范围 + 工具名 + 属性串（给 makeSelfClosingCall 抠参数）
    private static func firstSelfClosingRange(_ s: String)
        -> (full: Range<String.Index>, name: String, attrs: String)? {
        // 2026-11-05：改用共享常量——渲染侧（ContentBlocks）和执行侧必须是同一套
        // 判定，否则会出现「画成卡、但不执行」的假象（见 selfClosingTagPattern 注释）。
        let pat = Self.selfClosingTagPattern
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 2,
              let full = Range(m.range, in: s),
              let nameR = Range(m.range(at: 1), in: s),
              let attrR = Range(m.range(at: 2), in: s) else { return nil }
        let name = String(s[nameR]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return (full, name, String(s[attrR]))
    }

    /// 由自闭合标签构造一个 ToolCall。
    ///
    /// 工具名有讲究：`<call name="app" />` 里工具名在 name 属性上，
    /// 而 `<tool.describe name="app" />` 里工具名是标签名本身（tool.describe），
    /// name 属性反而表示"对哪个对象操作"。两种情况都要能跑。
    private static func makeSelfClosingCall(name tagName: String, attrs: String) -> ToolCall? {
        var params: [String: String] = [:]
        let attrPat = #"([A-Za-z_][A-Za-z0-9_\-]*)\s*=\s*["']([^"']*)["']"#
        if let re = try? NSRegularExpression(pattern: attrPat) {
            let ns = attrs as NSString
            for m in re.matches(in: attrs, range: NSRange(location: 0, length: ns.length))
            where m.numberOfRanges > 2 {
                let k = ns.substring(with: m.range(at: 1))
                let v = ns.substring(with: m.range(at: 2))
                params[k] = v
            }
        }
        // 工具名的决定规则
        let lower = tagName.lowercased()
        let finalName: String
        if lower == "call" || lower == "tool" || lower.hasPrefix("call.") || lower.hasPrefix("call:") {
            // <call name="app" /> → 工具名取 name 属性
            guard let n = params["name"], !n.isEmpty else { return nil }
            finalName = n
            params.removeValue(forKey: "name")
        } else {
            // <tool.describe name="app" /> → 工具名就是 tool.describe
            finalName = tagName
        }
        let argsJSON: String
        if let d = try? JSONSerialization.data(withJSONObject: params as [String: Any],
                                               options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            argsJSON = s
        } else {
            argsJSON = "{}"
        }
        return ToolCall(id: "textual-" + UUID().uuidString,
                        name: finalName,
                        arguments: argsJSON,
                        toolTitle: ToolCall.extractTitle(from: argsJSON))
    }

    /// 2026-11-03：把正文里的文本形态工具调用**剔除掉**，只留真正的自然语言说明。
    ///
    /// parseTextualToolCalls 已经把 XML 反解成 ToolCall 去真执行了，但屏幕上那段
    /// 还留着 → 用户看到「上面能看懂的中文 + 下面一大片英文 XML」，英文还会不断
    /// 刷屏把中文顶走。执行完必须把这段从气泡内容里删干净。
    ///
    /// 不改变正常正文：只有真的匹配到 invoke/DSML token 才动手。
    ///
    /// ⚠️ 这个带占位文案的版本只给「文本兜底执行」那条路径用——那里工具是靠解析
    /// 这段 XML 才跑起来的，削光后补一句说明是必要的。**结构化 tool_calls 分支
    /// 必须用下面那个不带占位文案的 `stripTextualToolCallBlocks`**，
    /// 否则会冒出一句「已自动执行上面的工具调用」，而那句话是多余的。
    static func stripTextualToolCalls(_ text: String) -> String {
        let t = stripTextualToolCallBlocks(text)
        // 全被削光就留一句提示，别让气泡空白（看起来像 Bug）
        return t.isEmpty ? "（已自动执行上面的工具调用）" : t
    }

    /// 纯清洗：只把 XML 残片删掉，**不塞任何占位文案**。
    ///
    /// 返回空字符串 = 整段都是 XML、没有任何自然语言。
    /// 调用方自己决定空的时候要不要补话（结构化调用分支就不补）。
    static func stripTextualToolCallBlocks(_ text: String) -> String {
        guard containsTextualToolCall(text) else { return text }
        var t = normalizeDSML(text)

        // ① 整块 invoke（含 calls 外层包裹）
        let blockPats = [
            #"<\|DSML\|\s*invoke\b[\s\S]*?</\|\s*DSML\s*\|?\s*invoke\s*>"#,
            #"<antml:invoke\b[\s\S]*?</antml:invoke\s*>"#,
            #"<invoke\b[\s\S]*?</invoke\s*>"#,
        ]
        for p in blockPats {
            if let re = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) {
                let ns = t as NSString
                t = re.stringByReplacingMatches(in: t,
                                                range: NSRange(location: 0, length: ns.length),
                                                withTemplate: "")
            }
        }
        // ② 未闭合的最后一个 invoke（流式截断/模型漏写）
        for p in [#"<\|DSML\|\s*invoke\b[\s\S]*$"#, #"<antml:invoke\b[\s\S]*$"#] {
            if let re = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) {
                let ns = t as NSString
                if let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
                   let r = Range(m.range, in: t) {
                    t = String(t[..<r.lowerBound])
                }
            }
        }
        // ③ 孤立残留的包裹/参数标签（含 calls 外层、闭合形态 </|DSML|calls>）
        //    注意顺序：带 "/" 的闭合标签必须先匹配掉，否则残留成 "</|DSML|calls>"
        let strayPats = [
            #"</\s*\|DSML\|\s*/?\s*(calls|invoke|parameter|call|function_calls|function_results)\s*>"#,
            #"<\s*\|DSML\|\s*/?\s*(calls|invoke|parameter|call|function_calls|function_results)\s*>"#,
            #"<\|DSML\|\s*parameter\b[\s\S]*?</\|\s*DSML\s*\|?\s*parameter\s*>"#,
            #"</\|\s*DSML\s*\|?\s*>"#,
            #"<\|DSML\|\s*>"#,
            // 2026-11-03 新增：自闭合短标签本身也要剥掉。
            // 用户截图中 `<|DSML|calls>` 和 `</|DSML|calls>` 之间横着一个
            // `<tool.describe name="app" />`，外壳被剥了、中间那行还留着，
            // 于是正文里孤零零一行 XML —— 这条正则把它一起清掉。
            // 2026-11-05：改取共享常量，`<shell.exec … />` 这种形态一并覆盖。
            Self.selfClosingTagPattern,
        ]
        for p in strayPats {
            if let re = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) {
                let ns = t as NSString
                t = re.stringByReplacingMatches(in: t,
                                                range: NSRange(location: 0, length: ns.length),
                                                withTemplate: "")
            }
        }
        // ④ 收拾删除后留下的连续空行
        while t.contains("\n\n\n") {
            t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// v2.9.31：递归处理一批工具调用。工具在后台线程执行 (避免耗时操作阻塞主线程），
    /// 结果经 handleDispatchResult 回主线程继续。
    /// v3.5.3：文本工具调用兜底——从最终文本里提取文本式 shell 调用命令（shell.exec("...") /
    /// shell_exec(command="...") 等）。模型把调用写成文本(而非结构化 tool_call)时系统不执行，
    /// 这里兜底提取出真实命令让 runTextualShellIfNeeded 真正执行。
    ///
    /// 2026-11-03：入口先做 DSML 归一化，否则全角双竖线的 `<｜｜DSML｜｜ parameter ...>`
    /// 用半角正则一条都匹配不到 → 命令提取失败 → 工具根本没执行。
    private static func extractTextualShellCommand(from text: String) -> String? {
        let normalized = normalizeDSML(text)
        // ① DSML / antml 参数块里的 command（真机截图那形态）
        let dsmlPatterns = [
            #"parameter\s+name=["']command["'][^>]*>([\s\S]*?)</\|\s*DSML\s*\|?\s*parameter>"#,
            #"parameter\s+name=["']command["'][^>]*>([\s\S]*?)</antml:parameter>"#,
            #"parameter\s+name=["']command["'][^>]*>([\s\S]*?)</parameter>"#,
            #"parameter\s+name=["']command["'][^>]*>([\s\S]*?)<"#,
        ]
        for p in dsmlPatterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) else { continue }
            let ns = normalized as NSString
            if let m = re.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                var c = ns.substring(with: m.range(at: 1))
                for junk in ["</|DSML| parameter>", "</|DSML|parameter>",
                             "</antml:parameter>", "</parameter>", "</|DSML|>"] {
                    c = c.replacingOccurrences(of: junk, with: "")
                }
                c = c.trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { return c }
            }
        }
        // ② 老的自然写法
        let patterns = [
            #"shell\.exec\s*\(\s*["']([^"']+?)["']\s*\)"#,          // shell.exec("cmd") / shell.exec('cmd')
            #"shell_exec\s*\(\s*command\s*[:=]\s*["']([^"']+?)["']"#, // shell_exec(command="cmd")
            #"shell_exec\s*\(\s*["']([^"']+?)["']\s*\)"#           // shell_exec("cmd")
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: []) else { continue }
            let ns = normalized as NSString
            if let m = re.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                let c = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { return c }
            }
        }
        return nil
    }

    /// 2026-11-05 新增：清掉「解析不出调用、却会画成卡片」的 XML 残留。
    ///
    /// 场景：模型把工具调用写成正文，但标签残缺/名字不规范，`parseTextualToolCalls`
    /// 反解出 0 个可执行调用（于是 `!textualCalls.isEmpty` 那条分支进不去）。
    /// 可渲染侧 `ContentBlocks` 认得这类标签，照样画一张工具卡，
    /// 卡上写死「未执行」——而且它永远不会变，因为压根没东西去执行它。
    ///
    /// 用户的感受就是「总是这样提示」。既然解析不出调用，这段对它就只剩噪音，
    /// 直接清掉，不留骗人的卡。
    ///
    /// 只动当前流式消息里**确实含 XML** 的那条，纯自然语言正文一个字不碰。
    private func cleanupResidualToolXml() {
        guard let sid = self.streamingMessageId, let ci = self.activeConvIndex else { return }
        let cur = self.conversations[ci].messages.first(where: { $0.id == sid })?.content ?? ""
        guard Self.containsTextualToolCall(cur) else { return }
        let cleaned = Self.stripTextualToolCallBlocks(cur)
        // 削光后如果什么都不剩，就别把气泡留成空白（会让人以为渲染坏了）。
        // 这里补一句中性说明，而不是「已自动执行」——那是假话，工具真没跑。
        let finalText = cleaned.isEmpty
            ? "（模型这次没给出可执行的操作，也没有正文内容）"
            : cleaned
        _ = self.updateMessage(in: self.conversations[ci].id, msgId: sid) { m in
            m.content = finalText
        }
        CrashBreadcrumb.shared.mark("清掉无法执行的工具 XML 残留 原长:\(cur.count) 新长:\(finalText.count)")
    }

    /// v3.5.3：执行文本兜底提取出的 shell 命令，把结果作为 tool 消息上屏并继续 agent 循环，
    /// 让模型看到结果后能继续下一步（而非卡死在"写了文本没执行"）。
    private func runTextualShellIfNeeded(text: String, config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int, personaPrompt: String? = nil) {
        guard let cmd = Self.extractTextualShellCommand(from: text) else { return }
        let cmdCopy = cmd
        DispatchQueue.global().async {
            let params: [String: Any] = ["command": cmdCopy]
            let result: Result<[String: Any], Error>
            do { result = .success(try ToolRegistry.shared.dispatch(name: "shell.exec", params: params)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                var tm = ChatMessage(role: "tool", content: "", toolCallId: UUID().uuidString, toolName: "shell.exec")
                switch result {
                case .success(let r):
                    let raw = Self.jsonString(r)
                    // v7.2.3-fix25：工具结果硬截断上限 8000 → 48000（旧 16k 窗口时代的值；
                    // contextTokens 默认已 128k，8000 会把工具完整结果（即使显式 limit=50000）
                    // 砍到 8k——用户实测 1000 行输出仍 truncated 根因）
                    tm.content = raw.count > 48000 ? raw.prefix(48000) + "\n... [tool result truncated, total \(raw.count) chars]" : raw
                    tm.toolArgs = String("Command: \(cmdCopy.prefix(120))")
                    tm.toolDuration = 0.01
                case .failure(let e):
                    tm.content = "Execution failed: \(e.localizedDescription)"
                    tm.isError = true
                    tm.toolArgs = String("Command: \(cmdCopy.prefix(120))")
                }
                self.appendToCurrent(tm)
                self.liveProducedID = tm.id
                // 继续 agent 循环，模型看到结果后可决定下一步
                self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth + 1, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
            }
        }
    }

    private func processToolCalls(_ calls: [ToolCall],
                                  index: Int,
                                  toolMessages: [ChatMessage],
                                  newlyDisclosed: [String],
                                  config: ModelConfig,
                                  tools: [[String: Any]]?,
                                  disclosed: [String],
                                  depth: Int,
                                  reasoningLevel: Int,
                                  thinkText: String = "",
                                  personaPrompt: String? = nil) {
        // 批耗尽出口：calls 全量（v7.1.108-minis 起不再截断）。串行路径（混合/全副作用批）
        // 在这里按原序依次执行全部调用后回模型；纯只读批在下方 index==0 分流走分波并发。
        if index >= calls.count {
            // v3.4.1：工具气泡已在 handleDispatchResult 逐条实时上屏（对齐 OpenMinis 逐步展示），
            // 不再攒批到最后统一追加 —— 边做边说更接近"直播"。
            //
            // 2026-11-06 **熔断检查必须在这里做，不能在单条结果里 return**。
            //   API 协议要求「assistant 的 N 条 toolCalls 必须配 N 条 tool 结果」，
            //   在 index < calls.count 时 return 会留下半截序列 → 下一轮请求直接被拒，
            //   用户看到的是「莫名报错/整段对话卡死」，比原来的无限重试更难查。
            //   到这里时全部结果都已按原序回填 → 序列完整 → 停手安全。
            if self.consecutiveSameToolFailures >= 3 {
                self.stopForRepeatedToolFailure()
                return
            }
            let merged = Array(Set(disclosed + newlyDisclosed))
            self.runLoop(config: config, tools: tools, disclosed: merged, depth: depth + 1, reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
            return
        }
        // v7.1.106：真并行分流——只读/独立工具批（count>1）走 DispatchGroup 并发执行，
        // 全部完成后按 tool_use 原序回填 tool 消息（API 要求 assistant toolCalls 与结果顺序配对）。
        // 并行安全判定见 isParallelSafeTool。
        // v7.1.108-minis：废除截断后全量批进这里——全安全批 → 分波并发（≤4 一波自动续，
        // 等价 OpenMinis in-flight 排队）；混合/全副作用批 → 落到下方串行路径（calls 全量
        // 原序依次执行，index+1 循环天然支持）。v7.1.109-fix(审计)：曾用 ordered 两阶段
        // "全部 writer 先跑"——违背模型原序意图（[grep,rm] 被执行为先删后查，grep 读到
        // 删除后状态）。Minis BatchToolOrder 只让 reader 等原序前序 writer，writer 不提前；
        // 本地保守策略 = 混合批严格原序串行，纯只读批才并发。
        if index == 0, calls.count > 1, Self.isParallelSafeTool(calls) {
            self.processToolCallsParallel(calls, toolMessages: toolMessages, newlyDisclosed: newlyDisclosed,
                                          config: config, tools: tools, disclosed: disclosed, depth: depth,
                                          reasoningLevel: reasoningLevel, thinkText: thinkText, personaPrompt: personaPrompt)
            return
        }
        let call = calls[index]
        let params = Self.parseArgs(call.arguments)
        // v3.5.6：工具参数 schema 预校验（机制级，治"缺参盲试"老毛病）——
        // 调工具前先用工具 schema 校验必填参数，缺了就不执行，注入纠正消息重跑一轮逼模型补齐。
        // 不再像以前那样直接执行→报"invalid params required"→靠提示词让模型自己改（常盲试好几次）。
        if let schema = ToolRegistry.shared.openAISchema(for: call.name),
           let fn = schema["function"] as? [String: Any],
           let ps = fn["parameters"] as? [String: Any],
           let required = ps["required"] as? [String] {
            let missing = required.filter { params[$0] == nil }
            if !missing.isEmpty && self.paramCorrectionCount < 2 {
                self.paramCorrectionCount += 1
                self.pendingParamCorrection = "The tool \(call.name) you want to call is missing required params: \(missing.joined(separator: ", ")). Fill them in and call again; don't keep retrying the same missing-param call in the same way."
                self.trailStep(.done(.note, "工具缺少参数", detail: "\(call.name) 缺少：\(missing.joined(separator: "、"))", ok: false))
                // v7.1.101：缺参不再剥离回模型——v7.1.99 多条合批后，剥离会留下
                // "assistant 带 N 条 toolCalls 却只有部分 tool 结果"的非法序列（API 拒）。
                // 改为：缺参作为错误 tool 消息 append（toolCallId 匹配），继续执行下一条，
                // 全部执行完再回模型——模型看到错误消息自己补齐，序列始终完整合法。
                var next = toolMessages
                let body: [String: Any] = [
                    "ok": false,
                    "message": "Missing required params for \(call.name): \(missing.joined(separator: ", ")). Fill them in and call again."
                ]
                var failMsg = ChatMessage(role: "tool", content: Self.jsonString(body), isError: true,
                                          toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
                failMsg.toolArgs = Self.summarizeArgs(call.arguments)
                next.append(failMsg)
                self.appendToCurrent(failMsg)   // 对话可见（缺参步骤卡）
                self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                      config: config, tools: tools, disclosed: disclosed, depth: depth,
                                      reasoningLevel: reasoningLevel, thinkText: thinkText, personaPrompt: personaPrompt)
                return
            }
            self.paramCorrectionCount = 0
        }
        // v2.9.34：展示"正在执行工具 xxx…"
        self.runningTool = call.name
        // v3.5.10：工具启动即上屏一张 running 步骤卡（机制保证每步可见，不依赖模型解说）。
        // 先把真实工具名+命令+解说(若有)做成 isRunning=true 的占位卡立即上屏；
        // 结果回来后在 handleDispatchResult 原地更新成完成/出错卡（同一张，不新增第二条）。
        do {
            var runMsg = ChatMessage(role: "tool", content: "", toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            runMsg.toolArgs = Self.summarizeArgs(call.arguments)
            let nar = thinkText.trimmingCharacters(in: .whitespacesAndNewlines)
            runMsg.toolNarration = nar.isEmpty ? nil : thinkText
            runMsg.isRunning = true
            self.appendToCurrent(runMsg)
            self.pendingToolMsgIDs[call.id] = runMsg.id
            // fix73j-p5b：锚定占位卡所在会话（resolve 不依赖 activeConvIndex，防 UI 切换漂移）
            if let ci = self.activeConvIndex { self.pendingToolConvIDs[call.id] = self.conversations[ci].id }
            self.diag("APPEND-PLACEHOLDER: call=\(call.id) conv=\(self.activeConvIndex.map { self.conversations[$0].id.uuidString } ?? "nil")")
        }
        // v3.3.4：记录工具执行耗时（UI 气泡显示，对齐 OpenMinis 步骤耗时样式）
        let toolStart = CFAbsoluteTimeGetCurrent()
        // v2.9.127：轨迹——单工具开始执行 (参数序列化展示）
        self.trailStep(.running(.tool, call.name, detail: Self.jsonString(params)))
        do {
            // v2.9.29：工具执行放后台线程，避免注入/文件操作等耗时调用阻塞主线程
            //  (授权恢复后Run injection导致一直转圈 + 聊天框/输入框无响应）。
            // dispatch 在后台执行，结果/授权/错误统一回主线程继续递归。
            DispatchQueue.global().async {
                let result: Result<[String: Any], Error>
                // 2026-11-03：崩溃现场留痕——工具是崩溃高发区（越狱环境下权限/内存问题多），
                // 记下「正在跑哪个工具」，崩了就知道是哪个工具带崩的。
                CrashBreadcrumb.shared.mark("工具执行 → \(call.name)")
                do { result = .success(try ToolRegistry.shared.dispatch(name: call.name, params: params)) }
                catch { result = .failure(error) }
                CrashBreadcrumb.shared.mark("工具结束 ← \(call.name)")
                let toolDuration = CFAbsoluteTimeGetCurrent() - toolStart
                DispatchQueue.main.async {
                    self.runningTool = nil
                    self.handleDispatchResult(result, call: call, calls: calls, index: index,
                                              toolMessages: toolMessages, newlyDisclosed: newlyDisclosed,
                                              config: config, tools: tools,
                                              disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                              thinkText: thinkText, toolDuration: toolDuration, personaPrompt: personaPrompt)
                }
            }
        }
    }

    /// v7.1.106：真并行执行只读工具批（DispatchGroup）。
    /// 语义对齐串行路径但并发：schema 预校验（缺参生成错误消息、位置保留）→ 全部工具并发执行 →
    /// 主线程按原序回填 tool 消息 → 一次性回模型。UI：每工具一张 running 卡（多槽 pendingToolMsgIDs），
    /// 完成后原地更新。线程安全：dispatch 内部可变字典已由 ToolRegistry.stateLock 串行化，
    /// 本函数只收集结果（resultsLock 保护），UI 操作全部在主线程。
    private func processToolCallsParallel(_ calls: [ToolCall],
                                          toolMessages: [ChatMessage],
                                          newlyDisclosed: [String],
                                          config: ModelConfig,
                                          tools: [[String: Any]]?,
                                          disclosed: [String],
                                          depth: Int,
                                          reasoningLevel: Int,
                                          thinkText: String,
                                          personaPrompt: String?) {
        // 0) schema 预校验：缺必填参的 call 不执行，生成错误 tool 消息占位（顺序保留，v7.1.101 语义）
        var preErrors: [Int: ChatMessage] = [:]
        for (i, call) in calls.enumerated() {
            if let schema = ToolRegistry.shared.openAISchema(for: call.name),
               let fn = schema["function"] as? [String: Any],
               let ps = fn["parameters"] as? [String: Any],
               let required = ps["required"] as? [String] {
                let params = Self.parseArgs(call.arguments)
                let missing = required.filter { params[$0] == nil }
                if !missing.isEmpty && self.paramCorrectionCount < 2 {
                    self.paramCorrectionCount += 1
                    let body: [String: Any] = [
                        "ok": false,
                        "message": "Missing required params for \(call.name): \(missing.joined(separator: ", ")). Fill them in and call again."
                    ]
                    var failMsg = ChatMessage(role: "tool", content: Self.jsonString(body), isError: true,
                                              toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
                    failMsg.toolArgs = Self.summarizeArgs(call.arguments)
                    preErrors[i] = failMsg
                }
            }
        }
        // 1) 每工具上屏一张 running 卡（主线程；结果回来后在原地更新成完成/出错卡）
        self.runningTool = calls.first?.name
        let nar = thinkText.trimmingCharacters(in: .whitespacesAndNewlines)
        for call in calls {
            var runMsg = ChatMessage(role: "tool", content: "", toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            runMsg.toolArgs = Self.summarizeArgs(call.arguments)
            runMsg.toolNarration = nar.isEmpty ? nil : thinkText
            runMsg.isRunning = true
            self.appendToCurrent(runMsg)
            self.pendingToolMsgIDs[call.id] = runMsg.id
            // fix73j-p5b：锚定占位卡所在会话（resolve 不依赖 activeConvIndex，防 UI 切换漂移）
            if let ci = self.activeConvIndex { self.pendingToolConvIDs[call.id] = self.conversations[ci].id }
            self.diag("APPEND-PLACEHOLDER: call=\(call.id) conv=\(self.activeConvIndex.map { self.conversations[$0].id.uuidString } ?? "nil")")
        }
        self.trailStep(.running(.tool, "并行执行一批工具", detail: calls.map { $0.name }.joined(separator: "、")))
        // 2) 分波并发执行（v7.1.108-minis：全执行不截断，≤4 个一波自动续，等价 OpenMinis
        // in-flight 排队；结果按 (index, result, duration) 收集，最终按原序回填）
        let allIndices = calls.indices.filter { preErrors[$0] == nil }
        let step = 4
        var collected: [(index: Int, result: Result<[String: Any], Error>, duration: Double)] = []
        let resultsLock = NSLock()

        func runWave(_ indices: [Int]) {
            guard !indices.isEmpty else {
                // 3) 全部完成 → 主线程按原序合并 tool 消息（与 assistant toolCalls 顺序一致），一次性回模型
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.runningTool = nil
                    var next = toolMessages
                    for (i, call) in calls.enumerated() {
                        if let pre = preErrors[i] {
                            // 缺参：错误消息直接进序列（toolCallId 匹配，序列始终完整合法），并更新对应 running 卡
                            next.append(pre)
                            self.resolvePendingTool(callId: call.id, content: pre.content, toolDuration: 0, isError: true, narration: nil)
                            self.trailStep(.done(.note, "工具缺少参数",
                                                 detail: "\(call.name) missing required params", ok: false))
                            continue
                        }
                        let entry = collected.first { $0.index == i }
                        let r = entry?.result ?? .failure(MCPError.failed("parallel tool result missing for \(call.name)"))
                        next = self.applyParallelResult(r, call: call, toolMessages: next,
                                                        toolDuration: entry?.duration ?? 0, thinkText: thinkText)
                    }
                    // 2026-11-06 **熔断检查放在这里**，不放 applyParallelResult 里面。
                    // 原因：并行批在 API 协议上要求「assistant 的 N 条 toolCalls 必须配 N 条
                    // tool 结果」，中途 return 会留下半截序列，请求直接被拒。
                    // 现在所有结果都已按原序回填 → 序列完整 → 此时停手是安全的。
                    if self.consecutiveSameToolFailures >= 3 {
                        self.stopForRepeatedToolFailure()
                        return
                    }
                    let merged = Array(Set(disclosed + newlyDisclosed))
                    self.runLoop(config: config, tools: tools, disclosed: merged, depth: depth + 1,
                                 reasoningLevel: reasoningLevel, personaPrompt: personaPrompt)
                }
                return
            }
            let wave = Array(indices.prefix(step))
            let rest = Array(indices.dropFirst(step))
            let group = DispatchGroup()
            for i in wave {
                let call = calls[i]
                group.enter()
                DispatchQueue.global().async {
                    let start = CFAbsoluteTimeGetCurrent()
                    let r: Result<[String: Any], Error>
                    do { r = .success(try ToolRegistry.shared.dispatch(name: call.name, params: Self.parseArgs(call.arguments))) }
                    catch { r = .failure(error) }
                    let duration = CFAbsoluteTimeGetCurrent() - start
                    resultsLock.lock()
                    collected.append((i, r, duration))
                    resultsLock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                // fix73j-审计 M-14：停止后重发竞态——若停止（stopRequested）后旧 wave 完成，
                // 不 guard 会继续递归 runWave(rest) 执行剩余工具包，与新请求的双 runLoop 并发错乱。
                guard let self = self, !self.stopRequested else { return }
                runWave(rest)
            }
        }
        runWave(allIndices)
    }

    /// v7.1.106：并行批的单条工具结果处理（三分支与 handleDispatchResult 一致，但非递归——
    /// 只返回更新后的 toolMessages，由 processToolCallsParallel 主线程循环按原序调用）。
    @discardableResult
    private func applyParallelResult(_ result: Result<[String: Any], Error>,
                                     call: ToolCall,
                                     toolMessages: [ChatMessage],
                                     toolDuration: Double,
                                     thinkText: String) -> [ChatMessage] {
        switch result {
        case .success(let r):
            let rawContent = Self.jsonString(r)
            let content: String
            // v7.2.3-fix25：同上——并行批路径同步提升到 48000
            if rawContent.count > 48000 {
                content = rawContent.prefix(48000) + "\n... [tool result truncated, total \(rawContent.count) chars. For full data, call the tool with params like limit/filter/query to narrow the range.]"
            } else {
                content = rawContent
            }
            var next = toolMessages
            var toolMsg = ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            toolMsg.toolArgs = Self.summarizeArgs(call.arguments)
            toolMsg.toolDuration = toolDuration
            toolMsg.toolNarration = thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : thinkText
            next.append(toolMsg)
            self.resolvePendingTool(callId: call.id, content: content, toolDuration: toolDuration, isError: false, narration: toolMsg.toolNarration)
            self.trailStep(.done(.result, call.name, detail: Self.trailSummary(rawContent), ok: true))
            // 2026-11-06：并行路径也要记成功（否则一批里先失败后成功会把失败计数留住）
            self.registerToolSuccess(call: call)
            return next
        case .failure(let err as MCPError):
            var next = toolMessages
            let failureBody: [String: Any]
            if case MCPError.classified(let m, let code, let reason, let nextStep) = err {
                failureBody = ["ok": false, "message": m,
                               "error": ["code": code, "reason": reason, "next_step": nextStep]]
            } else {
                failureBody = ["ok": false, "message": err.description]
            }
            let content = Self.jsonString(failureBody)
            var failMsg = ChatMessage(role: "tool", content: content, isError: true, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            failMsg.toolDuration = toolDuration
            next.append(failMsg)
            self.resolvePendingTool(callId: call.id, content: content, toolDuration: toolDuration, isError: true, narration: nil)
            self.trailStep(.done(.result, call.name, detail: Self.trailSummary(content), ok: false))
            // 2026-11-06：登记失败（不在这里停——停机判断在本批全部结果合并后统一做）
            _ = self.registerToolFailure(call: call, errorText: err.description)
            return next
        case .failure(let err):
            var next = toolMessages
            let errStr = err.localizedDescription.lowercased()
            var reason = "Tool execution failed"
            var nextStep = "Check the error message above. Try a different approach or tool."
            if errStr.contains("not found") || errStr.contains("no such file") {
                reason = "File or path does not exist"
                nextStep = "Check path with shell.exec. If app container, verify bundle_id."
            } else if errStr.contains("refused") || errStr.contains("connection") || errStr.contains("unreachable") {
                reason = "Target app or service not reachable"
                nextStep = "Start the target app first, or check if injection is active (injection.status)."
            } else if errStr.contains("permission") || errStr.contains("denied") {
                reason = "Permission denied"
                nextStep = "Check tool permissions in settings, or use a different approach."
            } else if errStr.contains("required") || errStr.contains("invalid") {
                reason = "Missing or wrong parameter"
                nextStep = "Check tool parameters. Required params are marked (REQUIRED) in the tool description."
            } else if errStr.contains("timeout") {
                reason = "Operation timed out"
                nextStep = "Try again with longer timeout, or check if the app is responsive."
            }
            let errBody: [String: Any] = [
                "ok": false,
                "tool": call.name,
                "error": err.localizedDescription,
                "reason": reason,
                "next_step": nextStep
            ]
            var errMsg = ChatMessage(role: "tool", content: Self.jsonString(errBody),
                                    isError: true, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            next.append(errMsg)
            self.resolvePendingTool(callId: call.id, content: Self.jsonString(errBody), toolDuration: toolDuration, isError: true, narration: nil)
            self.trailStep(.done(.result, call.name, detail: "❌ \(err.localizedDescription.prefix(200))", ok: false))
            // 2026-11-06：登记失败（停机判断在本批合并后统一做）
            _ = self.registerToolFailure(call: call, errorText: err.localizedDescription)
            return next
        }
    }

    /// v2.9.29：在主线程处理一次工具执行结果，然后继续递归调用链
    /// v2.9.31：去掉授权弹窗分支 (工具搜索即自动授权，无需暂停等待用户选择）。
    private func handleDispatchResult(_ result: Result<[String: Any], Error>,
                                      call: ToolCall, calls: [ToolCall], index: Int,
                                      toolMessages: [ChatMessage], newlyDisclosed: [String],
                                      config: ModelConfig, tools: [[String: Any]]?,
                                      disclosed: [String], depth: Int, reasoningLevel: Int,
                                      thinkText: String = "", toolDuration: Double = 0,
                                      personaPrompt: String? = nil) {
        switch result {
        case .success(let r):
            let rawContent = Self.jsonString(r)
            // v2.9.49：工具结果截断 (>8000字符），防止单条工具结果 (如 browser.snapshot / injection.list）
            // 撑爆上下文导致后续请求巨慢。截断后加提示，模型可调用带分页/过滤参数的工具获取完整数据。
            let content: String
            // v7.2.3-fix25：同上——并行批路径同步提升到 48000
            if rawContent.count > 48000 {
                content = rawContent.prefix(48000) + "\n... [tool result truncated, total \(rawContent.count) chars. For full data, call the tool with params like limit/filter/query to narrow the range.]"
            } else {
                content = rawContent
            }
            var next = toolMessages
            var toolMsg = ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            // v3.1.26：存参数摘要，UI 里用特殊颜色显示
            toolMsg.toolArgs = Self.summarizeArgs(call.arguments)
            // v3.3.4：耗时显示
            toolMsg.toolDuration = toolDuration
            // v3.5.8：存解说（模型写的"先解说后执行"正文）到工具消息——Minis 式工具卡当步骤标题
            toolMsg.toolNarration = thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : thinkText
            // v3.1.72：不再写 toolMsg.thinking——思考已在 assistant 消息的 thinking 字段显示一次，
            // 旧逻辑把同一文本又塞进 tool 消息导致"回复内容和思考内容一模一样" (用户实测反馈）
            next.append(toolMsg)
            // v3.5.10：原地更新"启动即上屏"的 running 步骤卡 → 完成卡（同一张，不再新增第二条）
            self.resolvePendingTool(callId: call.id, content: content, toolDuration: toolDuration, isError: false, narration: toolMsg.toolNarration)
            // v2.9.127：轨迹——工具执行OK (结果摘要 200 字符，完整结果在 tool 消息里）
            self.trailStep(.done(.result, call.name,
                                 detail: Self.trailSummary(rawContent),
                                 ok: true))
            // 2026-11-06：成功一次就说明没卡死 → 工具失败熔断状态清零
            self.registerToolSuccess(call: call)
            var nextDisclosed = newlyDisclosed
            // v3.1.66：tool_search 已删除，全量加载所有工具，无需披露机制。
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: nextDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText, personaPrompt: personaPrompt)
        case .failure(let err as MCPError):
            // v2.9.125：failed也输出结构化 JSON (对齐 CLI 返回协议），AI 可直接解析分类与下一步
            var next = toolMessages
            let failureBody: [String: Any]
            if case MCPError.classified(let m, let code, let reason, let nextStep) = err {
                failureBody = ["ok": false, "message": m,
                               "error": ["code": code, "reason": reason, "next_step": nextStep]]
            } else {
                failureBody = ["ok": false, "message": err.description]
            }
            let content = Self.jsonString(failureBody)
            var failMsg = ChatMessage(role: "tool", content: content, isError: true, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            // v3.1.72：不再写 failMsg.thinking (思考只在 assistant 消息显示一次，避免重复）
            // v3.3.4：耗时显示
            failMsg.toolDuration = toolDuration
            next.append(failMsg)
            // v3.5.10：原地更新 running 步骤卡 → 出错卡
            self.resolvePendingTool(callId: call.id, content: content, toolDuration: toolDuration, isError: true, narration: nil)
            // v2.9.127：轨迹——工具执行failed (四分类错误摘要）
            self.trailStep(.done(.result, call.name,
                                 detail: Self.trailSummary(Self.jsonString(failureBody)),
                                 ok: false))
            // 2026-11-06：登记失败。**这里不停手**——停机统一在「批耗尽出口」判断，
            // 否则会中断本批剩余调用，留下 toolCalls/结果不配对的非法序列。
            _ = self.registerToolFailure(call: call, errorText: err.description)
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText, personaPrompt: personaPrompt)
        case .failure(let err):
            var next = toolMessages
            // v3.0.77：智能错误诊断——AI 看到错误就知道为什么failed、下一步该做什么
            let errStr = err.localizedDescription.lowercased()
            var reason = "Tool execution failed"
            var nextStep = "Check the error message above. Try a different approach or tool."
            if errStr.contains("not found") || errStr.contains("no such file") {
                reason = "File or path does not exist"
                nextStep = "Check path with shell.exec or shell.exec. If app container, verify bundle_id."
            } else if errStr.contains("refused") || errStr.contains("connection") || errStr.contains("unreachable") {
                reason = "Target app or service not reachable"
                nextStep = "Start the target app first, or check if injection is active (injection.status)."
            } else if errStr.contains("permission") || errStr.contains("denied") {
                reason = "Permission denied"
                nextStep = "Check tool permissions in settings, or use a different approach."
            } else if errStr.contains("required") || errStr.contains("invalid") {
                reason = "Missing or wrong parameter"
                nextStep = "Check tool parameters. Required params are marked (REQUIRED) in the tool description."
            } else if errStr.contains("timeout") {
                reason = "Operation timed out"
                nextStep = "Try again with longer timeout, or check if the app is responsive."
            }
            let errBody: [String: Any] = [
                "ok": false,
                "tool": call.name,
                "error": err.localizedDescription,
                "reason": reason,
                "next_step": nextStep
            ]
            var errMsg = ChatMessage(role: "tool", content: Self.jsonString(errBody),
                                    isError: true, toolCallId: call.id, toolName: call.name, toolTitle: call.toolTitle)
            // v3.1.72：不再写 errMsg.thinking (思考只在 assistant 消息显示一次，避免重复）
            next.append(errMsg)
            // v3.5.10：原地更新 running 步骤卡 → 出错卡
            self.resolvePendingTool(callId: call.id, content: Self.jsonString(errBody), toolDuration: toolDuration, isError: true, narration: nil)
            self.trailStep(.done(.result, call.name,
                                 detail: "❌ \(err.localizedDescription.prefix(200))",
                                 ok: false))
            // 2026-11-06：同上——只登记，停机统一在「批耗尽出口」判断（保住序列配对）
            _ = self.registerToolFailure(call: call, errorText: err.localizedDescription)
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText, personaPrompt: personaPrompt)
        }
    }

    /// 2026-11-06 工具失败登记 —— 返回 true 表示「同一个动作已经连续失败到该停手」。
    ///
    /// 用户实测的一句话是「现在有二个出错了，但是他还没停止工作呢」：
    /// 界面连出两张红卡，模型还在往下跑。根因是这里**根本没有失败计数**：
    /// 失败只是变成一条 error tool 消息回模型，模型换个写法继续试，
    /// 于是错误卡一张接一张，而整轮永远不会自己停。
    ///
    /// 为什么不按「本轮失败总数」停：会误伤。
    /// 实测过的正常场景——模型先调 `device.probe` 失败、再换 `shell.exec` 失败、
    /// 第三把用 `system.exec_root` 成功。三次「失败两次」，但活儿在推进。
    /// 所以只认**同一个工具 + 同一份参数**的连续失败：换了目标就清零，成功更清零。
    /// 这样「正常试错」永远够不着阈值，只有真正在原地撞墙才会触发。
    private func registerToolFailure(call: ToolCall, errorText: String) -> Bool {
        let sig = call.name + "|" + call.arguments
        if sig == lastFailedToolSignature {
            consecutiveSameToolFailures += 1
        } else {
            lastFailedToolSignature = sig
            consecutiveSameToolFailures = 1
        }
        lastFailedToolName = call.name
        lastFailedToolArgs = Self.summarizeArgs(call.arguments)
        lastFailedToolError = errorText
        toolFailuresThisTurn += 1
        diag("TOOL-FAIL: \(call.name) same=\(consecutiveSameToolFailures) total=\(toolFailuresThisTurn) err=\(errorText.prefix(160))")
        return consecutiveSameToolFailures >= 3
    }

    /// 工具成功 → 熔断状态清零（任何一次成功都说明它没卡死）。
    private func registerToolSuccess(call: ToolCall) {
        if !lastFailedToolSignature.isEmpty {
            diag("TOOL-OK: \(call.name) → failure streak reset (was \(consecutiveSameToolFailures))")
        }
        lastFailedToolSignature = ""
        consecutiveSameToolFailures = 0
    }

    /// 熔断收尾：说清「卡在哪 / 试了几次 / 为什么停 / 下一步怎么办」，然后结束本轮。
    /// 刻意不用静默 return —— 用户 2026-11-03 就抱怨过「不知道怎么就停止了，也没有原因」。
    ///
    /// 用存下来的 lastFailed* 而不是传参：并行批要等所有结果合并后才统一判断
    /// （中途 return 会留下「assistant 带了 N 条 toolCalls 却只有部分 tool 结果」的非法序列）。
    private func stopForRepeatedToolFailure() {
        let n = consecutiveSameToolFailures
        let toolName = lastFailedToolName.isEmpty ? "该工具" : lastFailedToolName
        let errorText = lastFailedToolError
        let argsPreview = lastFailedToolArgs
        trailStep(.done(.note, "已停止：同一动作反复失败",
                        detail: "\(toolName) 连续 \(n) 次同样失败，参数一字未改", ok: false))
        Self.reportStop(
            to: self,
            title: "AI 停下了：同一个工具反复失败",
            body: """
            它连续 \(n) 次调用 **\(toolName)**，参数一字未改，每次都是同样的错误，\
            所以停在这里 —— 再试下去只会重复烧掉额度。

            最后一次的错误：
            \(errorText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))

            参数：
            \(argsPreview.isEmpty ? "（无）" : argsPreview)

            这通常意味着：
            1. 工具名或参数写错了（工具名必须一字不差，可以问我「有哪些工具」）
            2. 这件事本机确实做不到（比如缺某个系统权限、或目标 App 没开）
            3. 网络/服务端问题（超时、取不到文件）

            建议直接说一句「别试了，说说你卡在哪」，它会把卡点讲出来；
            或者换个说法把要求讲得更具体一点再发一次。
            """,
            reason: "工具 \(toolName) 连续 \(n) 次同样失败")
        lastFailedToolSignature = ""
        consecutiveSameToolFailures = 0
        lastFailedToolName = ""
        lastFailedToolArgs = ""
        lastFailedToolError = ""
        activeConvId = nil
    }

    /// v3.5.10：工具结果回来后，原地更新"启动即上屏"的 running 步骤卡（同一张卡变完成/出错）。
    /// v7.1.106：按 toolCallId 定位多槽（真并行批每工具一张卡），完成后移除该槽。
    private func resolvePendingTool(callId: String, content: String, toolDuration: Double, isError: Bool, narration: String?) {
        guard let mid = self.pendingToolMsgIDs[callId] else {
            self.diag("RESOLVE-FAIL: no pendingToolMsgID call=\(callId)")
            self.pendingToolMsgIDs.removeValue(forKey: callId)
            return
        }
        // fix73j-p5b：会话锚定——优先 append 时记录的 convId，兜底 activeConvIndex
        //（activeConvIndex 会随 UI 切换漂移，漂移时找不到占位卡 → 不落盘 → 重启误判失败）
        var convId = self.pendingToolConvIDs[callId]
        if convId == nil, let ci = self.activeConvIndex { convId = self.conversations[ci].id }
        guard let cid = convId else {
            self.diag("RESOLVE-FAIL: no convId call=\(callId)")
            self.pendingToolMsgIDs.removeValue(forKey: callId)
            return
        }
        self.diag("RESOLVE: call=\(callId) conv=\(cid.uuidString) mid=\(mid.uuidString) contentLen=\(content.count) isErr=\(isError)")
        // fix73j-p5：统一变更入口——自动标 dirty + 同步 flush（isRunning=false/结果内容
        // 立即落盘；p3e 根因：裸改不标 dirty 时 persist 增量不写任何行，杀后台重启误判失败）。
        let ok = self.updateMessage(in: cid, msgId: mid) { msg in
            msg.content = content
            msg.toolDuration = toolDuration
            msg.isError = isError
            msg.isRunning = false
            if let n = narration, !n.isEmpty {
                msg.toolNarration = n
            }
        }
        self.diag("RESOLVE-DONE: call=\(callId) updated=\(ok)")
        self.pendingToolMsgIDs.removeValue(forKey: callId)
        self.pendingToolConvIDs.removeValue(forKey: callId)
    }

    /// v2.9.138：动态会话状态块——设备/App/工作区/当前会话，injected system 最前
    ///  (位于稳定块之后，最新状态放最后）。让 AI 始终感知当前环境，不靠猜。
    ///
    /// 2026-11-05 **必须传入请求所属会话 ID**：
    /// 「当前会话标题」和「自动提取的上下文」都跟会话有关。
    /// 原来前者读 `shared.selectedIndex`（用户切窗口期间会漂移），
    /// 后者读全局单例（跨会话污染），两者叠加就是用户看到的
    /// 「我在第二个会话问去广告，它去干第一个会话的活」。
    private static func dynamicStatePrompt(sessionId: UUID?) -> String {
        var device = "iPhone"
        var os = ""
        #if canImport(UIKit)
        device = UIDevice.current.model
        os = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        #endif
        var appVer = ""
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { appVer = v }
        var parts = ["[Current env] device: \(device)\(os.isEmpty ? "" : " · \(os)")"]
        if !appVer.isEmpty { parts.append("App: All-in-One AI Assistant \(appVer)") }
        parts.append("Workspace: \(Workspace.root.path)")
        // 2026-11-05：按 sessionId 找标题，不再读 selectedIndex（切会话时它会漂）
        if let sid = sessionId,
           let conv = ConversationStore.shared.conversations.first(where: { $0.id == sid }) {
            parts.append("Current conversation: \(conv.title)")
        }
        // v3.1.5: 自动提取的关键信息 (App 名、bundle id、文件路径等）
        // 2026-11-05：**只取本会话的**，别的会话提到过什么都不算。
        if let hint = AutoContextExtractor.shared.contextHint(sessionId: sessionId) {
            parts.append(hint)
        }
        return parts.joined(separator: " | ")
    }

    /// v4.3.71：返回 (messages, compactSource, droppedCount) —— compactSource 是被裁掉的旧消息原文，
    /// 供 OpenAIClient 在发送主请求前交给模型生成结构化摘要 (LLM Compaction)。
    /// v7.1.41：旧摘要（[Long-conversation summary 前缀）单独拎出——不参与裁剪、永远保留在结果最前；
    /// 压缩时旧摘要作为 compactSource 的第一条输入（增量演进：合并更新而非重复压缩）。
    /// v7.1.109-peers：分档预算（OpenMinis ContextPolicy）+ 校准系数（calibration ratio）。
    private func messagesForAPI(budget: Int) -> (messages: [ChatMessage], compactSource: [ChatMessage], droppedCount: Int) {
        // fix73j-审计 M-15：请求上下文绑定"请求发起时会话"（requestSessionId ?? activeConvId），
        // 而非 selectedIndex（用户切会话窗口期间 selectedIndex 已漂移而 requestSessionId 未变）——
        // 否则读 selectedIndex 的上下文、写 activeConvIndex 的结果 → 切会话窗口跨会话污染/答非所问。
        var all: [ChatMessage]
        // v7.1.267-audit6：isError 过滤改为"只滤非工具消息"——工具失败消息（role=tool,
        // isError=true，含 classify 的 reason/next_step）必须发给 AI，否则模型下一轮看不到
        // 失败原因（只剩 repairDanglingToolCalls 补的占位），会盲试重调同一工具（死循环）。
        // 非工具 isError（报错回复/系统错误卡）照旧过滤（不污染 AI 上下文）。
        if let rid = requestSessionId ?? activeConvId, let i = conversations.firstIndex(where: { $0.id == rid }) {
            all = conversations[i].messages.filter { !($0.isError && $0.role != "tool") }
        } else {
            all = currentMessages.filter { !($0.isError && $0.role != "tool") }
        }
        // fix73j-审计：子代理状态卡消息的 API 序列安全化——
        // 子代理完成/派发时机完全随机，若状态卡(user)原样插在 assistant(tool_calls) 与 tool 结果
        // 之间，API 报 "tool message must follow a message with tool_calls" 400（实测风险）。
        // ① [SUBAGENT-RUNNING]（toolName=subagent.running）完全过滤：纯 UI 状态卡，
        //   主 agent 自己派发的任务无需看到运行中 JSON（省上下文、防误导）；
        // ② [SUBAGENT-DONE]（toolName=subagent.complete）移到序列末尾：回传通道保留
        //   （user 消息结尾合法，主 agent 必然看到结果），且绝不落在 tool_calls/tool 之间。
        let doneCards = all.filter { $0.toolName == "subagent.complete" }
        all = all.filter { $0.toolName != "subagent.complete" && $0.toolName != "subagent.running" } + doneCards
        guard !all.isEmpty else { return ([], [], 0) }
        var priorSummary: ChatMessage?
        if let i = all.firstIndex(where: { $0.role == "system" && $0.content.hasPrefix("[Long-conversation summary") }) {
            priorSummary = all.remove(at: i)
        }
        // v2.9.138：工具结果修剪 (Claude Code Precision Forgetting Layer 1）——
        // 非最近 3 条 tool 消息、内容 > 300 字符的旧工具结果替换为紧凑占位符。
        // 零 LLM 成本回收上下文：AI 需要细节时可重新调用该工具。
        // v3.1.68：阈值 300 → 2000 (AI 实测"377 字符不该被截"属实，小结果不再替换）；
        // 替换时保留原内容前 500 字符 ("截空看不到主体"根因——占位符不再整条顶替，
        // 且后续预算裁剪/sanitize 删占位符时头部仍在，AI 不至于完全失去线索）。
        let toolIdx = all.enumerated().filter { $0.element.isTool }.map { $0.offset }
        let keepTool = Set(toolIdx.suffix(3))
        for (i, m) in all.enumerated() where m.isTool && !keepTool.contains(i) && m.content.count > 2000 {
            var nm = m
            let toolName = m.toolName ?? "tool"
            let head = String(m.content.prefix(500))
            nm.content = "[Tool result trimmed: \(toolName), original \(m.content.count) chars, head below]\n\(head)\n…for the full result re-call the tool with limit=20000 or full=true"
            all[i] = nm
        }
        // v7.1.109-peers：分档压缩线（OpenMinis ContextPolicy 借鉴）+ 校准系数——
        // compactLine = 窗口按档位减余量（<32K=0 硬停档；32-128K 减 10K；≥128K 减 20K）；
        // 校准：估算总 token 乘最近真实 usage 的 ratio（clamp 0.5–2.5），防估算器偏差。
        let compactLine = ModelConfig.contextCompactLine(for: budget)
        let ratio = UsageRecorder.shared.lastRealRatio
        // 预算预留 20% 给 tools schema + 系统/开发者指令 + 请求开销（分档线已含余量，0.7→0.8）
        // 2026-11-03：0.8 → 0.85（给上下文多留 5%，配合保底条数提升，减少「AI 忘了前文」）
        let theBudget = max(Int(Double(compactLine) * 0.85), 2000)
        // fix73j-审计 M-12：裁剪基于"非状态卡消息"（core），[SUBAGENT-DONE] 卡
        // （toolName=subagent.complete）永远附加在 result 末尾——若让卡占 suffix(6/2)
        // 保留槽，多子代理完成后用户最新提问/最近轮次被删，主 agent 答非所问。
        // （改名 doneCardsTail：函数上方 fix73j-审计序列安全化处已有 doneCards 同名变量）
        let doneCardsTail = all.filter { $0.toolName == "subagent.complete" }
        let core = all.filter { $0.toolName != "subagent.complete" }
        // 估算总 token（校准后）；低于预算直接返回 (短会话，无需压缩)
        let total = Int(Double(core.reduce(0) { $0 + Self.estimateTokens($1) }) * ratio)
        if total <= theBudget {
            var short = core + doneCardsTail
            if let s = priorSummary { short.insert(s, at: 0) }   // 旧摘要永远保留
            return (short, [], 0)
        }
        // 长会话：从旧到新裁剪，但始终保留最后 N 条核心消息
        // v7.1.109-peers：极限压缩（对齐 OpenMinis 硬停思想但适配 Agent 长任务）——
        // 保底 6 条仍超预算时降为 2 条（只留最新提问），宁可裁到极限也不硬停卡住任务。
        //
        // 2026-11-03 修用户反馈「查看聊天记录不能查看全部，只能查看几条」：
        // 界面其实显示全量，真正被砍的是**发给模型的上下文**——旧逻辑预算吃紧时
        // 保底只留 2 条（相当于只记得最后一问），模型自然「忘了」前面聊过什么，
        // 表现就是「翻了半天记录，它还问你要背景」。
        // 现在：保底从 6 提到 10，极限兜底从 2 提到 4，并把预算预留从 0.8 提到 0.85
        // （分档线本身已含余量，实测不会超发）。
        // P77（2026-11-04）修崩溃：Collection.prefix 负数 trap。
        //
        // 崩溃证据（TrollAgent-2026-11-04-170216.ips，1.0.16 build 17）：
        //   exception = EXC_BREAKPOINT / SIGTRAP, codes = 0x1
        //   调用栈 = specialized Collection.prefix(_:) +108
        //            ← ConversationStore.runLoop(...) +3424
        //            ← ConversationStore.send(...) ← ChatView.send()
        // 用户现象：点发送后 App 直接退出。
        //
        // 根因（两行代码长得像，行为相反）：
        //   suffix(keepMin) 在 core.count < keepMin 时**自动截断**，安全；
        //   prefix(core.count - keepMin) 在同样情况下算出**负数**，
        //   而 Collection.prefix(_:) 有前置条件 maxLength >= 0，
        //   负数 ⇒ Swift 运行时主动 trap ⇒ SIGTRAP（不是野指针，是断言）。
        //
        // 触发条件：消息条数 < 10 但 token 预算已超（少而大的消息，比如粘贴长文/大工具结果）。
        //   此时 total > theBudget 走到这里，core.count=5 就 prefix(-5) 崩了。
        // 复现率低但必崩，且属于「一点发送就退出」这种最伤用户的问题。
        //
        // 修法：把 keepMin 夹到 core.count 以内，保证 core.count - keepMin >= 0。
        //   不用 max(0, ...) 只夹参数，是因为 keepMin 后面还要用于 suffix，
        //   夹 keepMin 本身语义更清楚（「最多保留这么多」）。
        var keepMin = min(10, core.count)
        var suffix = Array(core.suffix(keepMin))
        var prefix = Array(core.prefix(core.count - keepMin))
        var used = suffix.reduce(0) { $0 + Self.estimateTokens($1) }
        if used > theBudget, core.count > 4 {
            // P77 配套：这里 core.count > 4 已经保证 4 不越界（4-4=0 非负），
            // 仍显式夹一次，防止将来把 4 调大或把 >4 的守卫改掉时静默复活同一个 trap。
            keepMin = min(4, core.count)
            suffix = Array(core.suffix(keepMin))
            prefix = Array(core.prefix(core.count - keepMin))
            used = suffix.reduce(0) { $0 + Self.estimateTokens($1) }
        }
        var kept: [ChatMessage] = []
        // 从旧到新累计到「预算 - suffix」内 (v2.9.16：suffix 计入预算，避免超发）
        for m in prefix {
            let t = Self.estimateTokens(m)
            if used + t > theBudget { break }
            kept.append(m)
            used += t
        }
        var result = kept + suffix + doneCardsTail
        // 清理孤立 tool 消息：裁剪可能导致 assistant(tool_calls) 被裁、其 tool 结果残留
        result = Self.sanitizeToolSequence(result)
        // 插入截断提示 (v2.9.88：本地生成话题摘要，而非简单丢弃 —— 不用额外请求，
        // 从被裁消息里提取用户提问/工具名作为"旧会话记忆"，AI 仍能感知上下文主题）
        let dropped = all.count - result.count
        // v4.3.71：被裁旧消息原文交给 LLM Compaction 生成结构化摘要（替换下方启发式摘要）
        // v7.1.41：旧摘要作为 compactSource 的第一条——增量演进（合并更新），而非重复压缩同一堆旧消息
        var compactSource: [ChatMessage] = []
        if dropped > 0 {
            compactSource = Array(all.prefix(dropped))
            if let s = priorSummary { compactSource.insert(s, at: 0) }
        }
        if dropped > 0 {
            let droppedMsgs = compactSource
            var topics: [String] = []
            var toolNames: Set<String> = []
            var idx = 0
            for m in droppedMsgs {
                idx += 1
                if m.role == "tool" { continue }
                if m.role == "system" { continue }   // 旧摘要不参与话题提取
                if let calls = m.toolCalls, !calls.isEmpty {
                    for c in calls {
                        if !c.name.isEmpty {
                            toolNames.insert(c.name)
                        }
                    }
                    if topics.count < 8, idx % 4 == 0 { topics.append("Tool calls") }
                    continue
                }
                if m.role == "user" || m.role == "assistant" {
                    let text = m.content.replacingOccurrences(of: "\n", with: " ")
                    if !text.isEmpty, topics.count < 8 {
                        topics.append(String(text.prefix(24)))
                    }
                }
            }
            var summaryParts: [String] = ["earliest \(dropped) history messages omitted"]
            if !topics.isEmpty {
                summaryParts.append("Topics: " + topics.prefix(6).joined(separator: " / "))
            }
            if !toolNames.isEmpty {
                summaryParts.append("Tools involved: " + toolNames.sorted().prefix(10).joined(separator: ", "))
            }
            summaryParts.append("For old details, just ask — AI will re-run the relevant tools to get them.")
            // v7.1.41：已有旧摘要时不再插启发式占位（send 会直接增量更新旧摘要）
            if priorSummary == nil {
                let hint = ChatMessage(role: "system", content: "[System] " + summaryParts.joined(separator: ". "))
                result.insert(hint, at: 0)
            }
        }
        // v7.1.41：旧摘要永远保留在结果最前（增量演进的基底）
        if let s = priorSummary { result.insert(s, at: 0) }
        return (result, compactSource, dropped)
    }

    // MARK: - v7.1.41 LLM Compaction 持久化（对齐 Claude Code /compact：摘要替换进会话历史，增量演进）

    /// 压缩确认后应用——删除被裁消息、替换/插入摘要 system 消息（破坏性替换，写回并持久化）
    /// v7.1.267-audit：conversationID 绑定"压缩发起时会话"（requestSessionId 快照）——
    /// 摘要回调是异步的，若回调时用户已切会话，旧代码 activeConvIndex 漂移 → 删错会话头部消息
    /// （跨会话污染：用户最新会话的历史被无端删掉）。绑定发起会话后回调写回必然正确。
    func applyCompaction(summary: String, droppedCount: Int, conversationID: UUID? = nil) {
        guard droppedCount > 0 else { return }
        let idx: Int?
        if let cid = conversationID, let i = conversations.firstIndex(where: { $0.id == cid }) {
            idx = i
        } else {
            idx = activeConvIndex ?? selectedIndex
        }
        guard let idx else { return }
        var conv = conversations[idx]
        // 删除头部 droppedCount 条非 error 消息（isError 消息保留不删——与 messagesForAPI 的过滤口径一致）
        var remaining = droppedCount
        var i = 0
        while i < conv.messages.count && remaining > 0 {
            if !conv.messages[i].isError {
                conv.messages.remove(at: i)
                remaining -= 1
            } else {
                i += 1
            }
        }
        let newSummary = "[Long-conversation summary, model-generated]\n" + summary
        if let si = conv.messages.firstIndex(where: { $0.role == "system" && $0.content.hasPrefix("[Long-conversation summary") }) {
            conv.messages[si] = ChatMessage(role: "system", content: newSummary)   // 增量：更新旧摘要
        } else {
            conv.messages.insert(ChatMessage(role: "system", content: newSummary), at: 0)
        }
        conv.updatedAt = Date()
        conversations[idx] = conv
        // v7.4.0-fix68：压缩 = 结构性变更（删头部+插摘要）→ 强制整会话重写。
        // 否则 count 减少走 count<last 重写已覆盖，但"头部全 isError 保留"边缘场景
        // count+1 会走 append 尾部（重复最后一条、摘要丢失）。
        dirtySessions.insert(conv.id)
        sortAndSave()
        // v7.1.109-peers：OpenMinis 压缩后重测借鉴——摘要写回后重算（用校准系数），
        // 仍超窗则提示（防"压缩白做"导致的连环压缩误读）
        if let cfg = ConversationStore.currentModelConfig() {
            let win = cfg.effectiveContextTokens
            let ratio = UsageRecorder.shared.lastRealRatio
            let after = Int(Double(conv.messages.reduce(0) { $0 + Self.estimateTokens($1) }) * ratio)
            if win > 0, after > win {
                self.statusText = "⚠️ 压缩后仍超出窗口(≈\(after)/\(win))——建议新建会话"
            }
        }
    }

    /// v7.1.41：手动压缩当前会话（对齐 Claude Code /compact）——只生成摘要并持久化，不发主请求
    func compactNow(completion: @escaping (Bool, String) -> Void) {
        guard let config = ConversationStore.currentModelConfig() else {
            completion(false, "未找到模型配置")
            return
        }
        let prepared = messagesForAPI(budget: config.effectiveContextTokens)
        guard !prepared.compactSource.isEmpty else {
            completion(false, "会话不长，无需压缩")
            return
        }
        let client = OpenAIClient(config)
        client.summarize(prepared.compactSource) { [weak self] summary in
            DispatchQueue.main.async {
                guard let self else { return }
                if let s = summary, !s.isEmpty {
                    self.applyCompaction(summary: s, droppedCount: prepared.droppedCount)
                    completion(true, "已压缩 \(prepared.droppedCount) 条历史消息")
                } else {
                    completion(false, "摘要生成失败（网络或模型问题），未压缩")
                }
            }
        }
    }

    /// 当前使用的模型配置（最近使用优先，兜底第一个）
    private static func currentModelConfig() -> ModelConfig? {
        let store = ModelStore.shared
        if let id = store.lastUsedConfigId, let c = store.configs.first(where: { $0.id.uuidString == id }) {
            return c
        }
        return store.configs.first
    }

    /// 粗估 token：中文/日文等约 1 字≈1.5 token；ASCII 约 4 字符≈1 token；图片按固定值计
    /// v7.4.0-fix73d：private → internal——SubAgentRunner 多轮折叠复用此估算（子代理 12-30 轮膨胀防护）
    static func estimateTokens(_ m: ChatMessage) -> Int {
        var t = 0
        let content = m.content
        var cjk = 0
        for ch in content.unicodeScalars {
            if (ch.value >= 0x4E00 && ch.value <= 0x9FFF) || (ch.value >= 0x3040 && ch.value <= 0x30FF) || (ch.value >= 0xAC00 && ch.value <= 0xD7AF) {
                cjk += 1
            }
        }
        let ascii = content.count - cjk
        // v2.9.87：CJK 1.5→2.0 保守估算 (中文实际约 1.5~2 token/字），
        // 低估会让请求体超预算 → 中转处理慢。
        t += Int(Double(cjk) * 2.0) + ascii / 3
        t += (m.imageDataURLs?.count ?? 0) * 600   // 每张图约 600 token (低分辨率近似）
        return max(t, 8)
    }

    /// 保证 assistant tool_calls 与其 tool 结果成对存在；删掉孤立的 tool 消息
    private static func sanitizeToolSequence(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var pendingToolCalls = false
        for m in msgs {
            if m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty {
                pendingToolCalls = true
                out.append(m)
            } else if m.role == "tool" {
                // 只有前面有未配对的 assistant tool_calls 才保留 tool 结果
                if pendingToolCalls {
                    out.append(m)
                }
                // 忽略孤立的 tool 消息
            } else {
                pendingToolCalls = false
                out.append(m)
            }
        }
        return out
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    // MARK: - v7.1.99 工具合批分类（只读可合批 / 副作用一次一条）

    /// v7.1.103：shell 只读命令白名单（首词）
    private static let readOnlyShellCmds: Set<String> = [
        "cat", "ls", "find", "grep", "ps", "df", "free", "uname", "echo", "pwd", "which",
        "uptime", "netstat", "ifconfig", "head", "tail", "wc", "du", "date", "env", "printenv",
        "curl", "ping", "mount", "id", "whoami", "sysctl", "defaults", "plutil", "strings",
        "file", "stat", "readlink"
        // v7.1.103：kill 移出白名单——真实副作用(杀进程)，合批语义不成立，应一次一条
    ]

    /// v7.1.103：curl 写文件排除（-o/-O/--output/--download → 副作用，不可合批）
    private static func curlWritesFile(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        return c.contains("-o ") || c.contains("-o\t") || c.contains("--output")
            || c.contains("-o\"") || c.contains(" -o") || c.contains("-O ") || c.contains("--download")
    }

    /// 一批 toolCalls 是否全部可合批（依次执行，不回模型重生成）
    static func isParallelSafeTool(_ calls: [ToolCall]) -> Bool {
        calls.allSatisfy { isParallelSafeTool($0) }
    }

    /// 单个工具是否可合批：只读/查询类（无副作用、互相独立）→ true；
    /// 副作用/写类/未知（inject、app、control、artifact、shell 写命令等）→ false（保持一次一条）
    static func isParallelSafeTool(_ call: ToolCall) -> Bool {
        let name = call.name
        // 纯只读/验证大工具（内部只读 ToolRegistry/Bundle，无共享可变状态）
        // v7.2.1：扩充白名单——web.search/web.fetch/knowledge.search/device.* 等
        // 确定性只读工具加入可合批（此前模型按提示词批量发也会被强制一条条跑，
        // 用户实测"AI 还是一条或两条发命令"）。browser 共享 WebView 仍串行。
        let readOnlyTools: Set<String> = [
            "tools_audit",
            "web_search", "web_fetch", "knowledge_search",
            "device_info", "device_probe"
        ]
        if readOnlyTools.contains(name) { return true }
        // shell_exec：仅【单命令】纯只读命令可并行（ls/cat/grep/ps/find/stat...）。
        // v7.1.107：复合命令（; && || | > >> < 等）无法静态确认只读——例如
        // `ls && rm x`、`cat a | tee out` 首词只读但实际有副作用，并行会互相踩，保守不并行。
        if name == "shell_exec" {
            let cmd = (parseArgs(call.arguments)["command"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cmd.contains(";") || cmd.contains("&&") || cmd.contains("||")
                || cmd.contains("|") || cmd.contains(">") || cmd.contains("<") {
                return false
            }
            let first = cmd.components(separatedBy: .whitespacesAndNewlines).first(where: { !$0.isEmpty }) ?? ""
            let base = first.hasPrefix("-") ? "" : first
            // v7.1.103：env VAR=1 cmd 包装 → 递归判断真实命令（裸 env 列环境变量才只读）
            if base == "env" {
                let after = cmd.components(separatedBy: .whitespacesAndNewlines).dropFirst()
                let realFirst = after.first(where: { !$0.isEmpty && !$0.contains("=") }) ?? ""
                if realFirst.isEmpty { return true }   // 裸 env
                return isShellCmdReadOnly(realFirst, cmd: cmd)
            }
            return isShellCmdReadOnly(base, cmd: cmd)
        }
        // v7.1.107：browser 只读子命令（text/snapshot/status...）共享同一 WebView——
        // 并发 evaluateJavaScript 有导航/状态竞态，保守不并行（一次一条，防闪退优先）
        return false
    }

    /// v7.1.103：shell 首词 + 写特征统一判定（env 包装/curl 写文件共用）
    private static func isShellCmdReadOnly(_ base: String, cmd: String) -> Bool {
        if readOnlyShellCmds.contains(base) {
            // curl 写文件（-o/-O/--output）→ 副作用，不可合批
            if base == "curl" && curlWritesFile(cmd) { return false }
            return true
        }
        // v7.2.3-audit3：sed 无就地写（-i/--in-place）→ 纯只读可合批
        // `sed -n '1,400p' file` / `sed -e 's/x/y/'` 无重定向都只读；-i 就地写拦截。
        // 复合符(;&&|||><)已在前置检查拦截，此处只需防 -i。
        if base == "sed" {
            if cmd.contains("-i") || cmd.contains("--in-place") { return false }
            return true
        }
        // v7.1.102：解释器命令（python3/node/perl/ruby/php/bash -c...）——
        // 合批后依次执行（非并行，副作用有序、依赖可见、错误可恢复），
        // 用脚本内容黑名单兜底：含写/危险 API 特征 → 一次一条，纯只读脚本 → 可合批。
        // v7.1.103：sed/awk 移出——sed -i 就地写/awk 重定向无法静态区分，保守一次一条
        let interpreters: Set<String> = [
            "python3", "python", "node", "perl", "ruby", "php", "bash", "sh", "zsh", "lua", "jq"
        ]
        if interpreters.contains(base) {
            return !scriptHasWriteRisk(cmd)
        }
        return false
    }

    /// v7.1.102：解释器命令脚本内容黑名单——含写/危险特征视为副作用（一次一条），
    /// 纯只读脚本才可合批。保守原则：宁可多几轮往返，不放过写操作。
    static func scriptHasWriteRisk(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        let dangerous: [String] = [
            "open(", "open ", "write", "write_text", "writefile", "remove", "unlink", "rmdir",
            "os.system", "system(", "popen", "subprocess", "exec(", "eval(", "spawn",
            "makedirs", "chmod", "chown", "shutil", "truncate", "replace(", "save", "dump",
            "append", "rm ", "rm -", "mv ", "cp ", "mkdir", "touch ", "touch(", "tee ",
            ">>", "> ", "| tee", "curl -o", "wget -o", "install", "apt", "apk add",
            "pip install", "npm i ", "npm install", "delete", "drop ", "insert into",
            "update ", "alter "
        ]
        return dangerous.contains { c.contains($0) }
    }

    // v2.9.171：工具结果序列化去掉 prettyPrinted → 紧凑 JSON (无缩进空格）。
    private static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func sortAndSave() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    private func title(from text: String) -> String {
        // v2.9.293：剔除附件描述，避免标题变成 "[📎 文件：全局加速+...2.deb]已保存到 /var/..."
        // 用正则兼容 [📎文件：/ [📎 文件：/ 中文冒号/英文冒号 所有变体
        var clean = text
        func stripTag(_ pattern: String) {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let ns = clean as NSString
            let range = NSRange(location: 0, length: ns.length)
            clean = rx.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        stripTag("\\[📎\\s*文件\\s*[：:][^\\]]*\\]")
        stripTag("\\[📱\\s*应用\\s*[：:][^\\]]*\\]")
        // 去掉 "已保存到 <路径>，可用..." 路径描述
        if let r = clean.range(of: "已保存到 ") {
            clean = String(clean[..<r.lowerBound])
        }
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "📎 File" }
        let line = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return String(line.prefix(30))
    }

    // v4.3.66：会话存储从 UserDefaults 全量迁移到独立文件（对齐微信/WCDB：大对象不进
    // UserDefaults 同步 IO；文件原子写 + 备份轮换，编码/写盘放后台串行队列，不阻塞主线程）
    private var storeDir: String {
        let p = NSHomeDirectory().appending("/Documents/Workspace/store")
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private var storeFile: String { storeDir.appending("/conversations.json") }
    private let saveQueue = DispatchQueue(label: "trollmcp2.conversations.save", qos: .utility)

    /// fix73j-p5：持久化核心——save()/flush() 唯一实现（消除 40 行重复）。
    /// sync=true 同步落盘（切后台/工具结果 resolve/编辑等数据安全关键点——杀后台不丢）；
    /// sync=false 走 saveQueue 异步（高频流式更新等——结束兜底由 attachTrail 等 sync 点补）。
    private func persistSnapshot(_ snapshot: [ChatConversation], _ dirty: Set<UUID>, sync: Bool) {
        let dir = storeDir
        let path = storeFile
        var persistOK = false
        let work = {
            // v7.4.0-sessionstore：增量双层优先（JSONL 真源 + SQLite 索引）——
            // 只 append 新消息行 + upsert 索引行，根治全量重写 O(N²)（长会话卡顿）。
            if SessionStore.shared.persist(snapshot: snapshot, dirty: dirty) {
                persistOK = true
                return
            }
            // 失败可降级：回退旧全量 JSON（不丢数据）
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let fm = FileManager.default
            let bak1 = dir.appending("/conversations.bak.1.json")
            let bak2 = dir.appending("/conversations.bak.2.json")
            // 备份轮换：旧 bak1 → bak2，旧主文件 → bak1
            if fm.fileExists(atPath: bak1) {
                try? fm.removeItem(atPath: bak2)
                try? fm.moveItem(atPath: bak1, toPath: bak2)
            }
            if fm.fileExists(atPath: path) {
                try? fm.moveItem(atPath: path, toPath: bak1)
            }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            persistOK = true
        }
        if sync {
            saveQueue.sync(execute: work)
            diag("FLUSH-DONE: dirty=\(dirty.count) persistOK=\(persistOK)")
        } else {
            saveQueue.async(execute: work)
        }
    }

    private func save() {
        // v7.4.0-sessionstore：dirty 快照随 save 清空（主线程独占；队列只读快照）
        let snapshot = conversations
        let dirty = dirtySessions
        dirtySessions.removeAll()
        persistSnapshot(snapshot, dirty, sync: false)
    }

    /// fix73j-p3a：同步落盘当前快照——save() 走 saveQueue.async，用户杀后台（进程直接
    /// 终止）时异步任务被丢弃，盘上残留 isRunning=true 的占位卡，重启 applyLoaded 的
    /// 崩溃恢复逻辑误判"Execution interrupted"把成功结果标失败（用户实测根因）。
    /// 切后台、工具结果 resolve 后必须同步 flush 保结果状态落盘。
    func flush() {
        let snapshot = conversations
        let dirty = dirtySessions
        dirtySessions.removeAll()
        persistSnapshot(snapshot, dirty, sync: true)
    }

    private func decodeFile(_ path: String) -> [ChatConversation]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode([ChatConversation].self, from: data)
    }

    /// - Parameter autoSelect: 是否自动选中第一个会话并打开。
    ///   2026-11-03 新增：崩溃循环自救时传 false——不自动打开上次会话，
    ///   让用户停在会话列表自己选。数据不删，只是不自动进。
    private func applyLoaded(_ decoded: [ChatConversation], autoSelect: Bool = true) {
        diag("LOADED-JSONL: convs=\(decoded.count) msgs=\(decoded.reduce(0) { $0 + $1.messages.count })")
        var convs = decoded.sorted { $0.updatedAt > $1.updatedAt }
        // fix73j-p5：职责拆分——applyLoaded 只做"加载 + 调崩溃恢复"；
        // 崩溃残留标记/悬空序列修补独立为 repairCrashResidue（单一职责，可单测）。
        let cleaned = repairCrashResidue(&convs)
        conversations = convs
        // 2026-11-03：安全模式不自动选中。
        // 以前无条件 `conversations.first?.id`，而列表按 updatedAt 降序 →
        // 第一条正是"刚崩过的那个会话"→ 每次启动都自动重开它 → 再崩 → 被锁在门外。
        selectedId = autoSelect ? conversations.first?.id : nil
        // fix73j-p3f：清理必须固化落盘——旧代码 save() 异步 + 未标 dirty → persist 增量
        // 不写（count 不变），isRunning=false/isError=true 清理结果不落盘，每次启动重复
        // 改写（幂等但无效）。标全部 dirty + 同步 flush，让崩溃恢复结果真正写盘。
        if cleaned {
            for conv in convs { dirtySessions.insert(conv.id) }
            flush()
        }
    }

    /// fix73j-p5：崩溃恢复（v6.1.5-14bp3 原逻辑，独立函数）——App 被系统终止时工具调用卡
    /// "执行中…"且永不返回，重启加载后把残留 running 工具消息标记为中断失败，避免 UI 永远
    /// 挂着无结果；同时修补崩溃残留的非法序列（assistant toolCalls 无配对 tool 结果 →
    /// 后续请求 API 400/挂起）。p3d 误判保护：仅"无内容"残留卡标失败（有内容 = 结果已返回）。
    private func repairCrashResidue(_ convs: inout [ChatConversation]) -> Bool {
        var cleaned = false
        for ci in convs.indices {
            for mi in convs[ci].messages.indices where convs[ci].messages[mi].isRunning {
                convs[ci].messages[mi].isRunning = false
                let c = convs[ci].messages[mi].content
                // fix73j-p3d：误判保护——仅"无内容"的残留 running 卡（真·结果未返回）
                // 才标失败并改写错误提示；有内容的消息 = 结果已返回（即使 isRunning 因
                // 未同步落盘残留），只清 running 不清 isError，保留真实成功结果。
                if c.isEmpty || c == "…" {
                    convs[ci].messages[mi].isError = true
                    let toolName = convs[ci].messages[mi].toolName ?? ""
                    convs[ci].messages[mi].content = "⚠️ Execution interrupted: the app was terminated by the system (crash) while tool \(toolName.isEmpty ? "was running" : "「\(toolName)」was running"). Please resend the command."
                    diag("CRASH-REWRITE: conv=\(convs[ci].id.uuidString) msg=\(convs[ci].messages[mi].id.uuidString) tool=\(toolName) wasEmpty=true")
                } else {
                    diag("CRASH-KEEP: conv=\(convs[ci].id.uuidString) msg=\(convs[ci].messages[mi].id.uuidString) tool=\(convs[ci].messages[mi].toolName ?? "") contentLen=\(c.count) (p3d 保护保留)")
                }
                cleaned = true
            }
            // v7.2.1：崩溃残留非法序列——assistant 带 toolCalls 但对应 tool 结果缺失
            // （崩溃发生在 tool 卡异步写盘前，盘上只剩 assistant toolCalls）。
            // 后续请求把 [assistant(toolCalls), user] 直接发给 API → toolCalls 无配对
            // tool 结果 = 非法序列 → 中转 400 或挂起 → 表现"无论发什么 AI 都不回复"。
            // 补一条中断伪 tool 结果，恢复序列合法（对齐 OpenAI tool_calls 配对约束）。
            // v7.2.3-fix42：修复悬空 toolCalls 必须遍历全部——此前内层/外层两个 break
            // 导致一批多个工具崩溃时（如并发 5 个、web.search 触发 BPT trap 整批结果没写盘）
            // 只补第一个，其余悬空到下一轮请求时才被 repairDanglingToolCalls 补占位符。
            // 仅处理"整批完全缺失"（最常见的崩溃场景）；部分配对的边缘情况由
            // repairDanglingToolCalls 在请求时兜底。先收集再从后往前插入，避免索引位移。
            var fullMissing: [(at: Int, tcs: [ToolCall])] = []
            for mi in convs[ci].messages.indices {
                guard convs[ci].messages[mi].role == "assistant",
                      let tcs = convs[ci].messages[mi].toolCalls, !tcs.isEmpty else { continue }
                let missing = tcs.filter { tc in
                    !convs[ci].messages.contains { $0.role == "tool" && $0.toolCallId == tc.id }
                }
                if !missing.isEmpty && missing.count == tcs.count {
                    fullMissing.append((mi, missing))
                }
            }
            if !fullMissing.isEmpty {
                for (at, tcs) in fullMissing.sorted(by: { $0.at > $1.at }) {
                    // reversed 插入到 at+1，最终顺序与 toolCalls 原序一致
                    for tc in tcs.reversed() {
                        let im = ChatMessage(role: "tool",
                                             content: "⚠️ Tool \(tc.name) execution was interrupted by an app crash; result unavailable. You may retry this tool call.",
                                             isError: true, toolCallId: tc.id, toolName: tc.name)
                        convs[ci].messages.insert(im, at: at + 1)
                    }
                }
                cleaned = true
            }
        }
        return cleaned
    }

    /// v7.4.0-fix71：旧路径（文件/备份/UserDefaults 迁移）——同步、主线程调用；
    /// 原 JSONL 双层优先分支已移入 init 的后台异步（loadAll 全量解码不阻塞主线程）
    private func loadLegacy() {
        let fm = FileManager.default
        // 1. 文件主数据
        if fm.fileExists(atPath: storeFile), let d = decodeFile(storeFile), !d.isEmpty {
            applyLoaded(d); return
        }
        // 2. 文件备份
        for i in 1...2 {
            let bak = storeDir.appending("/conversations.bak.\(i).json")
            if fm.fileExists(atPath: bak), let d = decodeFile(bak), !d.isEmpty {
                applyLoaded(d); save(); return
            }
        }
        // 3. 一次性迁移：旧 UserDefaults 主数据 + 其备份（迁移后写入文件，旧数据保留不删）
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ChatConversation].self, from: data),
           !decoded.isEmpty {
            applyLoaded(decoded); save(); return
        }
        for i in 1...2 {
            if let bak = UserDefaults.standard.data(forKey: key + ".bak.\(i)"),
               let decoded = try? JSONDecoder().decode([ChatConversation].self, from: bak),
               !decoded.isEmpty {
                applyLoaded(decoded); save(); return
            }
        }

        // 从旧版单一会话记录迁移
        if let oldData = UserDefaults.standard.data(forKey: "trollmcp2.transcript"),
           let messages = try? JSONDecoder().decode([ChatMessage].self, from: oldData),
           !messages.isEmpty {
            let first = messages.first!
            let title = String(first.content.prefix(30))
            let conv = ChatConversation(
                title: title,
                createdAt: first.timestamp,
                updatedAt: messages.last?.timestamp ?? Date(),
                messages: messages
            )
            conversations = [conv]
            selectedId = conv.id
            save()
            UserDefaults.standard.removeObject(forKey: "trollmcp2.transcript")
        } else {
            newConversation()
        }
    }
}

// MARK: - 熔断器 (v2.9.107，对齐 cc-switch circuit_breaker 三态机）

enum CircuitState: String {
    case closed = "closed", open = "open", halfOpen = "half_open"
    var label: String {
        switch self {
        case .closed: return "Normal"
        case .open: return "Open (tripped)"
        case .halfOpen: return "Probing"
        }
    }
}

final class CircuitBreaker {
    private let lock = NSLock()
    private var state: CircuitState = .closed
    private var consecutiveFailures = 0
    private var consecutiveSuccesses = 0
    private var totalRequests = 0
    private var failedRequests = 0
    private var lastOpenedAt: Date?
    private var halfOpenRequests = 0

    var failureThreshold = 4          // 连续failed阈值 → Open
    var successThreshold = 2          // HalfOpen OK次数 → Closed
    var timeoutSeconds: TimeInterval = 60  // Open 后多久尝试 HalfOpen
    var errorRateThreshold = 0.6      // 错误率阈值 → Open
    var minRequests = 10              // 计算错误率前最少请求数

    let name: String
    init(name: String) { self.name = name }

    var stateInfo: (state: CircuitState, failures: Int, total: Int, failRate: Double) {
        lock.lock(); defer { lock.unlock() }
        let rate = totalRequests > 0 ? Double(failedRequests) / Double(totalRequests) : 0
        return (state, consecutiveFailures, totalRequests, rate)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        state = .closed
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        totalRequests = 0
        failedRequests = 0
        halfOpenRequests = 0
        lastOpenedAt = nil
    }

    /// 路由可用性判断 (不占 HalfOpen 探测名额）
    func isAvailable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed, .halfOpen:
            return true
        case .open:
            if let opened = lastOpenedAt, Date().timeIntervalSince(opened) >= timeoutSeconds {
                state = .halfOpen
                consecutiveSuccesses = 0
                halfOpenRequests = 0
                return true
            }
            return false
        }
    }

    /// 请求前调用：是否放行 (HalfOpen 限流 1 个探测请求）
    func allowRequest() -> (allowed: Bool, usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed:
            return (true, false)
        case .open:
            if let opened = lastOpenedAt, Date().timeIntervalSince(opened) >= timeoutSeconds {
                state = .halfOpen
                consecutiveSuccesses = 0
                halfOpenRequests = 0
            } else {
                return (false, false)
            }
            if halfOpenRequests < 1 {
                halfOpenRequests += 1
                return (true, true)
            }
            return (false, false)
        case .halfOpen:
            if halfOpenRequests < 1 {
                halfOpenRequests += 1
                return (true, true)
            }
            return (false, false)
        }
    }

    func recordSuccess(usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        if usedHalfOpenPermit, halfOpenRequests > 0 { halfOpenRequests -= 1 }
        consecutiveFailures = 0
        totalRequests += 1
        if state == .halfOpen {
            consecutiveSuccesses += 1
            if consecutiveSuccesses >= successThreshold {
                state = .closed
                consecutiveSuccesses = 0
                totalRequests = 0
                failedRequests = 0
                halfOpenRequests = 0
            }
        }
    }

    func recordFailure(usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        if usedHalfOpenPermit, halfOpenRequests > 0 { halfOpenRequests -= 1 }
        consecutiveFailures += 1
        consecutiveSuccesses = 0
        totalRequests += 1
        failedRequests += 1
        switch state {
        case .halfOpen:
            state = .open
            lastOpenedAt = Date()
            consecutiveFailures = 0
        case .closed:
            if consecutiveFailures >= failureThreshold {
                state = .open
                lastOpenedAt = Date()
                consecutiveFailures = 0
            } else if totalRequests >= minRequests {
                let rate = Double(failedRequests) / Double(totalRequests)
                if rate >= errorRateThreshold {
                    state = .open
                    lastOpenedAt = Date()
                    consecutiveFailures = 0
                }
            }
        case .open:
            break
        }
    }
}

// MARK: - v2.9.126 深链导入暂存 (对齐 cc-switch DeepLinkImportDialog）

/// AppDelegate 收到 trollagent://import?... 后暂存配置，发通知；SwiftUI 层弹确认页。
/// 确认才写入 ModelStore (防误导入），取消即丢弃。
final class PendingImport: ObservableObject {
    static let shared = PendingImport()
    static let didStageNotification = Notification.Name("trollagent.pendingImport.staged")

    @Published var staged: ModelConfig?

    private init() {}

    func stage(_ config: ModelConfig) {
        staged = config
        NotificationCenter.default.post(name: Self.didStageNotification, object: config)
    }

    func confirm() {
        guard let c = staged else { return }
        let ok = ModelStore.shared.importFromDeepLink(c)
        staged = nil
        // 通知 UI 显示结果 (导入OK/已存在重复）
        NotificationCenter.default.post(name: Self.didStageNotification,
                                        object: nil,
                                        userInfo: ["result": ok ? "imported" : "duplicate"])
    }

    func cancel() {
        staged = nil
    }
}
