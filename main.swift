import Foundation

struct CloudflareEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let errors: [CloudflareMessage]?
    let messages: [CloudflareMessage]?
    let result: T?
}

struct CloudflareMessage: Decodable, Error {
    let code: Int?
    let message: String
}

struct DomainCheckRequest: Encodable {
    let domains: [String]
}

struct DomainCheckResponse: Decodable {
    let domains: [DomainAvailability]
}

struct DomainAvailability: Decodable {
    let name: String
    let registrable: Bool
    let reason: String?
    let tier: String?
    let pricing: DomainPricing?
}

struct DomainPricing: Decodable {
    let currency: String
    let registration_cost: String
    let renewal_cost: String
}

struct DomainOutput: Encodable {
    let domain: String
    let registration_cost: String
}

enum AppError: Error, CustomStringConvertible {
    case missingEnvironment(String)
    case invalidResponse
    case apiError(String)
    case noWordsAvailable

    var description: String {
        switch self {
        case .missingEnvironment(let name):
            return "Missing required environment variable: \(name)"
        case .invalidResponse:
            return "Invalid response from server"
        case .apiError(let message):
            return "API error: \(message)"
        case .noWordsAvailable:
            return "Could not retrieve a random popular word"
        }
    }
}

final class CloudflareRegistrarClient {
    private let accountID: String
    private let apiToken: String
    private let session: URLSession
    private let baseURL: URL

    init(accountID: String, apiToken: String, session: URLSession = .shared) {
        self.accountID = accountID
        self.apiToken = apiToken
        self.session = session
        self.baseURL = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/registrar")!
    }

    func checkDomains(_ domains: [String]) async throws -> [DomainAvailability] {
        let url = baseURL.appendingPathComponent("domain-check")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DomainCheckRequest(domains: domains))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw AppError.apiError("HTTP \(http.statusCode): \(body)")
        }

        let decoded = try JSONDecoder().decode(CloudflareEnvelope<DomainCheckResponse>.self, from: data)
        guard decoded.success, let result = decoded.result else {
            let message = decoded.errors?.map(\.message).joined(separator: "; ")
                ?? decoded.messages?.map(\.message).joined(separator: "; ")
                ?? "Unknown Cloudflare error"
            throw AppError.apiError(message)
        }

        return result.domains
    }
}

final class RandomWordProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func randomPopularWord() async throws -> String {
        if let word = try await fetchRandomWordFromRandomWordAPI() {
            return sanitize(word)
        }
        throw AppError.noWordsAvailable
    }

    private func fetchRandomWordFromRandomWordAPI() async throws -> String? {
        let url = URL(string: "https://random-word-api.herokuapp.com/word")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }

        let words = try JSONDecoder().decode([String].self, from: data)
        return words.first
    }

    private func sanitize(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}


