package tr.edu.etu.dealership.panel;

import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;
import tr.edu.etu.dealership.web.ApiHatasi;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.sql.Types;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Randevu uçları (sözleşme §3–5): listeleme, ekleme, durum değişikliği.
 *
 * <p>Kurallar (mesai, tür saat penceresi, çalışan şubesi/departmanı/yetkinliği,
 * çakışma) DB'de: trigger ({@code 220_trg_randevu_dogrula}) ve EXCLUDE
 * kısıtları. Handler bunları tekrar yazmaz, DB hatasını sözleşme koduna çevirir.
 */
public final class RandevuPanelHandler extends PanelHandler {

    static final ZoneId ISTANBUL = ZoneId.of("Europe/Istanbul");
    private static final String TELEFON_DESENI = "^\\+[1-9]\\d{7,14}$";
    private static final Set<String> DURUMLAR = Set.of("PLANLANDI", "TAMAMLANDI", "IPTAL", "GELMEDI");
    private static final String EXCLUSION_VIOLATION = "23P01";
    private static final String TRIGGER_HATASI = "P0001";

    /** Liste ve tekil yanıtın ortak satır biçimi. */
    private static final String SATIR = """
            SELECT r.randevu_id, r.baslangic, r.bitis, r.durum, r.kaynak,
                   r.tur_kodu, rt.ad AS tur_adi, r.sube_id,
                   r.calisan_id, c.ad || ' ' || c.soyad AS calisan,
                   r.musteri_id, nullif(concat_ws(' ', mu.ad, mu.soyad), '') AS musteri,
                   mu.telefon, r.arac_vin, a.plaka, mo.ad AS model_adi, r.notlar
              FROM randevu r
              JOIN randevu_turu rt ON rt.tur_kodu = r.tur_kodu
              JOIN calisan c       ON c.calisan_id = r.calisan_id
              JOIN musteri mu      ON mu.musteri_id = r.musteri_id
              LEFT JOIN arac a     ON a.vin = r.arac_vin
              LEFT JOIN versiyon v ON v.versiyon_id = a.versiyon_id
              LEFT JOIN model mo   ON mo.model_id = v.model_id
            """;

    public RandevuPanelHandler(PanelVeritabani db, Oturumlar oturumlar) {
        super(db, oturumlar);
        rota("GET", "/panel/randevu", Rol.PERSONEL, this::listele);
        rota("POST", "/panel/randevu", Rol.PERSONEL, this::ekle);
    }

    // ---- §3 Listeleme -----------------------------------------------------------

