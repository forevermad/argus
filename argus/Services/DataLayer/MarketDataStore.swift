import Foundation
import Combine

/// Unified Data Store - The Single Source of Truth
/// Owns all data caches, handles request coalescing (deduplication), and enforces TTLs.
@MainActor
final class MarketDataStore: ObservableObject {
    static let shared = MarketDataStore()
    
    // MARK: - State (The Truth)
    // We use DataValue wrapper to include Provenance and Freshness
    @Published var quotes: [String: DataValue<Quote>] = [:]
    @Published var candles: [String: DataValue<[Candle]>] = [:]
    @Published var fundamentals: [String: DataValue<FinancialsData>] = [:]
    @Published var macro: [String: DataValue<MacroData>] = [:]
    
    // MARK: - Coalescing (Flight Control)
    private var quoteTasks: [String: Task<Quote, Error>] = [:]
    private var candleTasks: [String: Task<[Candle], Error>] = [:]
    private var macroTasks: [String: Task<MacroData, Error>] = [:]
    private var fundamentalTasks: [String: Task<FinancialsData, Error>] = [:]

    // MARK: - Per-symbol provider priority lock (2026-05-14)
    /// `recordBatchQuote` çağrıldığında hangi provider'ın yazdığını sayısal öncelik
    /// ile takip eder. Aynı round içinde Alpaca (priority 1) bir sembolü yazdıktan
    /// sonra Stooq (priority 4) onun üzerine yazamaz — yoksa IEX-RT quote'un yerine
    /// 15-min delayed kapanış geçer (Faz II "Quote Source Determinism" recordBatchQuote
    /// için açıktı, sadece combined-map merge'inde çözülmüştü).
    /// Refresh round başında `ensureQuotes` ilgili sembolleri sıfırlar.
    private var lastQuotePriority: [String: Int] = [:]

    // MARK: - User Focus (Phase 6 PR-C.2)
    /// Detay sayfası açıldığında bu sembol set edilir. AutoPilot taraması
    /// kullanıcı bir sembolde odaklıyken çalışmamalı — onun yerine **odaklanılan
    /// sembolün** istekleri full bant genişliğine erişsin. Detay sayfası
    /// `.onAppear { setUserFocus(symbol) }` / `.onDisappear { clearUserFocus() }`
    /// pattern'iyle yönetir. AutoPilot.scanMarket başında bu değer kontrol edilir.
    @Published var userFocusedSymbol: String?

    func setUserFocus(_ symbol: String) {
        userFocusedSymbol = symbol
    }

    func clearUserFocus() {
        userFocusedSymbol = nil
    }

    /// BorsaPy warmup tamamlandıktan sonra çağrılır. Cold-start süresinde
    /// fallback sağlayıcıdan (İş Yatırım / Yahoo) cache'e giren eski BIST
    /// fiyatlarını stale işaretler; SWR BorsaPy'den taze veri çeker.
    func invalidateBistQuotes() {
        let bistKeys = quotes.keys.filter { $0.uppercased().hasSuffix(".IS") }
        for key in bistKeys {
            guard let old = quotes[key], old.value != nil else { continue }
            quotes[key] = DataValue(value: old.value, provenance: old.provenance, status: .stale)
        }
        if !bistKeys.isEmpty {
            print("🔄 MarketDataStore: \(bistKeys.count) BIST quote stale işaretlendi (BorsaPy warmup sonrası yenileme).")
        }
    }
    
    // MARK: - Configuration
    // 2026-05-04: Quote TTL 60 → 180s (3 dakika). Watchlist refresh interval'iyle
    // hizalandı. Eski 60sn'de refresh tam TTL süresinde tekrar tetikleniyordu →
    // AutoPilot/Scout her seferinde stale cache + SWR triggering = Yahoo'ya çift
    // fan-out. 180sn TTL + 180sn refresh = aynı pencere içinde gerçek cache hit.
    // Intra-day fiyat hareketi için 180sn hâlâ kabul edilebilir (UI 5sn streaming
    // injection ile zaten taze).
    // Phase 5 (2026-04-29): Quote TTL 15s → 60s.
    private let quoteTTL: TimeInterval = 180 // 180 seconds (was 60, was 15)
    private let macroTTL: TimeInterval = 3600 // 1 hour (Macro changes slowly)
    private let fundamentalsTTL: TimeInterval = 86400 // 24 hours
    
    private init() {}
    
