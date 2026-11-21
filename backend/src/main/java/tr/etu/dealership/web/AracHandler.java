package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import tr.edu.etu.dealership.db.Veritabani;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * {@code GET /bot/arac} — sözleşme: docs/api/bot-sozlesmesi.md §3
 *
 * <p>İki iş yapar:
 * <ul>
 *   <li><b>Stok bilgisi</b> (varsayılan): stoktaki ve yoldaki araçları model /
 *       şehir / şube kırılımında sayar. Filtre verilmezse en geniş (model),
 *       filtre verdikçe bir seviye daralan grup döner.</li>
 *   <li><b>Kendi araçlarım</b> ({@code kapsam=benim}): müşterinin satın aldığı
 *       araçları VIN ve plakasıyla listeler (servis/teslim randevusu için).</li>
 * </ul>
 *
 * <p>Stok, {@code STOKTA} ve {@code YOLDA} durumlarıdır; {@code SATILDI} araçlar
 * stok sayılmaz (onlar müşterilerin araçlarıdır ve RLS ile yalnız sahibine görünür).
 */
public final class AracHandler extends BotHandler {

    private static final String STOK_DURUMLARI = "('STOKTA','YOLDA')";

    private static final String FROM_STOK = """
              FROM arac a
              JOIN versiyon v ON v.versiyon_id = a.versiyon_id
              JOIN model   md ON md.model_id   = v.model_id
              JOIN sube     s ON s.sube_id     = a.sube_id
            """;

    /** Filtre yok: model bazında toplam. */
    private static final String OZET_MODEL_SQL = """
            SELECT md.ad AS model,
                   count(*) FILTER (WHERE a.durum = 'STOKTA') AS stokta,
                   count(*) FILTER (WHERE a.durum = 'YOLDA')  AS yolda,
                   min(a.tahmini_varis_tarihi) FILTER (WHERE a.durum = 'YOLDA')
                                                              AS en_erken_varis
            """ + FROM_STOK + """
             WHERE a.durum IN """ + STOK_DURUMLARI + """
             GROUP BY md.ad
             ORDER BY md.ad COLLATE "C"
            """;

    /** Yalnız model: şehir + paket kırılımı. */
    private static final String MODEL_SEHIR_SQL = """
            SELECT s.sehir,
                   v.paket_adi AS paket,
                   count(*) FILTER (WHERE a.durum = 'STOKTA') AS stokta,
                   count(*) FILTER (WHERE a.durum = 'YOLDA')  AS yolda,
                   min(a.tahmini_varis_tarihi) FILTER (WHERE a.durum = 'YOLDA')
                                                              AS en_erken_varis
            """ + FROM_STOK + """
             WHERE a.durum IN """ + STOK_DURUMLARI + """
               AND md.ad = ?
             GROUP BY s.sehir, v.paket_adi
             ORDER BY s.sehir COLLATE "C", v.paket_adi COLLATE "C"
            """;

    /** Şehir (model opsiyonel): şube + model + paket kırılımı. */
    private static final String SEHIR_SUBE_SQL = """
            SELECT s.sube_id, s.ad AS sube,
                   md.ad AS model,
                   v.paket_adi AS paket,
                   count(*) FILTER (WHERE a.durum = 'STOKTA') AS stokta,
                   count(*) FILTER (WHERE a.durum = 'YOLDA')  AS yolda,
                   min(a.tahmini_varis_tarihi) FILTER (WHERE a.durum = 'YOLDA')
                                                              AS en_erken_varis
            """ + FROM_STOK + """
             WHERE a.durum IN """ + STOK_DURUMLARI + """
               AND s.sehir = ?
               AND (?::varchar IS NULL OR md.ad = ?)
             GROUP BY s.sube_id, s.ad, md.ad, v.paket_adi
             ORDER BY s.ad COLLATE "C", md.ad COLLATE "C", v.paket_adi COLLATE "C"
            """;

    /** Şube (model opsiyonel): paket kırılımı. */
    private static final String SUBE_PAKET_SQL = """
            SELECT md.ad AS model,
                   v.paket_adi AS paket,
                   count(*) FILTER (WHERE a.durum = 'STOKTA') AS stokta,
                   count(*) FILTER (WHERE a.durum = 'YOLDA')  AS yolda,
                   min(a.tahmini_varis_tarihi) FILTER (WHERE a.durum = 'YOLDA')
                                                              AS en_erken_varis
            """ + FROM_STOK + """
             WHERE a.durum IN """ + STOK_DURUMLARI + """
               AND a.sube_id = ?
               AND (?::varchar IS NULL OR md.ad = ?)
             GROUP BY md.ad, v.paket_adi
             ORDER BY md.ad COLLATE "C", v.paket_adi COLLATE "C"
            """;

