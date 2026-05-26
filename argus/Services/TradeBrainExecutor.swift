import Foundation
import Combine

// MARK: - Trade Brain Executor
/// Council kararlarını alım/satım emirlerine çeviren uygulayıcı

class TradeBrainExecutor: ObservableObject {
    static let shared = TradeBrainExecutor()
    
    @Published var executionLogs: [String] = []
    @Published var isEnabled: Bool = true
    @Published var lastMultiHorizonDecisions: [String: MultiHorizonDecision] = [:]
    @Published var lastContradictionAnalyses: [String: ContradictionAnalysis] = [:]
    @Published var lastCorrelResult: CorrelationHeatGate.CorrelationResult? = nil
    @Published var lastCrisisOpportunities: [CrisisAlphaScanner.AlphaOpportunity] = []
    @Published var lastVelocityAnalysis: AetherVelocityEngine.VelocityAnalysis? = nil

    /// Son tarama özeti — "Trade neden olmuyor?" sorusuna somut cevap.
    /// Durum Panosu bu snapshot'ı okuyup kullanıcıya gösterir.
    struct ScanStats {
        var timestamp: Date
        var evaluatedCount: Int         // Kaç karar değerlendirildi
        var buyDecisions: Int           // aggressiveBuy + accumulate
        var sellDecisions: Int          // trim + liquidate
        var neutralDecisions: Int
        var skippedCooldown: Int        // Cooldown yüzünden atlanan
        var skippedLowConfidence: Int   // Düşük güven yüzünden atlanan
        var skippedNoPrice: Int         // Fiyat verisi yok
        var executedBuys: Int           // Gerçekten alım emri yollananlar
        var executedSells: Int          // Gerçekten satım emri yollananlar
        var globalBalance: Double
        var bistBalance: Double
        var openPositions: Int

        static let empty = ScanStats(
            timestamp: Date.distantPast,
            evaluatedCount: 0, buyDecisions: 0, sellDecisions: 0, neutralDecisions: 0,
            skippedCooldown: 0, skippedLowConfidence: 0, skippedNoPrice: 0,
            executedBuys: 0, executedSells: 0,
            globalBalance: 0, bistBalance: 0, openPositions: 0
        )
    }
    @Published var lastScanStats: ScanStats = .empty

    // Momentum seviyesi takibi — fade tespiti için önceki döngünün değeri
    private var prevGlobalMomentumLevel: MarketMomentumGate.MomentumSignal.Level = .neutral
    private var prevBistMomentumLevel:   MarketMomentumGate.MomentumSignal.Level = .neutral

    private var cancellables = Set<AnyCancellable>()
    private var lastExecutionTime: [String: Date] = [:]
    
    private let baseCooldownSeconds: TimeInterval = 300
    
    private let horizonEngine = HorizonEngine.shared
    private let selfQuestionEngine = SelfQuestionEngine.shared
    private let confidenceCalibration = ConfidenceCalibrationService.shared
    private let eventMemory = EventMemoryService.shared
    private let regimeMemory = RegimeMemoryService.shared
    private let learningService = TradeBrainLearningService.shared
    
    private init() {}

    // MARK: - Symbol Profile

    private struct SymbolExecutionProfile {
        enum RiskTier: String {
            case defensive = "DEFANSİF"
            case balanced = "DENGELİ"
            case offensive = "ATAK"
        }

        let symbol: String
        let tier: RiskTier
        let allocationMultiplier: Double
        let cooldownMultiplier: Double
        let minDecisionConfidence: Double
        let notes: [String]
    }
    
    // MARK: - Add-On Gate

    private func shouldAllowAddOn(
        symbol: String,
        currentPrice: Double,
        globalAetherScore: Double,
        bistAetherScore: Double,
        portfolio: [Trade],
        balance: Double,
        bistBalance: Double,
        quotes: [String: Quote],
        policy: RiskEscapePolicy,
        isSafeSymbol: Bool
    ) -> Bool {
        let isBist = SymbolResolver.shared.isBistSymbol(symbol)
        let effectiveAether = isBist ? bistAetherScore : globalAetherScore

        guard effectiveAether >= 65 else {
            debugSkip(symbol: symbol, reason: "ekleme reddedildi: Aether \(Int(effectiveAether)) < 65")
            return false
        }

        if policy.blockRiskyBuys && !isSafeSymbol {
            debugSkip(symbol: symbol, reason: "ekleme reddedildi: policy riskli alım kapalı")
            return false
        }

        let tradesForSymbol = portfolio.filter { $0.isOpen && $0.symbol == symbol }
        let existingValue = tradesForSymbol.reduce(0.0) { $0 + ($1.quantity * currentPrice) }

        let marketPortfolio = portfolio.filter { $0.isOpen && SymbolResolver.shared.isBistSymbol($0.symbol) == isBist }
        let portfolioValue = marketPortfolio.reduce(0.0) { sum, t in
            let price = quotes[t.symbol]?.currentPrice ?? t.entryPrice
            return sum + (t.quantity * price)
        }
        let availableBalance = isBist ? bistBalance : balance
        let totalEquity = availableBalance + portfolioValue
        let currentWeight = totalEquity > 0 ? (existingValue / totalEquity) : 1.0

        guard currentWeight < 0.12 else {
            debugSkip(symbol: symbol, reason: "ekleme reddedildi: pozisyon ağırlığı %\(Int(currentWeight * 100)) >= %12")
            return false
        }

        ArgusLogger.info("TradeBrainExecutor: \(symbol) ekleme onaylandı (Aether: \(Int(effectiveAether)), ağırlık: %\(Int(currentWeight * 100)))", category: "TRADEBRAIN")
        return true
    }

    // MARK: - Main Execution Loop

