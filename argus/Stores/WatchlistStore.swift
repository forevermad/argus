import Foundation
import Combine
import SwiftUI

@MainActor
class WatchlistStore: ObservableObject {
    static let shared = WatchlistStore()
    
    @Published var items: [String] = [] {
        didSet {
            saveWatchlist()
        }
    }
    
    private init() {
        loadWatchlist()
    }
    
    // MARK: - Public API
    
    func add(_ symbol: String) -> Bool {
        if !items.contains(symbol) {
            items.append(symbol)
            return true
        }
        return false
    }
    
    func remove(_ symbol: String) {
        if let index = items.firstIndex(of: symbol) {
            items.remove(at: index)
        }
    }
    
    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }
    
    // MARK: - Persistence Logic
    
    private func loadWatchlist() {
        // Comprehensive Universe — 2026-04 genişletildi
        // Hedef: çeşit + likidite. Scan kapasitesi (batch 30, timer 180s)
        // ~300 sembole kadar rahat kaldırıyor. Üzerine çıkarmak Yahoo rate
        // limit ve BorsaPy tıkanmasına yol açabilir.
        let comprehensiveUniverse: [String] = [
            // Technology — core (21)
            "AAPL", "MSFT", "NVDA", "AVGO", "ORCL", "ADBE", "CRM", "AMD", "QCOM", "TXN",
            "IBM", "INTC", "NOW", "AMAT", "MU", "LRCX", "ADI", "KLAC", "PANW", "SNOW", "PLTR",
            // Technology — yeni: semi + AI/cloud derinliği (18)
            "ARM", "MCHP", "ON", "MRVL", "SMCI", "DELL", "NET", "DDOG", "MDB", "ESTC",
            "ZS", "CRWD", "FTNT", "CSCO", "HPQ", "WDC", "STX", "ANET",
            // Communication (10)
            "GOOGL", "META", "NFLX", "DIS", "CMCSA", "TMUS", "VZ", "T", "CHTR", "WBD",
            // Communication — yeni: sosyal + medya (6)
            "SNAP", "PINS", "RBLX", "DKNG", "SPOT", "PARA",
            // Financials — core (16)
            "JPM", "V", "MA", "BAC", "WFC", "MS", "GS", "BLK", "C", "AXP",
            "SPGI", "CB", "PGR", "SCHW", "COIN",
            // Financials — yeni: fintech + regional (7)
            "SQ", "PYPL", "HOOD", "AFRM", "SOFI", "USB", "TFC",
            // Healthcare — core (15)
            "LLY", "UNH", "JNJ", "MRK", "ABBV", "TMO", "PFE", "AMGN", "ISRG", "ABT",
            "DHR", "BMY", "CVS", "ELV", "GILD",
            // Healthcare — yeni: biotech + pharma (8)
            "REGN", "VRTX", "BIIB", "MRNA", "NVO", "AZN", "HUM", "CI",
            // Consumer Discretionary (12)
            "AMZN", "TSLA", "HD", "MCD", "NKE", "SBUX", "BKNG", "TJX", "LOW", "LVS", "MAR", "HLT",
            // Consumer Discretionary — yeni: EV + retail (8)
            "F", "GM", "RIVN", "LCID", "ABNB", "CMG", "YUM", "EBAY",
            // Consumer Staples — core (10)
            "WMT", "PG", "COST", "KO", "PEP", "PM", "MO", "CL", "TGT", "EL",
            // Consumer Staples — yeni (5)
            "KHC", "MDLZ", "KDP", "DG", "KR",
            // Energy (8)
            "XOM", "CVX", "COP", "SLB", "EOG", "OXY", "MPC", "PSX",
            // Energy — yeni: hizmet + pipeline (4)
            "VLO", "HES", "KMI", "WMB",
            // Industrials (10)
            "CAT", "GE", "UNP", "HON", "UPS", "LMT", "RTX", "BA", "DE", "MMM",
            // Industrials — yeni: defense + transport (6)
            "NOC", "GD", "HII", "FDX", "NSC", "CSX",
            // Airlines (4)
            "AAL", "DAL", "UAL", "LUV",
            // Materials (4)
            "LIN", "SHW", "FCX", "NEM",
            // Materials — yeni (3)
            "DOW", "APD", "ECL",
            // Real Estate (4)
            "PLD", "AMT", "EQIX", "O",
            // Real Estate — yeni (3)
            "SPG", "WELL", "DLR",
            // Utilities (3)
            "NEE", "SO", "DUK",
            // Utilities — yeni (3)
            "AEP", "EXC", "SRE",
            // Crypto (2)
            "BTC-USD", "ETH-USD",
            // Crypto — yeni: majors (4)
            "SOL-USD", "ADA-USD", "AVAX-USD", "LINK-USD",
            // ETF — sektör (10)
            "XLK", "XLF", "XLV", "XLE", "XLI", "XLY", "XLP", "XLU", "XLRE", "XLC",
            // ETF — piyasa + hacim (6)
            "SPY", "QQQ", "IWM", "DIA", "VTI", "VOO",
            // ETF — emtia + tahvil (8)
            "GLD", "SLV", "USO", "UNG", "TLT", "IEF", "LQD", "HYG",
            // ETF — volatilite + emerging (4)
            "VIXY", "EEM", "FXI", "INDA",
            // International ADR (5)
            "TSM", "MELI", "UBER", "ASML", "SHOP",
            // International ADR — yeni: Çin + Avrupa (6)
            "BABA", "JD", "PDD", "TCEHY", "SONY", "RACE",

            // BIST — core (50, 2026-04 öncesi liste)
            "THYAO.IS", "ASELS.IS", "KCHOL.IS", "AKBNK.IS", "GARAN.IS",
            "SAHOL.IS", "TUPRS.IS", "EREGL.IS", "BIMAS.IS", "SISE.IS",
            "PETKM.IS", "SASA.IS", "HEKTS.IS", "FROTO.IS", "TOASO.IS",
            "ENKAI.IS", "ISCTR.IS", "YKBNK.IS", "VAKBN.IS", "HALKB.IS",
            "PGSUS.IS", "TAVHL.IS", "TCELL.IS", "TTKOM.IS",
            "TKFEN.IS", "MGROS.IS", "SOKM.IS", "AEFES.IS",
            "ARCLK.IS", "ALARK.IS", "ASTOR.IS", "BRSAN.IS", "CIMSA.IS",
            "DOAS.IS", "EGEEN.IS", "EKGYO.IS", "ENJSA.IS", "GESAN.IS",
            "KONTR.IS", "ODAS.IS", "ULKER.IS", "VESTL.IS", "GUBRF.IS",
            "AKSEN.IS", "KORDS.IS", "LOGO.IS", "MAVI.IS", "OTKAR.IS",
            // BIST — yeni: likit mid-cap + sektör derinliği (25)
            "AGHOL.IS", "AKFGY.IS", "ALKIM.IS", "AYGAZ.IS", "BIOEN.IS",
            "CCOLA.IS", "ECILC.IS", "EUPWR.IS", "ISMEN.IS", "KLKIM.IS",
            "MPARK.IS", "PARSN.IS", "PENGD.IS", "SELEC.IS", "SKBNK.IS",
            "SMRTG.IS", "TATGD.IS", "TTRAK.IS", "YATAS.IS", "ZOREN.IS",
            "BIZIM.IS", "OYAKC.IS", "ALBRK.IS"
        ].sorted()
        
        // Priority: Check v2
        if let data = UserDefaults.standard.data(forKey: "watchlist_v2"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.items = decoded
        } else if let legacyData = UserDefaults.standard.data(forKey: "watchlist"),
                  let decoded = try? JSONDecoder().decode([String].self, from: legacyData) {
            // MIGRATION: Restore Legacy Data
            print("📦 WatchlistStore: Migration from Legacy Storage")
            self.items = decoded
            saveWatchlist()
        }
        
        // FAILSAFE: If user has fewer than 5 symbols
        if self.items.isEmpty || (self.items.count < 5 && UserDefaults.standard.object(forKey: "watchlist_v2") == nil) {
            print("⚠️ WatchlistStore: Initializing Comprehensive Universe.")
            self.items = comprehensiveUniverse
            saveWatchlist()
        }
        
        // DYNAMIC INJECTION — 2026-04 genişletme.
        // Mevcut kullanıcılarda watchlist zaten varsa bu liste eksik
        // sembolleri ekler (mevcut olanlara dokunmaz). Yeni kullanıcılar
        // yukarıdaki comprehensiveUniverse'ı alır.
        let requiredSymbols = [
            // Semi + AI/cloud derinliği
            "ARM", "MCHP", "ON", "MRVL", "SMCI", "DELL", "NET", "DDOG", "MDB", "ESTC",
            "ZS", "CRWD", "FTNT", "CSCO", "HPQ", "WDC", "STX", "ANET",
            // Sosyal + medya
            "SNAP", "PINS", "RBLX", "DKNG", "SPOT", "PARA",
            // Fintech + regional bank
            "SQ", "PYPL", "HOOD", "AFRM", "SOFI", "USB", "TFC",
            // Biotech + pharma
            "REGN", "VRTX", "BIIB", "MRNA", "NVO", "AZN", "HUM", "CI",
            // EV + retail
            "F", "GM", "RIVN", "LCID", "ABNB", "CMG", "YUM", "EBAY",
            // Staples
            "KHC", "MDLZ", "KDP", "DG", "KR",
            // Energy service + pipeline
            "VLO", "HES", "KMI", "WMB",
            // Defense + transport
            "NOC", "GD", "HII", "FDX", "NSC", "CSX",
            // Airlines
            "AAL", "DAL", "UAL", "LUV",
            // Materials
            "DOW", "APD", "ECL",
            // Real Estate
            "SPG", "WELL", "DLR",
            // Utilities
            "AEP", "EXC", "SRE",
            // Crypto majors
            "SOL-USD", "ADA-USD", "AVAX-USD", "LINK-USD",
            // Sector ETFs
            "XLK", "XLF", "XLV", "XLE", "XLI", "XLY", "XLP", "XLU", "XLRE", "XLC",
            // Market ETFs
            "SPY", "QQQ", "IWM", "DIA", "VTI", "VOO",
            // Commodity + bond ETFs
            "GLD", "SLV", "USO", "UNG", "TLT", "IEF", "LQD", "HYG",
            // Volatility + emerging ETFs
            "VIXY", "EEM", "FXI", "INDA",
            // International ADRs
            "TSM", "MELI", "UBER", "ASML", "SHOP",
            "BABA", "JD", "PDD", "TCEHY", "SONY", "RACE",

            // BIST core
            "THYAO.IS", "ASELS.IS", "KCHOL.IS", "AKBNK.IS", "GARAN.IS",
            "SAHOL.IS", "TUPRS.IS", "EREGL.IS", "BIMAS.IS", "SISE.IS",
            "PETKM.IS", "SASA.IS", "HEKTS.IS", "FROTO.IS", "TOASO.IS",
            "ENKAI.IS", "ISCTR.IS", "YKBNK.IS", "VAKBN.IS", "HALKB.IS",
            "PGSUS.IS", "TAVHL.IS", "TCELL.IS", "TTKOM.IS",
            "TKFEN.IS", "MGROS.IS", "SOKM.IS", "AEFES.IS",
            "ARCLK.IS", "ALARK.IS", "ASTOR.IS", "BRSAN.IS", "CIMSA.IS",
            "DOAS.IS", "EGEEN.IS", "EKGYO.IS", "ENJSA.IS", "GESAN.IS",
            "KONTR.IS", "ODAS.IS", "ULKER.IS", "VESTL.IS", "GUBRF.IS",
            "AKSEN.IS", "KORDS.IS", "LOGO.IS", "MAVI.IS", "OTKAR.IS",
            // BIST mid-cap
            "AGHOL.IS", "AKFGY.IS", "ALKIM.IS", "AYGAZ.IS", "BIOEN.IS",
            "CCOLA.IS", "ECILC.IS", "EUPWR.IS", "ISMEN.IS", "KLKIM.IS",
            "MPARK.IS", "PARSN.IS", "PENGD.IS", "SELEC.IS", "SKBNK.IS",
            "SMRTG.IS", "TATGD.IS", "TTRAK.IS", "YATAS.IS", "ZOREN.IS",
            "BIZIM.IS", "OYAKC.IS", "ALBRK.IS",
            // BIST — mayıs 2026 tam liste (hisse listesi yeni mayıs2026.txt)
            "A1CAP.IS", "ACSEL.IS", "ADEL.IS", "ADESE.IS", "ADGYO.IS", "AFYON.IS", "AGESA.IS", "AGROT.IS",
            "AHSGY.IS", "AKCNS.IS", "AKENR.IS", "AKFYE.IS", "AKGRT.IS", "AKMGY.IS", "AKSA.IS", "ALCAR.IS",
            "ALCTL.IS", "ALFAS.IS", "ALKA.IS", "ALKLC.IS", "ALTNY.IS", "ALVES.IS", "ANELE.IS", "ANGEN.IS",
            "ANSGR.IS", "ARDYZ.IS", "ARENA.IS", "ARSAN.IS", "ARTMS.IS", "ASGYO.IS", "ASUZU.IS", "ATAKP.IS",
            "ATATP.IS", "AVGYO.IS", "AVHOL.IS", "AVOD.IS", "AVPGY.IS", "AYDEM.IS", "AYEN.IS", "AYES.IS",
            "AZTEK.IS", "BAGFS.IS", "BAHKM.IS", "BAKAB.IS", "BALSU.IS", "BANVT.IS", "BASGZ.IS", "BAYRK.IS",
            "BEGYO.IS", "BERA.IS", "BEYAZ.IS", "BIGCH.IS", "BINBN.IS", "BINHO.IS", "BJKAS.IS", "BLCYT.IS",
            "BNTAS.IS", "BOBET.IS", "BORLS.IS", "BORSK.IS", "BOSSA.IS", "BRISA.IS", "BRKO.IS", "BRKSN.IS",
            "BRMEN.IS", "BRYAT.IS", "BSOKE.IS", "BTCIM.IS", "BUCIM.IS", "BULGS.IS", "BURCE.IS", "BURVA.IS",
            "BVSAN.IS", "CANTE.IS", "CATES.IS", "CELHA.IS", "CEMAS.IS", "CEMTS.IS", "CEMZY.IS", "CLEBI.IS",
            "CMBTN.IS", "CMENT.IS", "CONSE.IS", "COSMO.IS", "CRDFA.IS", "CUSAN.IS", "CVKMD.IS", "CWENE.IS",
            "DAGI.IS", "DAPGM.IS", "DARDL.IS", "DCTTR.IS", "DGATE.IS", "DGGYO.IS", "DGNMO.IS", "DIRIT.IS",
            "DITAS.IS", "DMLKT.IS", "DMSAS.IS", "DOCO.IS", "DOFER.IS", "DOHOL.IS", "DOKTA.IS", "DUNYH.IS",
            "DURKN.IS", "DYOBY.IS", "DZGYO.IS", "EBEBK.IS", "ECZYT.IS", "EDATA.IS", "EDIP.IS", "EGEPO.IS",
            "EGGUB.IS", "EGPRO.IS", "EKIZ.IS", "EKOS.IS", "EKSUN.IS", "ELITE.IS", "EMKEL.IS", "ENDAE.IS",
            "ENSRI.IS", "ENTRA.IS", "ERSU.IS", "ESCOM.IS", "ESEN.IS", "ETILR.IS", "EUREN.IS", "EYGYO.IS",
            "FENER.IS", "FLAP.IS", "FMIZP.IS", "FONET.IS", "FORMT.IS", "FRIGO.IS", "FZLGY.IS", "GARFA.IS",
            "GENIL.IS", "GENTS.IS", "GEREL.IS", "GIPTA.IS", "GLBMD.IS", "GLCVY.IS", "GLRYH.IS", "GLYHO.IS",
            "GMTAS.IS", "GOKNR.IS", "GOODY.IS", "GOZDE.IS", "GRNYO.IS", "GRSEL.IS", "GSDDE.IS", "GSDHO.IS",
            "GSRAY.IS", "GUNDG.IS", "GWIND.IS", "GZNMI.IS", "HATEK.IS", "HEDEF.IS", "HKTM.IS", "HLGYO.IS",
            "HOROZ.IS", "HRKET.IS", "HTTBT.IS", "HUBVC.IS", "HUNER.IS", "HURGZ.IS", "ICBCT.IS", "IDGYO.IS",
            "IEYHO.IS", "IHAAS.IS", "IHEVA.IS", "IHGZT.IS", "IHLAS.IS", "IHLGM.IS", "IHYAY.IS", "IMASM.IS",
            "INDES.IS", "INFO.IS", "INGRM.IS", "INTEM.IS", "ISATR.IS", "ISBTR.IS", "ISDMR.IS", "ISFIN.IS",
            "ISGSY.IS", "ISGYO.IS", "ISKPL.IS", "ISSEN.IS", "ISYAT.IS", "IZENR.IS", "IZFAS.IS", "IZINV.IS",
            "IZMDC.IS", "JANTS.IS", "KAPLM.IS", "KAREL.IS", "KARYE.IS", "KATMR.IS", "KAYSE.IS", "KFEIN.IS",
            "KGYO.IS", "KIMMR.IS", "KLGYO.IS", "KLMSN.IS", "KLRHO.IS", "KLSYN.IS", "KLYPV.IS", "KMPUR.IS",
            "KNFRT.IS", "KOCMT.IS", "KONYA.IS", "KOTON.IS", "KRDMA.IS", "KRDMB.IS", "KRDMD.IS", "KRGYO.IS",
            "KRONT.IS", "KRPLS.IS", "KRSTL.IS", "KRVGD.IS", "KSTUR.IS", "KTSKR.IS", "KUTPO.IS", "KUVVA.IS",
            "LIDER.IS", "LIDFA.IS", "LILAK.IS", "LINK.IS", "LMKDC.IS", "LRSHO.IS", "LUKSK.IS", "LYDHO.IS",
            "MAALT.IS", "MAGEN.IS", "MAKTK.IS", "MANAS.IS", "MARKA.IS", "MARTI.IS", "MEDTR.IS", "MEGAP.IS",
            "MEGMT.IS", "MEPET.IS", "MERCN.IS", "MERKO.IS", "METRO.IS", "METUR.IS", "MIATK.IS", "MMCAS.IS",
            "MNDRS.IS", "MNDTR.IS", "MOBTL.IS", "MOGAN.IS", "MRGYO.IS", "MRSHL.IS", "MSGYO.IS", "MTRKS.IS",
            "MTRYO.IS", "MZHLD.IS", "NIBAS.IS", "NTGAZ.IS", "NTHOL.IS", "NUGYO.IS", "NUHCM.IS", "OBAMS.IS",
            "ODINE.IS", "ONCSM.IS", "ONRYT.IS", "ORCAY.IS", "ORGE.IS", "ORMA.IS", "OYAYO.IS", "OYLUM.IS",
            "OYYAT.IS", "OZATD.IS", "OZGYO.IS", "OZKGY.IS", "OZRDN.IS", "PAGYO.IS", "PAMEL.IS", "PAPIL.IS",
            "PASEU.IS", "PATEK.IS", "PCILT.IS", "PEKGY.IS", "PENTA.IS", "PETUN.IS", "PINSU.IS", "PKART.IS",
            "PKENT.IS", "PNLSN.IS", "PNSUT.IS", "POLHO.IS", "POLTK.IS", "PRDGS.IS", "PRKAB.IS", "PRKME.IS",
            "PRZMA.IS", "PSGYO.IS", "QUAGR.IS", "RALYH.IS", "RAYSG.IS", "REEDR.IS", "RNPOL.IS", "RODRG.IS",
            "RTALB.IS", "RUBNS.IS", "RYGYO.IS", "RYSAS.IS", "SAFKR.IS", "SAMAT.IS", "SANEL.IS", "SANKO.IS",
            "SARKY.IS", "SAYAS.IS", "SDTTR.IS", "SEGMN.IS", "SEKFK.IS", "SEKUR.IS", "SELGD.IS", "SELVA.IS",
            "SILVR.IS", "SKTAS.IS", "SMART.IS", "SNGYO.IS", "SNICA.IS", "SONME.IS", "SRVGY.IS", "SUNTK.IS",
            "SURGY.IS", "TABGD.IS", "TATEN.IS", "TCKRC.IS", "TDGYO.IS", "TEKTU.IS", "TERA.IS", "TGSAS.IS",
            "TKNSA.IS", "TMSN.IS", "TNZTP.IS", "TRALT.IS", "TRCAS.IS", "TRENJ.IS", "TRGYO.IS", "TRILC.IS",
            "TRMET.IS", "TSKB.IS", "TSPOR.IS", "TUCLK.IS", "TUKAS.IS", "TUREX.IS", "TURSG.IS", "UFUK.IS",
            "ULAS.IS", "ULUFA.IS", "ULUSE.IS", "ULUUN.IS", "UMPAS.IS", "USAK.IS", "VAKFN.IS", "VAKKO.IS",
            "VANGD.IS", "VBTYZ.IS", "VERTU.IS", "VERUS.IS", "VESBE.IS", "VKFYO.IS", "VKGYO.IS", "VKING.IS",
            "YAPRK.IS", "YAYLA.IS", "YBTAS.IS", "YEOTK.IS", "YESIL.IS", "YGGYO.IS", "YIGIT.IS", "YKSLN.IS",
            "YONGA.IS", "YUNSA.IS", "YYAPI.IS", "YYLGD.IS", "ZEDUR.IS", "ZRGYO.IS"
        ]
        
        var addedCount = 0
        for symbol in requiredSymbols {
            if !self.items.contains(symbol) {
                self.items.append(symbol)
                addedCount += 1
            }
        }
        
        if addedCount > 0 {
            print("✨ WatchlistStore: Added \(addedCount) new required symbols.")
            saveWatchlist()
        }

        // 2026-04-22: Delisted sembolleri kaldır.
        // Yahoo/borsapy 404 döndüren, artık işlem görmeyen semboller:
        //   KOZAL.IS, KOZAA.IS — halka arz kapandı
        //   ANACM.IS — delisted
        //   KERVT.IS — delisted
        //   MMC — NYSE'de yok (Marsh McLennan şimdi farklı ticker)
        let delisted: Set<String> = ["KOZAL.IS", "KOZAA.IS", "ANACM.IS", "KERVT.IS", "MMC"]
        let beforeCount = self.items.count
        self.items.removeAll { delisted.contains($0) }
        let removed = beforeCount - self.items.count
        if removed > 0 {
            print("🧹 WatchlistStore: Delisted \(removed) sembol temizlendi (KOZAL/KOZAA/ANACM/KERVT/MMC)")
            saveWatchlist()
        }
    }
    
    private func saveWatchlist() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: "watchlist_v2")
        }
    }

    // MARK: - BIST TÜM Universe Sync

    /// BIST TÜM (XUTUM) endeksindeki tüm hisseleri BorsaPy'den çekip listeye ekler.
    /// Zaten varsa dokunmaz (idempotent). Sadece backend erişilebilirken çalışır.
    func refreshBistUniverse() async {
        guard await BorsaPyProvider.shared.isBackendWarm() else { return }
        do {
            // XUTUM (BIST TÜM) 568+ sembol döndürüyor — GIPTA dahil tüm pazarlar.
            let components = try await BorsaPyProvider.shared.getIndexComponents(code: "XUTUM")
            guard !components.isEmpty else { return }
            let withSuffix = components.map { $0.hasSuffix(".IS") ? $0 : "\($0).IS" }
            var added = 0
            for symbol in withSuffix {
                if !items.contains(symbol) {
                    items.append(symbol)
                    added += 1
                }
            }
            if added > 0 {
                print("✨ WatchlistStore: BIST TÜM'den \(added) yeni hisse eklendi (\(items.filter { $0.hasSuffix(".IS") }.count) toplam BIST).")
                saveWatchlist()
            }
        } catch {
            print("⚠️ WatchlistStore: BIST TÜM güncelleme başarısız — \(error.localizedDescription)")
        }
    }
}
