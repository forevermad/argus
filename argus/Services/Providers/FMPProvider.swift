import Foundation

class FMPProvider {
    static let shared = FMPProvider()

    // FMP v3 legacy endpoint was sunset Aug 2025 for new accounts → /stable
    private let baseURL = "https://financialmodelingprep.com/stable"

    private init() {}

    var hasKey: Bool { !Secrets.fmpKey.isEmpty }

    private var apiKey: String { Secrets.fmpKey }

    // MARK: - Fundamentals (canonical)

    /// Returns a `FinancialsData` populated from FMP's quote, key
    /// metrics, ratios, financial growth and price target endpoints.
    /// The Finnhub `/stock/metric` adapter (`FinnhubProvider.fetchBasicFinancials`)
    /// can be merged on top by the caller for fields FMP leaves blank.
    func fetchFundamentals(symbol: String, mergingFinnhub finnhub: FinnhubProvider.BasicFinancials? = nil) async throws -> FinancialsData {
        guard hasKey else {
            throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "FMP key missing"])
        }

        async let quotePart  = fetchQuote(symbol: symbol)
        async let metricsPart = fetchKeyMetrics(symbol: symbol)
        async let ratiosPart  = fetchRatios(symbol: symbol)
        async let growthPart  = fetchFinancialGrowth(symbol: symbol)
        async let targetPart  = fetchPriceTargetConsensus(symbol: symbol)
        async let profilePart = fetchProfile(symbol: symbol)

        let quote     = try? await quotePart
        let metrics   = try? await metricsPart
        let ratios    = try? await ratiosPart
        let growth    = try? await growthPart
        let target    = try? await targetPart
        let profile   = try? await profilePart

        let revenueHistory: [Double] = []
        let netIncomeHistory: [Double] = []

        let marketCap = quote?.marketCap ?? profile?.marketCap ?? finnhub?.marketCapitalization
        let pe = ratios?.priceToEarningsRatioTTM ?? metrics?.peRatio ?? finnhub?.peTTM
        let pb = ratios?.priceToBookRatioTTM ?? finnhub?.pbAnnual
        let dividendYield = ratios?.dividendYieldTTM ?? finnhub?.dividendYieldIndicatedAnnual
        let eps = finnhub?.epsTTM
        let revenueTTM = finnhub?.revenueTTM
        let netIncome = finnhub?.netIncomeAnnual
        let roe = metrics?.returnOnEquityTTM ?? finnhub?.roeTTM
        let currentRatio = ratios?.currentRatioTTM ?? metrics?.currentRatioTTM ?? finnhub?.currentRatioAnnual

        var data = FinancialsData(
            symbol: symbol,
            currency: profile?.currency ?? "USD",
            lastUpdated: Date(),
            totalRevenue: revenueTTM,
            netIncome: netIncome,
            totalShareholderEquity: nil,
            marketCap: marketCap,
            revenueHistory: revenueHistory,
            netIncomeHistory: netIncomeHistory,
            ebitda: nil,
            shortTermDebt: nil,
            longTermDebt: nil,
            operatingCashflow: nil,
            capitalExpenditures: nil,
            cashAndCashEquivalents: nil,
            peRatio: pe,
            forwardPERatio: nil,
            priceToBook: pb,
            evToEbitda: metrics?.evToEBITDATTM,
            dividendYield: dividendYield,
            earningsPerShare: eps,
            forwardGrowthEstimate: growth?.epsgrowth,
            isETF: profile?.isEtf ?? false,
            targetMeanPrice: target?.targetConsensus,
            targetHighPrice: target?.targetHigh,
            targetLowPrice: target?.targetLow,
            recommendationMean: nil,
            numberOfAnalystOpinions: nil
        )
        data.profitMargin = ratios?.netProfitMarginTTM
        data.returnOnEquity = roe
        data.returnOnAssets = metrics?.returnOnAssetsTTM
        data.debtToEquity = ratios?.debtToEquityRatioTTM
        data.currentRatio = currentRatio
        data.priceToSales = ratios?.priceToSalesRatioTTM
        data.pegRatio = ratios?.priceToEarningsGrowthRatioTTM
        data.enterpriseValue = metrics?.enterpriseValueTTM
        data.revenueGrowth = growth?.revenueGrowth
        data.earningsGrowth = growth?.epsgrowth
        return data
    }

    // MARK: - Existing endpoints

    func fetchProfile(symbol: String) async throws -> FMPProfile? {
        let response: [FMPProfile] = try await get(path: "profile", params: ["symbol": symbol])
        return response.first
    }

    func fetchQuote(symbol: String) async throws -> FMPQuote? {
        let response: [FMPQuote] = try await get(path: "quote", params: ["symbol": symbol])
        return response.first
    }

    private func fetchKeyMetrics(symbol: String) async throws -> KeyMetrics? {
        let response: [KeyMetrics] = try await get(path: "key-metrics-ttm", params: ["symbol": symbol, "limit": "1"])
        return response.first
    }

    private func fetchRatios(symbol: String) async throws -> Ratios? {
        let response: [Ratios] = try await get(path: "ratios-ttm", params: ["symbol": symbol, "limit": "1"])
        return response.first
    }

    private func fetchFinancialGrowth(symbol: String) async throws -> FinancialGrowth? {
        let response: [FinancialGrowth] = try await get(path: "financial-growth", params: ["symbol": symbol, "limit": "1"])
        return response.first
    }

    private func fetchPriceTargetConsensus(symbol: String) async throws -> PriceTargetConsensus? {
        try await get(path: "price-target-consensus", params: ["symbol": symbol])
    }

    // MARK: - HTTP

    private func get<T: Decodable>(path: String, params: [String: String]) async throws -> T {
        var components = URLComponents(string: "\(baseURL)/\(path)")!
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "apikey", value: apiKey))
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.requireOK(response, context: "FMP \(path)")
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func requireOK(_ response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(context): non-HTTP response"])
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(context): HTTP \(http.statusCode)"])
        }
    }
}

