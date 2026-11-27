package tr.edu.etu.dealership.panel;

import com.sun.net.httpserver.HttpExchange;
import tr.edu.etu.dealership.web.ApiHatasi;
import tr.edu.etu.dealership.web.JsonYanit;

import java.io.IOException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.time.format.ResolverStyle;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;

/**
 * Bir panel isteğinin bağlamı: oturum, bağlantı, yol grupları, query
 * parametreleri ve JSON gövdesi. Okuma yardımcıları sözleşmedeki hataları
 * ({@code 400 GECERSIZ_PARAMETRE}) üretir; handler'lar doğrulama yazmaz.
 */
public final class Istek {

    private static final DateTimeFormatter TARIH =
            DateTimeFormatter.ofPattern("uuuu-MM-dd").withResolverStyle(ResolverStyle.STRICT);
    private static final DateTimeFormatter ZAMAN =
            DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm").withResolverStyle(ResolverStyle.STRICT);

    private final HttpExchange ex;
    private final Oturumlar.Oturum oturum;
    private final Matcher yol;
    private final byte[] hamGovde;
    private final int azamiGovde;
    private Map<String, String> parametreler;
    private Map<String, Object> govde;
    private Connection conn;

    Istek(HttpExchange ex, Oturumlar.Oturum oturum, Matcher yol, byte[] hamGovde, int azamiGovde) {
        this.ex = ex;
        this.oturum = oturum;
        this.yol = yol;
        this.hamGovde = hamGovde;
        this.azamiGovde = azamiGovde;
    }

    void baglan(Connection conn) {
        this.conn = conn;
    }

    public Connection conn() { return conn; }
    public Oturumlar.Oturum oturum() { return oturum; }
    public HttpExchange exchange() { return ex; }

    /** Yoldaki sayısal grup (ör. {@code /panel/randevu/(\d+)/durum}). */
    public int yolSayi(int grup) {
        try {
            return Integer.parseInt(yol.group(grup));
        } catch (NumberFormatException e) {
            // \d+ int sınırını aşarsa: böyle bir kayıt olamaz
            throw ApiHatasi.goster("BULUNAMADI", "Kayıt bulunamadı.", 404, null);
        }
    }

    public String yolMetin(int grup) {
        return yol.group(grup);
    }

    // ---- Query parametreleri -------------------------------------------------

    /** Query parametreleri. Aynı ad iki kez gelirse 400 (hangisinin kullanıldığı belirsiz kalmasın). */
    public Map<String, String> parametreler() {
        if (parametreler != null) return parametreler;
        Map<String, String> sonuc = new LinkedHashMap<>();
        String q = ex.getRequestURI().getRawQuery();
        if (q != null && !q.isEmpty()) {
            for (String parca : q.split("&")) {
                if (parca.isEmpty()) continue;
                int i = parca.indexOf('=');
                String ad = cozum(i < 0 ? parca : parca.substring(0, i));
                String deger = i < 0 ? "" : cozum(parca.substring(i + 1));
                if (ad.isBlank()) continue;
                if (sonuc.put(ad, deger) != null) {
                    throw gecersiz(ad + " parametresi birden çok kez gönderilmiş.");
                }
            }
        }
        parametreler = Collections.unmodifiableMap(sonuc);
        return parametreler;
    }

    /** Bilinmeyen parametreyi reddeder: yazım hatası sessizce filtresiz sonuç dönmesin. */
    public void yalnizca(Set<String> izinli) {
        for (String ad : parametreler().keySet()) {
            if (!izinli.contains(ad)) {
                throw gecersiz("Bilinmeyen parametre: " + ad);
            }
        }
    }

    public String metinParam(String ad) {
        String v = parametreler().get(ad);
        return (v == null || v.isBlank()) ? null : v.trim();
    }

    public Integer sayiParam(String ad) {
        String v = metinParam(ad);
        if (v == null) return null;
        try {
            return Integer.valueOf(v);
        } catch (NumberFormatException e) {
            throw gecersiz(ad + " tam sayı olmalı.");
        }
    }

    public LocalDate tarihParam(String ad) {
        String v = metinParam(ad);
        return v == null ? null : tarih(ad, v);
    }

    public Boolean evetHayirParam(String ad) {
        String v = metinParam(ad);
        if (v == null) return null;
        return switch (v) {
            case "true" -> true;
            case "false" -> false;
            default -> throw gecersiz(ad + " true veya false olmalı.");
        };
    }

    /** Değer verilen kümeden biri olmalı. */
    public String secimParam(String ad, Set<String> secenekler) {
        String v = metinParam(ad);
        if (v != null && !secenekler.contains(v)) {
            throw gecersiz(ad + " geçersiz: " + v);
        }
        return v;
    }

