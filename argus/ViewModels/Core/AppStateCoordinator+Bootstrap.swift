import Foundation

/// App startup orchestration — TradingViewModel.bootstrap()'tan taşındı.
/// Faz 1-4'lük lazy startup: UI'yı bloklamayan hızlı işlemlerden başlayıp
/// ağır Atlas/Demeter analizine kadar background priority sırasıyla ilerler.
extension AppStateCoordinator {

    /// Tek seferlik startup. Idempotent — birden fazla çağrı no-op.
    func bootstrap() {
        guard !Self.bootstrapDone else { return }
        Self.bootstrapDone = true

        let startTime = Date()
        let signpost = SignpostLogger.shared
        let id = signpost.begin(log: signpost.startup, name: "BOOTSTRAP")

        defer {
            signpost.end(log: signpost.startup, name: "BOOTSTRAP", id: id)
            let duration = Date().timeIntervalSince(startTime)
            ArgusLogger.bootstrapComplete(seconds: duration)
            Task { @MainActor in DiagnosticsViewModel.shared.recordBootstrapDuration(duration) }
        }

        // PHASE 1: HIZLI — UI'ı bloklamayan işlemler (~100ms hedef)
        // Stores (WatchlistStore, PortfolioStore) kendi kendilerine init oluyor.

        // Eski TVM.init()'te çağrılan one-shot işler:
        Task { @MainActor in
            EconomicCalendarService.shared.checkAndNotifyMissingExpectations()
        }

        // BorsaPy warm-up'ı erken başlat — Render.com free tier 40-60sn cold-start
        // verebiliyor. Eskiden Faz 3'te (5sn delay sonrası) çağrılıyordu;
        // kullanıcı bu pencerede BIST sembolüne tıklarsa ardı ardına timeout
        // alıp circuit breaker açılıyor → AutoPilot BIST alımı 5dk bloklanıyor.
        // Faz 1'de paralel başlatınca AutoPilot loop'u (Faz 3 + 5sn + 25sn defer)
        // çalışmaya başladığında backend uyanmış oluyor.
        Task.detached(priority: .userInitiated) {
            ArgusLogger.phase(.veri, "BorsaPy: Backend ısındırılıyor (erken)...")
            await BorsaPyProvider.shared.warmUp()
            // Warmup tamamlandı → cold-start sırasında İş Yatırım/Yahoo'dan
            // giren eski BIST fiyatlarını temizle ve hemen yenile.
            await MainActor.run { MarketDataStore.shared.invalidateBistQuotes() }
            await MarketViewModel.shared.fetchQuotes()
        }

        ArgusLogger.success(.bootstrap, "Faz 1: UI hazır")

        // PHASE 2: Stream + initial data load — hemen başlar, fake delay yok.
        // Stream WebSocket; HTTP burst yapmaz, Yahoo cap'ini yemez.
        // Tier 1 fetch (Watchlist loop içinde) chunked 4@1.1s → 3.6 r/s.
        // Eski 2sn Task.sleep gereksizdi — UI render zaten render kuyruğunda.
        Task { @MainActor in
            let market = MarketViewModel.shared
            let risk = RiskViewModel.shared

            // RL-Lite: Tune System based on history
            ArgusFeedbackLoopService.shared.tuneSystem(history: risk.portfolio)

            // Enable Live Mode
            market.isLiveMode = true

            // Connect Stream for Watchlist (WebSocket — ücretsiz cap)
            ArgusLogger.phase(.veri, "Faz 2: Stream bağlanıyor...")
            MarketDataProvider.shared.connectStream(symbols: market.watchlist)

            // Initial data load — TVM.loadData()'dan taşındı.
            // Quotes startWatchlistLoop'un immediate run'ında Tier 1+2 ile çekiliyor.
            // loadDiscoverData zaten gainers + losers + mostActive paralel çekiyor;
            // ayrıca fetchTopLosers çağırırsak losers Yahoo screener 2x istek gider.
            // Kaldırıldı (2026-05-08 logda gözlendi: "Screener: losers" 2 kez).
            ArgusLogger.phase(.veri, "Faz 2: Initial data load başlatılıyor...")
            market.loadMacroEnvironment()
            market.loadDiscoverData()
            Task { await market.fetchCandles() }
        }

        // PHASE 3: Scout/Watchlist polling — UI bloklamadan paralel başlar.
        // (BorsaPy warm-up Faz 1'e taşındı, AutoPilot 9sn'de Tier 1 bitsin diye)
        Task { @MainActor in
            ArgusLogger.phase(.autopilot, "Faz 3: Scout + Watchlist döngüsü başlatılıyor...")
            SignalViewModel.shared.startScoutLoop()
            MarketViewModel.shared.startWatchlistLoop()

            // AutoPilot ML — Tier 1 fetch'in (~8sn) tamamlanmasına süre tanı,
            // ondan sonra başlasın. Aynı saniyede ağ üstüne çıkmasın.
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                await MainActor.run {
                    AutoPilotStore.shared.startAutoPilotLoop()
                }
            }

            // BIST TÜM universe sync — BorsaPy cold-start 40-60sn sürebiliyor;
            // 30sn bekleyince warmUp() genellikle tamamlanmış oluyor.
            // refreshBistUniverse() kendi içinde isBackendWarm() kontrolü yapar (güvenli).
            Task.detached(priority: .background) {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await WatchlistStore.shared.refreshBistUniverse()
            }
        }

        // PHASE 4: BACKGROUND — Atlas/Demeter (en ağır)
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 10_000_000_000)

            ArgusLogger.phase(.atlas, "Faz 4: Atlas/Demeter başlatılıyor...")
            await SignalViewModel.shared.hydrateAtlas()
            await SignalViewModel.shared.runDemeterAnalysis()

            await QuotaLedger.shared.reset(provider: "Finnhub")
            await QuotaLedger.shared.reset(provider: "Yahoo")
            await QuotaLedger.shared.reset(provider: "Yahoo Finance")
        }

        ArgusLogger.info(.bootstrap, "Lazy loading aktif")
    }

    private static var bootstrapDone: Bool = false
}
