package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import tr.edu.etu.dealership.db.Veritabani;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;

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
     * İş kuralları Türkiye saatine göredir. Sunucu UTC'de çalışsa bile "bugün"
     * İstanbul'a göre hesaplanır; aksi halde 21:00-00:00 arasında bir gün geri
     * kayma olur ve geçerli tarih yanlışlıkla geçmiş sayılır.
     */
    private static final ZoneId BOLGE = ZoneId.of("Europe/Istanbul");

    /**
     * Araç gerektiren türler — tek kaynak: {@code db/150_randevu.sql} CHECK kısıtı
     * ve aynı araç için EXCLUDE kuralı. Beş tür de araç kaynağını tüketir:
     * test sürüşü, yeni araç teslimi, servisten teslim, periyodik bakım,
     * servise giriş. Araç inceleme ve satın alım araç istemez.
     */
    private static final String ARAC_GEREKEN_TURLER =
            "'TEST_SURUSU','TESLIMAT','SERVIS_TESLIM','PERIYODIK_BAKIM','SERVIS_GIRIS'";

    /**
     * Müsaitlik sorgusu (docs/api/bot-sozlesmesi.md §2, doğrulanmış hali).
     *
     * <p>Parametre sırası:
     * <ol>
     *   <li>tarih, tarih, tur_kodu, tarih — olası dilimler</li>
     *   <li>tur_kodu — türün kuralları</li>
     *   <li>sube_id, tarih, tarih — uygun çalışanlar (şube + yetkinlik geçerliliği)</li>
     *   <li>sube_id — test sürüşü aracı</li>
     *   <li>sube_id — yeni araç teslimi</li>
     *   <li>sube_id — servisten teslim</li>
     *   <li>arac_vin ×4 — araç filtresi</li>
     * </ol>
     */
    private static final String SLOT_SQL = """
            WITH olası_ham AS (
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
            -- Aynı tür için örtüşen saat pencereleri tanımlanabilir; her dilim
            -- bir kez listelenir.
            olası AS (
                SELECT DISTINCT baslangic, bitis FROM olası_ham
            ),
            tur AS (
                SELECT rt.tur_kodu, rt.yetkinlik_id, rt.departman,
                       rt.tur_kodu IN (""" + ARAC_GEREKEN_TURLER + """
                       ) AS arac_gerekli
                  FROM randevu_turu rt
                 WHERE rt.tur_kodu = ?
            ),
            uygun_calisan AS (
                -- Yetkinliğin randevu günü geçerli olması şart: trigger aynı kuralı
                -- uygular (bitiş günü dahil), slot üretimi ondan ayrışmamalı.
                SELECT c.calisan_id
                  FROM calisan c, tur t
                 WHERE c.sube_id = ?
                   AND c.aktif_mi
                   AND c.departman = t.departman
                   AND (t.yetkinlik_id IS NULL OR EXISTS (
                         SELECT 1 FROM calisan_yetkinlik cy
                          WHERE cy.calisan_id = c.calisan_id
                            AND cy.yetkinlik_id = t.yetkinlik_id
                            AND cy.verilis_tarihi <= ?::date
                            AND (cy.bitis_tarihi IS NULL OR cy.bitis_tarihi >= ?::date)))
            ),
            uygun_arac AS (
                -- Test sürüşü: şubede stokta olan araç
                SELECT a.vin, v.paket_adi, md.ad AS model, a.renk
                  FROM arac a
                  JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                  JOIN model   md ON md.model_id   = v.model_id
                 WHERE (SELECT tur_kodu FROM tur) = 'TEST_SURUSU'
                   AND a.sube_id = ?
                   AND a.durum = 'STOKTA'
                UNION ALL
                -- Yeni araç teslimi: müşterinin kendi satılmış aracı. Yoldaki
                -- araçların sahibi yoktur (bkz. db/110_arac.sql CHECK), bu yüzden
                -- "müşterinin yoldaki aracı" diye bir kavram yoktur.
                SELECT a.vin, v.paket_adi, md.ad AS model, a.renk
                  FROM arac a
                  JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                  JOIN model   md ON md.model_id   = v.model_id
                 WHERE (SELECT tur_kodu FROM tur) = 'TESLIMAT'
                   AND a.sube_id = ?
                   AND a.durum = 'SATILDI'
                   AND a.musteri_id = fn_aktif_musteri_id()
                UNION ALL
                -- Servisten teslim: bu şubede açık ve TESLİME HAZIR kaydı olan araç.
                -- DISTINCT: aynı araç için birden çok açık kayıt olabilir.
                SELECT DISTINCT a.vin, v.paket_adi, md.ad AS model, a.renk
                  FROM arac a
                  JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                  JOIN model   md ON md.model_id   = v.model_id
                  JOIN v_musteri_servis_durumu msd ON msd.arac_vin = a.vin
                 WHERE (SELECT tur_kodu FROM tur) = 'SERVIS_TESLIM'
                   AND msd.kapandi_mi = false
                   AND msd.son_durum = 'TESLIME_HAZIR'
                   AND msd.sube_id = ?
                UNION ALL
                -- Periyodik bakım / servise giriş: müşterinin kendi aracı.
                -- Şube serbest (araç ağ içinde herhangi bir şubeye gelebilir);
                -- EXCLUDE kısıtı aynı aracın aynı anda iki randevuda olmasını
                -- zaten engeller, slot üretimi de onu hesaba katar.
                SELECT a.vin, v.paket_adi, md.ad AS model, a.renk
                  FROM arac a
                  JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                  JOIN model   md ON md.model_id   = v.model_id
                 WHERE (SELECT tur_kodu FROM tur) IN ('PERIYODIK_BAKIM', 'SERVIS_GIRIS')
                   AND a.durum = 'SATILDI'
                   AND a.musteri_id = fn_aktif_musteri_id()
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
                                          'renk',  ua.renk) ORDER BY ua.vin)
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
            SELECT ts.gun, ts.baslangic, ts.bitis
              FROM tur_saat ts
             WHERE ts.tur_kodu = ?
             ORDER BY ts.gun, ts.baslangic
            """;

    private static final String TUR_ADI_SQL =
            "SELECT ad FROM randevu_turu WHERE tur_kodu = ?";

    private static final Map<Integer, String> GUN_ADLARI = Map.of(
            1, "Pazartesi", 2, "Salı", 3, "Çarşamba", 4, "Perşembe",
            5, "Cuma", 6, "Cumartesi", 7, "Pazar");

    public SlotHandler(Veritabani db, BotTokeni token) {
        super(db, token);
    }

    @Override
    protected Object isle(HttpExchange ex, Connection conn) throws Exception {
        Map<String, String> p = parametreler(ex);

        int subeId = zorunluInt(p, "sube_id");
        String turKodu = zorunluStr(p, "tur_kodu");
        LocalDate tarih = zorunluTarih(p, "tarih");
        String aracVin = bosIseNull(p.get("arac_vin"));

        LocalDate bugun = LocalDate.now(BOLGE);
        if (tarih.isBefore(bugun)) {
            throw ApiHatasi.goster("GECMIS_TARIH",
                    "Geçmiş bir tarih için randevu alınamaz.", 400, null);
        }
        if (tarih.isAfter(bugun.plusDays(AZAMI_GUN))) {
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
     * VIN verildiyse aracın bu randevu için uygun olduğunu doğrular.
     *
     * <ul>
     *   <li>Test sürüşü: şubede STOKTA</li>
     *   <li>Yeni araç teslimi: müşterinin kendi satılmış aracı, o şubede</li>
     *   <li>Servisten teslim: açık ve teslime hazır servis kaydı, o şubede</li>
     *   <li>Periyodik bakım / servise giriş: müşterinin kendi aracı</li>
     *   <li>Araç inceleme / satın alım: araç istemez; VIN verilmesi 400</li>
     * </ul>
     */
    private void aracUygunMu(Connection conn, int subeId, String turKodu, String vin)
            throws Exception {
        if (turKodu.equals("SERVIS_TESLIM")) {
            // v_musteri_servis_durumu: yalnızca konuşulan müşterinin kayıtları
            // (oturum değişkeni ile süzülür), masraf ve çalışan bilgisi yok.
            // Aynı araç için birden çok açık kayıt olsa bile "herhangi biri
            // teslime hazırsa" teslim edilebilir; en yeni kaydı seçmeye çalışmak
            // eski bir kaydı gizleyerek yanlış sonuç verirdi.
            try (PreparedStatement ps = conn.prepareStatement("""
                    SELECT count(*)                                   AS acik_kayit,
                           coalesce(bool_or(son_durum = 'TESLIME_HAZIR'), false) AS hazir,
                           max(tahmini_teslim_tarihi) FILTER (WHERE son_durum <> 'TESLIME_HAZIR')
                                                                      AS tahmini,
                           coalesce((array_agg(son_durum ORDER BY son_durum_zamani DESC))[1],
                                    'BILINMIYOR')                     AS son_durum
                      FROM v_musteri_servis_durumu
                     WHERE arac_vin = ? AND kapandi_mi = false AND sube_id = ?
                    """)) {
                ps.setString(1, vin);
                ps.setInt(2, subeId);
                try (ResultSet rs = ps.executeQuery()) {
                    rs.next();
                    if (rs.getInt("acik_kayit") == 0) {
                        throw ApiHatasi.goster("ARAC_SERVISTE_DEGIL",
                                "Bu araç için açık bir servis kaydı bulunmuyor.", 404, null);
                    }
                    if (!rs.getBoolean("hazir")) {
                        String sonDurum = rs.getString("son_durum");
                        Map<String, Object> detay = new LinkedHashMap<>();
                        detay.put("son_durum", sonDurum);
                        detay.put("tahmini_teslim_tarihi",
                                rs.getDate("tahmini") == null ? null : rs.getDate("tahmini").toString());
                        throw ApiHatasi.goster("SERVIS_TESLIM_HAZIR_DEGIL",
                                "Aracınız serviste; mevcut durumu: " + durumAdi(sonDurum) + ".",
                                409, detay);
                    }
                }
            }
            return;
        }

        if (turKodu.equals("TEST_SURUSU")) {
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
            return;
        }

        if (turKodu.equals("TESLIMAT")) {
            // Teslim edilen araç müşterinin kendi satılmış aracı ve o şubede olmalı.
            try (PreparedStatement ps = conn.prepareStatement("""
                    SELECT 1 FROM arac
                     WHERE vin = ? AND sube_id = ?
                       AND durum = 'SATILDI'
                       AND musteri_id = fn_aktif_musteri_id()
                    """)) {
                ps.setString(1, vin);
                ps.setInt(2, subeId);
                try (ResultSet rs = ps.executeQuery()) {
                    if (!rs.next()) {
                        throw ApiHatasi.goster("ARAC_STOKTA_YOK",
                                "Bu araç bu şubede teslim edilebilir durumda değil.", 404, null);
                    }
                }
            }
            return;
        }

        if (turKodu.equals("PERIYODIK_BAKIM") || turKodu.equals("SERVIS_GIRIS")) {
            // Araç müşterinin kendi aracı olmalı; şube serbest (ağ içi servis).
            try (PreparedStatement ps = conn.prepareStatement("""
                    SELECT 1 FROM arac
                     WHERE vin = ? AND durum = 'SATILDI'
                       AND musteri_id = fn_aktif_musteri_id()
                    """)) {
                ps.setString(1, vin);
                try (ResultSet rs = ps.executeQuery()) {
                    if (!rs.next()) {
                        throw ApiHatasi.goster("ARAC_YOK",
                                "Bu araç müşterinin kayıtlı araçları arasında bulunmuyor.",
                                404, null);
                    }
                }
            }
            return;
        }

        // Araç inceleme ve satın alım araç istemez.
        throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                "Bu randevu türünde arac_vin kullanılamaz.", 400, null);
    }

    // --- sorgular -----------------------------------------------------------

    private List<Map<String, Object>> slotlariGetir(Connection conn, LocalDate tarih,
                                                    String turKodu, int subeId, String aracVin)
            throws Exception {
        List<Map<String, Object>> slotlar = new ArrayList<>();
        try (PreparedStatement ps = conn.prepareStatement(SLOT_SQL)) {
            String t = tarih.toString();
            int i = 1;
            ps.setString(i++, t);            // olası: başlangıç
            ps.setString(i++, t);            // olası: bitiş
            ps.setString(i++, turKodu);      // olası: tür
            ps.setString(i++, t);            // olası: isodow
            ps.setString(i++, turKodu);      // tur: tür kuralları
            ps.setInt(i++, subeId);          // uygun çalışan: şube
            ps.setString(i++, t);            // yetkinlik: veriliş <= gün
            ps.setString(i++, t);            // yetkinlik: bitiş >= gün
            ps.setInt(i++, subeId);          // test sürüşü aracı: şube
            ps.setInt(i++, subeId);          // teslimat aracı: şube
            ps.setInt(i++, subeId);          // servisten teslim: kaydın şubesi
            ps.setString(i++, aracVin);      // araç filtresi (agg)
            ps.setString(i++, aracVin);
            ps.setString(i++, aracVin);      // araç filtresi (where)
            ps.setString(i++, aracVin);

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

    /**
     * Türün adını ve tanımlı saat aralıklarını LLM'in doğrudan kullanabileceği
     * tek satıra çevirir. Gün kapsamı her zaman yazılır: tür yalnız Cumartesi
     * tanımlıysa "her gün açık" sanılmamalı.
     */
    private String turBilgisi(Connection conn, String turKodu) throws Exception {
        String turAdi = turKodu;
        try (PreparedStatement ps = conn.prepareStatement(TUR_ADI_SQL)) {
            ps.setString(1, turKodu);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) turAdi = rs.getString("ad");
            }
        }

        Map<Integer, String> guneGore = new TreeMap<>();
        try (PreparedStatement ps = conn.prepareStatement(TUR_SAATLERI_SQL)) {
            ps.setString(1, turKodu);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    int gun = rs.getInt("gun");
                    String aralik = kisaSaat(rs.getString("baslangic"))
                            + "-" + kisaSaat(rs.getString("bitis"));
                    guneGore.merge(gun, aralik, (a, b) -> a + ", " + b);
                }
            }
        }

        if (guneGore.isEmpty()) {
            return turAdi + " için tanımlı saat aralığı yok.";
        }

        List<Integer> gunler = new ArrayList<>(guneGore.keySet());
        String ilk = guneGore.values().iterator().next();
        boolean ayniPencere = guneGore.values().stream().allMatch(ilk::equals);
        boolean ardisik = true;
        for (int k = 1; k < gunler.size(); k++) {
            if (gunler.get(k) != gunler.get(k - 1) + 1) {
                ardisik = false;
                break;
            }
        }

        if (ayniPencere && ardisik) {
            String kapsam = gunler.size() == 1
                    ? GUN_ADLARI.get(gunler.get(0))
                    : GUN_ADLARI.get(gunler.get(0)) + "-"
                      + GUN_ADLARI.get(gunler.get(gunler.size() - 1));
            return turAdi + ": " + kapsam + " " + ilk;
        }

        StringBuilder sb = new StringBuilder(turAdi).append(": ");
        boolean ilkGun = true;
        for (Map.Entry<Integer, String> e : guneGore.entrySet()) {
            if (!ilkGun) sb.append("; ");
            sb.append(GUN_ADLARI.getOrDefault(e.getKey(), "?")).append(" ").append(e.getValue());
            ilkGun = false;
        }
        return sb.toString();
    }

    /** {@code 10:00:00} -> {@code 10:00} */
    private static String kisaSaat(String hhmmss) {
        return hhmmss == null ? null : hhmmss.substring(0, 5);
    }

    /** Servis durum kodunu müşterinin anlayacağı Türkçe metne çevirir. */
    private static String durumAdi(String kod) {
        if (kod == null) return "Bilinmiyor";
        return switch (kod) {
            case "INCELENIYOR"       -> "İnceleniyor";
            case "PARCA_BEKLENIYOR"  -> "Parça bekleniyor";
            case "EKSPERTIZ_BEKLENIYOR" -> "Ekspertiz raporu bekleniyor";
            case "ISLEMDE"           -> "İşlem yapılıyor";
            case "TESLIME_HAZIR"     -> "Teslime hazır";
            case "TAMAMLANDI"        -> "Tamamlandı";
            default                  -> kod;
        };
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

    /**
     * VIN'ler veritabanında büyük harftir; köprüden küçük harf gelirse sessizce
     * "araç yok" demek yerine normalize edilir.
     */
    private static String bosIseNull(String s) {
        return (s == null || s.isBlank()) ? null : s.trim().toUpperCase(Locale.ROOT);
    }
}
