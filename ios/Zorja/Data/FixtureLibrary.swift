import Foundation

/// The synthetic contract examples from `api/examples`, bundled as a folder
/// reference so the repository keeps a single copy.
enum FixtureLibrary {
    enum Payload: Sendable, Equatable {
        case forecast(Forecast)
        case error(APIError)
    }

    static var directory: URL? {
        Bundle.main.url(forResource: "examples", withExtension: nil)
    }

    static var names: [String] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    static func load(_ name: String) throws -> Payload {
        guard let url = directory?.appendingPathComponent("\(name).json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder.forecast()
        if let error = try? decoder.decode(APIError.self, from: data) {
            return .error(error)
        }
        return .forecast(try decoder.decode(Forecast.self, from: data))
    }
}