    // MARK: - Public API (Accessors)
    
    func getQuote(for symbol: String) -> Quote? {
        return quotes[symbol]?.value
    }
    
    // Provenance Access
    func getQuoteProvenance(for symbol: String) -> DataProvenance? {
        return quotes[symbol]?.provenance
    }
    
    /// Live Quotes Dictionary - TradingViewModel uyumlu format
    /// DataValue wrapper'ı unwrap ederek [String: Quote] döndürür
    var liveQuotes: [String: Quote] {
        var result: [String: Quote] = [:]
        for (symbol, dataValue) in quotes {
            if let quote = dataValue.value {
                result[symbol] = quote
            }
        }
        return result
    }

    /// Injection for Streaming Engine (MarketDataProvider)
    func injectLiveQuote(_ quote: Quote, source: String) {
        guard let sym = quote.symbol else { return }

        // Drop duplicate ticks to avoid invalidating SwiftUI on every
        // identical frame. WS sources can emit several ticks per second
        // for liquid names; without this guard each one publishes an
        // unchanged Quote downstream.
        if let existing = quotes[sym]?.value,
           existing.c == quote.c,
           existing.timestamp == quote.timestamp {
            return
        }

        var finalQuote = quote

        // MERGE LOGIC: Preserve rich data (Previous Close, Name, etc.) from existing Cache
        if let existing = quotes[sym]?.value {
            if finalQuote.previousClose == nil {
                finalQuote.previousClose = existing.previousClose
            }
            if finalQuote.shortName == nil {
                finalQuote.shortName = existing.shortName
            }
            if finalQuote.marketCap == nil {
                finalQuote.marketCap = existing.marketCap
            }
            if finalQuote.peRatio == nil {
                finalQuote.peRatio = existing.peRatio
            }
        }
        
        // SESSION BASELINE LOGIC (Sychronized with ViewModel)
        // If no previousClose exists (even after merge), assume current price is the start.
        if finalQuote.previousClose == nil || finalQuote.previousClose == 0 {
            finalQuote.previousClose = finalQuote.currentPrice
        }
        
        // Manual Recalculation (Session based change)
        if (finalQuote.d == nil || finalQuote.d == 0) && (finalQuote.previousClose != nil && finalQuote.previousClose! > 0) {
            finalQuote.d = finalQuote.currentPrice - finalQuote.previousClose!
            finalQuote.dp = (finalQuote.d! / finalQuote.previousClose!) * 100.0
        }
            // If the stream sends 0 change, and we have previousClose, let the computed property handle it.
            // But we must ensure d/dp are nil if strictly 0 so the computed property kicks in? 
            // Actually Quote.change logic is: if d != 0 return d. 
            // TwelveDataService sends 0. So we should probably reset d/dp to nil if they are 0 in the stream, 
            // so the specific logic `if let val = d, val != 0` skips and goes to `previousClose`.
            
        // MANUAL DERIVATION (Senior Architect Fix)
        // If the Stream/Provider sends 0.00% (or nil), we MUST attempt to derive it from Cached Candles.
        // This is the "Safety Net" for the 0.00% bug.
        if (finalQuote.dp == nil || finalQuote.dp == 0) {
            // Check Cached Candles for this symbol
            // We need a synchronous check or assume "injectLiveQuote" might be called often.
            // Since this is MainActor, we can access 'candles' directly.
            
            // Try 1-Day Candles first (Best for Day Change)
            if let dailyData = candles["\(sym)_1d"]?.value ?? candles["\(sym)_1day"]?.value {
                 if dailyData.count >= 2 {
                     // Last candle is "today" (incomplete), previous is "yesterday"
                     let prevClose = dailyData[dailyData.count - 2].close
                     if prevClose > 0 {
                         finalQuote.previousClose = prevClose // Correct the baseline
                         finalQuote.d = finalQuote.currentPrice - prevClose
                         finalQuote.dp = (finalQuote.d! / prevClose) * 100.0
                     }
                 }
            }
        }

        // Final Cleanup: If still 0, ensure it's nil so UI shows "—" instead of "0.00%"
        // This enforces the "No Fake Data" rule.
        if finalQuote.dp == 0.0 && finalQuote.d == 0.0 {
             // Only if price is also 0? No, if price hasn't moved it IS 0.00.
             // But usually it's unlikely to be EXACTLY 0.000000 unless market is closed and no data.
             // We'll leave it 0.0 if we successfully calculated it, but if it was 0 from start and we failed to calculate,
             // we might want to mark it?
             // For now, let's trust the logic above. If we found a prevClose, 0 is valid.
             // If we didn't fine prevClose, we set d/dp to nil.
             if finalQuote.previousClose == nil || finalQuote.previousClose == 0 {
                 finalQuote.d = nil
                 finalQuote.dp = nil
             }
        }
        
        self.quotes[sym] = DataValue.fresh(finalQuote, source: source)
    }
    
