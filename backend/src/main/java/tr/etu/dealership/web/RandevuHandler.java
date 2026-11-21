package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import tr.edu.etu.dealership.db.MusteriDeposu;
import tr.edu.etu.dealership.db.Veritabani;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * {@code POST /bot/randevu} — sözleşme: docs/api/bot-sozlesmesi.md §4
 *
 * <p>Randevuyu WhatsApp üzerinden oluşturur. Çalışanı ve aracı sistem atar:
 * <ul>
 *   <li><b>Çalışan:</b> uygun + o saatte boş olanlar arasında son 7 günün
 *       randevu sayısı en az olan (haftalık yük dengeleme); eşitlikte
 *       {@code calisan_id} küçük olan seçilir (deterministik).</li>
 *   <li><b>Araç:</b> türün izin verdiği kümeden, o saatte boş olan ilk araç.
 *       {@code model} verilirse o modelle sınırlanır.</li>
 * </ul>
 *
 * <p>Çakışma kilitle önlenmez: son sözü {@code randevu} tablosundaki EXCLUDE
 * kısıtları söyler. Aynı saniyede gelen iki istekten biri 23P01 alır ve
 * {@code 409 SLOT_DOLU} döner — 500 değil.
 */
public final class RandevuHandler extends BotHandler {

    private static final int AZAMI_GUN = 21;
    private static final ZoneId BOLGE = ZoneId.of("Europe/Istanbul");

    /** PostgreSQL exclusion_violation; EXCLUDE kısıtı çakışmayı bildirir. */
    private static final String EXCLUSION_VIOLATION = "23P01";

    private static final String ARAC_GEREKEN_TURLER =
            "'TEST_SURUSU','TESLIMAT','SERVIS_TESLIM','PERIYODIK_BAKIM','SERVIS_GIRIS'";

    private static final String TUR_SQL = """
            SELECT rt.sure_dakika,
                   rt.tur_kodu IN (""" + ARAC_GEREKEN_TURLER + """
                   ) AS arac_gerekli
              FROM randevu_turu rt
             WHERE rt.tur_kodu = ?
            """;

    private static final String SUBE_SQL =
            "SELECT sehir, ad FROM sube WHERE sube_id = ?";

    /** Zaman penceresi kontrolü — trigger'ın kuralının aynısı (bitiş dahil). */
    private static final String SAAT_UYGUN_SQL = """
            SELECT 1
              FROM tur_saat ts
             WHERE ts.tur_kodu = ?
               AND ts.gun = ?
               AND ts.baslangic <= ?::time
               AND ts.bitis     >= ?::time
             LIMIT 1
            """;

    /**
     * Çalışan seçimi: uygun + boş + son 7 günde en az randevusu olan.
     * Sayaç {@code v_dolu_slot}'tan okunur: bot {@code randevu} tablosunda
     * başkalarının satırlarını göremez (RLS), bu view PII'siz zaman/kaynak verir.
     */
    private static final String CALISAN_SEC_SQL = """
            WITH tur AS (
                SELECT yetkinlik_id, departman
                  FROM randevu_turu WHERE tur_kodu = ?
            )
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
               AND NOT EXISTS (
                     SELECT 1 FROM v_dolu_slot d
                      WHERE d.calisan_id = c.calisan_id
                        AND tsrange(d.baslangic, d.bitis) && tsrange(?::timestamp, ?::timestamp))
             ORDER BY (SELECT count(*)
                         FROM v_dolu_slot d2
                        WHERE d2.calisan_id = c.calisan_id
                          AND d2.baslangic >= (now() AT TIME ZONE 'Europe/Istanbul')::date
                                              - interval '6 day'
                          AND d2.baslangic <  (now() AT TIME ZONE 'Europe/Istanbul')::date
                                              + interval '1 day') ASC,
                      c.calisan_id ASC
             LIMIT 1
            """;

