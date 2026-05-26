import Foundation
import Combine

/// Plan CRUD + persistence repository.
/// God Object Aşama B — PositionPlanStore'dan çıkarıldı.
///
/// Sorumluluk:
/// - `plans: [UUID: PositionPlan]` SSoT (@Published)
/// - createPlan / updatePlan / completePlan / markStepCompleted
/// - syncWithPortfolio (varsayılan plan oluşturma)
/// - JSON persistence (UserDefaults)
///
/// Trigger evaluation + technical analysis PlanTriggerEngine'de.
///
/// NOT: @MainActor değil — orijinal PositionPlanStore non-isolated idi,
/// caller'lar (PortfolioStore.handleQuoteUpdates vb.) cross-actor.
final class PlanRepository: ObservableObject {
    static let shared = PlanRepository()

    /// SSoT plan dict. NOT: `private(set)` değil çünkü PlanTriggerEngine
    /// updatePlanPrices/checkRegimeShift içinde doğrudan yazıyor (eski
    /// monolitik PositionPlanStore'dan kalan davranış). Caller'lar facade
    /// üzerinden gitmeli — direct write düşük güvenlikli ama davranış korunmuş.
    @Published var plans: [UUID: PositionPlan] = [:]

    private let persistenceKey = "ArgusPositionPlansVortex"

    private init() {
        loadPlans()
    }

    /// External mutation sonrası persist tetikleyici (TriggerEngine'in
    /// updatePlanPrices/checkRegimeShift sonrası savePlans çağırması için).
    func persist() {
        savePlans()
    }

    // MARK: - Sync with Portfolio

    /// Mevcut açık trade'ler için eksik planları oluştur.
    func syncWithPortfolio(trades: [Trade], grandDecisions: [String: ArgusGrandDecision]) {
        let openTrades = trades.filter { $0.isOpen }
        var createdCount = 0

        for trade in openTrades {
            if hasPlan(for: trade.id) { continue }

            let decision: ArgusGrandDecision
            if let gd = grandDecisions[trade.symbol] {
                decision = gd
            } else {
                decision = ArgusGrandDecision(
                    id: UUID(),
                    symbol: trade.symbol,
                    action: .accumulate,
                    strength: .normal,
                    confidence: 0.5,
                    reasoning: "Mevcut pozisyon için varsayılan plan",
                    contributors: [],
                    vetoes: [],
                    orionDecision: CouncilDecision(
                        symbol: trade.symbol,
                        action: .hold,
                        netSupport: 0.5,
                        approveWeight: 0,
                        vetoWeight: 0,
                        isStrongSignal: false,
                        isWeakSignal: false,
                        winningProposal: nil,
                        allProposals: [],
                        votes: [],
                        vetoReasons: [],
                        timestamp: Date()
                    ),
                    atlasDecision: nil,
                    aetherDecision: AetherDecision(
                        stance: .cautious,
                        marketMode: .neutral,
                        netSupport: 0.5,
                        isStrongSignal: false,
                        winningProposal: nil,
                        votes: [],
                        warnings: [],
                        timestamp: Date()
                    ),
                    hermesDecision: nil,
                    phoenixAdvice: nil,
                    orionDetails: nil,
                    financialDetails: nil,
                    orionV2TotalScore: nil,
                    bistDetails: nil,
                    patterns: nil,
                    kellyMultiplier: 1.0,
                    timestamp: Date()
                )
            }

            createPlan(for: trade, decision: decision)
            createdCount += 1
        }

        if createdCount > 0 {
            print("📋 \(createdCount) mevcut trade için plan oluşturuldu")
        }
    }

    // MARK: - Public CRUD

    func hasPlan(for tradeId: UUID) -> Bool {
        return plans[tradeId] != nil
    }

    func getPlan(for tradeId: UUID) -> PositionPlan? {
        return plans[tradeId]
    }

