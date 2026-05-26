import Foundation

/// "The Gatekeeper" - market-aware data orchestrator with inline
/// multi-provider fallback chains. Each data method walks a chain of
/// providers in order, respecting per-provider/endpoint circuit
/// breakers; the first one to succeed wins. Yahoo stays as a first
/// class citizen alongside Stooq, Finnhub, FMP, Binance, BorsaPy and
/// FRED.
@MainActor
final class HeimdallOrchestrator {
    static let shared = HeimdallOrchestrator()

    private let yahoo       = YahooFinanceProvider.shared
    private let borsaPy     = BorsaPyProvider.shared
    private let stooq       = StooqProvider.shared
    private let finnhub     = FinnhubProvider.shared
    private let binance     = BinanceCandleAdapter.shared
    private let fmp         = FMPProvider.shared
    private let alpaca      = AlpacaProvider.shared
    private let frankfurter = FrankfurterProvider.shared
    private let tcmbToday   = TCMBTodayProvider.shared
    private let secEdgar    = SECEdgarProvider.shared
    private let btcTurk     = BtcTurkProvider.shared
    private let coinbase    = CoinbasePublicProvider.shared
    private let isYatirim   = IsYatirimProvider.shared
    private let news        = GoogleNewsRSSProvider.shared
    private let gdelt       = GDELTNewsProvider.shared
    private let fred        = FredProvider.shared
    private let resolver    = SymbolResolver.shared

    private init() {
        print("HEIMDALL: multi-provider chain initialized")
    }

    // MARK: - Error helpers

    private func isLocalThrottle(_ error: Error) -> Bool {
        if let h = error as? HeimdallCoreError {
            return h.code == HeimdallNetwork.localThrottleCode
        }
        return false
    }

    private func isAuthOrEntitlementError(_ error: Error) -> Bool {
        if let h = error as? HeimdallCoreError {
            return h.category == .authInvalid || h.category == .entitlementDenied
        }
        return false
    }

    private func symbolBlockedError(provider: String, endpoint: String, symbol: String, reason: String) -> HeimdallCoreError {
        HeimdallCoreError(
            category: .authInvalid,
            code: HeimdallNetwork.symbolBlockedCode,
            message: "Symbol \(symbol) locally blocked on \(provider)/\(endpoint): \(reason)",
            bodyPrefix: "symbol-blocked"
        )
    }

    private func circuitKey(provider: String, endpoint: String) -> String {
        "\(provider):\(endpoint)"
    }

