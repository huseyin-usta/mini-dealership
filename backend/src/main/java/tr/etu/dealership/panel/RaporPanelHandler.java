package tr.edu.etu.dealership.panel;

import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;
import tr.edu.etu.dealership.web.ApiHatasi;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.sql.Types;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Rapor uçları (sözleşme §11–12). {@code rapor} rolüyle çalışır: bu rol
 * yalnızca maskeli/PII'siz view'ları okuyabilir, ham müşteri tablosuna erişemez.
 * Raporda müşteri adı ve telefonu bu yüzden DB tarafından maskelenmiş gelir.
 */
public final class RaporPanelHandler extends PanelHandler {

    /** Tek raporun kapsayabileceği en uzun aralık. */
    static final int AZAMI_GUN = 366;
    static final int AZAMI_SATIR = 100_000;

    /** Rapor filtresi: tarih aralığı [baslangic, bitis] + isteğe bağlı şube. */
    record Aralik(LocalDate baslangic, LocalDate bitis, Integer subeId) {

        static Aralik oku(Istek i) {
            i.yalnizca(Set.of("baslangic", "bitis", "sube_id"));
            LocalDate b = i.tarihParam("baslangic");
            LocalDate s = i.tarihParam("bitis");
            if (b == null || s == null) throw Istek.gecersiz("baslangic ve bitis zorunlu.");
            if (s.isBefore(b)) throw Istek.gecersiz("bitis, baslangic'tan önce olamaz.");
            if (ChronoUnit.DAYS.between(b, s) >= AZAMI_GUN) {
                throw ApiHatasi.goster("ARALIK_COK_GENIS",
                        "Rapor aralığı en fazla " + AZAMI_GUN + " gün olabilir.", 400, null);
            }
            return new Aralik(b, s, i.sayiParam("sube_id"));
        }

        /** {@code WHERE} parçası: {@code r} takma adlı v_rapor_randevu için 4 parametre. */
        static final String KOSUL =
                " r.baslangic >= ? AND r.baslangic < ?"
                + " AND (?::int IS NULL OR r.sube_id = ?)";

        int bagla(PreparedStatement ps, int n) throws SQLException {
            ps.setTimestamp(n++, Timestamp.valueOf(baslangic.atStartOfDay()));
            ps.setTimestamp(n++, Timestamp.valueOf(bitis.plusDays(1).atStartOfDay()));
            for (int k = 0; k < 2; k++) {
                if (subeId == null) ps.setNull(n++, Types.INTEGER); else ps.setInt(n++, subeId);
            }
            return n;
        }
    }

    public RaporPanelHandler(PanelVeritabani db, Oturumlar oturumlar) {
        super(db, oturumlar);
        rota("GET", "/panel/rapor/ozet", Rol.RAPOR, this::ozetUcu);
        rota("GET", "/panel/rapor/randevu\\.xlsx", Rol.RAPOR, this::excel);
    }

    private Object excel(Istek i) throws Exception {
        Aralik a = Aralik.oku(i);
        String ad = "randevular_" + a.baslangic() + "_" + a.bitis()
                + (a.subeId() == null ? "" : "_sube" + a.subeId()) + ".xlsx";
        return new Dosya(ExcelRaporu.uret(i.conn(), a),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ad);
    }

    private Object ozetUcu(Istek i) throws Exception {
        Aralik a = Aralik.oku(i);
        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("baslangic", a.baslangic().toString());
        veri.put("bitis", a.bitis().toString());
        veri.put("sube_id", a.subeId());
        veri.putAll(ozet(i.conn(), a));
        return veri;
    }