    /** Şube detayı: yalnız stoktaki araçların renk kırılımı. */
    private static final String SUBE_RENK_SQL = """
            SELECT md.ad AS model, v.paket_adi AS paket, a.renk, count(*) AS adet
            """ + FROM_STOK + """
             WHERE a.durum = 'STOKTA'
               AND a.sube_id = ?
             GROUP BY md.ad, v.paket_adi, a.renk
             ORDER BY md.ad COLLATE "C", v.paket_adi COLLATE "C", a.renk COLLATE "C"
            """;

    private static final String BENIM_ARACLAR_SQL = """
            SELECT a.vin, md.ad AS model, v.paket_adi AS paket, a.renk, a.plaka
              FROM arac a
              JOIN versiyon v ON v.versiyon_id = a.versiyon_id
              JOIN model   md ON md.model_id   = v.model_id
             WHERE a.durum = 'SATILDI'
               AND a.musteri_id = fn_aktif_musteri_id()
               AND (?::varchar IS NULL OR md.ad = ?)
             ORDER BY md.ad COLLATE "C", v.paket_adi COLLATE "C", a.vin
            """;

    private static final String SUBE_BILGISI_SQL =
            "SELECT sube_id, sehir, ad FROM sube WHERE sube_id = ?";

    private static final String SEHIR_VAR_MI_SQL =
            "SELECT 1 FROM sube WHERE sehir = ? LIMIT 1";

    private static final String MODEL_VAR_MI_SQL =
            "SELECT 1 FROM model WHERE ad = ?";

    /** Renk kırılımı anahtarı; metin birleştirme yerine tip güvenli çift. */
    private record RenkAnahtari(String model, String paket) {
    }

    public AracHandler(Veritabani db, BotTokeni token) {
        super(db, token);
    }

    @Override
    protected Object isle(HttpExchange ex, Connection conn) throws Exception {
        Map<String, String> p = parametreler(ex);

        // Boş değer sessizce "filtre yok" sayılmaz: LLM'in boş string göndermesi
        // ulusal özet döndürür ve müşteriye yanlış cevap üretirdi.
        for (String ad : List.of("model", "sehir", "kapsam", "sube_id")) {
            if (p.containsKey(ad) && p.get(ad).isBlank()) {
                throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                        ad + " parametresi boş olamaz.", 400, null);
            }
        }

        String model = bosIseNull(p.get("model"));
        String sehir = bosIseNull(p.get("sehir"));
        Integer subeId = sayiIseNull(p.get("sube_id"), "sube_id");
        String kapsam = bosIseNull(p.get("kapsam"));

