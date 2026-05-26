import Foundation
import Combine

// MARK: - Position Plan Store (Facade)
/// God Object Aşama B — 2 sorumluluğa bölündü:
/// - PlanRepository:    CRUD + persistence (UserDefaults JSON)
/// - PlanTriggerEngine: trigger evaluation + technical helpers + regime shift
///
/// Backward compat: 25+ caller `PositionPlanStore.shared.X` formuna alışkın
/// → method delegasyonu ile API korundu. View migration'a gerek yok.
/// L61: Repository'nin objectWillChange'ı parent'a relay edilir.
///
/// NOT: Orijinal `PositionPlanStore` @MainActor değildi (cross-actor caller'lar
/// var: PortfolioStore.handleQuoteUpdates non-isolated context). Davranışı
/// korumak için child'lar da @MainActor değil — Combine + UserDefaults tabanlı
/// erişim zaten thread-safe pattern.
final class PositionPlanStore: ObservableObject {
    static let shared = PositionPlanStore()

    // MARK: - Children

    let repository: PlanRepository
    let triggerEngine: PlanTriggerEngine

    private var cancellables = Set<AnyCancellable>()

    private init() {
        self.repository = PlanRepository.shared
        self.triggerEngine = PlanTriggerEngine.shared

        repository.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Smart Plan Sheet State

    @Published var generatedSmartPlan: PositionPlan?

    func triggerSmartPlan(for trade: Trade) {
        Task {
            guard let decision = await MainActor.run(body: { SignalStateViewModel.shared.grandDecisions[trade.symbol] }) else { return }
            guard let plan = createPlan(for: trade, decision: decision) else { return }
            await MainActor.run { self.generatedSmartPlan = plan }
        }
    }

    // MARK: - Forward (Repository)

    var plans: [UUID: PositionPlan] { repository.plans }

    func hasPlan(for tradeId: UUID) -> Bool { repository.hasPlan(for: tradeId) }
    func getPlan(for tradeId: UUID) -> PositionPlan? { repository.getPlan(for: tradeId) }

    @discardableResult
    func createPlan(for trade: Trade, decision: ArgusGrandDecision, thesis: String? = nil) -> PositionPlan? {
        repository.createPlan(for: trade, decision: decision, thesis: thesis)
    }

    func updatePlan(_ plan: PositionPlan) { repository.updatePlan(plan) }
    func updatePlanStatus(tradeId: UUID, status: PlanStatus) { repository.updatePlanStatus(tradeId: tradeId, status: status) }
    func completePlan(tradeId: UUID) { repository.completePlan(tradeId: tradeId) }
    func markStepCompleted(tradeId: UUID, stepId: UUID) { repository.markStepCompleted(tradeId: tradeId, stepId: stepId) }
    /// Faz III: plan revize bayrağı (auto-sellAll yerine "tezi gözden geçir" pattern'i)
    func markPlanForReview(tradeId: UUID, reason: String, triggeredBy: String = "Plan Lifecycle") {
        repository.markPlanForReview(tradeId: tradeId, reason: reason, triggeredBy: triggeredBy)
    }
    func syncWithPortfolio(trades: [Trade], grandDecisions: [String: ArgusGrandDecision]) {
        repository.syncWithPortfolio(trades: trades, grandDecisions: grandDecisions)
    }

    // MARK: - Forward (TriggerEngine)

    func updatePriceQuotes(_ quotes: [String: Quote]) { triggerEngine.updatePriceQuotes(quotes) }
    func updateCandles(_ candles: [String: [Candle]]) { triggerEngine.updateCandles(candles) }
    func updatePlanPrices() { triggerEngine.updatePlanPrices() }

    func checkTriggers(trade: Trade, currentPrice: Double, grandDecision: ArgusGrandDecision?) -> PlannedAction? {
        triggerEngine.checkTriggers(trade: trade, currentPrice: currentPrice, grandDecision: grandDecision)
    }

    static func currentRegimeLabel() -> String? {
        PlanTriggerEngine.currentRegimeLabel()
    }

    // MARK: - Debug

    func printPlanSummary(for tradeId: UUID) {
        guard let plan = repository.plans[tradeId] else {
            print("❌ Plan bulunamadı: \(tradeId)")
            return
        }

        print("═══════════════════════════════════════")
        print("📋 POZİSYON PLANI: \(plan.originalSnapshot.symbol)")
        print("═══════════════════════════════════════")
        print("Tez: \(plan.thesis)")
        print("Giriş: \(String(format: "%.2f", plan.originalSnapshot.entryPrice)) @ \(plan.originalSnapshot.capturedAt.formatted())")
        print("Miktar: \(String(format: "%.2f", plan.initialQuantity))")
        print("Niyet: \(plan.intent.rawValue)")
        print("───────────────────────────────────────")

        let scenarios = [plan.bullishScenario, plan.bearishScenario, plan.neutralScenario].compactMap { $0 }

        for scenario in scenarios {
            print("\(scenario.type.rawValue) (\(scenario.isActive ? "AKTİF" : "PASİF")):")
            for step in scenario.steps {
                let completed = plan.executedSteps.contains(step.id) ? "✅" : "⏳"
                print("  \(completed) \(step.trigger.displayText) → \(step.action.displayText)")
            }
        }
        print("═══════════════════════════════════════")
        if !plan.journeyLog.isEmpty {
            print("📜 PLAN GEÇMİŞİ:")
            for rev in plan.journeyLog {
                print("  - \(rev.timestamp.formatted()): \(rev.changeDescription) (\(rev.reason))")
            }
            print("═══════════════════════════════════════")
        }
    }
}