    /// Yeni plan oluştur — NEUTRAL kararlar reddedilir.
    ///
    /// O4: Plan üretimi direktif-isteyen bir karar verir: "şurada sat, burada kes."
    /// NEUTRAL kararın ne alım ne satım tarafı vardır; eskiden burada sessiz fabrikasyon
    /// vardı (SmartPlanGenerator yine de plan üretiyordu). Artık NEUTRAL açıkça reddediliyor —
    /// caller nil'i fark edip UI'da "karar yok" gösterebilir.
    @discardableResult
    func createPlan(
        for trade: Trade,
        decision: ArgusGrandDecision,
        thesis: String? = nil
    ) -> PositionPlan? {
        guard decision.action != .neutral else {
            print("⚠️ PlanRepository: \(trade.symbol) için plan reddedildi — NEUTRAL karar (sinyal yok).")
            return nil
        }

        let symbolCandles = PlanTriggerEngine.shared.candleStore[trade.symbol] ?? []

        // 2026-05-04: hardcoded atlasScore=50 fake'i kaldırıldı.
        let orionScore = decision.orionDecision.netSupport * 100
        let atlasScore = decision.atlasDecision.map { $0.netSupport * 100 }
        let hermesScore = decision.hermesDecision.map { $0.netSupport * 100 }

        let defaultThesis = generateThesis(for: trade.symbol, decision: decision)
        let defaultInvalidation = generateInvalidation(for: trade.symbol, decision: decision)
        let finalThesis = thesis ?? defaultThesis

        // FAZE 1.3: Technical data'yı orionDetails + candle hesabı ile populate et
        let trendScore = decision.orionDetails?.components.trend
        let mappedTrend: TrendDirection?
        if let score = trendScore {
            if score > 80 { mappedTrend = .strongUp }
            else if score > 60 { mappedTrend = .up }
            else if score < 20 { mappedTrend = .strongDown }
            else if score < 40 { mappedTrend = .down }
            else { mappedTrend = .sideways }
        } else {
            mappedTrend = nil
        }

        let engine = PlanTriggerEngine.shared
        let atr = engine.estimateATR(from: symbolCandles)
        let sma20 = engine.movingAverage(from: symbolCandles, period: 20)
        let sma50 = engine.movingAverage(from: symbolCandles, period: 50)
        let sma200 = engine.movingAverage(from: symbolCandles, period: 200)
        let supportResistance = engine.estimateSupportResistance(from: symbolCandles)
        let trendFromCandles = engine.estimateTrend(from: symbolCandles, sma20: sma20, sma50: sma50)

        let techData = TechnicalSnapshotData(
            rsi: decision.orionDetails?.components.rsi,
            atr: atr,
            sma20: sma20,
            sma50: sma50,
            sma200: sma200,
            distanceFromATH: nil, distanceFrom52WeekLow: nil,
            nearestSupport: supportResistance.support,
            nearestResistance: supportResistance.resistance,
            trend: mappedTrend ?? trendFromCandles
        )

        let snapshot = EntrySnapshot(
            tradeId: trade.id,
            symbol: trade.symbol,
            entryPrice: trade.entryPrice,
            grandDecision: decision,
            orionScore: orionScore,
            atlasScore: atlasScore,
            hermesScore: hermesScore,
            technicalData: techData,
            macroData: nil,
            fundamentalData: nil
        )

        // 2026-05-04: snapshot'ı EntrySnapshotStore'a da kaydet —
        // ChironHealthMonitor ve TradeDetailSheet bu store'dan okuyor.
        EntrySnapshotStore.shared.saveSnapshot(snapshot)

        var plan = VortexEngine.shared.createPlan(
            for: trade,
            snapshot: snapshot,
            decision: decision,
            thesis: finalThesis,
            invalidation: defaultInvalidation,
            candles: symbolCandles
        )

        plan.createdAtRegime = PlanTriggerEngine.currentRegimeLabel()

        plans[trade.id] = plan
        savePlans()

        print("📋 Yeni VORTEX planı oluşturuldu: \(trade.symbol)")
        return plan
    }