    /// Council kararlarını değerlendir ve gerekirse işlem yap
    func evaluateDecisions(
        decisions: [String: ArgusGrandDecision],
        portfolio: [Trade],
        quotes: [String: Quote],
        balance: Double,
        bistBalance: Double,
        macroScore: Double?,
        orionScores: [String: OrionScoreResult],
        candles: [String: [Candle]]
    ) async {
        guard isEnabled else { return }

        ArgusLogger.info("TradeBrainExecutor: \(decisions.count) karar değerlendiriliyor...", category: "TRADEBRAIN")

        let openTrades = portfolio.filter { $0.isOpen }
        let openSymbols = Set(openTrades.map { $0.symbol })
        let openTradeMap = Dictionary(openTrades.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        let aetherScore = macroScore ?? 50
        let policy = RiskEscapePolicy.from(aetherScore: aetherScore)

        // ── Velocity Engine'e Aether kaydı ────────────────────────────────
        await AetherVelocityEngine.shared.record(score: aetherScore)
        let velocityAnalysis = await AetherVelocityEngine.shared.analyze()
        await MainActor.run { self.lastVelocityAnalysis = velocityAnalysis }
        if let alert = velocityAnalysis.crossingAlert {
            ArgusLogger.info("⚡ Aether Velocity: \(alert.description)", category: "TRADEBRAIN")
        }

        // ── BIST-özel Türkiye makro skoru (SirkiyeAether) ─────────────────
        // Global Aether Türkiye makrosunu yansıtmaz. BIST sembolleri için
        // SirkiyeAetherEngine'i kullan (TCMB verisi, önbellekli).
        let bistAetherScore: Double = await {
            let score = await SirkiyeAetherEngine.shared.analyze().overallScore
            ArgusLogger.info("🇹🇷 SirkiyeAether: \(Int(score))", category: "TRADEBRAIN")
            return score
        }()

        // ── Piyasa Momentum Kapısı: breadth tabanlı hızlı sinyal ──────────
        // Rally başladığında Aether hâlâ düşük / rejim hâlâ riskOff olabilir.
        // Breadth (fiyat+hacim) bunu saatler içinde tespit eder.
        let watchlistSymbols = Array(decisions.keys)
        let globalMomentum = await MarketMomentumGate.shared.assessGlobal(
            quotes: quotes, candles: candles, watchlistSymbols: watchlistSymbols)
        let bistMomentum = await MarketMomentumGate.shared.assessBist(
            quotes: quotes, candles: candles, watchlistSymbols: watchlistSymbols)
        if globalMomentum.isActive {
            ArgusLogger.info("🚀 GlobalMomentum: \(globalMomentum.summary)", category: "TRADEBRAIN")
        }
        if bistMomentum.isActive {
            ArgusLogger.info("🚀 BistMomentum: \(bistMomentum.summary)", category: "TRADEBRAIN")
        }

        // ── Momentum Fade Exit ────────────────────────────────────────────
        // Önceki döngüde momentum aktifti, şimdi neutral → momentum pozisyonlarını %50 trim et.
        // Hedef: rally bitişinde hızlı kısmi çıkış; tam çıkış plan trigger'larına bırakılır.
        let globalFaded = prevGlobalMomentumLevel != .neutral && globalMomentum.level == .neutral
        let bistFaded   = prevBistMomentumLevel   != .neutral && bistMomentum.level   == .neutral
        if globalFaded || bistFaded {
            for trade in openTrades where trade.isOpen {
                let isBistTrade = SymbolResolver.shared.isBistSymbol(trade.symbol)
                let faded = isBistTrade ? bistFaded : globalFaded
                guard faded else { continue }
                guard trade.rationale?.hasPrefix("MOMENTUM:") == true else { continue }
                guard let currentPrice = quotes[trade.symbol]?.currentPrice, currentPrice > 0 else { continue }
                ArgusLogger.warn("📉 MomentumFade: \(trade.symbol) → %50 trim", category: "TRADEBRAIN")
                log("📉 \(trade.symbol): Momentum soldu — %50 kısmi çıkış")
                await MainActor.run {
                    AlertManager.shared.executeSell(
                        tradeId: trade.id,
                        price: currentPrice,
                        reason: "MomentumFade: breadth düştü → %50 trim",
                        trimPercentage: 50.0
                    )
                }
            }
        }
        // Seviyeyi güncelle (bu döngü sonunda referans olur)
        prevGlobalMomentumLevel = globalMomentum.level
        prevBistMomentumLevel   = bistMomentum.level

        // ── YENİ: Kelly profili (async, cache'li) ─────────────────────────
        let kellyProfile = await KellyCache.shared.getSystemProfile()
        let allVerdicts = await AlkindusMemoryStore.shared.loadVerdicts()

        // ── YENİ: Korelasyon bazlı portföy ısısı ──────────────────────────
        let priceHistory: [String: [Double]] = Dictionary(uniqueKeysWithValues:
            candles.map { (sym, cndls) in (sym, cndls.map { $0.close }) }
        )
        let correlResult = CorrelationHeatGate.assess(portfolio: portfolio, priceHistory: priceHistory)
        await MainActor.run { self.lastCorrelResult = correlResult }
        if correlResult.concentrationRisk != .healthy {
            ArgusLogger.warn("📊 Korelasyon: \(correlResult.concentrationRisk.label) — \(correlResult.rawPositionCount) pozisyon → \(Int(correlResult.effectivePositionCount)) bağımsız risk", category: "TRADEBRAIN")
        }
        
        ArgusLogger.info("TradeBrainExecutor: \(openSymbols.count) açık pozisyon", category: "TRADEBRAIN")
        ArgusLogger.warn("TradeBrainPolicy: \(policy.mode.rawValue) | \(policy.reason)", category: "TRADEBRAIN")
        
        var processedCount = 0
        var skippedCooldown = 0
        var skippedLowConfidence = 0
        var skippedNoPrice = 0

        // Karar dağılımı — kaç BUY / SELL / NEUTRAL
        var buyCount = 0, sellCount = 0, neutralCount = 0
        for (_, d) in decisions {
            switch d.action {
            case .aggressiveBuy, .accumulate: buyCount += 1
            case .trim, .liquidate:           sellCount += 1
            case .neutral:                    neutralCount += 1
            }
        }

        for (symbol, decision) in decisions {
            processedCount += 1

            let symbolCandles = candles[symbol] ?? []
            let profile = await buildExecutionProfile(
                symbol: symbol,
                decision: decision,
                portfolio: portfolio,
                quote: quotes[symbol],
                candles: symbolCandles
            )
            let cooldownSeconds = baseCooldownSeconds * profile.cooldownMultiplier
            ArgusLogger.info(
                "TradeBrainProfile[\(symbol)] tier=\(profile.tier.rawValue) " +
                "alloc×\(String(format: "%.2f", profile.allocationMultiplier)) " +
                "cooldown×\(String(format: "%.2f", profile.cooldownMultiplier)) " +
                "minConf=\(String(format: "%.2f", profile.minDecisionConfidence))",
                category: "TRADEBRAIN"
            )
            
            // T2.22: CooldownRegistry'yi güncelle (tek kaynak) + geriye uyumluluk
            let registryCooldown = await CooldownRegistry.shared.isInCooldown(symbol, type: .postTrade)
            if registryCooldown || (lastExecutionTime[symbol].map { Date().timeIntervalSince($0) < cooldownSeconds } ?? false) {
                skippedCooldown += 1
                debugSkip(symbol: symbol, reason: "cooldown aktif")
                if decision.action == .aggressiveBuy || decision.action == .accumulate {
                    let priceForRecord = quotes[symbol]?.currentPrice ?? symbolCandles.last?.close ?? 0
                    if priceForRecord > 0 {
                        await OpportunityCostTracker.shared.recordSkip(
                            symbol: symbol, price: priceForRecord,
                            reason: .policyBlock, aetherScore: aetherScore
                        )
                    }
                }
                continue
            }

            let currentPrice = quotes[symbol]?.currentPrice ?? symbolCandles.last?.close ?? 0
            guard currentPrice > 0 else {
                skippedNoPrice += 1
                debugSkip(symbol: symbol, reason: "fiyat yok (quote/candle)")
                continue
            }
            
            let hasOpenPosition = openSymbols.contains(symbol)
            let isSafeSymbol = isSafeAsset(symbol)
            
            ArgusLogger.info("TradeBrainExecutor: \(symbol) - Action: \(decision.action.rawValue), OpenPos: \(hasOpenPosition)", category: "TRADEBRAIN")

            if hasOpenPosition,
               policy.mode != .normal,
               !isSafeSymbol,
               let trade = openTradeMap[symbol] {
                let trimPercent = forcedTrimPercent(
                    policy: policy,
                    trade: trade,
                    currentPrice: currentPrice,
                    volatility: estimateVolatility(candles: symbolCandles, referencePrice: currentPrice)
                )
                await executePolicyReduce(
                    trade: trade,
                    trimPercent: trimPercent,
                    currentPrice: currentPrice,
                    policy: policy
                )
                continue
            }
            
            // ALIM KARARLARI
            let isBuyAction = decision.action == .aggressiveBuy || decision.action == .accumulate
            let isBistSym = SymbolResolver.shared.isBistSymbol(symbol)
            let isAddOn: Bool
            if !hasOpenPosition {
                isAddOn = false
            } else if isBuyAction {
                let addOnAllowed = shouldAllowAddOn(
                    symbol: symbol,
                    currentPrice: currentPrice,
                    globalAetherScore: aetherScore,
                    bistAetherScore: bistAetherScore,
                    portfolio: portfolio,
                    balance: balance,
                    bistBalance: bistBalance,
                    quotes: quotes,
                    policy: policy,
                    isSafeSymbol: isSafeSymbol
                )
                if !addOnAllowed {
                    await OpportunityCostTracker.shared.recordSkip(
                        symbol: symbol, price: currentPrice,
                        reason: .portfolioHot, aetherScore: aetherScore
                    )
                }
                isAddOn = addOnAllowed
            } else {
                isAddOn = false
            }

            let canProceedBuy = isBuyAction && (!hasOpenPosition || isAddOn)

            if canProceedBuy {
                if policy.blockRiskyBuys && !isSafeSymbol {
                    let velocityAllowsEntry = velocityAnalysis.signal == .recoveringFast ||
                                              velocityAnalysis.signal == .recovering
                    if !velocityAllowsEntry {
                        await OpportunityCostTracker.shared.recordSkip(
                            symbol: symbol, price: currentPrice,
                            reason: .aetherTooLow, aetherScore: aetherScore
                        )
                        debugSkip(symbol: symbol, reason: "policy riskli alimi kapatti (\(policy.mode.rawValue))")
                        continue
                    }
                    ArgusLogger.info("⚡ Velocity override: \(symbol) kriz'de ama Aether iyileşiyor (\(velocityAnalysis.signal.rawValue))", category: "TRADEBRAIN")
                }

                if correlResult.concentrationRisk == .critical {
                    await OpportunityCostTracker.shared.recordSkip(
                        symbol: symbol, price: currentPrice,
                        reason: .portfolioHot, aetherScore: aetherScore
                    )
                    debugSkip(symbol: symbol, reason: "korelasyon kritik: portföy tek risk faktörüne bağlı")
                    continue
                }

                let borsaPyCircuitOpen: Bool
                if isBistSym { borsaPyCircuitOpen = await BorsaPyProvider.shared.isCircuitOpen() }
                else { borsaPyCircuitOpen = false }
                let dataQualityPenalty: Double = borsaPyCircuitOpen ? 0.85 : 1.0

                let coreScore = decision.finalScoreCore
                let pulseScore = decision.finalScorePulse
                let bothBullish = coreScore >= 50 && pulseScore >= 50
                let bothBearish = coreScore < 50 && pulseScore < 50
                let conflictBig = (coreScore >= 60 && pulseScore < 40) || (pulseScore >= 60 && coreScore < 40)
                let horizonAgreementMultiplier: Double
                if bothBullish || bothBearish { horizonAgreementMultiplier = 1.10 }
                else if conflictBig { horizonAgreementMultiplier = 0.65 }
                else { horizonAgreementMultiplier = 0.85 }

                let effectiveConfidence = min(0.99, decision.confidence * dataQualityPenalty * horizonAgreementMultiplier)
                if dataQualityPenalty < 1.0 {
                    debugSkip(symbol: symbol, reason: "BorsaPy circuit açık → BIST confidence %15 düşürüldü")
                }
                if horizonAgreementMultiplier != 1.10 && horizonAgreementMultiplier != 1.0 {
                    ArgusLogger.info("TradeBrainExecutor: \(symbol) horizon \(horizonAgreementMultiplier < 0.85 ? "ÇELİŞKİ" : "uyumsuzluk") (Core=\(Int(coreScore)) Pulse=\(Int(pulseScore)) → ×\(String(format: "%.2f", horizonAgreementMultiplier)))", category: "TRADEBRAIN")
                } else if horizonAgreementMultiplier == 1.10 {
                    ArgusLogger.info("TradeBrainExecutor: \(symbol) horizon teyidi (Core=\(Int(coreScore)) Pulse=\(Int(pulseScore)) → ×1.10)", category: "TRADEBRAIN")
                }

                if effectiveConfidence < profile.minDecisionConfidence {
                    skippedLowConfidence += 1
                    await OpportunityCostTracker.shared.recordSkip(
                        symbol: symbol, price: currentPrice,
                        reason: .lowConfidence, aetherScore: aetherScore
                    )
                    debugSkip(
                        symbol: symbol,
                        reason: "güven düşük (\(String(format: "%.2f", effectiveConfidence)) < \(String(format: "%.2f", profile.minDecisionConfidence)))"
                    )
                    continue
                }

                let buyProfile: SymbolExecutionProfile
                if isAddOn {
                    let addOnCap = min(0.5, decision.allocationMultiplier)
                    buyProfile = SymbolExecutionProfile(
                        symbol: profile.symbol,
                        tier: profile.tier,
                        allocationMultiplier: profile.allocationMultiplier * addOnCap,
                        cooldownMultiplier: profile.cooldownMultiplier,
                        minDecisionConfidence: profile.minDecisionConfidence,
                        notes: profile.notes + ["pozisyon ekleme"]
                    )
                    ArgusLogger.info("TradeBrainExecutor: EKLEME yapılıyor: \(symbol) (cap: ×\(String(format: "%.2f", addOnCap)))", category: "TRADEBRAIN")
                } else {
                    buyProfile = profile
                    ArgusLogger.info("TradeBrainExecutor: ALIM yapılıyor: \(symbol)", category: "TRADEBRAIN")
                }

                await executeBuy(
                    symbol: symbol,
                    decision: decision,
                    currentPrice: currentPrice,
                    balance: balance,
                    bistBalance: bistBalance,
                    portfolio: portfolio,
                    quotes: quotes,
                    orionScore: orionScores[symbol]?.score ?? 50,
                    candles: symbolCandles,
                    profile: buyProfile,
                    kellyProfile: kellyProfile,
                    verdicts: allVerdicts,
                    velocityAnalysis: velocityAnalysis,
                    correlMultiplier: correlResult.positionMultiplier,
                    aetherOverride: isBistSym ? bistAetherScore : nil,
                    momentumFloor: isBistSym ? bistMomentum.aetherFloor : globalMomentum.aetherFloor,
                    isAddOn: isAddOn
                )
            } else if !isBuyAction && !hasOpenPosition {
                debugSkip(symbol: symbol, reason: "aksiyon alım değil (\(decision.action.rawValue))")
            }
            
            // SATIM KARARLARI (Plan bazlı - Trade Brain)
            // Not: Satım artık PositionPlanStore.checkTriggers() ile yapılıyor
            // Burada sadece acil durum satışları (liquidate) yapalım
            if hasOpenPosition && decision.action == .liquidate {
                if let trade = openTrades.first(where: { $0.symbol == symbol }) {
                    ArgusLogger.warn("TradeBrainExecutor: ACİL SATIŞ: \(symbol)", category: "TRADEBRAIN")
                    await executeEmergencySell(
                        trade: trade,
                        decision: decision,
                        currentPrice: currentPrice
                    )
                }
            }
        }
        
        ArgusLogger.info(
            "TradeBrainExecutor: Özet - İşlenen: \(processedCount), " +
            "Cooldown: \(skippedCooldown), Güven: \(skippedLowConfidence), Fiyat Yok: \(skippedNoPrice)",
            category: "TRADEBRAIN"
        )

        if policy.mode != .normal {
            for trade in openTrades where !decisions.keys.contains(trade.symbol) && !isSafeAsset(trade.symbol) {
                guard let currentPrice = quotes[trade.symbol]?.currentPrice, currentPrice > 0 else { continue }
                let symbolCandles = candles[trade.symbol] ?? []
                let trimPercent = forcedTrimPercent(
                    policy: policy,
                    trade: trade,
                    currentPrice: currentPrice,
                    volatility: estimateVolatility(candles: symbolCandles, referencePrice: currentPrice)
                )
                await executePolicyReduce(
                    trade: trade,
                    trimPercent: trimPercent,
                    currentPrice: currentPrice,
                    policy: policy
                )
            }
        }

        if policy.forceSafeOnlyBuys {
            await executeSafeAllocationOrders(
                policy: policy,
                openSymbols: openSymbols,
                quotes: quotes,
                globalBalance: balance,
                bistBalance: bistBalance
            )
        }

        // ── YENİ: Crisis Alpha — kriz ortamında scalp fırsatları tara
        if aetherScore >= 35 {
            await MainActor.run { self.lastCrisisOpportunities = [] }
        }
        if aetherScore < 35 {
            let crisisContext = CrisisAlphaScanner.CrisisContext(
                aetherScore: aetherScore,
                isActiveCrisis: true
            )
            let watchlistSymbols = Array(decisions.keys.filter { !openSymbols.contains($0) })
            let alphaOpportunities = CrisisAlphaScanner.scan(
                symbols: watchlistSymbols,
                quotes: quotes,
                candleHistory: candles,
                context: crisisContext
            )
            await MainActor.run { self.lastCrisisOpportunities = alphaOpportunities }
            for opp in alphaOpportunities {
                ArgusLogger.info("🎯 CrisisAlpha: \(opp.summary)", category: "TRADEBRAIN")
                guard let decision = decisions[opp.symbol] else { continue }
                let crisisProfile = SymbolExecutionProfile(
                    symbol: opp.symbol,
                    tier: .defensive,
                    allocationMultiplier: opp.positionSizeMultiplier,
                    cooldownMultiplier: 1.0,
                    minDecisionConfidence: 0.3,
                    notes: ["CrisisAlpha: \(opp.opportunityType.rawValue)"]
                )
                let isCrisisBist = SymbolResolver.shared.isBistSymbol(opp.symbol)
                await executeBuy(
                    symbol: opp.symbol,
                    decision: decision,
                    currentPrice: opp.suggestedEntry,
                    balance: balance,
                    bistBalance: bistBalance,
                    portfolio: portfolio,
                    quotes: quotes,
                    orionScore: 50,
                    candles: candles[opp.symbol] ?? [],
                    profile: crisisProfile,
                    kellyProfile: nil,
                    verdicts: allVerdicts,
                    velocityAnalysis: velocityAnalysis,
                    correlMultiplier: correlResult.positionMultiplier,
                    isCrisisAlpha: true,
                    aetherOverride: isCrisisBist ? bistAetherScore : nil,
                    momentumFloor: isCrisisBist ? bistMomentum.aetherFloor : globalMomentum.aetherFloor
                )
            }
        }
    }
    
    // MARK: - Buy Execution
    
    private func executeBuy(
        symbol: String,
        decision: ArgusGrandDecision,
        currentPrice: Double,
        balance: Double,
        bistBalance: Double,
        portfolio: [Trade],
        quotes: [String: Quote],
        orionScore: Double,
        candles: [Candle],
        profile: SymbolExecutionProfile,
        kellyProfile: KellyCriterionSizer.KellyProfile? = nil,
        verdicts: [AlkindusVerdict] = [],
        velocityAnalysis: AetherVelocityEngine.VelocityAnalysis? = nil,
        correlMultiplier: Double = 1.0,
        isCrisisAlpha: Bool = false,
        aetherOverride: Double? = nil,    // BIST: SirkiyeAether; Global: nil → MacroRegimeService
        momentumFloor: Double = 0,        // MarketMomentumGate'den gelen breadth tabanı
        isAddOn: Bool = false
    ) async {
        ArgusLogger.info("executeBuy: \(symbol) - Fiyat: \(currentPrice)", category: "TRADEBRAIN")

        let isBist = SymbolResolver.shared.isBistSymbol(symbol)
        let availableBalance = isBist ? bistBalance : balance

        ArgusLogger.info("executeBuy: Available Balance = \(availableBalance), isBist = \(isBist)", category: "TRADEBRAIN")

        // 0. CASH FLOOR + SCARCITY MODE
        let cashFloorEquity = isBist
            ? await MainActor.run { PortfolioStore.shared.getBistEquity(quotes: quotes) }
            : await MainActor.run { PortfolioStore.shared.getGlobalEquity(quotes: quotes) }
        let cashRatio = cashFloorEquity > 0 ? availableBalance / cashFloorEquity : 1.0
        let cashFloorRatio: Double = 0.20

        if cashRatio < cashFloorRatio {
            let requiredConfidence: Double = 0.65
            if decision.confidence < requiredConfidence {
                log("💰 \(symbol): Cash floor aktif (nakit %\(Int(cashRatio * 100)) < %20) — güven %\(Int(decision.confidence * 100)) < %65, atlandı")
                await TradeBrainExecutionTracker.shared.recordSkip(
                    symbol: symbol,
                    reason: "Cash floor: nakit %\(Int(cashRatio * 100)), güven yetersiz"
                )
                return
            }
            log("💰 \(symbol): Cash floor aktif ama güven yüksek (%\(Int(decision.confidence * 100))) — scarcity mode")

            // SWAP / ROTATION: Cash floor + yüksek güven — en zayıf pozisyonu çıkar
            let openTrades = portfolio.filter { $0.isOpen }
            let newScore = decision.confidence * 100

            var worstTrade: Trade? = nil
            var worstScore: Double = 200

            for trade in openTrades {
                let isSameMarket = SymbolResolver.shared.isBistSymbol(trade.symbol) == isBist
                guard isSameMarket else { continue }
                let td = await MainActor.run { SignalStateViewModel.shared.grandDecisions[trade.symbol] }
                if let td = td {
                    let score = td.confidence * 100
                    if score < worstScore {
                        worstScore = score
                        worstTrade = trade
                    }
                }
            }

            let swapBuffer: Double = 15.0
            if let worst = worstTrade, newScore > worstScore + swapBuffer {
                let sellPrice = quotes[worst.symbol]?.currentPrice ?? worst.entryPrice
                log("🔄 SWAP: \(symbol) (skor \(Int(newScore))) > \(worst.symbol) (skor \(Int(worstScore))) + buffer 15")
                await MainActor.run {
                    AlertManager.shared.executeSell(
                        tradeId: worst.id,
                        price: sellPrice,
                        reason: "SWAP: \(symbol) daha güçlü (\(Int(newScore)) vs \(Int(worstScore)))"
                    )
                }
                // Aynı döngüde alma — nakit serbest kaldı, sonraki tarama alacak
                await TradeBrainExecutionTracker.shared.recordSkip(
                    symbol: symbol,
                    reason: "SWAP initiated: sold \(worst.symbol), will buy next scan"
                )
                return
            }
        }

        // 1. ALLOCATION HESAPLA
        // BIST sembolleri için SirkiyeAether kullan (Türkiye makrosu), globallar için MacroRegimeService
        let regimeAetherScore = aetherOverride ?? MacroRegimeService.shared.getCachedRating()?.numericScore ?? 50
        let currentRegime = ChironRegimeEngine.shared.globalResult.regime

        // Temel rejim çarpanı — momentumFloor ile riskOff bloğu aşılabilir
        var regimeMultiplier = RegimePositionSizer.multiplier(
            aetherScore: regimeAetherScore, regime: currentRegime, momentumFloor: momentumFloor)

        // Velocity düzeltmesi — kriz'den çıkışta veya bozulmada ayar
        if let vel = velocityAnalysis {
            regimeMultiplier = await AetherVelocityEngine.shared.velocityAdjustedMultiplier(base: regimeMultiplier)
            ArgusLogger.info("⚡ Velocity: \(vel.signal.rawValue) → çarpan: \(String(format: "%.2f", regimeMultiplier))", category: "TRADEBRAIN")
        }

        // ── YENİ: Kelly çarpanı — Alkindus geçmişine dayalı boyut (spesifik > sembol > sistem)
        let effectiveKellyProfile: KellyCriterionSizer.KellyProfile
        if !verdicts.isEmpty {
            effectiveKellyProfile = KellyCriterionSizer.specificProfile(
                symbol: symbol,
                regime: currentRegime,
                verdicts: verdicts
            )
        } else if let kp = kellyProfile {
            effectiveKellyProfile = kp
        } else {
            effectiveKellyProfile = KellyCriterionSizer.KellyProfile(
                winRate: 0.5, avgWinPct: 2.0, avgLossPct: 2.0,
                sampleSize: 0, kellyFraction: 0.25,
                confidence: .low(reason: "veri yok")
            )
        }
        let kellyMultiplier = effectiveKellyProfile.positionMultiplier

        // ── YENİ: Korelasyon çarpanı — portföy konsantrasyonu
        // CrisisAlpha: rejim bloğunu atla, profile.allocationMultiplier (0.15-0.40) direk kullan
        let finalMultiplier: Double
        if isCrisisAlpha {
            finalMultiplier = 1.0  // profile.allocationMultiplier zaten küçük (0.15-0.40)
            ArgusLogger.info("🎯 CrisisAlpha bypass: rejim bloğu atlandı, profile çarpanı geçerli", category: "TRADEBRAIN")
        } else {
            // 2026-05-05 FIX B (multiplier floor): 5 katmanlı kaskad
            // (basePercent × profile × regime × kelly × correl) tipik durumda
            // %0.1–%1 arası toplam üretiyor; allocation eriyor, minTradeAmount altına
            // düşüyor, sembol "Yetersiz bakiye" RED'i yiyor. Asıl niyet rejim bloğu
            // değil, sadece kaskad çarpanların çarpılmasından kaynaklanan dip.
            //
            // Çözüm: regimeMultiplier == 0 (deep risk-off) durumu hâlâ tam blok;
            // ama nominal (>0) raw cumulative %20 altına düşse bile floor uygulanır.
            let rawCumulative = regimeMultiplier * kellyMultiplier * correlMultiplier
            guard rawCumulative > 0 else {
                // Faz 0 Task 9: Kelly 0.0 (sample ≥10, negatif edge) ile Rejim 0.0
                // (deep risk-off) ayrı sebepler — log/skip mesajı net ayrılır.
                if kellyMultiplier == 0.0 {
                    log("🚫 \(symbol): Kelly negatif (örneklem ≥10) — Sinyal blok. Sistem henüz kârlı edge bulamadı.")
                    await TradeBrainExecutionTracker.shared.recordSkip(
                        symbol: symbol,
                        reason: "Kelly negatif — sistem henüz kârlı edge bulamadı"
                    )
                } else {
                    log("🛑 \(symbol): Rejim bloğu — Aether:\(Int(regimeAetherScore)) Rejim:\(currentRegime.rawValue)")
                    await TradeBrainExecutionTracker.shared.recordSkip(
                        symbol: symbol,
                        reason: "Rejim bloğu (Aether=\(Int(regimeAetherScore)))"
                    )
                }
                return
            }
            finalMultiplier = max(0.20, rawCumulative)
            ArgusLogger.info(
                "📐 Çarpanlar: Rejim×\(String(format: "%.2f", regimeMultiplier)) Kelly×\(String(format: "%.2f", kellyMultiplier)) Korel×\(String(format: "%.2f", correlMultiplier)) → Raw×\(String(format: "%.3f", rawCumulative)) → Final×\(String(format: "%.2f", finalMultiplier)) [floor 0.20]",
                category: "TRADEBRAIN"
            )
        }

        let allocation: Double
        let minTradeAmount: Double

        if isBist {
            // 2026-05-05 FIX D: BIST basePercent 0.05 → 0.08. Eski sürümde Global %10 / BIST %5
            // ayrımı için kod'da gerekçe yoktu; FIX B (multiplier floor 0.20) ve FIX C+E
            // (notional + whole-share guard) ile alt sınır artık güvenle korunduğu için BIST'i
            // Global'e yakınsadık. Bu, BIST aksiyonlarının "yetersiz allocation" RED'inden
            // kurtulup gerçek pozisyon açmasını mümkün kılar.
            let basePercent = 0.08
            let adjustedPercent = basePercent * profile.allocationMultiplier * finalMultiplier
            allocation = availableBalance * adjustedPercent
            minTradeAmount = 1000.0
            ArgusLogger.info(
                "executeBuy: BIST Allocation = %\(Int(adjustedPercent * 100)) " +
                "(\(String(format: "%.2f", profile.allocationMultiplier))x profile, " +
                "\(String(format: "%.2f", finalMultiplier))x final) of ₺\(availableBalance) = ₺\(allocation)",
                category: "TRADEBRAIN"
            )
        } else {
            let basePercent = 0.10
            let adjustedPercent = basePercent * profile.allocationMultiplier * finalMultiplier
            allocation = availableBalance * adjustedPercent
            minTradeAmount = 50.0
            ArgusLogger.info(
                "executeBuy: Global Allocation = %\(Int(adjustedPercent * 100)) " +
                "(\(String(format: "%.2f", profile.allocationMultiplier))x profile, " +
                "\(String(format: "%.2f", finalMultiplier))x final) of $\(availableBalance) = $\(allocation)",
                category: "TRADEBRAIN"
            )
        }

        guard allocation >= minTradeAmount else {
            log("⚠️ \(symbol): Yetersiz bakiye (gereken: \(minTradeAmount), mevcut: \(allocation))")
            ArgusLogger.error("executeBuy: Yetersiz bakiye - Gereken: \(minTradeAmount), Mevcut: \(allocation)", category: "TRADEBRAIN")
            await TradeBrainExecutionTracker.shared.recordSkip(
                symbol: symbol,
                reason: "Yetersiz allocation (\(isBist ? "₺" : "$")\(Int(allocation)) < min \(Int(minTradeAmount)))"
            )
            return
        }

        // 2026-05-05 FIX C+E (notional + whole-share guard):
        // allocation kontrolü tek başına yetmiyor — BIST'te round-down sonrası kesirli paylar
        // 0'a yuvarlanabiliyor (örn. ₺1.500 / ₺2.000 = 0.75 pay). Bazı brokerlar kesirli kabul
        // etmiyor; round-down'dan sonra nominal trade boyutunu (quantity × price) doğrula.
        var proposedQuantity = allocation / currentPrice
        if isBist {
            // BIST: tam pay zorunlu — kesirli pay invalid (broker tarafında reject riski)
            proposedQuantity = floor(proposedQuantity)
            guard proposedQuantity >= 1 else {
                log("⚠️ \(symbol): Round-down 0 — fiyat ₺\(currentPrice) çok yüksek, allocation ₺\(Int(allocation)) tek pay alamıyor")
                ArgusLogger.error(
                    "executeBuy: Round-down 0 - Fiyat: \(currentPrice), Allocation: \(allocation)",
                    category: "TRADEBRAIN"
                )
                await TradeBrainExecutionTracker.shared.recordSkip(
                    symbol: symbol,
                    reason: "Round-down 0 (fiyat ₺\(Int(currentPrice)) çok yüksek)"
                )
                return
            }
        }
        let effectiveNotional = proposedQuantity * currentPrice
        guard effectiveNotional >= minTradeAmount else {
            log("⚠️ \(symbol): Notional yetersiz — \(proposedQuantity) pay × \(isBist ? "₺" : "$")\(currentPrice) = \(isBist ? "₺" : "$")\(Int(effectiveNotional)) < min \(Int(minTradeAmount))")
            ArgusLogger.error(
                "executeBuy: Notional yetersiz - \(effectiveNotional) < \(minTradeAmount)",
                category: "TRADEBRAIN"
            )
            await TradeBrainExecutionTracker.shared.recordSkip(
                symbol: symbol,
                reason: "Notional yetersiz (\(isBist ? "₺" : "$")\(Int(effectiveNotional)) < \(Int(minTradeAmount)))"
            )
            return
        }

        // 2. RİSK KONTROLÜ
        // FIX: portfolioValue sadece aynı pazar trade'lerini içermeli (BIST veya Global ayrı)
        let marketFilteredPortfolio = portfolio.filter { $0.isOpen && SymbolResolver.shared.isBistSymbol($0.symbol) == isBist }
        let portfolioValue = marketFilteredPortfolio.reduce(0) { sum, trade in
            let price = quotes[trade.symbol]?.currentPrice ?? trade.entryPrice
            return sum + (trade.quantity * price)
        }

        let totalEquity = availableBalance + portfolioValue

        // 2B. PORTFÖY ISI KAPISI
        let heatLevel = PortfolioHeatGate.assess(portfolio: marketFilteredPortfolio, quotes: quotes, equity: totalEquity)
        let heatMultiplier = PortfolioHeatGate.positionMultiplier(for: heatLevel)
        guard heatMultiplier > 0 else {
            log("🔥 \(symbol): Portföy ısı limiti (\(heatLevel.rawValue)) — yeni alım durduruldu")
            print("🔥 executeBuy: Portföy ısı bloğu (\(heatLevel.rawValue)) — alım iptal")
            await TradeBrainExecutionTracker.shared.recordSkip(
                symbol: symbol,
                reason: "Portföy ısı limiti (\(heatLevel.rawValue))"
            )
            return
        }
        if heatMultiplier < 1.0 {
            proposedQuantity *= heatMultiplier
            print("🌡️ executeBuy: Portföy ısısı (\(heatLevel.rawValue)) — miktar \(String(format: "%.0f%%", heatMultiplier * 100)) küçültüldü")
        }
        let marketOpenCount = marketFilteredPortfolio.count
        ArgusLogger.info("executeBuy: \(isBist ? "BIST" : "GLOBAL") açık pozisyon sayısı = \(marketOpenCount)", category: "TRADEBRAIN")
        
        let peakEquity = await MainActor.run {
            isBist ? PortfolioStore.shared.peakBistEquity : PortfolioStore.shared.peakGlobalEquity
        }
        let riskCheck = PortfolioRiskManager.shared.checkBuyRisk(
            symbol: symbol,
            proposedAmount: allocation,
            currentPrice: currentPrice,
            portfolio: marketFilteredPortfolio,
            cashBalance: availableBalance,
            totalEquity: totalEquity,
            peakEquity: peakEquity
        )
        
        ArgusLogger.info("executeBuy: Risk Check - CanTrade: \(riskCheck.canTrade), Blockers: \(riskCheck.blockers)", category: "TRADEBRAIN")
        
        if !riskCheck.canTrade {
            log("🛑 \(symbol): Risk engeli - \(riskCheck.blockers.joined(separator: ", "))")
            ArgusLogger.error("executeBuy: Risk engeli - \(riskCheck.blockers.joined(separator: ", "))", category: "TRADEBRAIN")
            let firstBlocker = riskCheck.blockers.first ?? "bilinmeyen"
            await TradeBrainExecutionTracker.shared.recordSkip(
                symbol: symbol,
                reason: "Risk gate: \(firstBlocker)"
            )
            return
        }
        
        // Uyarıları logla
        for warning in riskCheck.warnings {
            log("⚠️ \(symbol): \(warning)")
            ArgusLogger.warn("executeBuy: \(warning)", category: "TRADEBRAIN")
        }
        
        if let adjustedQty = riskCheck.adjustedQuantity {
            proposedQuantity = adjustedQty
            ArgusLogger.info("executeBuy: Quantity adjusted to \(adjustedQty)", category: "TRADEBRAIN")
        }
        
        // Uyarıları logla
        for warning in riskCheck.warnings {
            log("⚠️ \(symbol): \(warning)")
        }
        
        if let adjustedQty = riskCheck.adjustedQuantity {
            proposedQuantity = adjustedQty
        }
        
        // 3. GOVERNOR KONTROLÜ (YENİ - Execution Logic Centralization)
        if isBist {
            // BIST Vali (BistExecutionGovernor) Kontrolü
            ArgusLogger.info("executeBuy: BIST Vali kontrolü yapılıyor...", category: "TRADEBRAIN")
            if let bistDecision = decision.bistDetails {
                let snapshot = BistExecutionGovernor.shared.audit(
                    decision: bistDecision,
                    grandDecisionID: bistDecision.id,
                    currentPrice: currentPrice,
                    portfolio: portfolio,
                    lastTradeTime: nil // Executor zaten cooldown kontrolü yapıyor
                )
                
                ArgusLogger.info("executeBuy: BIST Vali kararı - Action: \(snapshot.action), Reason: \(snapshot.reason)", category: "TRADEBRAIN")
                
                if snapshot.action != .buy {
                    log("🇹🇷 BIST Vali VETO: \(symbol) -> \(snapshot.reason)")
                    ArgusLogger.error("executeBuy: BIST Vali VETO - \(snapshot.reason)", category: "TRADEBRAIN")
                    await TradeBrainExecutionTracker.shared.recordSkip(
                        symbol: symbol,
                        reason: "BIST Vali: \(snapshot.reason)"
                    )
                    return // İŞLEM İPTAL
                } else {
                    log("🇹🇷 BIST Vali ONAY: \(symbol)")
                    ArgusLogger.info("executeBuy: BIST Vali ONAY", category: "TRADEBRAIN")
                }
            } else {
                log("⚠️ \(symbol): BIST detayı eksik, Vali kontrolü atlanıyor.")
                ArgusLogger.warn("executeBuy: BIST detayı eksik", category: "TRADEBRAIN")
            }
        }
        
        // 3. TAKVİM KONTROLÜ
        ArgusLogger.info("executeBuy: Takvim kontrolü yapılıyor...", category: "TRADEBRAIN")
        let eventRisk = EventCalendarService.shared.assessPositionRisk(symbol: symbol)
        
        ArgusLogger.info("executeBuy: Event Risk - ShouldAvoid: \(eventRisk.shouldAvoidNewPosition)", category: "TRADEBRAIN")
        
        if eventRisk.shouldAvoidNewPosition {
            log("📅 \(symbol): Takvim engeli - Yaklaşan kritik olay")
            ArgusLogger.error("executeBuy: Takvim engeli", category: "TRADEBRAIN")
            for warning in eventRisk.warnings {
                log("   ⚠️ \(warning)")
                ArgusLogger.warn("executeBuy: \(warning)", category: "TRADEBRAIN")
            }
            await TradeBrainExecutionTracker.shared.recordSkip(
                symbol: symbol,
                reason: "Takvim engeli (kritik olay)"
            )
            return
        }
        
        // 4. GOVERNOR KONTROLÜ
        //
        // KRİTİK FIX: Eski sürüm `decision.aetherDecision.netSupport * 100.0` kullanıyordu.
        // netSupport -1..+1 aralığında; nötr makroda 0. Üstelik AetherCouncil son zamanda
        // "0 öneri toplandı" diyerek sık sık boş netSupport=0 döndürüyor. Sonuç: Governor'a
        // aether=0 gidiyor, Deep Risk-Off algılanıyor, HER ALIM VETO EDİLİYOR.
        //
        // Doğru kaynak: MacroRegimeService'in cached numericScore'u (0-100 aralığında,
        // satır 478'de `regimeAetherScore` olarak zaten hesaplandı).
        let atlasScoreForLogging = await MainActor.run { FundamentalScoreStore.shared.getScore(for: symbol)?.totalScore }
        let scores = (
            atlas: atlasScoreForLogging,
            orion: orionScore as Double?,
            aether: regimeAetherScore,
            hermes: nil as Double?
        )
        
        // ATR-bazlı SL/TP referans seviyeleri.
        // Bu seviyeler execution'da KULLANILMIYOR — Alkindus'un trade outcome'larını
        // R-multiple olarak değerlendirmesi için referans noktalar (Faz 2.1).
        // ATR yoksa fiyatın %3'ü fallback (volatil hisseler için makul ortalama).
        let atr = decision.phoenixAdvice?.atr ?? (currentPrice * 0.03)
        let computedStopLoss = currentPrice - (atr * 1.5)
        let computedTakeProfit = currentPrice + (atr * 2.5) // 1:1.67 R:R

        let signal = AutoPilotSignal(
            action: .buy,
            quantity: proposedQuantity,
            reason: decision.reasoning,
            stopLoss: computedStopLoss,
            takeProfit: computedTakeProfit,
            strategy: .pulse,
            trimPercentage: nil,
            grandDecision: decision
        )
        
        let governorDecision = await ExecutionGovernor.shared.review(
            signal: signal,
            symbol: symbol,
            quantity: proposedQuantity,
            portfolio: marketFilteredPortfolio,
            equity: totalEquity,
            scores: (scores.atlas, scores.orion, scores.aether, nil)
        )
        
        ArgusLogger.info("executeBuy: Governor input - Market: \(isBist ? "BIST" : "GLOBAL"), Equity: \(String(format: "%.2f", totalEquity)), OpenPos: \(marketFilteredPortfolio.count)", category: "TRADEBRAIN")
        
        ArgusLogger.info("executeBuy: ExecutionGovernor karar bekleniyor...", category: "TRADEBRAIN")
        
        switch governorDecision {
        case .approved(_, let adjustedQty):
            proposedQuantity = adjustedQty
            ArgusLogger.info("executeBuy: ExecutionGovernor ONAY - Quantity: \(adjustedQty)", category: "TRADEBRAIN")
            
        case .rejected(let reason):
            log("🛡️ \(symbol): Governor VETO - \(reason)")
            ArgusLogger.error("executeBuy: ExecutionGovernor VETO - \(reason)", category: "TRADEBRAIN")
            await TradeBrainExecutionTracker.shared.recordSkip(
                symbol: symbol,
                reason: "Governor VETO: \(reason)"
            )
            return
        }
        
        // 5. ALIM YAP - AlertManager.executeBuy() dogrudan cagiriliyor
        ArgusLogger.info("executeBuy: AlertManager.executeBuy cagiriliyor - Symbol: \(symbol), Qty: \(proposedQuantity), Price: \(currentPrice)", category: "TRADEBRAIN")
        
        let rationale: String
        if isAddOn {
            rationale = "EKLEME: \(decision.reasoning)"
        } else if momentumFloor > 0 {
            rationale = "MOMENTUM: \(decision.reasoning)"
        } else {
            rationale = decision.reasoning
        }

        let trade = await MainActor.run {
            AlertManager.shared.executeBuy(
                symbol: symbol,
                quantity: proposedQuantity,
                price: currentPrice,
                rationale: rationale,
                stopLoss: computedStopLoss,
                takeProfit: computedTakeProfit,
                decision: decision
            )
        }

        if let trade = trade {
            log("✅ \(symbol): \(isAddOn ? "EKLEME" : "ALIM") - \(String(format: "%.2f", trade.quantity)) adet @ \(String(format: "%.2f", currentPrice))\(isAddOn ? " [EKLEME]" : momentumFloor > 0 ? " [MOMENTUM]" : "")")
            log("   📋 Karar: \(decision.action.rawValue) (\(String(format: "%.0f", decision.confidence * 100))%)")
            ArgusLogger.info("executeBuy: ALIM BAŞARILI - \(symbol): \(trade.quantity) @ \(currentPrice)", category: "TRADEBRAIN")

            // Faz 0 Task 1+2: Forward test omurgası — ArgusLedger trades tablosuna
            // her başarılı alımı yaz, dönen ledger UUID'sini Trade.ledgerTradeId'ye
            // yansıt. Satım anında closeTrade bu UUID üzerinden ledger satırını kapatır.
            // Atlas/Hermes skorları Task 2'de decision.atlasDecision/hermesDecision'dan
            // beslenecek; şimdilik 0 — reason metni ve dominantSignal Orion ağırlıklı.
            let ledgerTradeId = await ExecutionGovernor.shared.didExecute(
                trade: trade,
                scores: (0, orionScore, regimeAetherScore, 0, nil),
                decisionId: decision.id.uuidString
            )
            await MainActor.run {
                PortfolioStore.shared.updateLedgerId(
                    tradeId: trade.id,
                    ledgerId: ledgerTradeId
                )
            }
        } else {
            let lastExecError = await MainActor.run { ExecutionLogger.shared.lastTradeError }
            log("❌ \(symbol): Alım REDDEDİLDİ — \(lastExecError ?? "?")")
            ArgusLogger.error("executeBuy: ALIM REDDEDİLDİ - \(symbol): \(lastExecError ?? "?")", category: "TRADEBRAIN")
            await TradeBrainExecutionTracker.shared.recordSkip(
                symbol: symbol,
                reason: "Execution failed: \(lastExecError ?? "?")"
            )
        }

        // Cooldown ayarla (eski + yeni registry)
        lastExecutionTime[symbol] = Date()
        await CooldownRegistry.shared.enter(
            symbol: symbol, type: .postTrade,
            duration: baseCooldownSeconds * profile.cooldownMultiplier,
            reason: "executeBuy"
        )
        ArgusLogger.info("executeBuy: Cooldown ayarlandı - \(symbol)", category: "TRADEBRAIN")
    }

    // MARK: - Emergency Sell (Liquidate Only)
    
    private func executeEmergencySell(
        trade: Trade,
        decision: ArgusGrandDecision,
        currentPrice: Double
    ) async {
        // Council LIQUIDATE dedi - acil çıkış
        await MainActor.run {
            AlertManager.shared.executeSell(
                tradeId: trade.id,
                price: currentPrice,
                reason: "🚨 Council LIQUIDATE: \(decision.reasoning)"
            )
        }
        
        log("🚨 \(trade.symbol): ACİL SATIŞ - Council LIQUIDATE kararı")
        log("   📋 Sebep: \(decision.reasoning)")
        
        // Plan tamamla
        PositionPlanStore.shared.completePlan(tradeId: trade.id)
        
        // Cooldown (eski + registry)
        lastExecutionTime[trade.symbol] = Date()
        await CooldownRegistry.shared.enter(
            symbol: trade.symbol, type: .postSell,
            duration: 300, reason: "emergencySell"
        )
    }

    private func executePolicyReduce(
        trade: Trade,
        trimPercent: Double,
        currentPrice: Double,
        policy: RiskEscapePolicy
    ) async {
        if trimPercent >= 100 {
            await MainActor.run {
                AlertManager.shared.executeSell(
                    tradeId: trade.id,
                    price: currentPrice,
                    reason: "POLICY_\(policy.mode.rawValue)_LIQUIDATE"
                )
            }
            log("🛡️ \(trade.symbol): Policy LIQUIDATE (\(policy.mode.rawValue))")
        } else {
            await MainActor.run {
                AlertManager.shared.executeSell(
                    tradeId: trade.id,
                    price: currentPrice,
                    reason: "POLICY_\(policy.mode.rawValue)_TRIM_\(Int(trimPercent))",
                    trimPercentage: trimPercent
                )
            }
            log("🛡️ \(trade.symbol): Policy TRIM %\(Int(trimPercent)) (\(policy.mode.rawValue))")
        }
        lastExecutionTime[trade.symbol] = Date()
        await CooldownRegistry.shared.enter(
            symbol: trade.symbol, type: .postTrade,
            duration: 300, reason: "policyReduce"
        )
    }

    private func forcedTrimPercent(
        policy: RiskEscapePolicy,
        trade: Trade,
        currentPrice: Double,
        volatility: Double
    ) -> Double {
        guard trade.entryPrice > 0 else { return policy.minimumTrimPercent }
        let pnlPercent = ((currentPrice - trade.entryPrice) / trade.entryPrice) * 100

        switch policy.mode {
        case .deepRiskOff:
            if pnlPercent <= -4 || volatility >= 0.06 { return 100 }
            return max(policy.minimumTrimPercent, 50)
        case .riskOff:
            if pnlPercent <= -6 || volatility >= 0.05 { return 40 }
            return max(policy.minimumTrimPercent, 25)
        case .normal:
            return 0
        }
    }

    private func executeSafeAllocationOrders(
        policy: RiskEscapePolicy,
        openSymbols: Set<String>,
        quotes: [String: Quote],
        globalBalance: Double,
        bistBalance: Double
    ) async {
        let safeUniverse = SafeUniverseService.shared
        let (_, target) = AetherAllocationEngine.shared.determineAllocation(aetherScore: policy.aetherScore)

        let deployRatio: Double = (policy.mode == .deepRiskOff) ? 0.60 : 0.35
        let globalBudget = globalBalance * deployRatio

        let selectedBond = safeUniverse.getActiveAssets(by: .bond).first?.symbol
        let selectedGold = safeUniverse.getActiveAssets(by: .gold).first?.symbol
        let selectedHedge = safeUniverse.getActiveAssets(by: .hedge).first?.symbol

        var orders: [SafeAllocationOrder] = []
        if let bond = selectedBond {
            orders.append(SafeAllocationOrder(symbol: bond, amount: globalBudget * target.bond, type: .bond, reason: "SAFE_ALLOC_BOND"))
        }
        if let gold = selectedGold {
            orders.append(SafeAllocationOrder(symbol: gold, amount: globalBudget * target.gold, type: .gold, reason: "SAFE_ALLOC_GOLD"))
        }
        if policy.mode == .deepRiskOff, let hedge = selectedHedge {
            orders.append(SafeAllocationOrder(symbol: hedge, amount: globalBudget * 0.15, type: .hedge, reason: "SAFE_ALLOC_HEDGE"))
        }

        for order in orders where order.amount > 50 {
            guard !openSymbols.contains(order.symbol) else { continue }
            guard let quote = quotes[order.symbol], quote.currentPrice > 0 else { continue }
            let qty = order.amount / quote.currentPrice
            if qty <= 0 { continue }

            let trade = await MainActor.run {
                AlertManager.shared.executeBuy(
                    symbol: order.symbol,
                    quantity: qty,
                    price: quote.currentPrice,
                    rationale: order.reason,
                    stopLoss: nil,
                    takeProfit: nil,
                    decision: nil
                )
            }
            if trade != nil {
                ArgusLogger.info(
                    "TradeBrainSafeAllocation: BUY \(order.symbol) amount=\(String(format: "%.2f", order.amount)) policy=\(policy.mode.rawValue)",
                    category: "TRADEBRAIN"
                )
            } else {
                let lastExecError = await MainActor.run { ExecutionLogger.shared.lastTradeError }
                ArgusLogger.error(
                    "TradeBrainSafeAllocation: BUY RED \(order.symbol) — \(lastExecError ?? "?")",
                    category: "TRADEBRAIN"
                )
            }
        }

        if bistBalance > 0, policy.mode != .normal {
            ArgusLogger.info(
                "TradeBrainSafeAllocation: TRY bakiye riskten korunma modunda nakitte tutuldu (\(String(format: "%.2f", bistBalance)))",
                category: "TRADEBRAIN"
            )
        }
    }

    private func isSafeAsset(_ symbol: String) -> Bool {
        guard let type = SafeUniverseService.shared.getUniverseType(for: symbol) else { return false }
        switch type {
        case .bond, .cashLike, .gold, .hedge:
            return true
        default:
            return false
        }
    }
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        
        DispatchQueue.main.async {
            self.executionLogs.insert(logEntry, at: 0)
            if self.executionLogs.count > 100 {
                self.executionLogs = Array(self.executionLogs.prefix(100))
            }
        }
        
        ArgusLogger.info("Trade Brain: \(message)", category: "TRADEBRAIN")
    }

