import Foundation

/// What a model's `config.json` says about its shape. Every field is optional: configs differ between families
/// (vision models nest the language part in `text_config`, some families use their own keys).
public struct ModelSpec: Codable, Hashable, Sendable {
    public var modelType: String?
    public var architectures: [String] = []
    public var layers: Int?
    public var hiddenSize: Int?
    public var kvHeads: Int?
    public var attentionHeads: Int?
    public var headDim: Int?
    public var maxContext: Int?
    public var vocabSize: Int?
    /// Layers that keep a full KV cache in hybrid models (the rest use linear attention).
    public var fullAttentionLayers: Int?
    public var quantBits: Int?
    public var quantGroupSize: Int?
    public var quantMethod: String?
    /// MLX writes its quantization under `quantization`; Hugging Face formats use `quantization_config`.
    public var hasMLXQuantization = false

    public init() {}

    public var isPartial: Bool { layers == nil || hiddenSize == nil || maxContext == nil }

    /// Same value for every copy of one architecture. Also true for a base model and its fine-tunes,
    /// so it only says "probably the same base model".
    public var architectureSignature: String? {
        guard let modelType, let layers, let hiddenSize, let vocabSize else { return nil }
        return "\(modelType)|\(layers)|\(hiddenSize)|\(kvHeads ?? 0)|\(vocabSize)"
    }

    public var kind: ModelKind {
        if architectures.contains(where: { $0.hasSuffix("ForCausalLM") || $0.hasSuffix("ForConditionalGeneration") }) {
            return .languageModel
        }
        return architectures.isEmpty && modelType == nil ? .unknown : .other
    }

    public static func parse(_ data: Data) -> ModelSpec? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let text = root["text_config"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { root[key] ?? text[key] }
        func int(_ key: String) -> Int? { (value(key) as? NSNumber)?.intValue }

        var spec = ModelSpec()
        spec.modelType = root["model_type"] as? String ?? text["model_type"] as? String
        spec.architectures = root["architectures"] as? [String] ?? text["architectures"] as? [String] ?? []
        spec.layers = int("num_hidden_layers")
        spec.hiddenSize = int("hidden_size")
        spec.attentionHeads = int("num_attention_heads")
        spec.kvHeads = int("num_key_value_heads") ?? spec.attentionHeads
        spec.headDim = int("head_dim")
        spec.maxContext = int("max_position_embeddings")
        spec.vocabSize = int("vocab_size")
        if let types = value("layer_types") as? [String] {
            spec.fullAttentionLayers = types.filter { $0 == "full_attention" }.count
        }
        spec.hasMLXQuantization = root["quantization"] is [String: Any]
        let quant = root["quantization"] as? [String: Any] ?? root["quantization_config"] as? [String: Any] ?? [:]
        spec.quantBits = (quant["bits"] as? NSNumber)?.intValue
        spec.quantGroupSize = (quant["group_size"] as? NSNumber)?.intValue
        spec.quantMethod = quant["quant_method"] as? String
        return spec
    }
}

public enum ModelKind: String, Codable, Sendable {
    case languageModel, other, unknown

    public var title: String {
        switch self {
        case .languageModel: "Modèle de langage"
        case .other: "Autre"
        case .unknown: "Inconnu"
        }
    }
}

public enum ModelFormat: String, Codable, Sendable {
    case mlx, safetensors, gguf, unknown

    public var title: String {
        switch self {
        case .mlx: "MLX"
        case .safetensors: "safetensors"
        case .gguf: "GGUF"
        case .unknown: "—"
        }
    }
}