    func getDataValueQuote(for symbol: String) -> DataValue<Quote>? {
        return quotes[symbol]
    }
    
    // MARK: - Generic Fetch Orchestration
    
    /// Ensures we have fresh Quote data. Returns the data (cached or fetched).
    ///
    /// Phase 6 PR-D (2026-04-29) — Stale-While-Revalidate.
    /// Cache stale ama mevcut bir değer varsa eski veri **anında** döner ve arka
    /// planda fresh fetch tetiklenir. Kullanıcı asla "Hazırlanıyor" boş ekran
    /// görmez (cache'inde değer varsa). Yalnızca cache hiç yok ya da çok eski
    /// (4× TTL) ise blocking fetch yapılır.
    @discardableResult
    func ensureQuote(symbol: String) async -> DataValue<Quote> {
        // 1. Check Cache
        if let current = quotes[symbol] {
            let age = -current.provenance.fetchedAt.timeIntervalSinceNow

            // 1a. Fresh: hemen dön.
            if current.isFresh && age < quoteTTL {
                return current
            }

            // 1b. Stale-while-revalidate: değer var, makul yaşta (<4× TTL),
            //     in-flight task yok → eski veriyi anında dön + arka planda yenile.
            if current.value != nil,
               age < quoteTTL * 4,
               quoteTasks[symbol] == nil {
                Task { [weak self] in
                    _ = await self?.fetchAndStoreQuote(symbol: symbol)
                }
                return current
            }
        }

        // 2. Check In-Flight (Dedup)
        if let existingTask = quoteTasks[symbol] {
            do {
                let result = try await existingTask.value
                return processQuoteSuccess(symbol: symbol, quote: result, source: "Coalesced")
            } catch {
                return processQuoteFailure(symbol: symbol, error: error)
            }
        }

        // 3. Phase 7 PR-Q+: Daily candle cache'inden türet.
        //    Cache hiç yok ama daily candle var → ek istek atmadan quote ürer.
        //    Detay panelinden ya da daha önce çekilmiş bir candles var ise
        //    quote için ayrıca network gitmeye gerek yok. Arka planda yine
        //    fresh quote fetch tetiklenir (UI'a sonra gelir).
        if let derived = quoteFromDailyCache(symbol: symbol) {
            let val = processQuoteSuccess(symbol: symbol, quote: derived, source: "Derived-Candle")
            Task { [weak self] in
                _ = await self?.fetchAndStoreQuote(symbol: symbol)
            }
            return val
        }

        // 4. Blocking fetch — hiçbir kaynak yok.
        return await fetchAndStoreQuote(symbol: symbol)
    }

    /// Phase 7 PR-Q+: Daily candle cache'inden quote türetir.
    /// 1d/1day master cache'inde en az 2 bar varsa son kapanış = current,
    /// önceki bar = previous close → quote inşa edilir. Currency sembol
    /// pattern'ından infer edilir (`.IS` → TRY, `-USD` → USD, default USD).
    /// Yetersiz veri / kötü prev → nil.
    private func quoteFromDailyCache(symbol: String) -> Quote? {
        let candidates = ["\(symbol)_1day"]
        for key in candidates {
            guard let candleList = candles[key]?.value, candleList.count >= 2 else { continue }
            guard let last = candleList.last else { continue }
            let prev = candleList[candleList.count - 2]
            guard prev.close > 0 else { continue }

            let change = last.close - prev.close
            let pct = (change / prev.close) * 100

            let upper = symbol.uppercased()
            let inferredCurrency: String = {
                if upper.hasSuffix(".IS") { return "TRY" }
                if upper.contains("-USD") { return "USD" }
                if upper.hasSuffix("=X") { return "USD" }
                if upper.hasSuffix("=F") { return "USD" }
                return "USD"
            }()

            var q = Quote(
                c: last.close,
                d: change,
                dp: pct,
                currency: inferredCurrency,
                shortName: nil,
                symbol: symbol
            )
            q.previousClose = prev.close
            q.timestamp = Date()
            return q
        }
        return nil
    }