    private Object listele(Istek i) throws Exception {
        i.yalnizca(Set.of("tarih", "sube_id", "tur_kodu", "durum", "calisan_id", "limit", "sayfa"));
        LocalDate tarih = i.tarihParam("tarih");
        if (tarih == null) tarih = LocalDate.now(ISTANBUL);
        Integer subeId = i.sayiParam("sube_id");
        if (subeId == null) subeId = i.oturum().subeId();
        String turKodu = i.metinParam("tur_kodu");
        String durum = i.secimParam("durum", DURUMLAR);
        Integer calisanId = i.sayiParam("calisan_id");
        int limit = i.limit();
        int sayfa = i.sayfa();

        String kosul = """
                 WHERE r.sube_id = ?
                   AND r.baslangic >= ? AND r.baslangic < ?
                   AND (?::varchar IS NULL OR r.tur_kodu = ?)
                   AND (?::varchar IS NULL OR r.durum = ?)
                   AND (?::int IS NULL OR r.calisan_id = ?)
                """;
        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("tarih", tarih.toString());
        veri.put("sube_id", subeId);
        try (PreparedStatement ps = i.conn().prepareStatement(
                "SELECT count(*) FROM randevu r" + kosul)) {
            listeParametreleri(ps, subeId, tarih, turKodu, durum, calisanId);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                veri.put("toplam", rs.getLong(1));
            }
        }
        try (PreparedStatement ps = i.conn().prepareStatement(
                SATIR + kosul + " ORDER BY r.baslangic, r.randevu_id LIMIT ? OFFSET ?")) {
            int n = listeParametreleri(ps, subeId, tarih, turKodu, durum, calisanId);
            ps.setInt(n++, limit);
            ps.setLong(n, (long) (sayfa - 1) * limit);
            veri.put("randevular", Satirlar.liste(ps));
        }
        return veri;
    }

    private static int listeParametreleri(PreparedStatement ps, int subeId, LocalDate tarih,
                                          String turKodu, String durum, Integer calisanId)
            throws SQLException {
        int n = 1;
        ps.setInt(n++, subeId);
        ps.setTimestamp(n++, Timestamp.valueOf(tarih.atStartOfDay()));
        ps.setTimestamp(n++, Timestamp.valueOf(tarih.plusDays(1).atStartOfDay()));
        ps.setString(n++, turKodu);
        ps.setString(n++, turKodu);
        ps.setString(n++, durum);
        ps.setString(n++, durum);
        if (calisanId == null) {
            ps.setNull(n++, Types.INTEGER);
            ps.setNull(n++, Types.INTEGER);
        } else {
            ps.setInt(n++, calisanId);
            ps.setInt(n++, calisanId);
        }
        return n;
    }

    // ---- §4 Ekleme ------------------------------------------------------------------

    private Object ekle(Istek i) throws Exception {
        i.alanlar(Set.of("telefon", "ad", "soyad", "sube_id", "tur_kodu", "calisan_id",
                "arac_vin", "baslangic", "notlar"));
        String telefon = i.zorunluMetin("telefon", 20);
        if (!telefon.matches(TELEFON_DESENI)) {
            throw Istek.gecersiz("telefon E.164 biçiminde olmalı (ör. +905321234567).");
        }
        String ad = i.metin("ad", 64);
        String soyad = i.metin("soyad", 64);
        int subeId = i.zorunluId("sube_id");
        String turKodu = i.zorunluMetin("tur_kodu", 32);
        int calisanId = i.zorunluId("calisan_id");
        String vin = i.metin("arac_vin", 17);
        LocalDateTime baslangic = i.zorunluZaman("baslangic");
        String notlar = i.metin("notlar", 1000);
        Connection c = i.conn();

        if (!baslangic.isAfter(LocalDateTime.now(ISTANBUL))) {
            throw ApiHatasi.goster("GECMIS_TARIH", "Geçmiş bir saate randevu verilemez.", 400, null);
        }
        var sure = tekSayi(c, "SELECT sure_dakika FROM randevu_turu WHERE tur_kodu = ?", turKodu);
        if (sure == null) throw Istek.bulunamadi("Randevu türü");
        boolean aracGerekli = KatalogHandler.ARAC_GEREKEN_TURLER.contains(turKodu);
        if (aracGerekli && vin == null) {
            throw Istek.gecersiz(turKodu + " türünde arac_vin zorunlu.");
        }
        if (!aracGerekli && vin != null) {
            throw Istek.gecersiz(turKodu + " türünde araç seçilmez.");
        }
        if (tekSayi(c, "SELECT 1 FROM sube WHERE sube_id = ?", subeId) == null) {
            throw Istek.bulunamadi("Şube");
        }
        if (tekSayi(c, "SELECT 1 FROM calisan WHERE calisan_id = ?", calisanId) == null) {
            throw Istek.bulunamadi("Çalışan");
        }
        if (vin != null && tekSayi(c, "SELECT 1 FROM arac WHERE vin = ?", vin) == null) {
            throw Istek.bulunamadi("Araç");
        }

        int musteriId = musteriBulVeyaOlustur(c, telefon, ad, soyad);

        int randevuId;
        try (PreparedStatement ps = c.prepareStatement("""
                INSERT INTO randevu (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin,
                                     baslangic, bitis, kaynak, notlar)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'PANEL', ?)
                RETURNING randevu_id""")) {
            ps.setInt(1, musteriId);
            ps.setInt(2, subeId);
            ps.setString(3, turKodu);
            ps.setInt(4, calisanId);
            ps.setString(5, vin);
            ps.setTimestamp(6, Timestamp.valueOf(baslangic));
            ps.setTimestamp(7, Timestamp.valueOf(baslangic.plusMinutes(sure)));
            ps.setString(8, notlar);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                randevuId = rs.getInt(1);
            }
        } catch (SQLException e) {
            throw dbHatasi(e);
        }
        return new Yanit(201, tekRandevu(c, randevuId));
    }

    private static int musteriBulVeyaOlustur(Connection c, String telefon, String ad, String soyad)
            throws SQLException {
        Integer id = tekSayi(c, "SELECT musteri_id FROM musteri WHERE telefon = ?", telefon);
        if (id != null) {
            if (ad != null || soyad != null) {
                try (PreparedStatement ps = c.prepareStatement("""
                        UPDATE musteri SET ad = coalesce(?, ad), soyad = coalesce(?, soyad)
                         WHERE musteri_id = ?""")) {
                    ps.setString(1, ad);
                    ps.setString(2, soyad);
                    ps.setInt(3, id);
                    ps.executeUpdate();
                }
            }
            return id;
        }
        if (ad == null || soyad == null) {
            throw Istek.gecersiz("Yeni müşteri için ad ve soyad zorunlu.");
        }
        try (PreparedStatement ps = c.prepareStatement(
                "INSERT INTO musteri (telefon, ad, soyad) VALUES (?, ?, ?) RETURNING musteri_id")) {
            ps.setString(1, telefon);
            ps.setString(2, ad);
            ps.setString(3, soyad);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                return rs.getInt(1);
            }
        }
    }

    /**
     * DB kural ihlalini sözleşme koduna çevirir. Tanınmayan trigger mesajı da
     * personele gösterilir (Türkçe ve iş kuralıdır); diğer hatalar 500 olur.
     */
    private static RuntimeException dbHatasi(SQLException e) throws SQLException {
        String mesaj = e.getMessage() == null ? "" : e.getMessage();
        if (EXCLUSION_VIOLATION.equals(e.getSQLState())) {
            String sebep = mesaj.contains("calisan_id") ? "CALISAN_DOLU"
                    : mesaj.contains("arac_vin") ? "ARAC_DOLU"
                    : mesaj.contains("musteri_id") ? "MUSTERI_DOLU" : "CAKISMA";
            String metin = switch (sebep) {
                case "CALISAN_DOLU" -> "Çalışanın bu saatte başka bir randevusu var.";
                case "ARAC_DOLU" -> "Araç bu saatte başka bir randevuda.";
                case "MUSTERI_DOLU" -> "Müşterinin bu saatte başka bir randevusu var.";
                default -> "Bu saat dolu.";
            };
            return ApiHatasi.goster("SLOT_DOLU", metin, 409, Map.of("sebep", sebep));
        }
        if (TRIGGER_HATASI.equals(e.getSQLState())) {
            String m = ilkSatir(mesaj);
            if (m.contains("pasif")) return calisanUygunDegil(m, "PASIF");
            if (m.contains("Çalışanın şubesi")) return calisanUygunDegil(m, "BASKA_SUBE");
            if (m.contains("departmanı")) return calisanUygunDegil(m, "DEPARTMAN");
            if (m.contains("yetkinlik")) return calisanUygunDegil(m, "YETKINLIK_YOK");
            if (m.contains("saat aralıklarında")) {
                return ApiHatasi.goster("GECERSIZ_SAAT",
                        "Bu tür için o gün ve saatte randevu verilmiyor.", 400, null);
            }
            if (m.contains("Test sürüşü aracı") || m.contains("Yoldaki aracın")) {
                return ApiHatasi.goster("ARAC_UYGUN_DEGIL", m, 409, null);
            }
            return ApiHatasi.goster("KURAL_IHLALI", m, 409, null);
        }
        throw e;
    }

    private static ApiHatasi calisanUygunDegil(String mesaj, String sebep) {
        return ApiHatasi.goster("CALISAN_UYGUN_DEGIL", mesaj, 409, Map.of("sebep", sebep));
    }

    /** PostgreSQL mesajının ilk satırı ("ERROR: " öneki ve Where/Detail satırları atılır). */
    static String ilkSatir(String mesaj) {
        String m = mesaj.lines().findFirst().orElse("");
        return m.startsWith("ERROR: ") ? m.substring(7) : m;
    }

    // ---- Yardımcılar ------------------------------------------------------------------

    private static Map<String, Object> tekRandevu(Connection c, int id) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(SATIR + " WHERE r.randevu_id = ?")) {
            ps.setInt(1, id);
            List<Map<String, Object>> l = Satirlar.liste(ps);
            return l.get(0);
        }
    }

    static Integer tekSayi(Connection c, String sql, Object param) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setObject(1, param);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getInt(1) : null;
            }
        }
    }
}
