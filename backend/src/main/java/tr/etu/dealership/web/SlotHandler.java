package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import tr.edu.etu.dealership.db.Veritabani;

import java.sql.Connection;
import java.sql.Date;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * {@code GET /bot/slot} — sözleşme: docs/api/bot-sozlesmesi.md
 *
 * <p>Bir şube, randevu türü ve gün için müsait saat dilimlerini ve her dilimdeki
 * imkanları döner. Dilim yalnızca o saatte uygun ve boş bir çalışan (tür araç
 * gerektiriyorsa ayrıca uygun ve boş bir araç) varsa listeye girer.
 */
public final class SlotHandler extends BotHandler {

    /** Sözleşme: bugünden itibaren en fazla 21 gün ileri. */
    private static final int AZAMI_GUN = 21;

    /**
     * Müsaitlik sorgusu (docs/api/bot-sozlesmesi.md §2, doğrulanmış hali).
     * Parametreler: 1 tarih, 2 tur_kodu, 3 sube_id, 4 arac_vin (NULL olabilir).
     */
    private static final String SLOT_SQL = """
            WITH olası AS (
                SELECT gs AS baslangic,
                       gs + (rt.sure_dakika * interval '1 minute') AS bitis
                  FROM randevu_turu rt
                  JOIN tur_saat ts ON ts.tur_kodu = rt.tur_kodu
                  JOIN mesai    m  ON m.gun = ts.gun
                 CROSS JOIN generate_series(
                       ?::date + ts.baslangic,
                       ?::date + ts.bitis - (rt.sure_dakika * interval '1 minute'),
                       (rt.sure_dakika * interval '1 minute')
                 ) AS gs
                 WHERE rt.tur_kodu = ?
                   AND extract(isodow FROM ?::date) = ts.gun
                   AND m.acilis <= ts.baslangic AND ts.bitis <= m.kapanis
            ),
            tur AS (
                SELECT rt.yetkinlik_id, rt.departman,
                       rt.tur_kodu IN ('TEST_SURUSU', 'TESLIMAT', 'SERVIS_TESLIM') AS arac_gerekli
                  FROM randevu_turu rt
                 WHERE rt.tur_kodu = ?
            ),
            uygun_calisan AS (
                SELECT c.calisan_id
                  FROM calisan c, tur t
                 WHERE c.sube_id = ?
                   AND c.aktif_mi
                   AND c.departman = t.departman
                   AND (t.yetkinlik_id IS NULL OR EXISTS (
                         SELECT 1 FROM calisan_yetkinlik cy
                          WHERE cy.calisan_id = c.calisan_id
                            AND cy.yetkinlik_id = t.yetkinlik_id))
            ),
            uygun_arac AS (
                SELECT a.vin, v.paket_adi, md.ad AS model, a.renk
                  FROM arac a
                  JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                  JOIN model   md ON md.model_id   = v.model_id
                 WHERE a.sube_id = ? AND a.durum = 'STOKTA'
            )
            SELECT o.baslangic::time AS baslangic,
                   o.bitis::time     AS bitis,
                   (SELECT count(*) FROM uygun_calisan uc
                     WHERE NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                                        WHERE d.calisan_id = uc.calisan_id
                                          AND tsrange(d.baslangic, d.bitis)
                                              && tsrange(o.baslangic, o.bitis))) AS musait_calisan_sayisi,
                   CASE WHEN t.arac_gerekli THEN
                     COALESCE((SELECT json_agg(json_build_object(
                                          'vin',   ua.vin,
                                          'model', ua.model,
                                          'paket', ua.paket_adi,
                                          'renk',  ua.renk))
                                 FROM uygun_arac ua
                                WHERE (?::varchar IS NULL OR ua.vin = ?)
                                  AND NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                                                   WHERE d.arac_vin = ua.vin
                                                     AND tsrange(d.baslangic, d.bitis)
                                                         && tsrange(o.baslangic, o.bitis))),
                              '[]'::json)
                   ELSE '[]'::json END AS musait_araclar
              FROM olası o, tur t
             WHERE (SELECT count(*) FROM uygun_calisan uc
                     WHERE NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                                        WHERE d.calisan_id = uc.calisan_id
                                          AND tsrange(d.baslangic, d.bitis)
                                              && tsrange(o.baslangic, o.bitis))) > 0
               AND (NOT t.arac_gerekli OR EXISTS (
                     SELECT 1 FROM uygun_arac ua
                      WHERE (?::varchar IS NULL OR ua.vin = ?)
                        AND NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                                         WHERE d.arac_vin = ua.vin
                                           AND tsrange(d.baslangic, d.bitis)
                                               && tsrange(o.baslangic, o.bitis))))
             ORDER BY o.baslangic
            """;