    /** Özet blokları; Excel'in "Özet" sayfası da bunu kullanır. */
    static Map<String, Object> ozet(Connection c, Aralik a) throws SQLException {
        Map<String, Object> veri = new LinkedHashMap<>();
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT count(*)                                         AS toplam,
                       count(*) FILTER (WHERE durum = 'PLANLANDI')      AS planlandi,
                       count(*) FILTER (WHERE durum = 'TAMAMLANDI')     AS tamamlandi,
                       count(*) FILTER (WHERE durum = 'IPTAL')          AS iptal,
                       count(*) FILTER (WHERE durum = 'GELMEDI')        AS gelmedi,
                       round(100.0 * count(*) FILTER (WHERE durum = 'IPTAL')
                             / nullif(count(*), 0), 1)                  AS iptal_yuzde,
                       round(100.0 * count(*) FILTER (WHERE durum = 'GELMEDI')
                             / nullif(count(*) FILTER (WHERE durum IN ('TAMAMLANDI', 'GELMEDI')), 0), 1)
                                                                        AS gelmeme_yuzde
                  FROM v_rapor_randevu r
                 WHERE""" + Aralik.KOSUL)) {
            a.bagla(ps, 1);
            veri.put("ozet", Satirlar.tek(ps).orElseThrow());
        }
        // Şube doluluk sıralaması: iptaller sayılmaz; RANK eşit sayıda aynı sırayı verir.
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT r.sube_id, r.sehir, r.sube_adi,
                       count(*) FILTER (WHERE r.durum <> 'IPTAL')       AS randevu,
                       count(*) FILTER (WHERE r.durum = 'TAMAMLANDI')   AS tamamlanan,
                       rank() OVER (ORDER BY count(*) FILTER (WHERE r.durum <> 'IPTAL') DESC) AS sira
                  FROM v_rapor_randevu r
                 WHERE""" + Aralik.KOSUL + """

                 GROUP BY r.sube_id, r.sehir, r.sube_adi
                 ORDER BY sira, r.sehir, r.sube_adi""")) {
            a.bagla(ps, 1);
            veri.put("sube_doluluk", Satirlar.liste(ps));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT r.tur_kodu, r.tur_adi, r.departman, count(*) AS adet
                  FROM v_rapor_randevu r
                 WHERE""" + Aralik.KOSUL + """

                 GROUP BY r.tur_kodu, r.tur_adi, r.departman
                 ORDER BY adet DESC, r.tur_kodu""")) {
            a.bagla(ps, 1);
            veri.put("tur_dagilimi", Satirlar.liste(ps));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT r.kaynak, count(*) AS adet,
                       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS yuzde
                  FROM v_rapor_randevu r
                 WHERE""" + Aralik.KOSUL + """

                 GROUP BY r.kaynak
                 ORDER BY r.kaynak""")) {
            a.bagla(ps, 1);
            veri.put("kaynak_dagilimi", Satirlar.liste(ps));
        }
        // Test sürüşünden satışa dönüşüm: tamamlanmış test sürüşünden sonraki 60 gün
        // içinde aynı müşteriye aynı modelden teslimat randevusu verildi mi?
        // (rapor rolü stok tablosunu göremez; teslimat randevusu satışın izidir.)
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT r.model_adi,
                       count(*) AS test_surusu,
                       count(*) FILTER (WHERE EXISTS (
                           SELECT 1 FROM v_rapor_randevu t
                            WHERE t.tur_kodu = 'TESLIMAT' AND t.durum <> 'IPTAL'
                              AND t.musteri_id = r.musteri_id
                              AND t.model_adi = r.model_adi
                              AND t.baslangic >= r.baslangic
                              AND t.baslangic < r.baslangic + interval '60 days')) AS satisa_donen
                  FROM v_rapor_randevu r
                 WHERE r.tur_kodu = 'TEST_SURUSU' AND r.durum = 'TAMAMLANDI'
                   AND""" + Aralik.KOSUL + """

                 GROUP BY r.model_adi
                 ORDER BY test_surusu DESC, r.model_adi""")) {
            a.bagla(ps, 1);
            veri.put("test_surusu_donusum", Satirlar.liste(ps));
        }
        return veri;
    }
}
