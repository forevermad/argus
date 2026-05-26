import Foundation
import Combine

@MainActor
final class TerminalViewModel: ObservableObject {
    static let shared = TerminalViewModel()

    @Published var terminalItems: [TerminalItem] = []
    @Published private(set) var watchlist: [String] = []
    @Published private(set) var isBootstrapping = false

    private var lastTerminalSignatures: [String: TerminalInputSignature] = [:]
    private var cancellables = Set<AnyCancellable>()

    private struct TerminalInputSignature: Equatable {
        let price: Double
        let percentChange: Double?
        let orionScore: Double?
        let councilScore: Double?
        let action: ArgusAction
        let hermesImpact: Double?
        let dataQuality: Int
        let regime: MarketRegime
        let forecastTrend: PrometheusTrend?
    }

    private init() {
        setupObservation()
    }

    // MARK: - Observation

    private func setupObservation() {
        WatchlistStore.shared.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                self?.watchlist = items
                self?.refreshTerminal()
            }
            .store(in: &cancellables)

        MarketViewModel.shared.$quotes
            .throttle(for: .seconds(0.7), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshTerminal() }
            .store(in: &cancellables)

        SignalStateViewModel.shared.$grandDecisions
            .throttle(for: .seconds(0.7), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshTerminal() }
            .store(in: &cancellables)

        DiagnosticsViewModel.shared.$dataHealthBySymbol
            .throttle(for: .seconds(1.0), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshTerminal() }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    func refreshTerminal() {
        let regime = MarketViewModel.shared.marketRegime

        let cachedQuotes = MarketViewModel.shared.quotes
        let cachedDecisions = SignalStateViewModel.shared.grandDecisions
        let cachedOrionScores = SignalStateViewModel.shared.orionScores
        let cachedNewsInsights = HermesNewsViewModel.shared.newsInsightsBySymbol
        let cachedDataHealth = DiagnosticsViewModel.shared.dataHealthBySymbol
        let cachedForecasts = SignalViewModel.shared.prometheusForecastBySymbol

        let existingByID: [String: TerminalItem] = Dictionary(
            uniqueKeysWithValues: terminalItems.map { ($0.id, $0) }
        )

        var didChange = false
        let newItems = watchlist.map { symbol -> TerminalItem in
            let isBist = symbol.uppercased().hasSuffix(".IS") || SymbolResolver.shared.isBistSymbol(symbol)
            let quote = cachedQuotes[symbol]
            let decision = cachedDecisions[symbol]
            let orion = cachedOrionScores[symbol]
            let hermesImpact = cachedNewsInsights[symbol]?.first?.impactScore
            let dataQuality = cachedDataHealth[symbol]?.qualityScore ?? 0
            let forecast = cachedForecasts[symbol]

            let signature = TerminalInputSignature(
                price: quote?.currentPrice ?? 0,
                percentChange: quote?.percentChange,
                orionScore: orion?.score,
                councilScore: decision?.confidence,
                action: decision?.action ?? .neutral,
                hermesImpact: hermesImpact,
                dataQuality: dataQuality,
                regime: regime,
                forecastTrend: forecast?.trend
            )

            if lastTerminalSignatures[symbol] == signature,
               let existing = existingByID[symbol] {
                return existing
            }

            didChange = true
            lastTerminalSignatures[symbol] = signature

            let fundScore = FundamentalScoreStore.shared.getScore(for: symbol)?.totalScore

            let chimeraResult = ChimeraSynergyEngine.shared.fuse(
                symbol: symbol,
                orion: orion,
                hermesImpactScore: hermesImpact,
                titanScore: fundScore,
                currentPrice: quote?.currentPrice ?? 0,
                marketRegime: regime
            )

            return TerminalItem(
                id: symbol,
                symbol: symbol,
                market: isBist ? .bist : .global,
                currency: isBist ? .TRY : .USD,
                price: quote?.currentPrice ?? 0.0,
                dayChangePercent: quote?.percentChange,
                orionScore: orion?.score,
                atlasScore: fundScore,
                councilScore: decision?.confidence,
                action: decision?.action ?? .neutral,
                dataQuality: dataQuality,
                forecast: forecast,
                chimeraSignal: chimeraResult.signals.first
            )
        }

        let watchlistSet = Set(watchlist)
        if lastTerminalSignatures.count > watchlistSet.count {
            lastTerminalSignatures = lastTerminalSignatures.filter { watchlistSet.contains($0.key) }
        }

        if didChange || newItems.count != terminalItems.count {
            terminalItems = newItems
        }
    }

    // MARK: - Bootstrap

    func bootstrapTerminalData() async {
        guard !isBootstrapping else { return }
        await MainActor.run { isBootstrapping = true }
        defer { Task { @MainActor in isBootstrapping = false } }

        await TerminalService.shared.bootstrapTerminal(
            symbols: watchlist,
            batchSize: 10,
            onProgress: { processed, total in
                Task { await ArgusLogger.shared.log("Bootstrap Progress: \(processed)/\(total)", level: .info, category: "Terminal") }
            },
            onBatchComplete: { [weak self] results in
                for data in results {
                    if let q = data.quote { MarketViewModel.shared.quotes[data.symbol] = q }
                    if let c = data.candles { MarketViewModel.shared.candles[data.symbol] = c }
                    if let f = data.forecast { SignalViewModel.shared.prometheusForecastBySymbol[data.symbol] = f }
                    DiagnosticsViewModel.shared.dataHealthBySymbol[data.symbol] = data.health
                }
                self?.refreshTerminal()
            }
        )
    }
}