    private func debugSkip(symbol: String, reason: String) {
        ArgusLogger.info("AUTOPILOT-SKIP: \(symbol) -> \(reason)", category: "TRADEBRAIN")
    }

    private func buildExecutionProfile(
        symbol: String,
        decision: ArgusGrandDecision,
        portfolio: [Trade],
        quote: Quote?,
        candles: [Candle]
    ) async -> SymbolExecutionProfile {
        var allocationMultiplier = 1.0
        var cooldownMultiplier = 1.0
        // 2026-05-04: Paper-trading kalibrasyonu. Eski (real-money kalibrasyonu):
        // accumulate %50 / aggressive %55 başlangıç + %42 / %48 taban → Yahoo'nun
        // gecikmeli/eksik verisiyle çoğu council kararı bu eşiklerin altında kaldığı
        // için trade hiç tetiklenmiyordu (kullanıcı "0 ya da 1 güven" sorununu yaşadı).
        // Yeni: accumulate %35 / aggressive %40 başlangıç + %25 / %30 taban.
        // Volatilite/event/zayıf-geçmiş çarpanları hâlâ minConfidence'i yukarı çeker
        // (aşırı riskli sembolde tighten korunur). Gerçek paraya geçilirse eski
        // değerlere (0.50/0.55 + 0.42/0.48) geri dönülmeli.
        var minConfidence: Double = decision.action == .accumulate ? 0.35 : 0.40
        var notes: [String] = []

        let referencePrice = quote?.currentPrice ?? candles.last?.close ?? 0
        let volatility = estimateVolatility(candles: candles, referencePrice: referencePrice)
        if volatility > 0.05 {
            allocationMultiplier *= 0.68
            cooldownMultiplier *= 1.45
            minConfidence += 0.10
            notes.append("yüksek volatilite")
        } else if volatility < 0.02 {
            allocationMultiplier *= 1.10
            cooldownMultiplier *= 0.92
            notes.append("düşük volatilite")
        }

        let eventRisk = EventCalendarService.shared.assessPositionRisk(symbol: symbol)
        if eventRisk.shouldAvoidNewPosition {
            allocationMultiplier *= 0.45
            cooldownMultiplier *= 1.8
            minConfidence += 0.12
            notes.append("yakın kritik olay")
        } else if eventRisk.shouldReducePosition {
            allocationMultiplier *= 0.72
            cooldownMultiplier *= 1.25
            minConfidence += 0.06
            notes.append("olay riski")
        }

        let closedTrades = portfolio.filter { !$0.isOpen && $0.symbol == symbol && $0.exitPrice != nil }
        if !closedTrades.isEmpty {
            let winCount = closedTrades.filter { $0.profit > 0 }.count
            let winRate = Double(winCount) / Double(closedTrades.count)
            let avgPnL = closedTrades.map(\.profitPercentage).reduce(0, +) / Double(closedTrades.count)

            if winRate < 0.40 || avgPnL < -1.0 {
                allocationMultiplier *= 0.72
                cooldownMultiplier *= 1.20
                minConfidence += 0.08
                notes.append("zayıf sembol geçmişi")
            } else if winRate > 0.65 && avgPnL > 1.5 {
                allocationMultiplier *= 1.10
                cooldownMultiplier *= 0.90
                minConfidence -= 0.03
                notes.append("güçlü sembol geçmişi")
            }
        }

        let hasCustomWeights = await MainActor.run {
            ChironWeightStore.shared.hasCustomWeights(symbol: symbol)
        }
        if hasCustomWeights {
            allocationMultiplier *= 1.10
            cooldownMultiplier *= 0.90
            minConfidence -= 0.02
            notes.append("custom chiron ağırlığı")
        }

        if decision.action == .aggressiveBuy && decision.confidence > 0.78 {
            allocationMultiplier *= 1.06
            notes.append("hücum güveni yüksek")
        }

        allocationMultiplier = min(max(allocationMultiplier, 0.35), 1.45)
        cooldownMultiplier = min(max(cooldownMultiplier, 0.75), 2.5)
        // 2026-05-13 Task 6 hijyen: paper-tuned tabanları dürüst kalibrasyona geri.
        // Eski (paper): BİRİKTİR 0.25, AGRESİF 0.30.
        // Yeni (dürüst): BİRİKTİR 0.42, AGRESİF 0.48 — council net BUY oyu için
        // üye oranı eşiğini gerçek para disipliniyle hizalar.
        let minConfFloor = decision.action == .accumulate ? 0.42 : 0.48
        minConfidence = min(max(minConfidence, minConfFloor), 0.85)

        let tier: SymbolExecutionProfile.RiskTier
        if allocationMultiplier <= 0.72 || minConfidence >= 0.72 {
            tier = .defensive
        } else if allocationMultiplier >= 1.15 && minConfidence <= 0.55 {
            tier = .offensive
        } else {
            tier = .balanced
        }

        return SymbolExecutionProfile(
            symbol: symbol,
            tier: tier,
            allocationMultiplier: allocationMultiplier,
            cooldownMultiplier: cooldownMultiplier,
            minDecisionConfidence: minConfidence,
            notes: notes
        )
    }

