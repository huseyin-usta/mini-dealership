package tr.edu.etu.dealership.panel;

import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Types;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Araç uçları (sözleşme §6): listeleme/arama ve araç detayı (özellikler,
 * garanti durumu, stok hareketleri, servis geçmişi).
 */
public final class AracPanelHandler extends PanelHandler {

    private static final Set<String> DURUMLAR = Set.of("STOKTA", "YOLDA", "SATILDI");

    private static final String SATIR = """
            SELECT a.vin, a.plaka, mo.model_id, mo.ad AS model_adi, v.paket_adi, v.model_yili,
                   a.renk, a.durum, a.tahmini_varis_tarihi, a.sube_id, s.ad AS sube_adi,
                   v.liste_fiyati
              FROM arac a
              JOIN versiyon v ON v.versiyon_id = a.versiyon_id
              JOIN model mo   ON mo.model_id = v.model_id
              JOIN sube s     ON s.sube_id = a.sube_id
            """;

    public AracPanelHandler(PanelVeritabani db, Oturumlar oturumlar) {
        super(db, oturumlar);
        rota("GET", "/panel/arac", Rol.PERSONEL, this::listele);
        rota("GET", "/panel/arac/([A-Za-z0-9]{17})", Rol.PERSONEL, this::detay);
    }

    /**
     * {@code ara} verilip {@code sube_id} verilmezse tüm şubelerde aranır: VIN/plaka
     * ile gelen müşterinin aracı başka şubede olabilir. Aksi halde varsayılan
     * oturumdaki şubedir.
     */
    private Object listele(Istek i) throws Exception {
        i.yalnizca(Set.of("sube_id", "durum", "ara", "model_id", "limit", "sayfa", "tumu"));
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
        String durum = i.secimParam("durum", DURUMLAR);
        Integer modelId = i.sayiParam("model_id");
        int limit = i.limit();
        int sayfa = i.sayfa();

        // Önek eşleşmesi LIKE yerine left() ile: kullanıcı girdisindeki % ve _ joker olmasın.
        String kosul = """
                 WHERE (?::int IS NULL OR a.sube_id = ?)
                   AND (?::varchar IS NULL OR a.durum = ?)
                   AND (?::int IS NULL OR v.model_id = ?)
                   AND (?::varchar IS NULL
                        OR left(a.vin, length(?)) = ?
                        OR left(upper(replace(a.plaka, ' ', '')), length(?)) = ?)
                """;
        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("sube_id", subeId);
        try (PreparedStatement ps = i.conn().prepareStatement("""
                SELECT count(*) FROM arac a JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                """ + kosul)) {
            parametreler(ps, subeId, durum, modelId, ara);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                veri.put("toplam", rs.getLong(1));
            }
        }
        try (PreparedStatement ps = i.conn().prepareStatement(
                SATIR + kosul + " ORDER BY mo.ad, v.paket_adi, a.vin LIMIT ? OFFSET ?")) {
            int n = parametreler(ps, subeId, durum, modelId, ara);
            ps.setInt(n++, limit);
            ps.setLong(n, (long) (sayfa - 1) * limit);
            veri.put("araclar", Satirlar.liste(ps));
        }
        return veri;
    }

    private static int parametreler(PreparedStatement ps, Integer subeId, String durum,
                                    Integer modelId, String ara) throws SQLException {
        int n = 1;
        for (int k = 0; k < 2; k++) {
            if (subeId == null) ps.setNull(n++, Types.INTEGER); else ps.setInt(n++, subeId);
        }
        ps.setString(n++, durum);
        ps.setString(n++, durum);
        for (int k = 0; k < 2; k++) {
            if (modelId == null) ps.setNull(n++, Types.INTEGER); else ps.setInt(n++, modelId);
        }
        for (int k = 0; k < 5; k++) ps.setString(n++, ara);
        return n;
    }

    private Object detay(Istek i) throws Exception {
        i.yalnizca(Set.of());
        String vin = i.yolMetin(1).toUpperCase(Locale.ROOT);
        Connection c = i.conn();
        Map<String, Object> arac;
        try (PreparedStatement ps = c.prepareStatement(SATIR + " WHERE a.vin = ?")) {
            ps.setString(1, vin);
            arac = Satirlar.tek(ps).orElseThrow(() -> Istek.bulunamadi("Araç"));
        }
        Map<String, Object> veri = new LinkedHashMap<>(arac);
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT mu.musteri_id, nullif(concat_ws(' ', mu.ad, mu.soyad), '') AS ad_soyad,
                       mu.telefon
                  FROM arac a JOIN musteri mu ON mu.musteri_id = a.musteri_id
                 WHERE a.vin = ?""")) {
            ps.setString(1, vin);
            veri.put("sahip", Satirlar.tek(ps).orElse(null));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT o.ozellik_adi, o.deger
                  FROM arac a JOIN versiyon_ozellik o ON o.versiyon_id = a.versiyon_id
                 WHERE a.vin = ? ORDER BY o.ozellik_adi""")) {
            ps.setString(1, vin);
            veri.put("ozellikler", Satirlar.liste(ps));
        }
        // Garanti yalnızca satılmış araçta anlamlıdır (başlangıç = ilk SATIS hareketi).
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT garanti_durumu, garanti_baslangic, garanti_bitis, garanti_km,
                       son_bilinen_km, son_bakim_tarihi, sonraki_bakim_son_tarih,
                       sonraki_bakim_son_km
                  FROM v_arac_garanti_durumu
                 WHERE vin = ? AND garanti_baslangic IS NOT NULL""")) {
            ps.setString(1, vin);
            veri.put("garanti", Satirlar.tek(ps).orElse(null));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT sh.hareket_turu, sh.zaman, ks.ad AS kaynak_sube, hs.ad AS hedef_sube
                  FROM stok_hareketi sh
                  LEFT JOIN sube ks ON ks.sube_id = sh.kaynak_sube_id
                  LEFT JOIN sube hs ON hs.sube_id = sh.hedef_sube_id
                 WHERE sh.arac_vin = ?
                 ORDER BY sh.zaman, sh.hareket_id""")) {
            ps.setString(1, vin);
            veri.put("stok_hareketleri", Satirlar.liste(ps));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT servis_kaydi_id, sebep, giris_zamani, giris_kilometresi, son_durum,
                       kapandi_mi, gecikti_mi, toplam_masraf
                  FROM v_servis_durumu
                 WHERE arac_vin = ?
                 ORDER BY giris_zamani DESC""")) {
            ps.setString(1, vin);
            veri.put("servis_kayitlari", Satirlar.liste(ps));
        }
        return veri;
    }
}
