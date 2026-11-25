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
    }

    // ---- §7 Listeleme ve detay -----------------------------------------------------

    private Object listele(Istek i) throws Exception {
        i.yalnizca(Set.of("sube_id", "acik", "gecikti", "ara", "limit", "sayfa"));
        String ara = i.metinParam("ara");
        if (ara != null) {
            ara = ara.toUpperCase(Locale.ROOT).replace(" ", "");
            if (ara.length() > 17) throw Istek.gecersiz("ara en fazla 17 karakter olabilir.");
        }
        Integer subeId = i.sayiParam("sube_id");
        if (subeId == null && ara == null) subeId = i.oturum().subeId();
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


}
