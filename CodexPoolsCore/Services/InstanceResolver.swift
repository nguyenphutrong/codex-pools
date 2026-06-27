import Foundation

public enum InstanceResolveError: LocalizedError, Equatable {
    case notFound(String)
    case ambiguous(String, [CodexInstance])

    public var errorDescription: String? {
        switch self {
        case .notFound(let query):
            return "No instance matches '\(query)'."
        case .ambiguous(let query, let matches):
            let names = matches.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ")
            return "Multiple instances match '\(query)': \(names)."
        }
    }
}

public enum InstanceResolver {
    public static func resolve(_ query: String, in instances: [CodexInstance]) throws -> CodexInstance {
        if let uuid = UUID(uuidString: query),
           let instance = instances.first(where: { $0.id == uuid }) {
            return instance
        }

        let matches = instances.filter {
            $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }

        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw InstanceResolveError.notFound(query)
        default:
            throw InstanceResolveError.ambiguous(query, matches)
        }
    }
}