        if (kapsam != null && !kapsam.equals("benim")) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    "kapsam yalnızca 'benim' olabilir.", 400, null);
        }
        if (subeId != null && sehir != null) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    "sehir ve sube_id birlikte kullanılamaz; yalnızca biri verilebilir.", 400, null);
        }
        if (kapsam != null && (subeId != null || sehir != null)) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    "kapsam=benim yalnızca model filtresiyle kullanılabilir.", 400, null);
        }

        if (model != null) {
            modelVarMi(conn, model);
        }

        if (kapsam != null) {
            return benimAraclar(conn, model);
        }
        if (subeId != null) {
            return subeDetayi(conn, subeId, model);
        }
        if (sehir != null) {
            sehirVarMi(conn, sehir);
            return sehirKirilimi(conn, sehir, model);
        }
        if (model != null) {
            return modelKirilimi(conn, model);
        }
        return modelOzeti(conn);
    }

    // --- modlar -------------------------------------------------------------

    private Object modelOzeti(Connection conn) throws Exception {
        List<Map<String, Object>> modeller = new ArrayList<>();
        long stokta = 0, yolda = 0;
        try (PreparedStatement ps = conn.prepareStatement(OZET_MODEL_SQL);
             ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                Map<String, Object> m = new LinkedHashMap<>();
                m.put("model", rs.getString("model"));
                m.put("stokta", rs.getInt("stokta"));
                m.put("yolda", rs.getInt("yolda"));
                m.put("en_erken_varis", tarih(rs, "en_erken_varis"));
                modeller.add(m);
                stokta += rs.getInt("stokta");
                yolda += rs.getInt("yolda");
            }
        }
        return govde(toplam(stokta, yolda), "modeller", modeller, ozetMetni(stokta, yolda));
    }

    private Object modelKirilimi(Connection conn, String model) throws Exception {
        List<Map<String, Object>> sehirler = new ArrayList<>();
        long stokta = 0, yolda = 0;
        try (PreparedStatement ps = conn.prepareStatement(MODEL_SEHIR_SQL)) {
            ps.setString(1, model);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    Map<String, Object> r = new LinkedHashMap<>();
                    r.put("sehir", rs.getString("sehir"));
                    r.put("paket", rs.getString("paket"));
                    r.put("stokta", rs.getInt("stokta"));
                    r.put("yolda", rs.getInt("yolda"));
                    r.put("en_erken_varis", tarih(rs, "en_erken_varis"));
                    sehirler.add(r);
                    stokta += rs.getInt("stokta");
                    yolda += rs.getInt("yolda");
                }
            }
        }
        Map<String, Object> veri = govde(toplam(stokta, yolda),
                "sehirler", sehirler, ozetMetni(stokta, yolda));
        veri.put("model", model);
        return sirala(veri, "model");
    }

    private Object sehirKirilimi(Connection conn, String sehir, String model) throws Exception {
        List<Map<String, Object>> subeler = new ArrayList<>();
        long stokta = 0, yolda = 0;
        try (PreparedStatement ps = conn.prepareStatement(SEHIR_SUBE_SQL)) {
            ps.setString(1, sehir);
            ps.setString(2, model);
            ps.setString(3, model);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    Map<String, Object> r = new LinkedHashMap<>();
                    r.put("sube_id", rs.getInt("sube_id"));
                    r.put("sube", rs.getString("sube"));
                    r.put("model", rs.getString("model"));
                    r.put("paket", rs.getString("paket"));
                    r.put("stokta", rs.getInt("stokta"));
                    r.put("yolda", rs.getInt("yolda"));
                    r.put("en_erken_varis", tarih(rs, "en_erken_varis"));
                    subeler.add(r);
                    stokta += rs.getInt("stokta");
                    yolda += rs.getInt("yolda");
                }
            }
        }
        Map<String, Object> veri = govde(toplam(stokta, yolda),
                "subeler", subeler, sehir + ": " + ozetMetni(stokta, yolda));
        veri.put("sehir", sehir);
        return sirala(veri, "sehir");
    }

    private Object subeDetayi(Connection conn, int subeId, String model) throws Exception {
        Map<String, Object> sube = new LinkedHashMap<>();
        try (PreparedStatement ps = conn.prepareStatement(SUBE_BILGISI_SQL)) {
            ps.setInt(1, subeId);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw ApiHatasi.goster("SUBE_YOK", "Böyle bir şubemiz bulunmuyor.", 404, null);
                }
                sube.put("sube_id", rs.getInt("sube_id"));
                sube.put("sehir", rs.getString("sehir"));
                sube.put("ad", rs.getString("ad"));
            }
        }

        // Renk kırılımı önce toplanır: paket satırlarına iliştirilir.
        // Anahtar record: model/paket adında ayırıcı karakter olsa bile çakışmaz.
        Map<RenkAnahtari, List<Map<String, Object>>> renkler = new LinkedHashMap<>();
        try (PreparedStatement ps = conn.prepareStatement(SUBE_RENK_SQL)) {
            ps.setInt(1, subeId);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    RenkAnahtari anahtar = new RenkAnahtari(
                            rs.getString("model"), rs.getString("paket"));
                    Map<String, Object> r = new LinkedHashMap<>();
                    r.put("renk", rs.getString("renk"));
                    r.put("adet", rs.getInt("adet"));
                    renkler.computeIfAbsent(anahtar, k -> new ArrayList<>()).add(r);
                }
            }
        }

        List<Map<String, Object>> paketler = new ArrayList<>();
        long stokta = 0, yolda = 0;
        try (PreparedStatement ps = conn.prepareStatement(SUBE_PAKET_SQL)) {
            ps.setInt(1, subeId);
            ps.setString(2, model);
            ps.setString(3, model);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    Map<String, Object> r = new LinkedHashMap<>();
                    String modelAd = rs.getString("model");
                    String paket = rs.getString("paket");
                    r.put("model", modelAd);
                    r.put("paket", paket);
                    r.put("stokta", rs.getInt("stokta"));
                    r.put("yolda", rs.getInt("yolda"));
                    r.put("en_erken_varis", tarih(rs, "en_erken_varis"));
                    r.put("renkler", renkler.getOrDefault(
                            new RenkAnahtari(modelAd, paket), List.of()));
                    paketler.add(r);
                    stokta += rs.getInt("stokta");
                    yolda += rs.getInt("yolda");
                }
            }
        }

        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("sube", sube);
        veri.put("toplam", toplam(stokta, yolda));
        veri.put("paketler", paketler);
        veri.put("bilgi", sube.get("ad") + " (" + sube.get("sehir") + "): "
                + ozetMetni(stokta, yolda));
        return veri;
    }

    private Object benimAraclar(Connection conn, String model) throws Exception {
        List<Map<String, Object>> araclar = new ArrayList<>();
        try (PreparedStatement ps = conn.prepareStatement(BENIM_ARACLAR_SQL)) {
            ps.setString(1, model);
            ps.setString(2, model);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    Map<String, Object> a = new LinkedHashMap<>();
                    a.put("vin", rs.getString("vin"));
                    a.put("model", rs.getString("model"));
                    a.put("paket", rs.getString("paket"));
                    a.put("renk", rs.getString("renk"));
                    a.put("plaka", rs.getString("plaka"));
                    araclar.add(a);
                }
            }
        }
        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("toplam_arac", araclar.size());
        veri.put("araclar", araclar);
        veri.put("bilgi", araclar.isEmpty()
                ? "Kayıtlı aracınız bulunmuyor."
                : "Kayıtlı " + araclar.size() + " aracınız var.");
        return veri;
    }

    // --- doğrulamalar -------------------------------------------------------

    private void sehirVarMi(Connection conn, String sehir) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(SEHIR_VAR_MI_SQL)) {
            ps.setString(1, sehir);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw ApiHatasi.goster("SEHIRDE_SUBE_YOK",
                            "Bu şehirde şubemiz bulunmuyor.", 404, null);
                }
            }
        }
    }

    private void modelVarMi(Connection conn, String model) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(MODEL_VAR_MI_SQL)) {
            ps.setString(1, model);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    throw ApiHatasi.goster("MODEL_YOK",
                            "Böyle bir modelimiz bulunmuyor.", 404, null);
                }
            }
        }
    }

    // --- yardımcılar --------------------------------------------------------

    /** Sıralı toplam nesnesi: JSON'da stokta, sonra yolda gelsin. */
    private static Map<String, Object> toplam(long stokta, long yolda) {
        Map<String, Object> t = new LinkedHashMap<>();
        t.put("stokta", stokta);
        t.put("yolda", yolda);
        return t;
    }

    private static Map<String, Object> govde(Map<String, Object> toplam,
                                             String listeAdi,
                                             List<Map<String, Object>> liste,
                                             String bilgi) {
        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("toplam", toplam);
        veri.put(listeAdi, liste);
        veri.put("bilgi", bilgi);
        return veri;
    }

    /** {@code model}/{@code sehir} alanı listenin başında görünsün diye yeniden sıralar. */
    private static Map<String, Object> sirala(Map<String, Object> veri, String ilkAnahtar) {
        Map<String, Object> sonuc = new LinkedHashMap<>();
        sonuc.put(ilkAnahtar, veri.remove(ilkAnahtar));
        sonuc.putAll(veri);
        return sonuc;
    }

    private static String ozetMetni(long stokta, long yolda) {
        if (stokta == 0 && yolda == 0) {
            return "Bu kriterlerde araç bulunmuyor.";
        }
        if (yolda == 0) {
            return stokta + " araç stokta.";
        }
        if (stokta == 0) {
            return yolda + " araç yolda.";
        }
        return stokta + " araç stokta, " + yolda + " araç yolda.";
    }

    private static String tarih(ResultSet rs, String kolon) throws Exception {
        java.sql.Date d = rs.getDate(kolon);
        return d == null ? null : d.toString();
    }

    private static String bosIseNull(String s) {
        return (s == null || s.isBlank()) ? null : s.trim();
    }

    private static Integer sayiIseNull(String s, String ad) {
        if (s == null || s.isBlank()) return null;
        try {
            return Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE", ad + " sayısal olmalı.", 400, null);
        }
    }
}
