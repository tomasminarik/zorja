import Foundation

enum APITimestamp {
    /// The backend mixes whole-second and microsecond RFC3339 UTC instants.
    static func parse(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}

extension JSONDecoder {
    static func forecast() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = APITimestamp.parse(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not an RFC3339 instant: \(string)")
            }
            return date
        }
        return decoder
    }
}