    private static final String TUR_SAATLERI_SQL = """
            SELECT ts.baslangic, ts.bitis
              FROM tur_saat ts
             WHERE ts.tur_kodu = ?
             GROUP BY ts.baslangic, ts.bitis
             ORDER BY ts.baslangic
            """;

    public SlotHandler(Veritabani db) {
        super(db);
    }

    @Override
    protected Object isle(HttpExchange ex, Connection conn) throws Exception {
        Map<String, String> p = parametreler(ex);

        int subeId = zorunluInt(p, "sube_id");
        String turKodu = zorunluStr(p, "tur_kodu");
        LocalDate tarih = zorunluTarih(p, "tarih");
        String aracVin = bosIseNull(p.get("arac_vin"));

        if (tarih.isBefore(LocalDate.now())) {
            throw ApiHatasi.goster("GECMIS_TARIH",
                    "Geçmiş bir tarih için randevu oluşturulamaz.", 400, null);
        }
        if (tarih.isAfter(LocalDate.now().plusDays(AZAMI_GUN))) {
            throw ApiHatasi.goster("COK_UZAK_TARIH",
                    "En fazla " + AZAMI_GUN + " gün sonrası için randevu alınabilir.", 400, null);
        }

        subeVarMi(conn, subeId);
        turVarMi(conn, turKodu);

        if (aracVin != null) {
            aracUygunMu(conn, subeId, turKodu, aracVin);
        }

        List<Map<String, Object>> slotlar = slotlariGetir(conn, tarih, turKodu, subeId, aracVin);

        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("tarih", tarih.toString());
        veri.put("tur_kodu", turKodu);
        veri.put("bilgi", turBilgisi(conn, turKodu));
        veri.put("slotlar", slotlar);
        return veri;
    }

    // --- doğrulamalar -------------------------------------------------------

