import Foundation
import OpenAIEgressCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let json = """
{
  "ip": "203.0.113.10",
  "city": "Tokyo",
  "region": "Tokyo",
  "country": "JP",
  "loc": "35.6764,139.6500",
  "org": "AS64500 Example Network",
  "timezone": "Asia/Tokyo"
}
""".data(using: .utf8)!

let info = try IPInfo.decode(json)
expect(info.ip == "203.0.113.10", "ipinfo ip parses")
expect(info.country == "JP", "ipinfo country parses")
expect(info.countryDisplay == "🇯🇵 Japan", "ipinfo country display")
expect(info.city == "Tokyo", "ipinfo city parses")
expect(info.coordinateDisplay == "35.6764, 139.6500", "coordinates get readable spacing")

let ipapiJSON = """
{
  "ip": "198.51.100.22",
  "city": "Singapore",
  "region": "Singapore",
  "country_code": "SG",
  "latitude": 1.2897,
  "longitude": 103.8501,
  "org": "AS64501 Example Provider"
}
""".data(using: .utf8)!

let ipapiInfo = try PublicIPProbeAdapter.ipapiJSON.decode(ipapiJSON)
expect(ipapiInfo.ip == "198.51.100.22", "ipapi ip parses")
expect(ipapiInfo.country == "SG", "ipapi country parses")
expect(ipapiInfo.coordinateDisplay == "1.2897, 103.8501", "ipapi coordinates adapt")

let probeLine = "ipapi-json|https://ipapi.co/json/"
let probe = PublicIPProbe.parse(probeLine)
expect(probe?.adapter == .ipapiJSON, "probe adapter parses")
expect(probe?.url.absoluteString == "https://ipapi.co/json/", "probe url parses")

let body = """
fl=965f65
h=chatgpt.com
ip=203.0.113.11
colo=SIN
loc=SG
http=http/2
tls=TLSv1.3
"""

let trace = ChatGPTTrace.parse(body)
expect(trace.ip == "203.0.113.11", "trace ip parses")
expect(trace.country == "SG", "trace country parses")
expect(trace.countryDisplay == "🇸🇬 Singapore", "trace country display")
expect(trace.colo == "SIN", "trace colo parses")

let previous = EgressSnapshot(publicCountry: "SG", traceCountry: "SG")
let sameCountryNewIp = EgressSnapshot(publicCountry: "SG", traceCountry: "SG")
let changedCountry = EgressSnapshot(publicCountry: "JP", traceCountry: "JP")
expect(!EgressAlertPolicy.shouldNotifyCountryChange(previous: previous, current: sameCountryNewIp), "ip-only changes do not notify")
expect(EgressAlertPolicy.shouldNotifyCountryChange(previous: previous, current: changedCountry), "country changes notify")
expect(EgressAlertPolicy.isTraceCountryExpected("JP", expectedCountries: ["JP", "SG"]), "JP is expected")
expect(EgressAlertPolicy.isTraceCountryExpected("SG", expectedCountries: ["JP", "SG"]), "SG is expected")
expect(!EgressAlertPolicy.isTraceCountryExpected("US", expectedCountries: ["JP", "SG"]), "US is unexpected")
expect(CountryDisplay.display(for: "XX") == "XX", "unknown countries fall back to code")
expect(CountryDisplay.statusTitle(for: "XX") == "XX", "status title falls back to code")

print("OpenAIEgressCoreCheck passed")
