import Foundation

/// LLM-destekli Türkçe Argus analiz yorumu.
///
/// `ArgusGrandDecision`'daki motor skorlarını ve çelişki haritasını alıp
/// 3-5 cümlelik doğal Türkçe paragraf üretir. Sonuçlar memory-cache'te
/// 30 dakika tutulur — kullanıcı sheet'i kapatıp tekrar açtığında LLM
/// dövülmesin (bakiye + zaman).
///
/// Sıra: Cerebras (`gpt-oss-120b`) → Gemini 2.5 Flash → GLM → Groq.
/// `GroqClient.chat()` cascade'i şeffaf — biz sadece doğru prompt'u veriyoruz.
enum ArgusAnalysisNarrative {

    /// 30 dakika cache TTL — motorReasoningler hızlı değişmiyor.
    private static let cacheTTL: TimeInterval = 1800

    private struct CachedNarrative: Sendable {
        let text: String
        let createdAt: Date
    }

    // Thread-safe küçük cache — sembol+decision-hash başına.
    private static let cacheLock = NSLock()
    private static var cache: [String: CachedNarrative] = [:]

    static func generate(symbol: String, decision: ArgusGrandDecision) async throws -> String {
        let cacheKey = cacheKey(for: symbol, decision: decision)

        // Cache hit — `withLock` async-uyumlu (Swift 5.9+).
        if let cached: String = cacheLock.withLock({
            if let hit = cache[cacheKey], -hit.createdAt.timeIntervalSinceNow < cacheTTL {
                return hit.text
            }
            return nil
        }) {
            return cached
        }

        let prompt = await buildPrompt(symbol: symbol, decision: decision)
        let messages: [GroqClient.ChatMessage] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: prompt)
        ]

        let raw = try await GroqClient.shared.chat(messages: messages, maxTokens: 600)
        let cleaned = cleanResponse(raw)

        cacheLock.withLock {
            cache[cacheKey] = CachedNarrative(text: cleaned, createdAt: Date())
        }

        return cleaned
    }

    // MARK: - Cache key

    private static func cacheKey(for symbol: String, decision: ArgusGrandDecision) -> String {
        // ScoreCore + action konsey haline gore degisir. Bunlari hash edersek
        // ayni gun icinde tekrar acmalarda cache hit olur, gercek karar
        // degisince yeniden uretilir.
        let action = decision.finalActionCore
        let scoreRounded = Int(decision.finalScoreCore.rounded() / 5) * 5  // 5'lik bucket
        return "\(symbol.uppercased())_\(action)_\(scoreRounded)"
    }

    // MARK: - Prompt

    private static let systemPrompt = """
    Sen Argus'sun — profesyonel bir finansal analistsin. Konsey kararını ve
    yedi motorun oylarını okuyup, kullanıcıya 3-5 cümlelik doğal Türkçe bir
    paragraf yazıyorsun.

    KESİN KURALLAR:
    1. SADECE TÜRKÇE.
    2. İç sistem isimlerini ASLA KULLANMA. "Orion", "Atlas", "Aether",
       "Hermes", "Chiron", "Demeter", "Prometheus", "Phoenix", "Athena",
       "Konsey" sözcüklerini söyleme. Yerine kavramsal terim kullan:
       teknik analiz, temel/bilanço analizi, makro ortam, haber sentiment,
       piyasa rejimi, sektör görünümü, fiyat tahmini, dirilme/dip yapısı,
       risk-getiri profili.
    3. Her iddiayı verilen sayıyla destekle. Soyut konuşma ("güçlü görünüyor"
       yasak; "%72 güvenle alım sinyali, teknik tarafta 78/100, bilanço 65/100"
       gibi somut konuş).
    4. 3-5 cümle. Kısa ve net.
    5. Çelişki varsa onu açıkça vurgula ("teknik alım derken bilanço zayıflığa
       işaret ediyor" gibi).
    6. Spekülatif tavsiye yasak. Sentez veriyorsun, "şu fiyattan alın" demiyorsun.

    FORMAT YASAKLARI:
    - Yıldız (*, **), tire (-), diyez (#), alt çizgi (_), ters tırnak (`) YOK
    - Emoji YOK
    - Madde işaretleri YOK
    - Düz paragraf metin ver, başka hiçbir şey yok.
    """

    @MainActor
    private static func buildPrompt(symbol: String, decision d: ArgusGrandDecision) -> String {
        let action = humanAction(d.finalActionCore)
        let score = Int(d.finalScoreCore.rounded())

        var lines: [String] = []
        lines.append("Hisse: \(symbol)")
        lines.append("Konsey kararı: \(action) (güven: %\(score))")
        lines.append("")
        lines.append("Motor oyları:")

        for r in d.motorReasonings where r.isVisible {
            let stance = humanStance(r.stance)
            let s = Int(r.score.rounded())
            let category = motorCategory(r.motor)
            var line = "- \(category): \(stance) (\(s)/100)"
            if !r.summary.isEmpty {
                line += " — \(r.summary)"
            }
            lines.append(line)
        }

        if !d.conflictMapText.isEmpty {
            lines.append("")
            lines.append("Çelişki: \(d.conflictMapText)")
        }

        lines.append("")
        lines.append("Lütfen yukarıdaki verileri okuyup kullanıcıya 3-5 cümlelik doğal Türkçe bir yorum yaz. Motor isimlerini kullanmadan, kavramsal terimle anlat.")
        return lines.joined(separator: "\n")
    }

    private static func humanAction(_ a: SignalAction) -> String {
        switch a {
        case .buy:  return "Al"
        case .sell: return "Sat"
        case .hold: return "Bekle"
        case .wait: return "İzle"
        case .skip: return "Pas"
        }
    }

    private static func humanStance(_ s: MotorStance) -> String {
        switch s {
        case .strongBuy:  return "Güçlü alım"
        case .buy:        return "Alım"
        case .wait:       return "Beklemede"
        case .neutral:    return "Nötr"
        case .sell:       return "Satım"
        case .strongSell: return "Güçlü satım"
        }
    }

    /// Kullanıcıya motor isimleri yerine kavramsal terim ver — system
    /// prompt'taki kuralı pekiştirir ki LLM "Orion" yazma riskini azaltır.
    private static func motorCategory(_ m: MotorEngine) -> String {
        switch m {
        case .orion:      return "Teknik analiz"
        case .atlas:      return "Bilanço/temel analiz"
        case .aether:     return "Makro ortam"
        case .hermes:     return "Haber sentiment"
        case .chiron:     return "Piyasa rejimi"
        case .demeter:    return "Sektör görünümü"
        case .prometheus: return "Fiyat tahmini"
        case .phoenix:    return "Dirilme yapısı"
        case .athena:     return "Risk profili"
        case .council:    return "Konsey ortalaması"
        default:          return "Genel analiz"
        }
    }

    // MARK: - Response cleanup

    private static func cleanResponse(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Markdown başlık/vurgu temizliği (system prompt'a rağmen sızabiliyor)
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "###", with: "")
        s = s.replacingOccurrences(of: "##", with: "")
        s = s.replacingOccurrences(of: "`", with: "")

        // Madde işareti satır başları
        let lines = s.split(separator: "\n").map { line -> Substring in
            var l = line
            while l.hasPrefix("- ") || l.hasPrefix("• ") {
                l = l.dropFirst(2)
            }
            return l
        }
        s = lines.joined(separator: " ")

        // Fazla boşluk
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