    /// Yeni bir quote fetch task'i başlatır, sonucu cache'e yazar ve döndürür.
    /// `ensureQuote` (foreground) ve stale-while-revalidate (background) yolları
    /// tarafından paylaşılır — fetch logic tek source-of-truth.
    @discardableResult
    private func fetchAndStoreQuote(symbol: String) async -> DataValue<Quote> {
        let task = Task<Quote, Error> {
            return try await HeimdallOrchestrator.shared.requestQuote(symbol: symbol)
        }
        quoteTasks[symbol] = task

        do {
            let result = try await task.value
            quoteTasks[symbol] = nil
            return processQuoteSuccess(symbol: symbol, quote: result, source: "Heimdall")
        } catch {
            quoteTasks[symbol] = nil
            return processQuoteFailure(symbol: symbol, error: error)
        }
    }
    
    private func processQuoteSuccess(symbol: String, quote: Quote, source: String) -> DataValue<Quote> {
        let val = DataValue.fresh(quote, source: source)
        self.quotes[symbol] = val
        return val
    }

    /// Direct batch ingestion for slow buckets (BIST + global Alpaca/Stooq/Finnhub/Yahoo)
    /// that orchestrate themselves outside of `ensureQuotes`. The bucket pushes results
    /// here as soon as each symbol resolves, without blocking the global warm-tier path.
    ///
    /// `priority` low value = better provider. Aynı sembol için daha önce daha öncelikli
    /// bir provider yazdıysa (Alpaca=1), sonra gelen daha düşük öncelikli yazımlar (Stooq=4)
    /// reddedilir. Default 99 → eski API çağrıları her zaman yazar (geriye uyumlu).
    func recordBatchQuote(symbol: String, quote: Quote, source: String = "Batch", priority: Int = 99) {
        if let existing = lastQuotePriority[symbol], priority > existing {
            return  // mevcut yazım daha öncelikli (daha düşük sayı)
        }
        lastQuotePriority[symbol] = priority
        _ = processQuoteSuccess(symbol: symbol, quote: quote, source: source)
    }
    
    private func processQuoteFailure(symbol: String, error: Error) -> DataValue<Quote> {
        // print yerine kategori bazlı log — DataPipeline bölümünden filtrelenir.
        // Eski veri varsa stale olarak korunur ki UI "boş" yerine "eski" gösterebilsin.
        let msg = error.localizedDescription
        if let old = quotes[symbol], old.value != nil {
            ArgusLogger.info("\(symbol) quote fetch başarısız (\(msg)) — stale fallback", category: "DataPipeline")
            let newVal = DataValue(
                value: old.value,
                provenance: old.provenance,
                status: .stale
            )
            self.quotes[symbol] = newVal
            return newVal
        }

        ArgusLogger.warn("\(symbol) quote fetch başarısız + cache yok: \(msg)", category: "DataPipeline")
        let missing = DataValue<Quote>.missing(reason: msg)
        self.quotes[symbol] = missing
        return missing
    }
    
    // MARK: - Candles
    
