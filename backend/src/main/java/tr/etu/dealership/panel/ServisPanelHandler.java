package tr.edu.etu.dealership.panel;

import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;
import tr.edu.etu.dealership.web.ApiHatasi;

import java.sql.Connection;
import java.sql.Date;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Types;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Servis kaydı uçları (sözleşme §7–8). Durum geçmişi yalnızca eklenir
 * ({@code personel} rolünde o tabloda UPDATE yok); masraf kuralları
 * {@code 210_trg_servis_garanti} trigger'ında, burada sözleşme koduna çevrilir.
 */
public final class ServisPanelHandler extends PanelHandler {

    private static final Set<String> DURUMLAR = Set.of("INCELENIYOR", "PARCA_BEKLENIYOR",
            "EKSPERTIZ_BEKLENIYOR", "ISLEMDE", "TESLIME_HAZIR", "TAMAMLANDI");
    private static final Set<String> ODEME = Set.of("MUSTERI", "GARANTI", "SIGORTA");

    private static final String SATIR = """
            SELECT sd.servis_kaydi_id, sd.sube_id, sd.arac_vin, a.plaka, mo.ad AS model_adi,
                   sd.musteri_id, nullif(concat_ws(' ', mu.ad, mu.soyad), '') AS musteri,
                   sd.sebep, sd.giris_zamani, sd.giris_kilometresi, sd.son_durum,
                   sd.son_durum_zamani, sd.tahmini_teslim_tarihi, sd.kalan_gun,
                   sd.kapandi_mi, sd.gecikti_mi, sd.toplam_masraf
              FROM v_servis_durumu sd
              JOIN arac a     ON a.vin = sd.arac_vin
              JOIN versiyon v ON v.versiyon_id = a.versiyon_id
              JOIN model mo   ON mo.model_id = v.model_id
              JOIN musteri mu ON mu.musteri_id = sd.musteri_id
            """;

    public ServisPanelHandler(PanelVeritabani db, Oturumlar oturumlar) {
        super(db, oturumlar);
        rota("GET", "/panel/servis", Rol.PERSONEL, this::listele);
        rota("GET", "/panel/servis/(\\d+)", Rol.PERSONEL, this::detayUcu);
        rota("POST", "/panel/servis/(\\d+)/durum", Rol.PERSONEL, this::durumEkle);
        rota("POST", "/panel/servis/(\\d+)/islem", Rol.PERSONEL, this::islemEkle);
    }

    // ---- §7 Listeleme ve detay -----------------------------------------------------