    private func estimateVolatility(candles: [Candle], referencePrice: Double) -> Double {
        guard candles.count >= 8, referencePrice > 0 else { return 0.03 }

        let sample = Array(candles.suffix(24))
        guard sample.count >= 2 else { return 0.03 }

        var ranges: [Double] = []
        for index in 1..<sample.count {
            let high = sample[index].high
            let low = sample[index].low
            let previousClose = sample[index - 1].close
            let trueRange = max(high - low, abs(high - previousClose), abs(low - previousClose))
            ranges.append(trueRange)
        }

        guard !ranges.isEmpty else { return 0.03 }
        let atr = ranges.reduce(0, +) / Double(ranges.count)
        return atr / referencePrice
    }
    
    // MARK: - Public API
    
    func clearLogs() {
        executionLogs.removeAll()
    }
    
    func resetCooldowns() {
        lastExecutionTime.removeAll()
    }
    
    // MARK: - Trade Brain 3.0 Enhanced Decision
    
    func makeEnhancedDecision(
        symbol: String,
        grandDecision: ArgusGrandDecision,
        candles: [Candle],
        orionScore: OrionScoreResult?,
        atlasScore: Double?
    ) async -> EnhancedTradeBrainDecision {
        
        let regimeContext = await regimeMemory.getRegimeContext()
        let eventContext = await eventMemory.getEventContextForDecision(symbol: symbol)
        
        let macroContext = MacroContext(
            vix: regimeContext.vix,
            regime: regimeContext.regime,
            trend: "Yatay",
            fearGreedIndex: 50
        )
        
        let multiHorizon = await horizonEngine.generateMultiHorizonDecision(
            symbol: symbol,
            candles: candles,
            orionScore: orionScore,
            atlasScore: atlasScore,
            macroContext: macroContext
        )
        
        let orionModule = OrionModuleDecision(
            trendSignal: grandDecision.action == .aggressiveBuy || grandDecision.action == .accumulate ? "buy" : 
                         grandDecision.action == .trim || grandDecision.action == .liquidate ? "sell" : "neutral",
            confidence: grandDecision.confidence,
            rsi: orionScore?.components.rsi ?? 50,
            macdSignal: orionScore?.components.macdHistogram != nil ? (orionScore!.components.macdHistogram! > 0 ? "bullish" : "bearish") : "notr"
        )
        
        let atlasModule = atlasScore.map { AtlasModuleDecision(
            action: grandDecision.action == .aggressiveBuy || grandDecision.action == .accumulate ? "buy" : "sell",
            confidence: Double($0) / 100.0,
            score: $0
        )}
        
        let aetherModule = AetherModuleDecision(
            stance: regimeContext.regime == "Risk On" ? "risk_on" : regimeContext.regime == "Risk Off" ? "risk_off" : "neutral",
            confidence: regimeContext.historicalWinRate,
            riskLevel: regimeContext.riskScore
        )
        
        let hermesModule: HermesModuleDecision? = nil
        
        let contradictionAnalysis = await selfQuestionEngine.analyzeContradictions(
            orionDecision: orionModule,
            atlasDecision: atlasModule,
            aetherDecision: aetherModule,
            hermesDecision: hermesModule
        )
        
        let calibratedConfidence: Double
        if contradictionAnalysis.hasContradictions {
            calibratedConfidence = max(0.1, multiHorizon.calibratedConfidence - contradictionAnalysis.suggestedConfidenceDrop)
        } else {
            calibratedConfidence = multiHorizon.calibratedConfidence
        }
        
        await MainActor.run {
            self.lastMultiHorizonDecisions[symbol] = multiHorizon
            self.lastContradictionAnalyses[symbol] = contradictionAnalysis
        }
        
        await learningService.observeDecision(
            symbol: symbol,
            multiHorizon: multiHorizon,
            contradictionAnalysis: contradictionAnalysis,
            macroContext: macroContext,
            finalAction: grandDecision.action.rawValue,
            finalConfidence: calibratedConfidence
        )
        
        return EnhancedTradeBrainDecision(
            symbol: symbol,
            grandDecision: grandDecision,
            multiHorizon: multiHorizon,
            contradictionAnalysis: contradictionAnalysis,
            regimeContext: regimeContext,
            eventContext: eventContext,
            calibratedConfidence: calibratedConfidence,
            timestamp: Date()
        )
    }
    