    func ensureCandles(symbol: String, timeframe: String) async -> DataValue<[Candle]> {
        // Phase 5 (2026-04-29): Cache key normalizasyonu.
        let canonicalTimeframe = Self.normalizeTimeframe(timeframe)
        let key = "\(symbol)_\(canonicalTimeframe)"

        // Phase 7+ (2026-04-29): Candle TTL + SWR.
        // `DataValue.isFresh` 15 saniye sonra stale sayıyordu — günlük mum 15 sn'de
        // değişmez, ama eskiden ensureCandles 15 sn sonra tekrar fetch'e gidiyordu.
        // Prometheus + Orion peş peşe açılınca aynı candle 2-3 kez fetch ediliyor →
        // ikincisi rate-limit / cancel yiyince Orion fail → "Analiz Başarısız" hatası.
        //
        // Yeni: timeframe-bazlı TTL + stale-while-revalidate. Cache'te değer varsa
        // anında dön; eski ise arkada yenile.
        if let current = candles[key], let value = current.value, !value.isEmpty {
            let age = -current.provenance.fetchedAt.timeIntervalSinceNow
            let ttl = Self.candleTTL(for: canonicalTimeframe)

            // Fresh: hemen dön.
            if age < ttl { return current }

            // Stale: eski değeri DÖNDÜR + arka planda yenile (SWR).
            // In-flight task varsa yeni başlatma — coalescing.
            if candleTasks[key] == nil && age < ttl * 4 {
                Task { [weak self] in
                    _ = await self?.fetchAndStoreCandles(symbol: symbol, timeframe: timeframe, canonicalKey: key)
                }
                return current
            }
        }

        // 2. Coalesce — in-flight task varsa onu bekle.
        if let task = candleTasks[key] {
            let _ = await task.result
            return candles[key] ?? .missing(reason: "Task failed")
        }

        // 3. Phase 6 PR-B: Daily ailesi için master daily seriyi kullan.
        //
        // 1d/1wk/1mo/3mo aynı kaynaktan (1d, range=max) gelen daily seriden
        // lokalde aggregate edilebilir. 1d zaten master; 1wk/1mo/3mo master'ı
        // alıp `MultiTimeframeCandleService.aggregate` ile türetir. Tek hisse
        // için 4 daily-aile timeframe'i 4 yerine **1 Yahoo isteği** ister.
        if MultiTimeframeCandleService.isDailyFamily(canonicalTimeframe),
           canonicalTimeframe != "1day" {
            // Türev timeframe — master daily'yi al, aggregate et.
            let masterValue = await ensureCandles(symbol: symbol, timeframe: "1day")
            guard let dailyList = masterValue.value, !dailyList.isEmpty else {
                let missing = DataValue<[Candle]>.missing(
                    reason: masterValue.provenance.evidence ?? "Master daily yok"
                )
                candles[key] = missing
                return missing
            }
            let aggregated = MultiTimeframeCandleService.aggregate(daily: dailyList, to: canonicalTimeframe)
            let val = DataValue.fresh(aggregated, source: "Daily-Aggregate")
            candles[key] = val
            return val
        }

        // 4. Blocking fetch — cache hiç yok ya da çok eski.
        return await fetchAndStoreCandles(symbol: symbol, timeframe: timeframe, canonicalKey: key)
    }

    /// Yeni bir candles fetch task'i başlatır, sonucu cache'e yazar ve döndürür.
    /// `ensureCandles` (foreground) ve stale-while-revalidate (background) yolları
    /// tarafından paylaşılır — fetch logic tek source-of-truth.
    @discardableResult
    private func fetchAndStoreCandles(symbol: String, timeframe: String, canonicalKey: String) async -> DataValue<[Candle]> {
        let task = Task<[Candle], Error> {
            let limit = candleLimit(for: timeframe)
            return try await HeimdallOrchestrator.shared.requestCandles(symbol: symbol, timeframe: timeframe, limit: limit)
        }
        candleTasks[canonicalKey] = task

        do {
            let data = try await task.value
            candleTasks[canonicalKey] = nil
            let val = DataValue.fresh(data)
            candles[canonicalKey] = val
            return val
        } catch {
            candleTasks[canonicalKey] = nil
            print("📉 Store: Candles failed for \(canonicalKey): \(error)")
            // SWR: cache'te eski değer varsa stale olarak koru.
            // Ki üst seviye ensureCandles "no value" yerine eski candle'ı dönsün.
            if let old = candles[canonicalKey], let value = old.value, !value.isEmpty {
                let staleVal = DataValue(value: value, provenance: old.provenance, status: .stale)
                candles[canonicalKey] = staleVal
                return staleVal
            }
            let missing = DataValue<[Candle]>.missing(reason: error.localizedDescription)
            candles[canonicalKey] = missing
            return missing
        }
    }

    /// Phase 7+ (2026-04-29): Timeframe-bazlı cache TTL.
    /// Daha önce DataValue.isFresh 15 saniye sabitti — daily candle 15 sn'de
    /// değişmez ama 15 sn sonra cache stale sayılıp tekrar fetch'e gidiyordu.
    /// Bu da "ABBV detayı açıldığında Orion analiz başarısız" semptomunun ana
    /// sebebiydi (Prometheus daily fetch + Orion daily fetch arasındaki 15 sn'de
    /// ikinci fetch rate-limit yiyince tüm 6 timeframe fail).
    private static func candleTTL(for canonicalTimeframe: String) -> TimeInterval {
        switch canonicalTimeframe {
        case "5m":               return 60          // 1 dk — intraday hızlı bayatlar
        case "15m":              return 180         // 3 dk
        case "1h":               return 600         // 10 dk
        case "4h":               return 1800        // 30 dk
        case "1day":             return 1800        // 30 dk — gün ortasında son bar değişir
        case "1week", "1month",
             "3month":           return 3600        // 1 saat — uzun vade nadiren değişir
        default:                 return 300         // 5 dk default
        }
    }