    /**
     * Aracın türe göre aday kümesi (slot sorgusuyla aynı kurallar). Model
     * filtresi ve doluluk kontrolü Java tarafında yapılır; böylece "model yok,
     * şunlar var" yanıtı için müsait modeller de aynı taramadan toplanır.
     */
    private static final String ARAC_ADAY_SQL = """
            WITH tur AS (
                SELECT tur_kodu FROM randevu_turu WHERE tur_kodu = ?
            )
            SELECT aday.*,
                   NOT EXISTS (SELECT 1 FROM v_dolu_slot d
                                WHERE d.arac_vin = aday.vin
                                  AND tsrange(d.baslangic, d.bitis)
                                      && tsrange(?::timestamp, ?::timestamp)) AS musait
              FROM (
                    SELECT a.vin, v.paket_adi AS paket, md.ad AS model, a.renk
                      FROM arac a
                      JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                      JOIN model   md ON md.model_id   = v.model_id
                     WHERE (SELECT tur_kodu FROM tur) = 'TEST_SURUSU'
                       AND a.sube_id = ? AND a.durum = 'STOKTA'
                    UNION
                    SELECT a.vin, v.paket_adi, md.ad, a.renk
                      FROM arac a
                      JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                      JOIN model   md ON md.model_id   = v.model_id
                     WHERE (SELECT tur_kodu FROM tur) = 'TESLIMAT'
                       AND a.sube_id = ?
                       AND a.durum = 'SATILDI'
                       AND a.musteri_id = fn_aktif_musteri_id()
                    UNION
                    SELECT a.vin, v.paket_adi, md.ad, a.renk
                      FROM arac a
                      JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                      JOIN model   md ON md.model_id   = v.model_id
                      JOIN v_musteri_servis_durumu msd ON msd.arac_vin = a.vin
                     WHERE (SELECT tur_kodu FROM tur) = 'SERVIS_TESLIM'
                       AND msd.kapandi_mi = false
                       AND msd.son_durum = 'TESLIME_HAZIR'
                       AND msd.sube_id = ?
                    UNION
                    SELECT a.vin, v.paket_adi, md.ad, a.renk
                      FROM arac a
                      JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                      JOIN model   md ON md.model_id   = v.model_id
                     WHERE (SELECT tur_kodu FROM tur) IN ('PERIYODIK_BAKIM','SERVIS_GIRIS')
                       AND a.durum = 'SATILDI'
                       AND a.musteri_id = fn_aktif_musteri_id()
                   ) AS aday
             ORDER BY aday.vin
            """;


    private static final String EKLE_SQL = """
            INSERT INTO randevu
                (musteri_id, sube_id, tur_kodu, calisan_id, arac_vin,
                 baslangic, bitis, durum, kaynak)
            VALUES (?, ?, ?, ?, ?, ?::timestamp, ?::timestamp, 'PLANLANDI', 'WHATSAPP')
            RETURNING randevu_id
            """;

    /** Tür kuralları (tek sorguda). */
    private record Tur(int sureDakika, boolean aracGerekli) {
    }

    /** Seçilen araç. */
    private record Arac(String vin, String model, String paket, String renk) {
    }

    public RandevuHandler(Veritabani db, BotTokeni token) {
        super(db, token);
    }

    @Override
    protected String beklenenYontem() {
        return "POST";
    }

    @Override
    protected int basariliDurum() {
        return 201;
    }