    private func classifyError(_ error: Error) -> String {
        if let heimdallError = error as? HeimdallCoreError {
            return heimdallError.category.rawValue
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "timeout"
            case .notConnectedToInternet: return "network"
            case .userAuthenticationRequired: return "auth"
            case .cancelled: return "cancelled"
            default: return "network"
            }
        }
        return "unknown"
    }

    // MARK: - Chain runner

    private struct ChainStep<T> {
        let provider: String
        let body: () async throws -> T
    }

    /// Walks the provider chain for the given endpoint. Respects circuit
    /// breakers, retries on the next provider when one fails, and reports
    /// the surviving provider as the source string.
    private func firstSuccess<T>(_ steps: [ChainStep<T>], endpoint: String, symbol: String) async throws -> (T, String) {
        var lastError: Error?
        for step in steps {
            let circuit = circuitKey(provider: step.provider, endpoint: endpoint)
            guard await HeimdallCircuitBreaker.shared.canRequest(provider: circuit) else {
                lastError = HeimdallCoreError(category: .circuitOpen, code: 503, message: "Circuit open for \(step.provider)/\(endpoint)", bodyPrefix: "")
                continue
            }
            let start = Date()
            do {
                let value = try await step.body()
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                await HeimdallCircuitBreaker.shared.reportSuccess(provider: circuit)
                await HeimdallLogger.shared.info("fetch_success", provider: step.provider, endpoint: endpoint, symbol: symbol, latencyMs: latency)
                await HealthStore.shared.reportSuccess(provider: step.provider, latency: Double(latency))
                return (value, step.provider)
            } catch {
                if !isLocalThrottle(error) && !isAuthOrEntitlementError(error) {
                    await HeimdallCircuitBreaker.shared.reportFailure(provider: circuit, error: error)
                    await HealthStore.shared.reportError(provider: step.provider, error: error)
                }
                await HeimdallLogger.shared.warn(
                    "chain_step_failed",
                    provider: step.provider,
                    errorClass: classifyError(error),
                    errorMessage: error.localizedDescription,
                    endpoint: endpoint
                )
                lastError = error
            }
        }
        throw lastError ?? HeimdallCoreError(category: .emptyPayload, code: 204, message: "All providers exhausted for \(symbol)/\(endpoint)", bodyPrefix: "")
    }

    // MARK: - Quote (single)

    func requestQuote(symbol: String, context: UsageContext = .interactive) async throws -> Quote {
        if await SymbolBlocklist.shared.isBlocked(symbol),
           let reason = await SymbolBlocklist.shared.reasonFor(symbol) {
            throw symbolBlockedError(provider: "argus", endpoint: "quote", symbol: symbol, reason: reason)
        }
        await RateLimiter.shared.waitIfNeeded()

        let resolved = resolver.resolve(symbol)
        let destination = resolver.marketDestination(for: resolved)
        let chain = quoteChain(destination: destination, resolved: resolved, original: symbol)

        do {
            let (quote, _) = try await firstSuccess(chain, endpoint: "quote", symbol: symbol)
            await SymbolBlocklist.shared.reportSuccess(symbol: symbol)
            return quote
        } catch {
            if isAuthOrEntitlementError(error) {
                await SymbolBlocklist.shared.reportFailure(symbol: symbol, reason: "quote auth/paywall")
            }
            throw error
        }
    }

    private func quoteChain(destination: MarketDestination, resolved: String, original: String) -> [ChainStep<Quote>] {
        let bareBist = SymbolResolver.bareBistSymbol(resolved)

        switch destination {
        case .bist:
            // 2026-05-11: İş Yatırım BorsaPy ile Yahoo arasında —
            // BorsaPy cold-start (Render free) yiyince İş Yatırım
            // CDN-destekli kurumsal endpoint anında cevap verir.
            // BIST 15-min delayed kapanış zaten standart.
            return [
                ChainStep(provider: "borsapy") { [borsaPy] in
                    let bist = try await borsaPy.getBistQuote(symbol: bareBist)
                    return Self.convert(bist: bist, canonical: original)
                },
                ChainStep(provider: "isyatirim") { [isYatirim] in
                    try await isYatirim.fetchQuote(symbol: bareBist)
                },
                ChainStep(provider: "yahoo") { [yahoo] in
                    try await yahoo.fetchQuote(symbol: resolved)
                }
            ]
        case .crypto:
            // 2026-05-11: BtcTurk TR pair native (TRY karşılığı), Coinbase
            // ABD/EU yedek, Finnhub primary (key gerektirir). TR
            // kullanıcı için BtcTurk en doğrudan.
            return [
                ChainStep(provider: "finnhub")  { [finnhub]  in try await finnhub.fetchQuote(symbol: resolved) },
                ChainStep(provider: "btcturk")  { [btcTurk]  in try await btcTurk.fetchQuote(symbol: resolved) },
                ChainStep(provider: "coinbase") { [coinbase] in try await coinbase.fetchQuote(symbol: resolved) },
                ChainStep(provider: "yahoo")    { [yahoo]    in try await yahoo.fetchQuote(symbol: resolved) }
            ]
        case .usEquity:
            // 2026-05-11: Alpaca paper IEX RT birincil (200 r/dk, snapshot
            // endpoint trade+quote+prevDailyBar tek HTTP'de). Key yoksa
            // graceful fallback → Stooq batch (keyless CSV) → Yahoo →
            // Finnhub → FMP.
            var steps: [ChainStep<Quote>] = []
            if alpaca.hasKey {
                steps.append(ChainStep(provider: "alpaca") { [alpaca] in
                    try await alpaca.fetchQuote(symbol: resolved)
                })
            }
            steps.append(contentsOf: [
                ChainStep(provider: "stooq")   { [stooq]   in try await Self.singleFromBatch(stooq: stooq, resolved: resolved, original: original) },
                ChainStep(provider: "yahoo")   { [yahoo]   in try await yahoo.fetchQuote(symbol: resolved) },
                ChainStep(provider: "finnhub") { [finnhub] in try await finnhub.fetchQuote(symbol: resolved) },
                ChainStep(provider: "fmp")     { [fmp]     in try await Self.fmpToQuote(fmp: fmp, symbol: resolved) }
            ])
            return steps
        case .index:
            // Stooq US index için de hızlı; Yahoo fallback.
            // Frankfurter index sağlamaz; Alpaca free-tier de yok.
            return [
                ChainStep(provider: "stooq")   { [stooq]   in try await Self.singleFromBatch(stooq: stooq, resolved: resolved, original: original) },
                ChainStep(provider: "yahoo")   { [yahoo]   in try await yahoo.fetchQuote(symbol: resolved) },
                ChainStep(provider: "finnhub") { [finnhub] in try await finnhub.fetchQuote(symbol: resolved) }
            ]
        case .forex, .commodity:
            // 2026-05-11: FX/Commodity için Stooq önce (intraday batch),
            // Yahoo ve Finnhub orta, TCMB Today + Frankfurter referans
            // katmanı son. TCMB sadece TR pair'leri (USDTRY/EURTRY vb.)
            // için devreye girer (parsePair → quote=TRY). Frankfurter
            // ECB resmi referansı — XAU/XAG commodity için de çalışır
            // (GC=F → XAU/USD mapping).
            var steps: [ChainStep<Quote>] = [
                ChainStep(provider: "stooq")   { [stooq]   in try await Self.singleFromBatch(stooq: stooq, resolved: resolved, original: original) },
                ChainStep(provider: "yahoo")   { [yahoo]   in try await yahoo.fetchQuote(symbol: resolved) },
                ChainStep(provider: "finnhub") { [finnhub] in try await finnhub.fetchQuote(symbol: resolved) }
            ]
            if let pair = TCMBTodayProvider.parsePair(resolved), pair.quote == "TRY" {
                steps.append(ChainStep(provider: "tcmb_today") { [tcmbToday] in
                    try await tcmbToday.fetchQuote(symbol: resolved)
                })
            }
            if FrankfurterProvider.parsePair(resolved) != nil {
                steps.append(ChainStep(provider: "frankfurter") { [frankfurter] in
                    try await frankfurter.fetchQuote(symbol: resolved)
                })
            }
            return steps
        }
    }

    private static func singleFromBatch(stooq: StooqProvider, resolved: String, original: String) async throws -> Quote {
        let map = try await stooq.fetchSnapshotBatch(symbols: [resolved])
        if let quote = map[resolved] ?? map[original] { return quote }
        throw HeimdallCoreError(category: .emptyPayload, code: 204, message: "Stooq empty for \(resolved)", bodyPrefix: "")
    }

    private static func fmpToQuote(fmp: FMPProvider, symbol: String) async throws -> Quote {
        guard fmp.hasKey, let q = try await fmp.fetchQuote(symbol: symbol), let price = q.price else {
            throw HeimdallCoreError(category: .emptyPayload, code: 204, message: "FMP empty for \(symbol)", bodyPrefix: "")
        }
        var quote = Quote(
            c: price,
            d: q.change,
            dp: q.changePercentage,
            currency: "USD",
            shortName: q.name,
            symbol: symbol
        )
        quote.previousClose = q.previousClose
        quote.volume = q.volume.map(Double.init)
        quote.timestamp = q.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        quote.peRatio = nil  // moved to ratios-ttm in FMP stable API
        quote.eps = nil       // moved to ratios-ttm in FMP stable API
        quote.marketCap = q.marketCap
        return quote
    }

    // MARK: - Quote batch (300-400 watchlist warm tier)

    /// Groups symbols by market, fans out one-shot batch requests where
    /// available, and returns as soon as the global path resolves.
    /// BIST runs detached so a sleeping BorsaPy backend does not stall
    /// the warm tier; its results stream directly into MarketDataStore
    /// once they arrive.
    func requestQuotesBatch(symbols: [String], context: UsageContext = .interactive) async -> [String: Quote] {
        guard !symbols.isEmpty else { return [:] }

        // Resolve once so buckets, fallback filter, and chain closures
        // share the same canonical form.
        let routes: [Route] = symbols.map { sym in
            let resolved = resolver.resolve(sym)
            return Route(original: sym, resolved: resolved, destination: resolver.marketDestination(for: resolved))
        }
        let buckets = Dictionary(grouping: routes, by: \.destination)

        // BIST is decoupled: BorsaPy can take 5-30s when Render cold-
        // starts. Awaiting it here would also block the Stooq result
        // for every US ticker on the same watchlist. Run it detached
        // and let it write into the store on its own schedule.
        if let bist = buckets[.bist], !bist.isEmpty {
            Task { [weak self] in
                guard let self = self else { return }
                await self.streamBistBucket(bist)
            }
        }

        var combined: [String: Quote] = [:]

        // Faz II (2026-05-12) — Quote source determinism düzeltmesi.
        // Eski "first-gelen-kazanır" race: Stooq tipik 70-200ms, Alpaca
        // 200-400ms. Stooq önce dönüyor, `combined[key] == nil` filtresi
        // Alpaca'nın daha sonra gelen IEX RT sonucunu BLOKE EDİYORDU.
        // Sonuç: 15-dk delayed Stooq quote'u sembol başına final değer
        // oluyor; Alpaca free-tier'ından gereksiz HTTP atılıyordu ama
        // veri kullanılmıyordu.
        //
        // Yeni model: her bucket sonucu provider tag'i ile birleşiyor.
        // Sembol başına en yüksek önceli provider'ın sonucu saklanıyor
        // (Alpaca > Finnhub > Yahoo > Stooq > FMP). Aynı öncelikte daha
        // taze timestamp tercih ediliyor. Geliş sırası önemini kaybetti.
        var candidates: [String: (quote: Quote, priority: Int)] = [:]

        await withTaskGroup(of: QuoteBucketResult.self) { group in
            if let crypto = buckets[.crypto], !crypto.isEmpty, finnhub.hasKey {
                group.addTask { [weak self] in
                    guard let self = self else { return QuoteBucketResult(provider: "finnhub", quotes: [:]) }
                    let quotes = await self.parallelFetch(routes: crypto) { route in
                        do {
                            let q = try await self.finnhub.fetchQuote(symbol: route.resolved)
                            return q.with(symbol: route.original)
                        } catch {
                            await HeimdallLogger.shared.warn(
                                "crypto_finnhub_failed",
                                provider: "finnhub",
                                errorClass: self.classifyError(error),
                                errorMessage: "\(route.original): \(error.localizedDescription)",
                                endpoint: "fetchQuote"
                            )
                            throw error
                        }
                    }
                    // İncremental yazım: bucket bittiği anda MarketDataStore'a yaz.
                    // priority 2 (finnhub) — Alpaca (1) varsa override etmez.
                    for (sym, q) in quotes {
                        await MarketDataStore.shared.recordBatchQuote(
                            symbol: sym, quote: q,
                            source: "Batch-Finnhub",
                            priority: Self.providerPriority("finnhub")
                        )
                    }
                    return QuoteBucketResult(provider: "finnhub", quotes: quotes)
                }
            }
            // .usEquity için Alpaca multi-snapshot birincil (varsa). Stooq
            // batch'i de paralel çalışır; merge logic doğru provider'ı seçer.
            if let usEquity = buckets[.usEquity], !usEquity.isEmpty, alpaca.hasKey {
                group.addTask { [weak self] in
                    guard let self = self else { return QuoteBucketResult(provider: "alpaca", quotes: [:]) }
                    let quotes = await self.batchAlpacaBucket(usEquity)
                    // İncremental: Alpaca IEX-RT bucket ~500ms'de tamamlanıyor;
                    // diğer bucket'lar (Stooq 2s, Yahoo 5s+) tamamlanmasını bekletmeden
                    // UI'a yazsın. priority 1 → en yüksek, Stooq override edemez.
                    for (sym, q) in quotes {
                        await MarketDataStore.shared.recordBatchQuote(
                            symbol: sym, quote: q,
                            source: "Batch-Alpaca",
                            priority: Self.providerPriority("alpaca")
                        )
                    }
                    return QuoteBucketResult(provider: "alpaca", quotes: quotes)
                }
            }
            for destination: MarketDestination in [.usEquity, .index, .forex, .commodity] {
                if let bucket = buckets[destination], !bucket.isEmpty {
                    group.addTask { [weak self] in
                        guard let self = self else { return QuoteBucketResult(provider: "stooq", quotes: [:]) }
                        let quotes = await self.batchSnapshotBucket(bucket)
                        // İncremental: Stooq EOD/intraday batch sonucunu hemen yaz.
                        // priority 4 — Alpaca (1) veya Finnhub (2) zaten yazmışsa
                        // sembol için skip.
                        for (sym, q) in quotes {
                            await MarketDataStore.shared.recordBatchQuote(
                                symbol: sym, quote: q,
                                source: "Batch-Stooq",
                                priority: Self.providerPriority("stooq")
                            )
                        }
                        return QuoteBucketResult(provider: "stooq", quotes: quotes)
                    }
                }
            }

            for await result in group {
                let priority = Self.providerPriority(result.provider)
                for (key, value) in result.quotes {
                    if let existing = candidates[key] {
                        let shouldReplace: Bool
                        if priority < existing.priority {
                            // Yeni provider önceli daha iyi (Alpaca > Stooq)
                            shouldReplace = true
                        } else if priority > existing.priority {
                            shouldReplace = false
                        } else {
                            // Aynı öncelikte daha taze timestamp tercih
                            let newTs = value.timestamp ?? .distantPast
                            let existingTs = existing.quote.timestamp ?? .distantPast
                            shouldReplace = newTs > existingTs
                        }
                        if shouldReplace {
                            candidates[key] = (quote: value, priority: priority)
                        }
                    } else {
                        candidates[key] = (quote: value, priority: priority)
                    }
                }
            }
        }

        for (key, candidate) in candidates {
            combined[key] = candidate.quote
        }

        // Yahoo single-symbol backstop for anything the global buckets
        // did not satisfy. BIST is handled separately by the detached
        // task above so we exclude it here.
        let missing = routes.filter { route in
            guard combined[route.original] == nil else { return false }
            return route.destination != .bist
        }
        if !missing.isEmpty {
            let recovered = await yahooChunkedFallback(missing)
            // İncremental yazım: Yahoo fallback'i tamamlandıktan sonra hemen MDS'ye.
            // priority 3 — Alpaca/Finnhub varsa override edilmez.
            for (sym, q) in recovered {
                await MarketDataStore.shared.recordBatchQuote(
                    symbol: sym, quote: q,
                    source: "Batch-Yahoo",
                    priority: Self.providerPriority("yahoo")
                )
            }
            for (key, value) in recovered { combined[key] = value }
        }

        // Tüm fallback'ler bittikten sonra hâlâ değer alamayan non-BIST
        // sembolleri yansıt — yoksa silent return ile UI "—" gösterir,
        // hiçbir yerde sinyal kalmaz. BIST detached path üzerinden gelir.
        let nonBistRoutes = routes.filter { $0.destination != .bist }
        let nonBistMissing = nonBistRoutes.filter { combined[$0.original] == nil }
        if !nonBistMissing.isEmpty {
            let sample = nonBistMissing.prefix(10)
                .map { "\($0.original)[\($0.destination)]" }
                .joined(separator: ",")
            await HeimdallLogger.shared.warn(
                "batch_quote_missing",
                provider: "heimdall",
                errorClass: "no_quote_after_chain",
                errorMessage: "missing \(nonBistMissing.count)/\(nonBistRoutes.count): \(sample)",
                endpoint: "requestQuotesBatch"
            )
        }

        return combined
    }

    /// Walks the BIST bucket and pushes each successful fetch directly
    /// into `MarketDataStore`. Yahoo `.IS` is the fallback for symbols
    /// BorsaPy could not answer.
    private func streamBistBucket(_ routes: [Route]) async {
        await withTaskGroup(of: Void.self) { group in
            for route in routes {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    let bare = SymbolResolver.bareBistSymbol(route.resolved)
                    do {
                        let bist = try await self.borsaPy.getBistQuote(symbol: bare)
                        let quote = Self.convert(bist: bist, canonical: route.original)
                        await MarketDataStore.shared.recordBatchQuote(
                            symbol: route.original, quote: quote,
                            source: "Batch-BIST",
                            priority: Self.providerPriority("borsapy")
                        )
                    } catch {
                        // BorsaPy failed (sleeping, circuit open, network).
                        // Fall through to Yahoo `.IS` so the BIST symbol
                        // still lands in the store eventually.
                        await HeimdallLogger.shared.warn(
                            "bist_borsapy_failed",
                            provider: "borsapy",
                            errorClass: self.classifyError(error),
                            errorMessage: "\(route.original): \(error.localizedDescription)",
                            endpoint: "getBistQuote"
                        )
                        do {
                            let quote = try await self.yahoo.fetchQuote(symbol: route.resolved)
                            await MarketDataStore.shared.recordBatchQuote(
                                symbol: route.original, quote: quote,
                                source: "Batch-BIST-Yahoo",
                                priority: Self.providerPriority("yahoo")
                            )
                        } catch {
                            await HeimdallLogger.shared.warn(
                                "bist_yahoo_fallback_failed",
                                provider: "yahoo",
                                errorClass: self.classifyError(error),
                                errorMessage: "\(route.original): \(error.localizedDescription)",
                                endpoint: "fetchQuote(.IS)"
                            )
                        }
                    }
                }
            }
        }
    }

    private struct Route {
        let original: String
        let resolved: String
        let destination: MarketDestination
    }

    /// Faz II (2026-05-12): Bucket fetch sonucu provider tag'i ile.
    /// TaskGroup içinde sembol başına timestamp/priority-aware merge için
    /// gerekli — eski `[String: Quote]` payload provider bilgisini kaybediyordu.
    private struct QuoteBucketResult: Sendable {
        let provider: String
        let quotes: [String: Quote]
    }

    /// Generic parallel per-symbol fetch with timeout-friendly TaskGroup
    /// semantics. Used by buckets that have no native batch endpoint.
    private func parallelFetch(routes: [Route], fetch: @escaping (Route) async throws -> Quote) async -> [String: Quote] {
        var out: [String: Quote] = [:]
        await withTaskGroup(of: (String, Quote?).self) { group in
            for route in routes {
                group.addTask {
                    do {
                        return (route.original, try await fetch(route))
                    } catch {
                        return (route.original, nil)
                    }
                }
            }
            for await (symbol, quote) in group {
                if let quote = quote { out[symbol] = quote }
            }
        }
        return out
    }

    private func batchSnapshotBucket(_ routes: [Route]) async -> [String: Quote] {
        let circuit = circuitKey(provider: "stooq", endpoint: "quote")
        guard await HeimdallCircuitBreaker.shared.canRequest(provider: circuit) else {
            return [:]
        }
        do {
            let map = try await stooq.fetchSnapshotBatch(symbols: routes.map(\.resolved))
            await HeimdallCircuitBreaker.shared.reportSuccess(provider: circuit)
            var out: [String: Quote] = [:]
            for route in routes {
                if let quote = map[route.resolved] {
                    out[route.original] = quote.with(symbol: route.original)
                }
            }
            return out
        } catch {
            await HeimdallCircuitBreaker.shared.reportFailure(provider: circuit, error: error)
            await HeimdallLogger.shared.warn(
                "batch_snapshot_failed",
                provider: "stooq",
                errorClass: classifyError(error),
                errorMessage: error.localizedDescription,
                endpoint: "quote"
            )
            return [:]
        }
    }

    /// Alpaca multi-symbol snapshot bucket — used for `.usEquity` when
    /// the user has configured paper credentials. Returns up to 100
    /// symbols per HTTP call (IEX feed, real-time). Symbols Alpaca
    /// cannot resolve (BIST/FX/index/crypto) are filtered out by
    /// `AlpacaProvider.normalize`.
    private func batchAlpacaBucket(_ routes: [Route]) async -> [String: Quote] {
        guard alpaca.hasKey else { return [:] }
        let circuit = circuitKey(provider: "alpaca", endpoint: "quote")
        guard await HeimdallCircuitBreaker.shared.canRequest(provider: circuit) else {
            return [:]
        }
        do {
            let resolved = routes.map(\.resolved)
            let map = try await alpaca.fetchSnapshotBatch(symbols: resolved)
            await HeimdallCircuitBreaker.shared.reportSuccess(provider: circuit)
            var out: [String: Quote] = [:]
            for route in routes {
                guard let normalized = AlpacaProvider.normalize(route.resolved) else { continue }
                if let quote = map[normalized] {
                    out[route.original] = quote.with(symbol: route.original)
                }
            }
            return out
        } catch {
            await HeimdallCircuitBreaker.shared.reportFailure(provider: circuit, error: error)
            await HeimdallLogger.shared.warn(
                "batch_snapshot_failed",
                provider: "alpaca",
                errorClass: classifyError(error),
                errorMessage: error.localizedDescription,
                endpoint: "quote"
            )
            return [:]
        }
    }

    /// Yahoo single-symbol fetch fan-out for symbols Stooq dropped.
    /// 8 chunk x 800ms stays within Yahoo's 5 r/s sliding window.
    private func yahooChunkedFallback(_ routes: [Route]) async -> [String: Quote] {
        var out: [String: Quote] = [:]
        let chunkSize = 8
        let chunkDelayNs: UInt64 = 800_000_000

        let chunks = stride(from: 0, to: routes.count, by: chunkSize).map {
            Array(routes[$0..<min($0 + chunkSize, routes.count)])
        }
        for (index, batch) in chunks.enumerated() {
            let partial = await parallelFetch(routes: batch) { [yahoo, weak self] route in
                do {
                    return try await yahoo.fetchQuote(symbol: route.resolved)
                } catch {
                    await HeimdallLogger.shared.warn(
                        "yahoo_fallback_failed",
                        provider: "yahoo",
                        errorClass: self?.classifyError(error) ?? "unknown",
                        errorMessage: "\(route.original): \(error.localizedDescription)",
                        endpoint: "fetchQuote"
                    )
                    throw error
                }
            }
            for (key, value) in partial { out[key] = value }
            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: chunkDelayNs)
            }
        }
        return out
    }

    // MARK: - Fundamentals

    func requestFundamentals(symbol: String, context: UsageContext = .interactive) async throws -> FinancialsData {
        let resolved = resolver.resolve(symbol)
        let destination = resolver.marketDestination(for: resolved)

        if await SymbolBlocklist.shared.isBlocked(symbol) {
            if let cached = await getCachedFundamentals(symbol: symbol) { return cached }
            let reason = await SymbolBlocklist.shared.reasonFor(symbol) ?? "blocked"
            throw symbolBlockedError(provider: "argus", endpoint: "fundamentals", symbol: symbol, reason: reason)
        }

        await RateLimiter.shared.waitIfNeeded()

        let chain = fundamentalsChain(destination: destination, resolved: resolved, original: symbol)
        do {
            let (data, provider) = try await firstSuccess(chain, endpoint: "fundamentals", symbol: symbol)
            await SymbolBlocklist.shared.reportSuccess(symbol: symbol)
            DataCacheService.shared.save(value: data, kind: .fundamentals, symbol: symbol, source: provider)
            return data
        } catch {
            if isAuthOrEntitlementError(error) {
                await SymbolBlocklist.shared.reportFailure(symbol: symbol, reason: "fundamentals auth/paywall")
            }
            if shouldFallbackToCachedFundamentals(error),
               let cached = await getCachedFundamentals(symbol: symbol) {
                return cached
            }
            throw error
        }
    }

    private func fundamentalsChain(destination: MarketDestination, resolved: String, original: String) -> [ChainStep<FinancialsData>] {
        let bareBist = SymbolResolver.bareBistSymbol(resolved)

        switch destination {
        case .bist:
            return [
                ChainStep(provider: "borsapy") { [borsaPy] in
                    let bist = try await borsaPy.getFinancialStatements(symbol: bareBist)
                    return Self.convert(bistFinancials: bist, canonical: original)
                },
                ChainStep(provider: "yahoo") { [yahoo] in
                    try await yahoo.fetchFundamentals(symbol: resolved)
                }
            ]
        default:
            // 2026-05-11: SEC EDGAR Yahoo'dan SONRA, FMP'den ÖNCE.
            // Yahoo birincil (analyst targets, dividend yield, marketCap
            // gibi türev alanlar için). Yahoo fail edince SEC EDGAR
            // resmi XBRL — ham revenue/netIncome/cashFlow/debt/equity.
            // FMP free 250/day quota'sı bu sırayla korunur.
            var steps: [ChainStep<FinancialsData>] = [
                ChainStep(provider: "yahoo") { [yahoo] in
                    try await yahoo.fetchFundamentals(symbol: resolved)
                }
            ]
            if SECEdgarProvider.isLikelyUSEquity(resolved) {
                steps.append(ChainStep(provider: "sec_edgar") { [secEdgar] in
                    try await secEdgar.fetchFundamentals(symbol: resolved)
                })
            }
            steps.append(contentsOf: [
                ChainStep(provider: "fmp") { [fmp, finnhub] in
                    let metrics = try? await finnhub.fetchBasicFinancials(symbol: resolved)
                    return try await fmp.fetchFundamentals(symbol: resolved, mergingFinnhub: metrics)
                },
                ChainStep(provider: "finnhub") { [finnhub] in
                    let metrics = try await finnhub.fetchBasicFinancials(symbol: resolved)
                    return Self.convert(finnhubMetrics: metrics, canonical: original)
                }
            ])
            return steps
        }
    }

    // MARK: - Candles

    func requestCandles(
        symbol: String,
        timeframe: String,
        limit: Int,
        context: UsageContext = .interactive,
        provider providerTag: ProviderTag? = nil,
        instrument: CanonicalInstrument? = nil
    ) async throws -> [Candle] {
        if await SymbolBlocklist.shared.isBlocked(symbol),
           let reason = await SymbolBlocklist.shared.reasonFor(symbol) {
            throw symbolBlockedError(provider: "argus", endpoint: "candles", symbol: symbol, reason: reason)
        }
        await RateLimiter.shared.waitIfNeeded()

        let resolved = resolver.resolve(symbol)
        let destination = resolver.marketDestination(for: resolved)
        let chain = candleChain(destination: destination, resolved: resolved, original: symbol, timeframe: timeframe, limit: limit)
        do {
            let (candles, _) = try await firstSuccess(chain, endpoint: "candles", symbol: symbol)
            await SymbolBlocklist.shared.reportSuccess(symbol: symbol)
            return candles
        } catch {
            if isAuthOrEntitlementError(error) {
                await SymbolBlocklist.shared.reportFailure(symbol: symbol, reason: "candles auth/paywall")
            }
            throw error
        }
    }

    private func candleChain(destination: MarketDestination, resolved: String, original: String, timeframe: String, limit: Int) -> [ChainStep<[Candle]>] {
        let isDaily = Self.isDailyOrLonger(timeframe: timeframe)
        let bareBist = SymbolResolver.bareBistSymbol(resolved)

        switch destination {
        case .bist:
            // 2026-05-11: BIST daily için İş Yatırım eklendi — BorsaPy
            // cold-start veya circuit OPEN olduğunda hızlı fallback.
            // İntraday BIST kapsamı yok (sadece daily), o yüzden Yahoo
            // intraday için son halka olarak duruyor.
            var steps: [ChainStep<[Candle]>] = []
            if isDaily {
                steps.append(ChainStep(provider: "borsapy") { [borsaPy] in
                    let bistCandles = try await borsaPy.getBistHistory(symbol: bareBist, days: max(limit, 30))
                    return bistCandles.map { Candle(date: $0.date, open: $0.open, high: $0.high, low: $0.low, close: $0.close, volume: $0.volume) }
                })
                steps.append(ChainStep(provider: "isyatirim") { [isYatirim] in
                    try await isYatirim.fetchCandles(symbol: bareBist, days: max(limit, 30))
                })
            }
            steps.append(ChainStep(provider: "yahoo") { [yahoo] in
                try await yahoo.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
            })
            return steps
        case .crypto:
            // Binance birincil (cömert limit, derin tarihçe). Coinbase
            // yedek (Binance geo-block riskine karşı). Finnhub key var
            // ise ikinci alternatif. Yahoo en son.
            return [
                ChainStep(provider: "binance")  { [binance]  in
                    try await binance.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
                },
                ChainStep(provider: "coinbase") { [coinbase] in
                    try await coinbase.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
                },
                ChainStep(provider: "finnhub")  { [finnhub]  in
                    try await finnhub.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
                },
                ChainStep(provider: "yahoo")    { [yahoo]    in
                    try await yahoo.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
                }
            ]
        case .usEquity:
            // 2026-05-11: Alpaca paper IEX birincil — 5+ yıl history, daily
            // + intraday (1Min/5Min/15Min/30Min/1Hour/4Hour/1Day/1Week/
            // 1Month), 200 r/dk. Key yoksa Yahoo → Finnhub fallback.
            var steps: [ChainStep<[Candle]>] = []
            if alpaca.hasKey {
                steps.append(ChainStep(provider: "alpaca") { [alpaca] in
                    try await alpaca.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
                })
            }
            steps.append(contentsOf: [
                ChainStep(provider: "yahoo") { [yahoo] in
                    try await yahoo.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
                },
                ChainStep(provider: "finnhub") { [finnhub] in
                    try await finnhub.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
                }
            ])
            return steps
        case .index, .forex, .commodity:
            // Alpaca free-tier IEX feed indeks/FX/commodity sağlamıyor.
            // Stooq candle endpoint Mayıs 2026'da captcha-gated oldu;
            // Yahoo birincil, Finnhub backstop.
            return [
                ChainStep(provider: "yahoo") { [yahoo] in
                    try await yahoo.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
                },
                ChainStep(provider: "finnhub") { [finnhub] in
                    try await finnhub.fetchCandles(symbol: resolved, timeframe: timeframe, limit: limit)
                }
            ]
        }
    }

    // MARK: - News

    func requestNews(symbol: String, limit: Int = 10, context: UsageContext = .interactive) async throws -> [NewsArticle] {
        await RateLimiter.shared.waitIfNeeded()
        // 2026-05-11: GoogleNewsRSS birincil (hızlı, cache var). Boş veya
        // hata dönerse GDELT yedek (3-aylık dünya geneli, ticker-tone).
        do {
            let articles = try await news.fetchNews(symbol: symbol, limit: limit)
            if !articles.isEmpty { return articles }
            return (try? await gdelt.fetchNews(symbol: symbol, limit: limit)) ?? []
        } catch {
            return (try? await gdelt.fetchNews(symbol: symbol, limit: limit)) ?? []
        }
    }

    // MARK: - Screener

    func requestScreener(type: ScreenerType, limit: Int = 10) async throws -> [Quote] {
        await RateLimiter.shared.waitIfNeeded()
        let circuit = circuitKey(provider: "yahoo", endpoint: "screener")
        if await HeimdallCircuitBreaker.shared.canRequest(provider: circuit) {
            do {
                let result = try await yahoo.fetchScreener(type: type, limit: limit)
                await HeimdallCircuitBreaker.shared.reportSuccess(provider: circuit)
                return result
            } catch {
                if !isLocalThrottle(error) {
                    await HeimdallCircuitBreaker.shared.reportFailure(provider: circuit, error: error)
                }
                await HeimdallLogger.shared.warn(
                    "screener_yahoo_failed",
                    provider: "yahoo",
                    errorClass: classifyError(error),
                    errorMessage: error.localizedDescription,
                    endpoint: "screener"
                )
            }
        }
        // Local universe fallback: a small fixed list ranked by Stooq snapshot.
        let snapshot = try await stooq.fetchSnapshotBatch(symbols: Self.screenerUniverse)
        switch type {
        case .gainers:
            return Array(snapshot.values.sorted { ($0.dp ?? 0) > ($1.dp ?? 0) }.prefix(limit))
        case .losers:
            return Array(snapshot.values.sorted { ($0.dp ?? 0) < ($1.dp ?? 0) }.prefix(limit))
        case .mostActive:
            return Array(snapshot.values.sorted { ($0.volume ?? 0) > ($1.volume ?? 0) }.prefix(limit))
        case .etf:
            return Array(snapshot.values.prefix(limit))
        }
    }

    // MARK: - Macro

    func requestMacro(symbol: String, context: UsageContext = .interactive) async throws -> HeimdallMacroIndicator {
        if symbol.hasPrefix("FRED.") || ["INFLATION", "FEDFUNDS", "GDP", "UNRATE"].contains(symbol) {
            let seriesId: String
            switch symbol {
            case "INFLATION": seriesId = "CPIAUCSL"
            case "FEDFUNDS":  seriesId = "FEDFUNDS"
            case "GDP":       seriesId = "GDPC1"
            case "UNRATE":    seriesId = "UNRATE"
            default: seriesId = symbol.replacingOccurrences(of: "FRED.", with: "")
            }
            let series = try await fred.fetchSeries(seriesId: seriesId, limit: 1)
            guard let latest = series.first else { throw URLError(.badServerResponse) }
            return HeimdallMacroIndicator(
                symbol: symbol,
                value: latest.1,
                change: nil,
                changePercent: nil,
                lastUpdated: latest.0
            )
        }

        let resolved = resolver.resolve(symbol)
        let chain: [ChainStep<HeimdallMacroIndicator>] = [
            ChainStep(provider: "yahoo") { [yahoo] in
                try await yahoo.fetchMacro(symbol: resolved)
            },
            ChainStep(provider: "stooq") { [stooq] in
                let map = try await stooq.fetchSnapshotBatch(symbols: [resolved])
                guard let quote = map[resolved] else {
                    throw HeimdallCoreError(category: .emptyPayload, code: 204, message: "Stooq macro empty for \(resolved)", bodyPrefix: "")
                }
                return HeimdallMacroIndicator(
                    symbol: symbol,
                    value: quote.c,
                    change: quote.d,
                    changePercent: quote.dp,
                    lastUpdated: quote.timestamp ?? Date()
                )
            }
        ]
        let (indicator, _) = try await firstSuccess(chain, endpoint: "macro", symbol: symbol)
        return indicator
    }

    func requestMacroSeries(instrument: CanonicalInstrument, limit: Int = 24) async throws -> [(Date, Double)] {
        guard let seriesId = instrument.fredSeriesId else {
            throw HeimdallCoreError(category: .symbolNotFound, code: 404, message: "No FRED Series ID for \(instrument.internalId)", bodyPrefix: "")
        }
        return try await fred.fetchSeries(seriesId: seriesId, limit: limit)
    }

    func requestFredSeries(series: FredProvider.SeriesInfo, limit: Int = 24) async throws -> [(Date, Double)] {
        try await fred.fetchSeries(seriesId: series.rawValue, limit: limit)
    }

    func requestInstrumentCandles(instrument: CanonicalInstrument, timeframe: String = "1D", limit: Int = 60) async throws -> [Candle] {
        if instrument.internalId == "macro.trend" {
            throw HeimdallCoreError(category: .unknown, code: 400, message: "Cannot fetch candles for derived (TREND)", bodyPrefix: "")
        }
        let symbol = instrument.yahooSymbol ?? instrument.internalId
        return try await requestCandles(symbol: symbol, timeframe: timeframe, limit: limit, instrument: instrument)
    }

    // MARK: - System health

    enum SystemHealthStatus: String {
        case operational = "Operational"
        case degraded = "Degraded"
        case critical = "Critical - DO NOT TRADE"
    }

    func checkSystemHealth() async -> SystemHealthStatus {
        do {
            _ = try await yahoo.fetchQuote(symbol: "SPY")
            return .operational
        } catch {
            if isLocalThrottle(error) { return .degraded }
            // If Yahoo is misbehaving but Stooq still works, downgrade
            // rather than blocking the whole app.
            if (try? await stooq.fetchSnapshotBatch(symbols: ["SPY"])) != nil {
                return .degraded
            }
            return .critical
        }
    }

    func getProviderScores() async -> [String: ProviderScore] {
        return [
            "Yahoo": ProviderScore.neutral,
            "Stooq": ProviderScore.neutral,
            "Finnhub": ProviderScore.neutral,
            "BorsaPy": ProviderScore.neutral,
            "FMP": ProviderScore.neutral,
            "Binance": ProviderScore.neutral
        ]
    }

    // MARK: - Conversion helpers

    private static let screenerUniverse: [String] = [
        "AAPL", "MSFT", "GOOGL", "AMZN", "NVDA", "META", "TSLA", "JPM",
        "V", "JNJ", "WMT", "PG", "HD", "MA", "DIS", "BAC", "XOM", "PFE",
        "INTC", "CSCO", "T", "VZ", "PEP", "KO"
    ]

    private static func isDailyOrLonger(timeframe: String) -> Bool {
        switch timeframe.lowercased() {
        case "1d", "1day", "1g", "d", "1week", "1wk", "1w", "1month", "1mo", "3month", "1y": return true
        default: return false
        }
    }

    /// Faz II (2026-05-12) — Quote source önceliği. Düşük sayı = daha iyi.
    /// Sembol başına birden fazla provider sonucu geldiğinde hangisinin
    /// final değer olarak kalacağına `requestQuotesBatch` merge logic'i
    /// bu öncelik tablosuna göre karar verir. Aynı öncelikteki iki provider
    /// arasında daha taze timestamp kazanır.
    ///
    /// Önceliklendirme gerekçesi:
    ///   alpaca  (IEX RT, market hours boyunca canlı)
    ///   finnhub (RT paid / 60s free; çoğu sembol için tazedir)
    ///   yahoo   (delayed ama analyst/fundamentals zenginliği var; quote için mid)
    ///   stooq   (15-dk delayed snapshot)
    ///   fmp     (delayed)
    private static func providerPriority(_ provider: String) -> Int {
        switch provider {
        case "alpaca":    return 1
        case "borsapy":   return 1  // BIST primary (cold-sleep ama doğrudan veri)
        case "finnhub":   return 2
        case "isyatirim": return 2  // BIST CDN-destekli alternatif
        case "yahoo":     return 3
        case "stooq":     return 4
        case "fmp":       return 5
        default:          return 99
        }
    }

    nonisolated static func convert(bist: BistQuote, canonical: String) -> Quote {
        let prevClose = bist.previousClose > 0 ? bist.previousClose : nil
        var quote = Quote(
            c: bist.last,
            d: prevClose.map { bist.last - $0 },
            dp: prevClose.map { (bist.last - $0) / $0 * 100 },
            currency: "TRY",
            shortName: nil,
            symbol: canonical
        )
        quote.previousClose = prevClose
        quote.volume = bist.volume
        quote.timestamp = bist.timestamp
        return quote
    }

    nonisolated static func convert(bistFinancials: BistFinancials, canonical: String) -> FinancialsData {
        var data = FinancialsData(
            symbol: canonical,
            currency: "TRY",
            lastUpdated: bistFinancials.timestamp,
            totalRevenue: bistFinancials.revenue,
            netIncome: bistFinancials.netProfit,
            totalShareholderEquity: bistFinancials.totalEquity,
            marketCap: bistFinancials.marketCap,
            revenueHistory: [],
            netIncomeHistory: [],
            ebitda: bistFinancials.ebitda,
            shortTermDebt: bistFinancials.shortTermDebt,
            longTermDebt: bistFinancials.longTermDebt,
            operatingCashflow: bistFinancials.operatingCashFlow,
            capitalExpenditures: nil,
            cashAndCashEquivalents: bistFinancials.cash,
            peRatio: bistFinancials.pe,
            forwardPERatio: nil,
            priceToBook: bistFinancials.pb,
            evToEbitda: nil,
            dividendYield: nil,
            earningsPerShare: bistFinancials.eps,
            forwardGrowthEstimate: nil,
            isETF: false,
            targetMeanPrice: nil,
            targetHighPrice: nil,
            targetLowPrice: nil,
            recommendationMean: nil,
            numberOfAnalystOpinions: nil
        )
        data.profitMargin = bistFinancials.netMargin
        data.returnOnEquity = bistFinancials.roe
        data.returnOnAssets = bistFinancials.roa
        data.debtToEquity = bistFinancials.debtToEquity
        data.currentRatio = bistFinancials.currentRatio
        data.revenueGrowth = bistFinancials.revenueGrowth
        data.earningsGrowth = bistFinancials.netProfitGrowth
        data.grossMargin = bistFinancials.grossMargin
        data.operatingMargin = bistFinancials.operatingMargin
        return data
    }

    nonisolated static func convert(finnhubMetrics: FinnhubProvider.BasicFinancials, canonical: String) -> FinancialsData {
        var data = FinancialsData(
            symbol: canonical,
            currency: "USD",
            lastUpdated: Date(),
            totalRevenue: finnhubMetrics.revenueTTM,
            netIncome: finnhubMetrics.netIncomeAnnual,
            totalShareholderEquity: nil,
            marketCap: finnhubMetrics.marketCapitalization,
            revenueHistory: [],
            netIncomeHistory: [],
            ebitda: nil,
            shortTermDebt: nil,
            longTermDebt: nil,
            operatingCashflow: nil,
            capitalExpenditures: nil,
            cashAndCashEquivalents: nil,
            peRatio: finnhubMetrics.peTTM,
            forwardPERatio: nil,
            priceToBook: finnhubMetrics.pbAnnual,
            evToEbitda: nil,
            dividendYield: finnhubMetrics.dividendYieldIndicatedAnnual,
            earningsPerShare: finnhubMetrics.epsTTM,
            forwardGrowthEstimate: nil,
            isETF: false,
            targetMeanPrice: nil,
            targetHighPrice: nil,
            targetLowPrice: nil,
            recommendationMean: nil,
            numberOfAnalystOpinions: nil
        )
        data.returnOnEquity = finnhubMetrics.roeTTM
        data.currentRatio = finnhubMetrics.currentRatioAnnual
        return data
    }

    private func shouldFallbackToCachedFundamentals(_ error: Error) -> Bool {
        if let heimdallError = error as? HeimdallCoreError {
            switch heimdallError.category {
            case .rateLimited, .serverError, .networkError, .circuitOpen:
                return true
            default:
                return heimdallError.code == 1013
            }
        }
        let nsError = error as NSError
        if nsError.code == 1013 || nsError.code == 429 { return true }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("1013") || message.contains("rate limit") || message.contains("try again later")
    }

    private func getCachedFundamentals(symbol: String) async -> FinancialsData? {
        guard let entry = await DataCacheService.shared.getEntry(kind: .fundamentals, symbol: symbol) else {
            return nil
        }
        return try? JSONDecoder().decode(FinancialsData.self, from: entry.data)
    }
}

// MARK: - Quote rename helper

private extension Quote {
    func with(symbol: String) -> Quote {
        var copy = self
        copy.symbol = symbol
        return copy
    }
}

/// Hint for upstream callers about how a request should be prioritized
/// (interactive vs background vs realtime). Not yet wired into rate
/// limiter scheduling; kept on the public API so a future PR can use
/// it without breaking signatures.
enum UsageContext {
    case interactive
    case background
    case realtime
}
