import Foundation

/// Faz 1.B.6: Blob payload'larını `Caches/argus_blobs/` klasöründe dosya
/// olarak saklayan iki katmanlı önbellek.
///
/// **Strateji:** ArgusLedger.writeBlob/readBlob mevcut davranışı (SQLite BLOB
/// payload) korurken, bu servis paralel bir cache katmanı ekler. Yeni yazılan
/// blob'lar HEM DB'ye HEM Caches/'e yazılır; okuma önce Caches'i dener, dosya
/// yoksa DB'ye düşer. iOS düşük disk durumunda Caches'i otomatik temizleyebilir
/// — bu durumda fallback DB devreye girer ve ledger kayıp olmaz.
///
/// **Neden Caches/, Documents/ değil:**
/// - Documents iCloud'a yedeklenir (kullanıcı 5GB blob istemez)
/// - Caches yedeklenmez, sistem gerekirse temizler (graceful)
/// - Blob ledger'ın yeniden inşa edilebilir parçası (DB hash zaten var)
final class BlobCacheService {
    static let shared = BlobCacheService()

    /// Caches/argus_blobs/ tam yolu. İlk çağrıda klasör yoksa oluşturulur.
    private let blobDirectory: URL

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.blobDirectory = cachesDir.appendingPathComponent("argus_blobs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: blobDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Caches/argus_blobs/{hash}.dat — hash dosya adı olduğu için path traversal yok.
    /// SHA-256 hex hash sadece [0-9a-f] içerir, güvenli identifier.
    private func fileURL(forHash hash: String) -> URL {
        blobDirectory.appendingPathComponent("\(hash).dat")
    }

    // MARK: - Public API

    /// Veriyi Caches'e yaz. Aynı hash'le zaten yazılmışsa atla (idempotent).
    /// Hata durumunda sessizce geç — ledger'ın asıl yazımı DB'de.
    @discardableResult
    func writeToCache(hash: String, data: Data) -> Bool {
        let url = fileURL(forHash: hash)
        // Zaten varsa atla — gereksiz write engelle.
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            // iOS Caches yazma hatası nadirdir (disk dolu, izin sorunu).
            // Sessiz fail — DB write zaten yapıldı; cache opsiyonel.
            return false
        }
    }

    /// Cache'ten oku. Dosya yoksa `nil` — caller DB fallback'e düşmeli.
    func readFromCache(hash: String) -> Data? {
        let url = fileURL(forHash: hash)
        return try? Data(contentsOf: url)
    }

    /// Belirli hash'in cache'inde olup olmadığı (read'siz, sadece existence check).
    /// Settings → Veri Defteri ekranı veya migration helper'lar için.
    func existsInCache(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forHash: hash).path)
    }

    /// Tüm Caches/argus_blobs/ klasörünün toplam boyutu (byte). Settings ekranında
    /// "Cache: 12 MB" göstermek için.
    func totalCacheSizeBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: blobDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Tüm cache'i temizle — kullanıcı "Snapshot cache temizle (12 MB)" butonuna
    /// bastığında. DB BLOB payload'ları korunur, sadece Caches dosyaları silinir.
    /// Yeniden okumalarda DB fallback devreye girer.
    @discardableResult
    func clearAll() -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: blobDirectory,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        var deleted = 0
        for url in contents {
            if (try? FileManager.default.removeItem(at: url)) != nil {
                deleted += 1
            }
        }
        return deleted
    }

    /// Cache'teki dosya sayısı. UI sadece bilgi amaçlı.
    func cachedFileCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: blobDirectory,
            includingPropertiesForKeys: nil
        ).count) ?? 0
    }
}