// MARK: - Decode shapes

struct FMPProfile: Codable {
    let symbol: String
    let price: Double?
    let beta: Double?
    let marketCap: Double?          // was mktCap
    let lastDividend: Double?       // was lastDiv
    let range: String?
    let change: Double?             // was changes
    let companyName: String?
    let currency: String?
    let isin: String?
    let cusip: String?
    let exchange: String?
    let exchangeFullName: String?   // was exchangeShortName
    let industry: String?
    let website: String?
    let description: String?
    let ceo: String?
    let sector: String?
    let country: String?
    let fullTimeEmployees: String?
    let phone: String?
    let address: String?
    let city: String?
    let state: String?
    let zip: String?
    let image: String?
    let ipoDate: String?
    let defaultImage: Bool?
    let isEtf: Bool?
    let isActivelyTrading: Bool?
}

struct FMPQuote: Codable {
    let symbol: String
    let name: String?
    let price: Double?
    let changePercentage: Double?   // was changesPercentage
    let change: Double?
    let dayLow: Double?
    let dayHigh: Double?
    let yearHigh: Double?
    let yearLow: Double?
    let marketCap: Double?
    let priceAvg50: Double?
    let priceAvg200: Double?
    let volume: Int?
    let open: Double?
    let previousClose: Double?
    let timestamp: Int?
    // eps and pe moved to ratios endpoint in stable API
}

private struct KeyMetrics: Codable {
    let enterpriseValueTTM: Double?
    let evToEBITDATTM: Double?
    let returnOnEquityTTM: Double?
    let returnOnAssetsTTM: Double?
    let currentRatioTTM: Double?
    // legacy field kept for fallback mapping
    let peRatio: Double?
}

private struct Ratios: Codable {
    let dividendYieldTTM: Double?
    let debtToEquityRatioTTM: Double?
    let currentRatioTTM: Double?
    let netProfitMarginTTM: Double?
    let priceToSalesRatioTTM: Double?
    let priceToBookRatioTTM: Double?
    let priceToEarningsRatioTTM: Double?
    let priceToEarningsGrowthRatioTTM: Double?
}

private struct FinancialGrowth: Codable {
    let revenueGrowth: Double?
    let epsgrowth: Double?
}

private struct PriceTargetConsensus: Codable {
    let targetHigh: Double?
    let targetLow: Double?
    let targetConsensus: Double?
    let targetMedian: Double?
}