    /** {@code limit}: varsayılan 50, 1–200. */
    public int limit() {
        Integer l = sayiParam("limit");
        if (l == null) return 50;
        if (l < 1 || l > 200) throw gecersiz("limit 1 ile 200 arasında olmalı.");
        return l;
    }

    /** {@code sayfa}: 1'den başlar. */
    public int sayfa() {
        Integer s = sayiParam("sayfa");
        if (s == null) return 1;
        if (s < 1 || s > 100_000) throw gecersiz("sayfa 1 veya daha büyük olmalı.");
        return s;
    }

    // ---- JSON gövde ------------------------------------------------------------

    @SuppressWarnings("unchecked")
    public Map<String, Object> govde() {
        if (govde != null) return govde;
        if (hamGovde == null || hamGovde.length == 0) throw gecersiz("İstek gövdesi boş.");
        if (hamGovde.length > azamiGovde) throw gecersiz("İstek gövdesi çok büyük.");
        Object cozulen;
        try {
            cozulen = JsonYanit.mapper().readValue(hamGovde, Object.class);
        } catch (IOException e) {
            throw gecersiz("İstek gövdesi geçerli JSON değil.");
        }
        if (!(cozulen instanceof Map)) throw gecersiz("İstek gövdesi bir JSON nesnesi olmalı.");
        govde = (Map<String, Object>) cozulen;
        return govde;
    }

    /** Gövdede tanımsız alan varsa 400: yazım hatası sessizce yok sayılmasın. */
    public void alanlar(Set<String> izinli) {
        for (String ad : govde().keySet()) {
            if (!izinli.contains(ad)) throw gecersiz("Bilinmeyen alan: " + ad);
        }
    }

    public String metin(String ad, int enFazla) {
        String s = hamMetin(ad, enFazla);
        if (s == null) return null;
        String t = s.trim();
        return t.isEmpty() ? null : t;
    }

    /** Trim uygulanmaz (şifre gibi boşluğun anlamlı olduğu alanlar). */
    public String hamMetin(String ad, int enFazla) {
        Object v = govde().get(ad);
        if (v == null) return null;
        if (!(v instanceof String s)) throw gecersiz(ad + " metin olmalı.");
        if (s.isEmpty()) return null;
        if (s.length() > enFazla) throw gecersiz(ad + " en fazla " + enFazla + " karakter olabilir.");
        return s;
    }

    public String zorunluMetin(String ad, int enFazla) {
        String v = metin(ad, enFazla);
        if (v == null) throw gecersiz(ad + " zorunlu.");
        return v;
    }

    public String hamZorunluMetin(String ad, int enFazla) {
        String v = hamMetin(ad, enFazla);
        if (v == null) throw gecersiz(ad + " zorunlu.");
        return v;
    }

    public Long sayi(String ad) {
        Object v = govde().get(ad);
        if (v == null) return null;
        if (v instanceof Integer || v instanceof Long) return ((Number) v).longValue();
        throw gecersiz(ad + " tam sayı olmalı.");
    }

    public long zorunluSayi(String ad) {
        Long v = sayi(ad);
        if (v == null) throw gecersiz(ad + " zorunlu.");
        return v;
    }

    public int zorunluId(String ad) {
        long v = zorunluSayi(ad);
        if (v < 1 || v > Integer.MAX_VALUE) throw gecersiz(ad + " geçersiz.");
        return (int) v;
    }

    public LocalDate tarihAlani(String ad) {
        String v = metin(ad, 10);
        return v == null ? null : tarih(ad, v);
    }

    public LocalDateTime zorunluZaman(String ad) {
        String v = zorunluMetin(ad, 16);
        try {
            return LocalDateTime.parse(v, ZAMAN);
        } catch (DateTimeParseException e) {
            throw gecersiz(ad + " YYYY-MM-DDTHH:MM biçiminde olmalı.");
        }
    }

    // ---- Yardımcılar -------------------------------------------------------------

    private static LocalDate tarih(String ad, String v) {
        try {
            return LocalDate.parse(v, TARIH);
        } catch (DateTimeParseException e) {
            throw ApiHatasi.goster("GECERSIZ_TARIH", ad + " YYYY-MM-DD biçiminde olmalı.", 400, null);
        }
    }

    public static ApiHatasi gecersiz(String mesaj) {
        return ApiHatasi.goster("GECERSIZ_PARAMETRE", mesaj, 400, null);
    }

    public static ApiHatasi bulunamadi(String ne) {
        return ApiHatasi.goster("BULUNAMADI", ne + " bulunamadı.", 404, null);
    }

    private static String cozum(String s) {
        try {
            return URLDecoder.decode(s, StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            throw gecersiz("Parametre kodlaması bozuk.");
        }
    }
}