    private Object listele(Istek i) throws Exception {
        i.yalnizca(Set.of("sube_id", "acik", "gecikti", "ara", "limit", "sayfa", "tumu"));
        String ara = i.metinParam("ara");
        if (ara != null) {
            ara = ara.toUpperCase(Locale.ROOT).replace(" ", "");
            if (ara.length() > 17) throw Istek.gecersiz("ara en fazla 17 karakter olabilir.");
        }
        boolean tumu = Boolean.TRUE.equals(i.evetHayirParam("tumu"));
        Integer subeId = i.sayiParam("sube_id");
        if (tumu && subeId != null) {
            throw Istek.gecersiz("sube_id ile tumu birlikte gönderilemez.");
        }
        if (!tumu && subeId == null && ara == null) subeId = i.oturum().subeId();
        Boolean acik = i.evetHayirParam("acik");
        Boolean gecikti = i.evetHayirParam("gecikti");
        int limit = i.limit();
        int sayfa = i.sayfa();

        String kosul = """
                 WHERE (?::int IS NULL OR sd.sube_id = ?)
                   AND (?::boolean IS NULL OR sd.kapandi_mi = NOT ?)
                   AND (?::boolean IS NULL OR sd.gecikti_mi = ?)
                   AND (?::varchar IS NULL
                        OR left(sd.arac_vin, length(?)) = ?
                        OR left(upper(replace(a.plaka, ' ', '')), length(?)) = ?)
                """;
        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("sube_id", subeId);
        try (PreparedStatement ps = i.conn().prepareStatement("""
                SELECT count(*) FROM v_servis_durumu sd JOIN arac a ON a.vin = sd.arac_vin
                """ + kosul)) {
            parametreler(ps, subeId, acik, gecikti, ara);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                veri.put("toplam", rs.getLong(1));
            }
        }
        try (PreparedStatement ps = i.conn().prepareStatement(SATIR + kosul + """
                 ORDER BY sd.kapandi_mi, sd.tahmini_teslim_tarihi NULLS LAST, sd.servis_kaydi_id
                 LIMIT ? OFFSET ?""")) {
            int n = parametreler(ps, subeId, acik, gecikti, ara);
            ps.setInt(n++, limit);
            ps.setLong(n, (long) (sayfa - 1) * limit);
            veri.put("servisler", Satirlar.liste(ps));
        }
        return veri;
    }

    private static int parametreler(PreparedStatement ps, Integer subeId, Boolean acik,
                                    Boolean gecikti, String ara) throws SQLException {
        int n = 1;
        for (int k = 0; k < 2; k++) {
            if (subeId == null) ps.setNull(n++, Types.INTEGER); else ps.setInt(n++, subeId);
        }
        for (int k = 0; k < 2; k++) {
            if (acik == null) ps.setNull(n++, Types.BOOLEAN); else ps.setBoolean(n++, acik);
        }
        for (int k = 0; k < 2; k++) {
            if (gecikti == null) ps.setNull(n++, Types.BOOLEAN); else ps.setBoolean(n++, gecikti);
        }
        for (int k = 0; k < 5; k++) ps.setString(n++, ara);
        return n;
    }

    private Object detayUcu(Istek i) throws Exception {
        i.yalnizca(Set.of());
        return detay(i.conn(), i.yolSayi(1));
    }

    private static Map<String, Object> detay(Connection c, int id) throws SQLException {
        Map<String, Object> veri;
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT sd.*, a.plaka, mo.ad AS model_adi,
                       nullif(concat_ws(' ', mu.ad, mu.soyad), '') AS musteri, mu.telefon,
                       ca.ad || ' ' || ca.soyad AS sorumlu_calisan,
                       sk.sikayet_aciklama, sk.cikis_kilometresi, sk.teslim_randevu_id
                  FROM v_servis_durumu sd
                  JOIN servis_kaydi sk ON sk.servis_kaydi_id = sd.servis_kaydi_id
                  JOIN arac a     ON a.vin = sd.arac_vin
                  JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                  JOIN model mo   ON mo.model_id = v.model_id
                  JOIN musteri mu ON mu.musteri_id = sd.musteri_id
                  JOIN calisan ca ON ca.calisan_id = sd.sorumlu_calisan_id
                 WHERE sd.servis_kaydi_id = ?""")) {
            ps.setInt(1, id);
            veri = new LinkedHashMap<>(Satirlar.tek(ps).orElseThrow(() -> Istek.bulunamadi("Servis kaydı")));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT durum, zaman, aciklama FROM servis_durum_gecmisi
                 WHERE servis_kaydi_id = ? ORDER BY zaman, gecmis_id""")) {
            ps.setInt(1, id);
            veri.put("durum_gecmisi", Satirlar.liste(ps));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT islem_id, islem_adi, ucret, odeme_kaynagi, aciklama FROM servis_islem
                 WHERE servis_kaydi_id = ? ORDER BY islem_id""")) {
            ps.setInt(1, id);
            veri.put("islemler", Satirlar.liste(ps));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT ss.sirket_id, ssi.ad AS sirket, ss.dosya_no, ss.eksper, ss.onaylanan_tutar
                  FROM servis_sigorta ss JOIN sigorta_sirketi ssi ON ssi.sirket_id = ss.sirket_id
                 WHERE ss.servis_kaydi_id = ?""")) {
            ps.setInt(1, id);
            veri.put("sigorta", Satirlar.tek(ps).orElse(null));
        }
        return veri;
    }

    // ---- §8 Güncelleme ----------------------------------------------------------------

    private Object durumEkle(Istek i) throws Exception {
        int id = i.yolSayi(1);
        i.alanlar(Set.of("durum", "aciklama", "tahmini_teslim_tarihi"));
        String durum = i.zorunluMetin("durum", 32);
        if (!DURUMLAR.contains(durum)) throw Istek.gecersiz("durum geçersiz: " + durum);
        String aciklama = i.metin("aciklama", 1000);
        LocalDate tahmin = i.tarihAlani("tahmini_teslim_tarihi");
        if (tahmin != null && tahmin.isBefore(LocalDate.now(RandevuPanelHandler.ISTANBUL))) {
            throw ApiHatasi.goster("GECMIS_TARIH", "Tahmini teslim tarihi geçmişte olamaz.", 400, null);
        }
        Connection c = i.conn();
        acikKaydiKilitle(c, id);
        try (PreparedStatement ps = c.prepareStatement("""
                INSERT INTO servis_durum_gecmisi (servis_kaydi_id, durum, aciklama)
                VALUES (?, ?, ?)""")) {
            ps.setInt(1, id);
            ps.setString(2, durum);
            ps.setString(3, aciklama);
            ps.executeUpdate();
        }
        if (tahmin != null) {
            try (PreparedStatement ps = c.prepareStatement(
                    "UPDATE servis_kaydi SET tahmini_teslim_tarihi = ? WHERE servis_kaydi_id = ?")) {
                ps.setDate(1, Date.valueOf(tahmin));
                ps.setInt(2, id);
                ps.executeUpdate();
            }
        }
        return new Yanit(201, detay(c, id));
    }

    private Object islemEkle(Istek i) throws Exception {
        int id = i.yolSayi(1);
        i.alanlar(Set.of("islem_adi", "ucret", "odeme_kaynagi", "aciklama"));
        String ad = i.zorunluMetin("islem_adi", 128);
        long ucret = i.zorunluSayi("ucret");
        if (ucret < 0) throw Istek.gecersiz("ucret negatif olamaz.");
        String odeme = i.zorunluMetin("odeme_kaynagi", 10);
        if (!ODEME.contains(odeme)) throw Istek.gecersiz("odeme_kaynagi MUSTERI, GARANTI veya SIGORTA olmalı.");
        String aciklama = i.metin("aciklama", 1000);
        Connection c = i.conn();
        acikKaydiKilitle(c, id);
        try (PreparedStatement ps = c.prepareStatement("""
                INSERT INTO servis_islem (servis_kaydi_id, islem_adi, ucret, odeme_kaynagi, aciklama)
                VALUES (?, ?, ?, ?, ?)""")) {
            ps.setInt(1, id);
            ps.setString(2, ad);
            ps.setLong(3, ucret);
            ps.setString(4, odeme);
            ps.setString(5, aciklama);
            ps.executeUpdate();
        } catch (SQLException e) {
            throw masrafHatasi(e);
        }
        return new Yanit(201, detay(c, id));
    }

    /**
     * Kaydı kilitler; yoksa 404, kapanmışsa 409. Kapanma: teslim randevusu bağlı
     * ya da son durum TAMAMLANDI ({@code v_servis_durumu.kapandi_mi} ile aynı tanım).
     */
    private static void acikKaydiKilitle(Connection c, int id) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT 1 FROM servis_kaydi WHERE servis_kaydi_id = ? FOR UPDATE")) {
            ps.setInt(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) throw Istek.bulunamadi("Servis kaydı");
            }
        }
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT kapandi_mi FROM v_servis_durumu WHERE servis_kaydi_id = ?")) {
            ps.setInt(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next() && rs.getBoolean(1)) {
                    throw ApiHatasi.goster("KAPALI_KAYIT",
                            "Kapanmış servis kaydına durum veya işlem eklenemez.", 409, null);
                }
            }
        }
    }

    private static RuntimeException masrafHatasi(SQLException e) throws SQLException {
        if (!"P0001".equals(e.getSQLState())) throw e;
        String m = RandevuPanelHandler.ilkSatir(e.getMessage() == null ? "" : e.getMessage());
        if (m.contains("masraflarını yalnızca")) {
            return ApiHatasi.goster("ODEME_KAYNAGI_GECERSIZ", m, 409, null);
        }
        String sebep = m.contains("Satış kaydı bulunmayan") ? "SATIS_YOK"
                : m.contains("kilometresini aşmıştır") ? "KM_ASILDI"
                : m.contains("süresini doldurmuştur") ? "SURE_DOLDU"
                : m.contains("aksatıl") ? "BAKIM_AKSATILDI" : null;
        if (sebep != null) {
            return ApiHatasi.goster("GARANTI_GECERSIZ", m, 409, Map.of("sebep", sebep));
        }
        return ApiHatasi.goster("KURAL_IHLALI", m, 409, null);
    }
}