struct DomainFinder {
    static func eprint(_ string: String) {
        if let data = (string + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    static func main() async {
        do {
            let accountID = try env("CLOUDFLARE_ACCOUNT_ID")
            let apiToken = try env("CLOUDFLARE_API_TOKEN")

            let client = CloudflareRegistrarClient(accountID: accountID, apiToken: apiToken)
            let words = RandomWordProvider()

            let tlds = supportedProgrammaticTLDs()
            let maxWordAttempts = Int(ProcessInfo.processInfo.environment["MAX_WORD_ATTEMPTS"] ?? "1000") ?? 1000

            for attempt in 1...maxWordAttempts {
                let word = try await words.randomPopularWord()
                var shuffledTLDs = tlds.shuffled()

                eprint("Trying word \(attempt): \(word)")

                while !shuffledTLDs.isEmpty {
                    let batch = Array(shuffledTLDs.prefix(20))
                    shuffledTLDs.removeFirst(min(20, shuffledTLDs.count))

                    let domains = batch.map { "\(word).\($0)" }
                    let results = try await client.checkDomains(domains)

                    if let available = results.first(where: { result in
                        result.registrable && (result.tier == nil || result.tier == "standard")
                    }) {

                        let currency = available.pricing!.currency
                        let registrationCost = available.pricing!.registration_cost

                        let output = DomainOutput(
                            domain: available.name,
                            registration_cost: formattedCurrencyAmount(
                                currencyCode: currency,
                                amount: registrationCost
                            )
                        )
                        let data = try JSONEncoder().encode(output)
                        print(String(decoding: data, as: UTF8.self))
                        Foundation.exit(EXIT_SUCCESS)
                    }
                }

                eprint("No available supported TLDs found for word: \(word)")
            }

            eprint("No available domain found after \(maxWordAttempts) random words")
            Foundation.exit(EXIT_FAILURE)

        } catch {
            eprint("Error: \(error)")
            Foundation.exit(EXIT_FAILURE)
        }
    }

    static func env(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw AppError.missingEnvironment(name)
        }
        return value
    }

    static func formattedCurrencyAmount(currencyCode: String, amount: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if let decimal = Decimal(string: amount),
           let formatted = formatter.string(from: NSDecimalNumber(decimal: decimal)) {
            return formatted.replacingOccurrences(
                of: "([\\p{Sc}])\\s+([0-9])",
                with: "$1$2",
                options: .regularExpression
            )
        }

        return "\(currencyCode.trimmingCharacters(in: .whitespaces))\(amount.trimmingCharacters(in: .whitespaces))"
    }

    static func supportedProgrammaticTLDs() -> [String] {
["ab.ca", "ac", "academy", "accountant", "accountants", "actor", "adult", "agency", "ai", "airforce", "apartments", "app", "army", "associates", "attorney", "auction", "audio", "baby", "band", "bar", "bargains", "bc.ca", "beer", "bet", "bid", "bike", "bingo", "biz", "black", "blog", "blue", "boo", "boston", "boutique", "broker", "build", "builders", "business", "ca", "cab", "cafe", "cam", "camera", "camp", "capital", "cards", "care", "careers", "casa", "cash", "casino", "catering", "cc", "center", "ceo", "charity", "chat", "cheap", "christmas", "church", "city", "claims", "cleaning", "clinic", "clothing", "cloud", "club", "co", "co.nz", "co.uk", "coach", "codes", "coffee", "college", "com", "com.ai", "com.co", "com.mx", "community", "company", "compare", "computer", "condos", "construction", "consulting", "contact", "contractors", "cooking", "cool", "coupons", "credit", "creditcard", "cricket", "cruises", "dad", "dance", "date", "dating", "day", "dealer", "deals", "degree", "delivery", "democrat", "dental", "dentist", "design", "dev", "diamonds", "diet", "digital", "direct", "directory", "discount", "doctor", "dog", "domains", "download", "education", "email", "energy", "engineer", "engineering", "enterprises", "equipment", "esq", "estate", "events", "exchange", "expert", "exposed", "express", "fail", "faith", "family", "fan", "fans", "farm", "fashion", "feedback", "finance", "financial", "fish", "fishing", "fit", "fitness", "flights", "florist", "flowers", "fm", "foo", "football", "forex", "forsale", "forum", "foundation", "fun", "fund", "furniture", "futbol", "fyi", "gallery", "game", "games", "garden", "geek.nz", "gifts", "gives", "giving", "glass", "global", "gmbh", "gold", "golf", "graphics", "gratis", "green", "gripe", "group", "guide", "guitars", "guru", "haus", "health", "healthcare", "help", "hockey", "holdings", "holiday", "horse", "hospital", "host", "hosting", "house", "how", "icu", "immo", "immobilien", "inc", "industries", "info", "ing", "ink", "institute", "insure", "international", "investments", "io", "irish", "jetzt", "jewelry", "kaufen", "kim", "kitchen", "land", "lawyer", "lease", "legal", "lgbt", "life", "lighting", "limited", "limo", "link", "live", "loan", "loans", "lol", "love", "ltd", "luxe", "maison", "management", "market", "marketing", "markets", "mb.ca", "mba", "me", "me.uk", "media", "meme", "memorial", "men", "miami", "mobi", "moda", "mom", "money", "monster", "mortgage", "mov", "movie", "mx", "navy", "nb.ca", "net", "net.ai", "net.co", "net.nz", "net.uk", "network", "new", "news", "nexus", "ngo", "ninja", "nl.ca", "nom.co", "ns.ca", "nt.ca", "nu.ca", "nz", "observer", "off.ai", "on.ca", "ong", "online", "org", "org.ai", "org.mx", "org.nz", "org.uk", "organic", "page", "partners", "parts", "party", "pe.ca", "pet", "phd", "photography", "photos", "pics", "pictures", "pink", "pizza", "place", "plumbing", "plus", "porn", "press", "pro", "productions", "prof", "promo", "properties", "protection", "pub", "qc.ca", "racing", "realty", "recipes", "red", "rehab", "reise", "reisen", "rent", "rentals", "repair", "report", "republican", "rest", "restaurant", "review", "reviews", "rip", "rocks", "rodeo", "rsvp", "run", "sale", "salon", "sarl", "school", "schule", "science", "security", "select", "services", "sex", "sh", "shoes", "shop", "shopping", "show", "singles", "site", "sk.ca", "ski", "soccer", "social", "software", "solar", "solutions", "soy", "space", "storage", "store", "stream", "studio", "style", "supplies", "supply", "support", "surf", "surgery", "systems", "tax", "taxi", "team", "tech", "technology", "tennis", "theater", "theatre", "tienda", "tips", "tires", "today", "tools", "toronto.on.ca", "tours", "town", "toys", "trade", "trading", "training", "travel", "tv", "uk", "university", "uno", "us", "vacations", "ventures", "vet", "viajes", "video", "villas", "vin", "vip", "vision", "vodka", "voyage", "watch", "webcam", "website", "wedding", "wiki", "win", "wine", "work", "works", "world", "wtf", "xxx", "xyz", "yk.ca", "yoga", "yt.ca", "zone"]
    }
}

Task {
    await DomainFinder.main()
}

dispatchMain()