    @Override
    protected Object isle(HttpExchange ex, Connection conn, byte[] hamGovde) throws Exception {
        Map<String, Object> b = govde(hamGovde);

        int subeId = zorunluSayi(b, "sube_id");
        String turKodu = zorunluMetin(b, "tur_kodu");
        LocalDate tarih = tarihOku(b);
        LocalTime baslangic = saatOku(b, "baslangic");
        String model = metin(b, "model");
        String ad = metinEnFazla(b, "ad", 64);
        String soyad = metinEnFazla(b, "soyad", 64);

        LocalDate bugun = LocalDate.now(BOLGE);
        if (tarih.isBefore(bugun)) {
            throw ApiHatasi.goster("GECMIS_TARIH",
                    "Geçmiş bir tarih için randevu alınamaz.", 400, null);
        }
        if (tarih.isAfter(bugun.plusDays(AZAMI_GUN))) {
            throw ApiHatasi.goster("COK_UZAK_TARIH",
                    "En fazla " + AZAMI_GUN + " gün sonrası için randevu alınabilir.", 400, null);
        }

        Map<String, Object> sube = subeOku(conn, subeId);
        Tur tur = turOku(conn, turKodu);

        if (model != null && !tur.aracGerekli()) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    "Bu randevu türünde model kullanılamaz.", 400, null);
        }

        LocalTime bitis = baslangic.plusMinutes(tur.sureDakika());
        if (bitis.isBefore(baslangic) || bitis.equals(baslangic)) {
            throw ApiHatasi.goster("GECERSIZ_SAAT",
                    "Randevu saati gün sonunu aşıyor.", 400, null);
        }
        saatUygunMu(conn, turKodu, tarih, baslangic, bitis);

        Timestamp bas = Timestamp.valueOf(tarih.atTime(baslangic));
        Timestamp bit = Timestamp.valueOf(tarih.atTime(bitis));

        int calisanId = calisanSec(conn, turKodu, subeId, tarih, bas, bit);

        Arac arac = null;
        if (tur.aracGerekli()) {
            arac = aracSec(conn, turKodu, subeId, model, bas, bit);
        }

        // Müşteri kaydı: yoksa telefonla açılır, ad/soyad verildiyse yazılır.
        MusteriDeposu.Kayit musteri = MusteriDeposu.kaydet(conn, ad, soyad);

        long randevuId;
        try (PreparedStatement ps = conn.prepareStatement(EKLE_SQL)) {
            ps.setInt(1, musteri.musteriId());
            ps.setInt(2, subeId);
            ps.setString(3, turKodu);
            ps.setInt(4, calisanId);
            if (arac == null) {
                ps.setNull(5, java.sql.Types.VARCHAR);
            } else {
                ps.setString(5, arac.vin());
            }
            ps.setTimestamp(6, bas);
            ps.setTimestamp(7, bit);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                randevuId = rs.getLong("randevu_id");
            }
        } catch (SQLException e) {
            String durum = e.getSQLState();
            if (EXCLUSION_VIOLATION.equals(durum) || "P0001".equals(durum)) {
                // 23P01: aynı saniyede gelen ikinci istek (veya müşterinin kendi
                // çakışması). P0001: seçim ile INSERT arasında durum değişti
                // (ör. araç satıldı) ve trigger reddetti.
                throw ApiHatasi.goster("SLOT_DOLU",
                        "Bu saat artık müsait değil; başka bir saat seçin.", 409, null);
            }
            throw e;
        }

        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("randevu_id", randevuId);
        veri.put("musteri_id", musteri.musteriId());
        veri.put("sube", sube);
        veri.put("tur_kodu", turKodu);
        veri.put("tarih", tarih.toString());
        veri.put("baslangic", kisaSaat(baslangic));
        veri.put("bitis", kisaSaat(bitis));
        if (arac != null) {
            Map<String, Object> a = new LinkedHashMap<>();
            a.put("vin", arac.vin());
            a.put("model", arac.model());
            a.put("paket", arac.paket());
            a.put("renk", arac.renk());
            veri.put("arac", a);
        }
        veri.put("bilgi", "Randevunuz oluşturuldu: " + tarih + " "
                + kisaSaat(baslangic) + ", " + sube.get("ad") + " (" + sube.get("sehir") + ").");
        return veri;
    }

    // --- okuma / doğrulama --------------------------------------------------

    private Map<String, Object> subeOku(Connection conn, int subeId) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(SUBE_SQL)) {
            ps.setInt(1, subeId);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw ApiHatasi.goster("SUBE_YOK", "Böyle bir şubemiz bulunmuyor.", 404, null);
                }
                Map<String, Object> sube = new LinkedHashMap<>();
                sube.put("sube_id", subeId);
                sube.put("sehir", rs.getString("sehir"));
                sube.put("ad", rs.getString("ad"));
                return sube;
            }
        }
    }

    private Tur turOku(Connection conn, String turKodu) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(TUR_SQL)) {
            ps.setString(1, turKodu);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw ApiHatasi.goster("TUR_YOK", "Böyle bir randevu türü bulunmuyor.",
                            404, null);
                }
                return new Tur(rs.getInt("sure_dakika"), rs.getBoolean("arac_gerekli"));
            }
        }
    }

    private void saatUygunMu(Connection conn, String turKodu, LocalDate tarih,
                             LocalTime baslangic, LocalTime bitis) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(SAAT_UYGUN_SQL)) {
            ps.setString(1, turKodu);
            ps.setInt(2, tarih.getDayOfWeek().getValue());
            ps.setString(3, baslangic.toString());
            ps.setString(4, bitis.toString());
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw ApiHatasi.goster("GECERSIZ_SAAT",
                            "Bu saat, bu randevu türünün tanımlı aralığında değil.", 400, null);
                }
            }
        }
    }

    // --- atama --------------------------------------------------------------

    private int calisanSec(Connection conn, String turKodu, int subeId, LocalDate tarih,
                           Timestamp bas, Timestamp bit) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(CALISAN_SEC_SQL)) {
            ps.setString(1, turKodu);
            ps.setInt(2, subeId);
            ps.setString(3, tarih.toString());
            ps.setString(4, tarih.toString());
            ps.setTimestamp(5, bas);
            ps.setTimestamp(6, bit);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw ApiHatasi.goster("SLOT_DOLU",
                            "Bu saatte uygun çalışan kalmadı; başka bir saat seçin.",
                            409, Map.of("sebep", "CALISAN_YOK"));
                }
                return rs.getInt("calisan_id");
            }
        }
    }

    private Arac aracSec(Connection conn, String turKodu, int subeId, String model,
                         Timestamp bas, Timestamp bit) throws Exception {
        List<Arac> adaylar = new ArrayList<>();
        List<Arac> musaitler = new ArrayList<>();
        Set<String> modeller = new LinkedHashSet<>();

        try (PreparedStatement ps = conn.prepareStatement(ARAC_ADAY_SQL)) {
            int i = 1;
            ps.setString(i++, turKodu);   // tur CTE
            ps.setTimestamp(i++, bas);    // musaitlik penceresi
            ps.setTimestamp(i++, bit);
            ps.setInt(i++, subeId);       // test sürüşü
            ps.setInt(i++, subeId);       // teslimat
            ps.setInt(i++, subeId);       // servisten teslim
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    Arac aday = new Arac(rs.getString("vin"), rs.getString("model"),
                            rs.getString("paket"), rs.getString("renk"));
                    adaylar.add(aday);
                    if (rs.getBoolean("musait")) {
                        musaitler.add(aday);
                        modeller.add(aday.model());
                    }
                }
            }
        }

        if (adaylar.isEmpty()) {
            // Bu tür için hiç aday yok: müşterinin aracı yok ya da kayıt hazır değil.
            // "Başka saat seçin" demek yanıltıcı olurdu; sorun saatte değil.
            throw ApiHatasi.goster("ARAC_YOK",
                    "Bu randevu için uygun araç bulunmuyor.", 404, null);
        }

        if (musaitler.isEmpty()) {
            throw ApiHatasi.goster("SLOT_DOLU",
                    "Bu saatte uygun araç kalmadı; başka bir saat seçin.",
                    409, Map.of("sebep", "ARAC_YOK"));
        }

        if (model == null) {
            return musaitler.get(0);
        }

        for (Arac a : musaitler) {
            // Model adı katalogdan gelir; köprü büyük/küçük harf değiştirse de eşleşsin.
            if (a.model().equalsIgnoreCase(model)) {
                return a;
            }
        }

        // İstenen model o saatte boş değil: hangi modellerin olduğunu bildir.
        Map<String, Object> detay = new LinkedHashMap<>();
        detay.put("istenen_model", model);
        detay.put("mevcut_modeller", new ArrayList<>(modeller));
        throw ApiHatasi.goster("ARAC_YOK",
                "İstediğiniz model bu saatte müsait değil.", 404, detay);
    }

    // --- alan okuma ---------------------------------------------------------

    private static LocalDate tarihOku(Map<String, Object> b) {
        String v = zorunluMetin(b, "tarih");
        try {
            return LocalDate.parse(v);
        } catch (DateTimeParseException e) {
            throw ApiHatasi.goster("GECERSIZ_TARIH",
                    "Tarih YYYY-AA-GG biçiminde olmalı.", 400, null);
        }
    }

    private static LocalTime saatOku(Map<String, Object> b, String ad) {
        String v = zorunluMetin(b, ad);
        // LocalTime.parse("10:00:30") de kabul eder; sözleşme yalnız HH:MM.
        if (!v.matches("^([01]\\d|2[0-3]):[0-5]\\d$")) {
            throw ApiHatasi.goster("GECERSIZ_SAAT",
                    ad + " HH:MM biçiminde olmalı.", 400, null);
        }
        return LocalTime.parse(v);
    }
    private static String kisaSaat(LocalTime t) {
        return String.format("%02d:%02d", t.getHour(), t.getMinute());
    }
}
