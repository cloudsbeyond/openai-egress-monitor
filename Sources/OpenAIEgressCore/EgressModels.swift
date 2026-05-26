import Foundation

public struct IPInfo: Decodable, Equatable {
    public let ip: String
    public let city: String?
    public let region: String?
    public let country: String?
    public let loc: String?
    public let org: String?
    public let timezone: String?

    public init(
        ip: String,
        city: String?,
        region: String?,
        country: String?,
        loc: String?,
        org: String?,
        timezone: String?
    ) {
        self.ip = ip
        self.city = city
        self.region = region
        self.country = country
        self.loc = loc
        self.org = org
        self.timezone = timezone
    }

    public static func decode(_ data: Data) throws -> IPInfo {
        try JSONDecoder().decode(IPInfo.self, from: data)
    }

    public var countryDisplay: String {
        CountryDisplay.display(for: country)
    }

    public var coordinateDisplay: String {
        guard let loc, !loc.isEmpty else { return "--" }
        return loc.split(separator: ",", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: ", ")
    }
}

public struct PublicIPProbe: Equatable {
    public let adapter: PublicIPProbeAdapter
    public let url: URL

    public init(adapter: PublicIPProbeAdapter, url: URL) {
        self.adapter = adapter
        self.url = url
    }

    public static func parse(_ rawValue: String) -> PublicIPProbe? {
        let parts = rawValue.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let adapterName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let adapter = PublicIPProbeAdapter(rawValue: adapterName),
            let url = URL(string: urlString)
        else {
            return nil
        }
        return PublicIPProbe(adapter: adapter, url: url)
    }
}

public enum PublicIPProbeAdapter: String, Equatable, CaseIterable {
    case ipinfoJSON = "ipinfo-json"
    case ipapiJSON = "ipapi-json"
    case ipwhoisJSON = "ipwhois-json"

    public func decode(_ data: Data) throws -> IPInfo {
        switch self {
        case .ipinfoJSON:
            return try IPInfo.decode(data)
        case .ipapiJSON:
            let decoded = try JSONDecoder().decode(IPAPIResponse.self, from: data)
            return IPInfo(
                ip: decoded.ip,
                city: decoded.city,
                region: decoded.region,
                country: decoded.countryCode,
                loc: coordinateString(latitude: decoded.latitude, longitude: decoded.longitude),
                org: decoded.org,
                timezone: nil
            )
        case .ipwhoisJSON:
            let decoded = try JSONDecoder().decode(IPWhoIsResponse.self, from: data)
            return IPInfo(
                ip: decoded.ip,
                city: decoded.city,
                region: decoded.region,
                country: decoded.countryCode,
                loc: coordinateString(latitude: decoded.latitude, longitude: decoded.longitude),
                org: decoded.connection?.org ?? decoded.connection?.isp,
                timezone: decoded.timezone?.id
            )
        }
    }

    private func coordinateString(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude else { return nil }
        return "\(latitude),\(longitude)"
    }
}

private struct IPAPIResponse: Decodable {
    let ip: String
    let city: String?
    let region: String?
    let countryCode: String?
    let latitude: Double?
    let longitude: Double?
    let org: String?

    enum CodingKeys: String, CodingKey {
        case ip
        case city
        case region
        case countryCode = "country_code"
        case latitude
        case longitude
        case org
    }
}

private struct IPWhoIsResponse: Decodable {
    let ip: String
    let city: String?
    let region: String?
    let countryCode: String?
    let latitude: Double?
    let longitude: Double?
    let connection: Connection?
    let timezone: Timezone?

    enum CodingKeys: String, CodingKey {
        case ip
        case city
        case region
        case countryCode = "country_code"
        case latitude
        case longitude
        case connection
        case timezone
    }

    struct Connection: Decodable {
        let org: String?
        let isp: String?
    }

    struct Timezone: Decodable {
        let id: String?
    }
}

public struct ChatGPTTrace: Equatable {
    public let values: [String: String]

    public static func parse(_ body: String) -> ChatGPTTrace {
        var values: [String: String] = [:]
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                values[key] = value
            }
        }
        return ChatGPTTrace(values: values)
    }

    public var ip: String? { values["ip"] }
    public var country: String? { values["loc"] }
    public var colo: String? { values["colo"] }
    public var http: String? { values["http"] }
    public var tls: String? { values["tls"] }

    public var countryDisplay: String {
        CountryDisplay.display(for: country)
    }
}

public struct EgressSnapshot: Codable, Equatable {
    public let publicCountry: String?
    public let traceCountry: String?

    public init(publicCountry: String?, traceCountry: String?) {
        self.publicCountry = publicCountry?.uppercased()
        self.traceCountry = traceCountry?.uppercased()
    }
}

public enum EgressAlertPolicy {
    public static func shouldNotifyCountryChange(previous: EgressSnapshot?, current: EgressSnapshot) -> Bool {
        guard let previousTrace = previous?.traceCountry, !previousTrace.isEmpty else {
            return false
        }
        guard let currentTrace = current.traceCountry, !currentTrace.isEmpty else {
            return false
        }
        return previousTrace != currentTrace
    }

    public static func isTraceCountryExpected(_ country: String?, expectedCountries: Set<String>) -> Bool {
        guard let country, !country.isEmpty else { return false }
        return expectedCountries.contains(country.uppercased())
    }
}

public enum CountryDisplay {
    private static let names: [String: String] = [
        "AU": "Australia",
        "CA": "Canada",
        "CN": "China",
        "DE": "Germany",
        "FR": "France",
        "GB": "United Kingdom",
        "HK": "Hong Kong",
        "IN": "India",
        "JP": "Japan",
        "KR": "South Korea",
        "SG": "Singapore",
        "TW": "Taiwan",
        "US": "United States",
    ]

    public static func display(for rawCode: String?) -> String {
        guard let code = normalizedCode(rawCode) else { return "--" }
        guard let name = names[code], let flag = flagEmoji(for: code) else {
            return code
        }
        return "\(flag) \(name)"
    }

    public static func statusTitle(for rawCode: String?) -> String {
        guard let code = normalizedCode(rawCode) else { return "--" }
        guard names[code] != nil, let flag = flagEmoji(for: code) else {
            return code
        }
        return "\(flag) \(code)"
    }

    private static func normalizedCode(_ rawCode: String?) -> String? {
        guard let rawCode else { return nil }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.isEmpty ? nil : code
    }

    private static func flagEmoji(for code: String) -> String? {
        guard code.count == 2 else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            guard let regional = UnicodeScalar(127397 + scalar.value) else { return nil }
            scalars.append(regional)
        }
        return String(scalars)
    }
}
