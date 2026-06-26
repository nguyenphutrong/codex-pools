import Foundation

struct CodexModelPricing {
    struct Price: Equatable {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    private static let prices: [String: Price] = [
        "gpt-5": Price(input: 1.25, output: 10.00, cacheRead: 0.125, cacheWrite: 1.25),
        "gpt-5-mini": Price(input: 0.25, output: 2.00, cacheRead: 0.025, cacheWrite: 0.25),
        "gpt-5-nano": Price(input: 0.05, output: 0.40, cacheRead: 0.005, cacheWrite: 0.05),
        "gpt-4.1": Price(input: 2.00, output: 8.00, cacheRead: 0.50, cacheWrite: 2.00),
        "gpt-4.1-mini": Price(input: 0.40, output: 1.60, cacheRead: 0.10, cacheWrite: 0.40),
        "gpt-4.1-nano": Price(input: 0.10, output: 0.40, cacheRead: 0.025, cacheWrite: 0.10),
        "gpt-4o": Price(input: 2.50, output: 10.00, cacheRead: 1.25, cacheWrite: 2.50),
        "gpt-4o-mini": Price(input: 0.15, output: 0.60, cacheRead: 0.075, cacheWrite: 0.15),
        "o3": Price(input: 2.00, output: 8.00, cacheRead: 0.50, cacheWrite: 2.00),
        "o3-mini": Price(input: 1.10, output: 4.40, cacheRead: 0.55, cacheWrite: 1.10),
        "o4-mini": Price(input: 1.10, output: 4.40, cacheRead: 0.275, cacheWrite: 1.10),
        "codex-mini-latest": Price(input: 1.50, output: 6.00, cacheRead: 0.375, cacheWrite: 1.50)
    ]

    static func normalizedModelName(_ name: String?) -> String? {
        guard var normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty
        else {
            return nil
        }

        if let slashIndex = normalized.lastIndex(of: "/") {
            normalized = String(normalized[normalized.index(after: slashIndex)...])
        }

        if normalized.hasPrefix("model_") {
            normalized.removeFirst("model_".count)
            normalized = normalized.replacingOccurrences(of: "_", with: "-")
        }

        var candidates = [normalized]
        if normalized.contains(".") {
            candidates.append(normalized.replacingOccurrences(of: ".", with: "-"))
        }

        for candidate in candidates where prices[candidate] != nil {
            return candidate
        }

        for candidate in candidates {
            let withoutDate = candidate.replacingOccurrences(
                of: #"-\d{4}-?\d{2}-?\d{2}$"#,
                with: "",
                options: .regularExpression
            )
            if prices[withoutDate] != nil {
                return withoutDate
            }

            let withoutTag = candidate.replacingOccurrences(
                of: #":(latest|thinking)$"#,
                with: "",
                options: .regularExpression
            )
            if prices[withoutTag] != nil {
                return withoutTag
            }

            let withoutQualifier = candidate.replacingOccurrences(
                of: #"-(thinking|high|xhigh|preview|latest)(-thinking|-high|-xhigh|-preview)*"#,
                with: "",
                options: .regularExpression
            )
            if prices[withoutQualifier] != nil {
                return withoutQualifier
            }
        }

        let knownKeys = prices.keys.sorted { $0.count > $1.count }
        for candidate in candidates {
            if let key = knownKeys.first(where: { candidate.hasPrefix($0) }) {
                return key
            }
        }

        return nil
    }

    static func price(for modelName: String?) -> Price? {
        normalizedModelName(modelName).flatMap { prices[$0] }
    }

    static func estimatedCost(for modelName: String?, usage: CodexTokenUsage) -> Double? {
        guard let price = price(for: modelName) else { return nil }
        return (Double(usage.inputTokens) / 1_000_000 * price.input)
            + (Double(usage.outputTokens) / 1_000_000 * price.output)
            + (Double(usage.cacheReadTokens) / 1_000_000 * price.cacheRead)
            + (Double(usage.cacheWriteTokens) / 1_000_000 * price.cacheWrite)
    }
}