    func recordTradeOutcome(
        symbol: String,
        wasCorrect: Bool,
        pnlPercent: Double,
        holdingDays: Int
    ) async {
        guard let multiHorizon = lastMultiHorizonDecisions[symbol],
              let contradiction = lastContradictionAnalyses[symbol] else {
            return
        }
        
        await confidenceCalibration.recordOutcome(
            confidence: multiHorizon.calibratedConfidence,
            wasCorrect: wasCorrect,
            pnlPercent: pnlPercent
        )
        
        ArgusLogger.info("TradeBrain: \(symbol) sonuc kaydedildi - \(wasCorrect ? "BASARILI" : "BASARISIZ")", category: "TRADEBRAIN")
    }
}

struct EnhancedTradeBrainDecision {
    let symbol: String
    let grandDecision: ArgusGrandDecision
    let multiHorizon: MultiHorizonDecision
    let contradictionAnalysis: ContradictionAnalysis
    let regimeContext: RegimeDecisionContext
    let eventContext: EventDecisionContext
    let calibratedConfidence: Double
    let timestamp: Date
    
    var shouldProceed: Bool {
        calibratedConfidence > 0.45 && !contradictionAnalysis.hasContradictions || contradictionAnalysis.severity != .high
    }
    
    var riskWarning: String? {
        if contradictionAnalysis.hasContradictions {
            return contradictionAnalysis.recommendation
        }
        if eventContext.hasHighImpactEvent {
            return "Yuksek etkili olay yaklasti"
        }
        if regimeContext.riskScore > 0.6 {
            return "Piyasa risk ortami yuksek"
        }
        return nil
    }
}