    /// Cache key için kanonik timeframe adı.
    /// "1day", "1d", "1G", "1D", "daily" → "1day"; "1h", "1H", "60m" → "1h"; vs.
    /// Provider çağrılarında orijinal string geçirilir — Yahoo adapter'ı kendi
    /// mapping'ini yapıyor. Bu sadece coalescing/cache için.
    private static func normalizeTimeframe(_ tf: String) -> String {
        let trimmed = tf.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "1day", "1d", "1g", "daily", "d":         return "1day"
        case "1h", "1hour", "60m", "60min", "1s":      return "1h"
        case "4h", "4hour", "240m", "240min", "4s":    return "4h"
        case "15m", "15min", "15d":                    return "15m"
        case "5m", "5min", "5d":                       return "5m"
        case "1week", "1wk", "1w", "weekly":           return "1week"
        case "1month", "1mo", "1mon", "monthly":       return "1month"
        default:                                       return trimmed
        }
    }

    private func candleLimit(for timeframe: String) -> Int {
        let trimmed = timeframe.trimmingCharacters(in: .whitespacesAndNewlines)

        // UI kısa kodları (case-sensitive)
        switch trimmed {
        case "1H": return 260 // Haftalık
        case "1G": return 365
        case "1S": return 240
        case "4S": return 240
        case "15D", "5D": return 300
        default: break
        }

        let normalized = trimmed.lowercased()
        if ["1week", "1wk", "1w"].contains(normalized) { return 260 }
        if ["1day", "1d", "1g"].contains(normalized) { return 365 }
        if ["4h", "4hour", "240m", "240min"].contains(normalized) { return 240 }
        if ["1h", "1hour", "60min"].contains(normalized) { return 240 }
        if ["15m", "15min", "5m", "5min"].contains(normalized) { return 300 }
        return 200
    }
    
    // MARK: - Fundamentals (Atlas)
    
    func ensureFundamentals(symbol: String) async -> DataValue<FinancialsData> {
        // Cache
        if let current = fundamentals[symbol], !current.isMissing {
            return current
        }
        
        if let task = fundamentalTasks[symbol] {
             let _ = await task.result
             return fundamentals[symbol] ?? .missing(reason: "Task already in progress")
        }
        
        let task = Task<FinancialsData, Error> {
            try await HeimdallOrchestrator.shared.requestFundamentals(symbol: symbol)
        }
        fundamentalTasks[symbol] = task
        
        do {
            let data = try await task.value
            fundamentalTasks[symbol] = nil
            let val = DataValue.fresh(data)
            fundamentals[symbol] = val
            return val
        } catch {
             fundamentalTasks[symbol] = nil
             return .missing(reason: "Fetch failed")
        }
    }
    
    // MARK: - Bulk Operations

    /// In-flight batch refreshes keyed by the sorted symbol set so two
    /// view models calling `refreshQuotes` with the same watchlist do
    /// not produce two parallel Stooq fan-outs.
    private var batchTasks: [String: Task<Void, Never>] = [:]

    /// Stooq snapshot endpoint can return hundreds of symbols in a
    /// single request and BorsaPy handles BIST in parallel internally.
    /// Both converge in `HeimdallOrchestrator.requestQuotesBatch`.
    /// 2026-05-08 Abdullah PR #22: chunked single-fetch yaklaşımı (chunk=4 +
    /// 1.1s tier'lı gecikme) yerine batch endpoint'le tek çağrıda 80 sembol
    /// — 304 sembollük watchlist için 76 vs 4 istek.
    func ensureQuotes(symbols: [String]) async {
        let needsFetch = symbols.filter { sym in
            if let current = quotes[sym] {
                let age = -current.provenance.fetchedAt.timeIntervalSinceNow
                if current.isFresh && age < quoteTTL { return false }
            }
            return true
        }
        guard !needsFetch.isEmpty else { return }

        let key = needsFetch.sorted().joined(separator: ",")
        if let existing = batchTasks[key] {
            await existing.value
            return
        }
        // Yeni round → bucket'lar arasındaki priority yarışı sıfırlanır. Aksi halde
        // önceki round'da Alpaca yazımı (priority 1) sonsuza dek Stooq'un (4) yazımını
        // bloke ederdi ve fiyatlar güncellenmezdi.
        for sym in needsFetch { self.lastQuotePriority[sym] = nil }

        let task = Task<Void, Never> { [weak self] in
            guard let self = self else { return }
            // Bucket task'ları artık sonuçlarını gelir gelmez `recordBatchQuote` ile
            // priority-aware yazıyor; dönen map sadece yedek/tamamlama amaçlı. Eski
            // davranışta TaskGroup tüm bucket'lar bitmeden dönmüyordu — en yavaş
            // bucket (Yahoo fallback 5-10s, BorsaPy cold-start) hızlı bucket'ları
            // kilitliyordu. Şimdi UI Alpaca sonucunu 500ms'de görür.
            let map = await HeimdallOrchestrator.shared.requestQuotesBatch(symbols: needsFetch)
            for symbol in needsFetch {
                if let quote = map[symbol] {
                    // priority 99 → bucket zaten daha öncelikli yazdıysa override edilmez.
                    self.recordBatchQuote(symbol: symbol, quote: quote, source: "Batch", priority: 99)
                } else if self.quotes[symbol] == nil {
                    // BIST sembolleri `requestQuotesBatch`'in dönüş map'inde olmaz —
                    // orchestrator bunları detached `streamBistBucket` task'ına gönderir
                    // ve sonuç doğrudan `recordBatchQuote` ile yazılır. Non-BIST için
                    // "batch gerçekten boş döndü" semantiği geçerli, davranışı koru.
                    let destination = SymbolResolver.shared.marketDestination(for: symbol)
                    if destination != .bist {
                        self.quotes[symbol] = .missing(reason: "Batch returned no value")
                    }
                }
            }
        }
        batchTasks[key] = task
        await task.value
        batchTasks[key] = nil
    }

    /// Public API for view models that just need a quote refresh on
    /// many symbols. Routes through the batch path.
    func refreshQuotes(symbols: [String]) async {
        await ensureQuotes(symbols: symbols)
    }

    // MARK: - Hot tier (live tick subscriptions)

    /// The set of symbols the streaming WebSocket should subscribe to.
    /// Updated whenever the visible UI changes (open positions plus the
    /// rendered chunk of the watchlist).
    @Published var hotSymbols: Set<String> = []

    func setHotSymbols(_ symbols: Set<String>) {
        guard hotSymbols != symbols else { return }
        hotSymbols = symbols
        MarketDataProvider.shared.connectStream(symbols: Array(symbols))
    }
    // MARK: - Historical Data Access (Validator)
    
    /// Belirli bir tarihteki kapanış fiyatını getirir.
    /// Validator (Doğrulayıcı) modülü için kritik önem taşır.
    /// Önce cache'deki mumlara bakar, yoksa API'ye gider (henüz API geçmiş veri çekme implemente edilmediği için mum cache'i esastır).
    func fetchHistoricalClose(symbol: String, targetDate: Date) async -> Double? {
        // En yakın mumu bulmak için 1 günlük mumları kullanırız
        let candlesResult = await ensureCandles(symbol: symbol, timeframe: "1day")
        
        guard let candles = candlesResult.value, !candles.isEmpty else {
            return nil
        }
        
        // Hedef tarihe en yakın mumu bul
        // Mum tarihleri genellikle gün başlangıcıdır (00:00).
        let calendar = Calendar.current
        
        // Basit arama (Veri seti küçük olduğu için yeterli, ileride Binary Search yapılabilir)
        // Tarih sırasına göre olduğu varsayımıyla (Heimdall sort eder)
        
        let targetDay = calendar.startOfDay(for: targetDate)
        
        // Tam eşleşme ara
        if let match = candles.first(where: { calendar.isDate($0.date, inSameDayAs: targetDay) }) {
            return match.close
        }
        
        // Tam eşleşme yoksa (haftasonu vb.), hedef tarihten ÖNCEKİ en son kapanışı bul (Latest Known Value)
        // Veya hedef tarih bir "vade" ise ve o gün veri yoksa, o günü takip eden ilk işlem günü mü yoksa önceki mi?
        // Finansal standart: O gün tatilse, bir önceki işlem gününün kapanışı o günün değeri kabul edilir.
        
        let validCandles = candles.filter { $0.date <= targetDate }
        return validCandles.last?.close
    }
}
