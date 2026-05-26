import Foundation
import Combine
import SwiftUI

/// AutoPilot Store — otonom ticaret döngüsünün ana orchestratoru.
///
/// God Object Aşama B — Adım B.2: 871 LOC tek dosya → ana sınıf + 4 extension.
/// Davranış aynı, kod sorumluluk gruplarına ayrıldı:
/// - AutoPilotStore.swift          (state + init + lifecycle handlers)
/// - AutoPilotStore+Context.swift  (market context + multiplier + balance)
/// - AutoPilotStore+Loop.swift     (timer yönetimi)
/// - AutoPilotStore+Scan.swift     (runAutoPilot + processSignals + plan triggers)
/// - AutoPilotStore+Learning.swift (TradeBrain 3.0 öğrenme döngüsü)
@MainActor
final class AutoPilotStore: ObservableObject {
    static let shared = AutoPilotStore()

    // MARK: - State

    @Published var isAutoPilotEnabled: Bool = true {
        didSet {
            handleAutoPilotStateChange()
            if AutoPilotController.shared.isAutoPilotEnabled != isAutoPilotEnabled {
                AutoPilotController.shared.isAutoPilotEnabled = isAutoPilotEnabled
            }
        }
    }

    @Published var scoutingCandidates: [TradeSignal] = []
    @Published var scoutLogs: [ScoutLog] = []

    /// Son tarama özeti — "Trade neden olmuyor?" sorusuna somut cevap.
    /// Durum Panosu bu snapshot'ı okuyup "SON TARAMA" kartında gösterir.
    struct ScanSummary {
        let timestamp: Date
        let scannedCount: Int
        let signalCount: Int
        let skippedCount: Int
        /// Scan-level RED'ler (örn. "12x düşük güven", "8x cooldown")
        let topSkipReasons: [String]
        /// 2026-05-05 FIX A: Execution-level RED'ler (TradeBrainExecutor.executeBuy guard return'leri).
        /// Eski sürümde sadece log'a düşüyordu — UI "scan'de geçti, execution'da niye reddedildi"
        /// sorusunun cevabını göremiyordu. Artık summary tarafından sızdırılır.
        let executionBlockedReasons: [String]
        let globalBalance: Double
        let bistBalance: Double
        let openPositions: Int

        static let empty = ScanSummary(
            timestamp: Date.distantPast,
            scannedCount: 0, signalCount: 0, skippedCount: 0,
            topSkipReasons: [],
            executionBlockedReasons: [],
            globalBalance: 0, bistBalance: 0, openPositions: 0
        )

        var hasRun: Bool { timestamp != Date.distantPast }
        var ageSeconds: TimeInterval { Date().timeIntervalSince(timestamp) }
    }
    @Published var lastScanSummary: ScanSummary = .empty

    // MARK: - Internal State (extension'lardan erişilebilir)
    // Not: `private` yerine internal — aynı modüldeki extension'lar bu state'i okur/yazar.

    /// Loop timer — Loop extension yönetir.
    var autoPilotTimer: Timer?

    /// Son immediate-run zamanı. Kısa pencerede ard arda startTimer çağrılsa
    /// bile immediate-run sadece bir kez yapılır → triple trigger bug'ına karşı.
    var lastImmediateRunAt: Date?

    /// Son günlük öğrenme döngüsü zamanı. runAutoPilot her tetiklendiğinde
    /// 24h+ geçtiyse runDailyLearningCycle çağrılır (rate-limit). Eskiden
    /// runDailyLearningCycle hiçbir yerden çağrılmıyordu — TradeBrain Learning
    /// + RegimeMemory cache ölü kalıyordu.
    var lastDailyLearningRunAt: Date?

    /// HARMONY — Otopilot piyasa bağlamına göre pozisyon çarpanı okur.
    /// Kullanıcı toggle kapalıysa kapalı kalır, AÇIKKEN bu çarpan agresif/temkinli
    /// ayarlar (0.40–1.20). Coordinator otopilotun enabled durumuna ASLA dokunmaz.
    var contextMultiplier: Double = 1.0
    var controllerCancellable: AnyCancellable?
    var contextCancellable: AnyCancellable?
    var balanceCancellable: AnyCancellable?
    var lastKnownGlobalBalance: Double = 0
    var lastKnownBistBalance: Double = 0

    // Dependencies
    let portfolioStore = PortfolioStore.shared

    // MARK: - Init

    private init() {
        self.isAutoPilotEnabled = AutoPilotController.shared.isAutoPilotEnabled

        controllerCancellable = AutoPilotController.shared.$isAutoPilotEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self, self.isAutoPilotEnabled != enabled else { return }
                self.isAutoPilotEnabled = enabled
            }

        // Coordinator'ı başlat ve dinle
        MarketContextCoordinator.shared.start()
        contextCancellable = MarketContextCoordinator.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.handleMarketContextUpdate(snapshot)
            }

        // FİX #2: PortfolioStore.globalBalance değişimlerini dinle. Eski mimaride
        // AutoPilot bakiye değişikliğinden habersizdi — kullanıcı para yatırdığında
        // pozisyon sizing eski balance üzerinden hesaplanıyordu. Artık anlamlı
        // değişimde (> $500 veya ₺10k) log + state invalidation.
        balanceCancellable = Publishers.CombineLatest(
            PortfolioStore.shared.$globalBalance,
            PortfolioStore.shared.$bistBalance
        )
        .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self] (usd, tl) in
            self?.handleBalanceChange(usd: usd, tl: tl)
        }
    }

    // MARK: - Lifecycle Handlers

    func handleAutoPilotStateChange() {
        if isAutoPilotEnabled {
            startTimer()
        } else {
            stopAutoPilotLoop()
        }
    }
}