    private void subeVarMi(Connection conn, int subeId) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement("SELECT 1 FROM sube WHERE sube_id = ?")) {
            ps.setInt(1, subeId);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw ApiHatasi.goster("SUBE_YOK", "Böyle bir şubemiz bulunmuyor.", 404, null);
                }
            }
        }
    }

    private void turVarMi(Connection conn, String turKodu) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT 1 FROM randevu_turu WHERE tur_kodu = ?")) {
            ps.setString(1, turKodu);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw ApiHatasi.goster("TUR_YOK", "Böyle bir randevu türü bulunmuyor.", 404, null);
                }
            }
        }
    }

    /**
     * VIN verildiyse: test sürüşü/teslimatta araç o şubede STOKTA olmalı;
     * servisten teslimde o aracın açık bir servis kaydı olmalı. Servis girişi
     * ve bakımda araç müşteride olduğundan bu kontrol yapılmaz.
     */
    private void aracUygunMu(Connection conn, int subeId, String turKodu, String vin) throws Exception {
        if (turKodu.equals("SERVIS_TESLIM")) {
            try (PreparedStatement ps = conn.prepareStatement("""
                    SELECT (SELECT count(*) FROM servis_kaydi sk
                              JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id
                              JOIN arac a ON a.vin = r.arac_vin
                             WHERE a.vin = ? AND sk.teslim_randevu_id IS NULL) AS acik
                    """)) {
                ps.setString(1, vin);
                try (ResultSet rs = ps.executeQuery()) {
                    rs.next();
                    if (rs.getInt("acik") == 0) {
                        throw ApiHatasi.goster("ARAC_SERVISTE_DEGIL",
                                "Bu araç için açık bir servis kaydı bulunmuyor.", 404, null);
                    }
                }
            }
            return;
        }

        if (!turKodu.equals("TEST_SURUSU") && !turKodu.equals("TESLIMAT")) {
            return; // servis türlerinde araç müşteridedir; stok kontrolü anlamsız
        }

        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT durum FROM arac WHERE vin = ? AND sube_id = ?")) {
            ps.setString(1, vin);
            ps.setInt(2, subeId);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next() || !"STOKTA".equals(rs.getString("durum"))) {
                    throw ApiHatasi.goster("ARAC_STOKTA_YOK",
                            "Bu araç şu anda bu şubede stokta bulunmuyor.", 404, null);
                }
            }
        }
    }

    // --- sorgular -----------------------------------------------------------

    private List<Map<String, Object>> slotlariGetir(Connection conn, LocalDate tarih,
                                                    String turKodu, int subeId, String aracVin)
            throws Exception {
        List<Map<String, Object>> slotlar = new ArrayList<>();
        try (PreparedStatement ps = conn.prepareStatement(SLOT_SQL)) {
            ps.setString(1, tarih.toString());
            ps.setString(2, tarih.toString());
            ps.setString(3, turKodu);
            ps.setString(4, tarih.toString());
            ps.setString(5, turKodu);
            ps.setInt(6, subeId);
            ps.setInt(7, subeId);
            ps.setString(8, aracVin);
            ps.setString(9, aracVin);
            ps.setString(10, aracVin);
            ps.setString(11, aracVin);

            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    Map<String, Object> slot = new LinkedHashMap<>();
                    slot.put("baslangic", kisaSaat(rs.getString("baslangic")));
                    slot.put("bitis", kisaSaat(rs.getString("bitis")));
                    slot.put("musait_calisan_sayisi", rs.getInt("musait_calisan_sayisi"));
                    slot.put("musait_araclar", JsonYanit.mapper().readValue(
                            rs.getString("musait_araclar"), List.class));
                    slotlar.add(slot);
                }
            }
        }
        return slotlar;
    }

    /** Türün tanımlı saat aralıklarını tek satırlık açıklamaya çevirir (LLM için). */
    private String turBilgisi(Connection conn, String turKodu) throws Exception {
        StringBuilder sb = new StringBuilder();
        try (PreparedStatement ps = conn.prepareStatement(TUR_SAATLERI_SQL)) {
            ps.setString(1, turKodu);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    if (sb.length() > 0) sb.append(", ");
                    sb.append(kisaSaat(rs.getString("baslangic")))
                      .append("-")
                      .append(kisaSaat(rs.getString("bitis")));
                }
            }
        }
        if (sb.length() == 0) {
            return "Bu randevu türü için tanımlı saat aralığı yok.";
        }
        return "Saat aralıkları: " + sb;
    }

    /** {@code 10:00:00} -> {@code 10:00} */
    private static String kisaSaat(String hhmmss) {
        return hhmmss == null ? null : hhmmss.substring(0, 5);
    }

    // --- parametre yardımcıları --------------------------------------------

    private static int zorunluInt(Map<String, String> p, String ad) {
        String v = p.get(ad);
        if (v == null || v.isBlank()) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE", ad + " parametresi zorunlu.", 400, null);
        }
        try {
            return Integer.parseInt(v.trim());
        } catch (NumberFormatException e) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE", ad + " sayısal olmalı.", 400, null);
        }
    }

    private static String zorunluStr(Map<String, String> p, String ad) {
        String v = p.get(ad);
        if (v == null || v.isBlank()) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE", ad + " parametresi zorunlu.", 400, null);
        }
        return v.trim();
    }

    private static LocalDate zorunluTarih(Map<String, String> p, String ad) {
        String v = zorunluStr(p, ad);
        try {
            return LocalDate.parse(v);
        } catch (DateTimeParseException e) {
            throw ApiHatasi.goster("GECERSIZ_TARIH",
                    "Tarih YYYY-AA-GG biçiminde olmalı.", 400, null);
        }
    }

    private static String bosIseNull(String s) {
        return (s == null || s.isBlank()) ? null : s.trim();
    }
}