    func updatePlan(_ plan: PositionPlan) {
        var updatedPlan = plan
        updatedPlan.lastUpdated = Date()
        plans[plan.tradeId] = updatedPlan
        savePlans()
    }

    func markStepCompleted(tradeId: UUID, stepId: UUID) {
        guard var plan = plans[tradeId] else { return }

        if !plan.executedSteps.contains(stepId) {
            plan.executedSteps.append(stepId)
            plan.lastUpdated = Date()
            plans[tradeId] = plan
            savePlans()

            print("✅ Plan adımı tamamlandı: \(plan.originalSnapshot.symbol) - Step \(stepId.uuidString.prefix(8))")
        }
    }

    func updatePlanStatus(tradeId: UUID, status: PlanStatus) {
        guard var plan = plans[tradeId] else { return }
        plan.status = status
        plan.lastUpdated = Date()
        plans[tradeId] = plan
        savePlans()
    }

    func completePlan(tradeId: UUID) {
        updatePlanStatus(tradeId: tradeId, status: .completed)
    }

    /// Faz III (2026-05-12): Plan revize bayrağı.
    /// Konsey "ÇIK"/"AZALT" alert'i fire olduğunda, regime shift olduğunda veya
    /// kullanıcı tezi sorgulamak istediğinde çağrılır. Otomatik trade yapmaz —
    /// sadece UI'da "Plan güncel değil" rozeti gösterilmesini sağlar ve
    /// journeyLog'a iz bırakır.
    func markPlanForReview(tradeId: UUID, reason: String, triggeredBy: String = "Plan Lifecycle") {
        guard var plan = plans[tradeId] else { return }
        // Idempotent: zaten review bayraklı plana ikinci kez aynı sebebi ekleme.
        if plan.requiresReview == true,
           plan.journeyLog.last?.reason == reason {
            return
        }
        plan.requiresReview = true
        plan.lastUpdated = Date()
        plan.journeyLog.append(
            PlanRevision(
                timestamp: Date(),
                reason: reason,
                changeDescription: "Plan revize uyarısı: \(reason)",
                triggeredBy: triggeredBy
            )
        )
        plans[tradeId] = plan
        savePlans()
        print("📌 Plan revize bayrağı: \(plan.originalSnapshot.symbol) — \(reason)")
    }

    // MARK: - Thesis Helpers

    private func generateThesis(for symbol: String, decision: ArgusGrandDecision) -> String {
        let actionText: String
        switch decision.action {
        case .aggressiveBuy: actionText = "Güçlü alım sinyali"
        case .accumulate: actionText = "Kademeli birikim"
        case .trim: actionText = "Azaltma"
        case .liquidate: actionText = "Çıkış"
        case .neutral: actionText = "Nötr bekleme"
        }

        return "\(actionText). \(decision.reasoning)"
    }

    private func generateInvalidation(for symbol: String, decision: ArgusGrandDecision) -> String {
        switch decision.action {
        case .aggressiveBuy, .accumulate:
            return "Konsey AZALT veya ÇIK sinyali verirse, ya da -%10 stop tetiklenirse"
        default:
            return "Beklenmedik negatif gelişme"
        }
    }

    // MARK: - Persistence

    private func savePlans() {
        do {
            let data = try JSONEncoder().encode(Array(plans.values))
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            print("❌ Plan kaydetme hatası: \(error)")
        }
    }

    private func loadPlans() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return }

        do {
            let loadedPlans = try JSONDecoder().decode([PositionPlan].self, from: data)
            for plan in loadedPlans {
                plans[plan.tradeId] = plan
            }
            print("📋 \(loadedPlans.count) plan yüklendi")
        } catch {
            print("❌ Plan yükleme hatası: \(error)")
        }
    }
}
