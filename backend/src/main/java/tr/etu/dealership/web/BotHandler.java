package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tr.edu.etu.dealership.db.BotKimligi;
import tr.edu.etu.dealership.db.Veritabani;

import java.io.IOException;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Bot endpoint'lerinin ortak iskeleti.
 *
 * <p>Alt sınıflar yalnızca iş mantığını yazar; bu sınıf şunları garanti eder:
 * <ul>
 *   <li>Bot kimliği (X-Musteri-Telefon) her istekte okunur ve doğrulanır</li>
 *   <li>Transaction içinde {@code SET LOCAL app.musteri_telefon} yazılır → RLS</li>
 *   <li>İş biter → commit; istisna → rollback</li>
 *   <li>{@link ApiHatasi} sözleşmedeki zarfa çevrilir</li>
 *   <li>Beklenmedik hata loglanır, istemciye yalnızca SISTEM_HATASI gider</li>
 * </ul>
 */
public abstract class BotHandler implements HttpHandler {

    private static final Logger LOG = LoggerFactory.getLogger(BotHandler.class);

    protected final Veritabani db;
    protected final BotTokeni token;

    protected BotHandler(Veritabani db, BotTokeni token) {
        this.db = db;
        this.token = token;
    }

    @Override
    public final void handle(HttpExchange ex) throws IOException {
        try {
            // Köprü kimliği her şeyden önce: istek doğrulanmadan endpoint'in
            // varlığı ya da yöntemi hakkında bilgi verilmez.
            if (!token.gecerliMi(ex.getRequestHeaders().getFirst(BotTokeni.BASLIK))) {
                JsonYanit.yaz(ex, 401,
                        JsonYanit.hatali("YETKISIZ_ISTEK", "İstek doğrulanamadı.",
                                true, null));
                return;
            }

            // HttpServer context'leri onek ile eşleşir (/bot/sube/ekstra da gelir).
            // Sözleşmede tanımlı olmayan yol 404 döner.
            String istenenYol = ex.getRequestURI().getPath();
            String tanimliYol = ex.getHttpContext().getPath();
            if (!yolGecerliMi(tanimliYol, istenenYol)) {
                JsonYanit.yaz(ex, 404,
                        JsonYanit.hatali("YOL_YOK", "Böyle bir kaynak bulunmuyor.", true, null));
                return;
            }

            if (!izinliYontemler().contains(ex.getRequestMethod())) {
                ex.getResponseHeaders().set("Allow", String.join(", ", izinliYontemler()));
                JsonYanit.yaz(ex, 405,
                        JsonYanit.hatali("YONTEM_DESTEKLENMIYOR", "Bu yöntem desteklenmiyor.",
                                true, null));
                return;
            }

            String telefon = ex.getRequestHeaders().getFirst("X-Musteri-Telefon");
            if (telefon == null || telefon.isBlank()) {
                // Kimlik yoksa hiçbir sorgu çalıştırılmaz: RLS fail-closed.
                JsonYanit.yaz(ex, 401,
                        JsonYanit.hatali("KIMLIK_YOK", "Müşteri kimliği gönderilmedi.",
                                true, null));
                return;
            }

            // Gövde, bağlantı havuzundan bağlantı alınmadan önce okunur: yavaş
            // yükleyen bir istemci havuzdaki bağlantıyı meşgul etmesin.
            byte[] hamGovde = "POST".equals(ex.getRequestMethod())
                    ? ex.getRequestBody().readNBytes(AZAMI_GOVDE + 1)
                    : null;

            try (Connection conn = db.baglanti()) {
                try {
                    try {
                        BotKimligi.ata(conn, telefon.trim());
                    } catch (IllegalArgumentException e) {
                        // Biçimi bozuk kimlik: RLS'yi boş kümeye düşürmek yerine açıkça reddet.
                        conn.rollback();
                        JsonYanit.yaz(ex, 401,
                                JsonYanit.hatali("KIMLIK_YOK",
                                        "Müşteri kimliği geçersiz.", true, null));
                        return;
                    }
                    Object veri = isle(ex, conn, hamGovde);
                    if (veri == null) {
                        // Sözleşme her endpoint için gövde öngörür; null dönen bir
                        // handler protokol ihlalidir. Commit'ten ÖNCE fırlatılır ki
                        // istemci 500 alırken yazma kalıcı olmasın.
                        throw new IllegalStateException("Handler gövde üretmedi: "
                                + ex.getRequestURI().getPath());
                    }
                    conn.commit();
                    JsonYanit.yaz(ex, basariliDurum(ex), JsonYanit.basarili(veri));
                } catch (ApiHatasi e) {
                    conn.rollback();
                    JsonYanit.yaz(ex, e.httpDurum(),
                            JsonYanit.hatali(e.kod(), e.getMessage(),
                                    e.kullaniciyaGoster(), e.detay()));
                } catch (Exception e) {
                    conn.rollback();
                    throw e;
                }
            }

        } catch (SQLException e) {
            // Sözleşme: SISTEM_HATASI tek biçimdedir (HTTP 500). Altyapı arızası
            // ile iş hatasını ayırmak istemciye fayda sağlamaz; log'da ayrışır.
            LOG.error("Veritabanı hatası: {}", ex.getRequestURI(), e);
            JsonYanit.yaz(ex, 500,
                    JsonYanit.hatali("SISTEM_HATASI", "Şu an hizmet veremiyorum.", true, null));
        } catch (Exception e) {
            LOG.error("Beklenmedik hata: {}", ex.getRequestURI(), e);
            JsonYanit.yaz(ex, 500,
                    JsonYanit.hatali("SISTEM_HATASI", "Şu an hizmet veremiyorum.", true, null));
        } finally {
            ex.close();
        }
    }

    /**
     * İş mantığı. Dönen değer {@code {ok:true, veri:<değer>}} zarfına konur;
     * {@code null} dönerse yalnızca commit yapılır, gövde yazılmaz.
     */
    protected Object isle(HttpExchange ex, Connection conn) throws Exception {
        throw new IllegalStateException("Handler işleme biçimini tanımlamadı: "
                + getClass().getSimpleName());
    }

    /**
     * Gövdeyi önceden okunmuş haliyle alan sürüm. POST uçları bunu ezer;
     * GET uçları varsayılanı kullanır.
     */
    protected Object isle(HttpExchange ex, Connection conn, byte[] hamGovde) throws Exception {
        return isle(ex, conn);
    }

    /** Bu endpoint'in kabul ettiği HTTP yöntemi. Sözleşmede GET/POST olarak sabittir. */
    protected String beklenenYontem() {
        return "GET";
    }

    /**
     * İstenen yol bu context'e uyuyor mu? Varsayılan: tam yol veya sondaki eğik
     * çizgi. Parça içeren yollar ({@code /bot/randevu/12/iptal}) bu kancayı ezer.
     */
    protected boolean yolGecerliMi(String tanimliYol, String istenenYol) {
        return tanimliYol.equals(istenenYol) || (tanimliYol + "/").equals(istenenYol);
    }

    /** Bu endpoint'in kabul ettiği yöntemler. Aynı yolda GET ve POST varsa ikisi de. */
    protected List<String> izinliYontemler() {
        return List.of(beklenenYontem());
    }

    /** Başarılı yanıtın HTTP durumu. Kaynak oluşturan istekler 201 döner. */
    protected int basariliDurum(HttpExchange ex) {
        return 200;
    }

    /** JSON gövde üst sınırı: bot mesajları küçüktür, büyük gövde reddedilir. */
    private static final int AZAMI_GOVDE = 64 * 1024;

    /**
     * POST gövdesini JSON nesnesi olarak okur. Gövde yoksa, çok büyükse veya
     * geçerli bir JSON nesnesi değilse {@code 400 GECERSIZ_PARAMETRE} döner.
     */
    @SuppressWarnings("unchecked")
    protected static Map<String, Object> govde(byte[] ham) {
        if (ham == null || ham.length == 0) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE", "İstek gövdesi boş.", 400, null);
        }
        if (ham.length > AZAMI_GOVDE) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE", "İstek gövdesi çok büyük.", 400, null);
        }
        Object cozulen;
        try {
            cozulen = JsonYanit.mapper().readValue(ham, Object.class);
        } catch (IOException e) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    "İstek gövdesi geçerli JSON değil.", 400, null);
        }
        if (!(cozulen instanceof Map)) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    "İstek gövdesi bir JSON nesnesi olmalı.", 400, null);
        }
        return (Map<String, Object>) cozulen;
    }

    /** JSON gövdeden metin alanı; boş string yok sayılır. */
    protected static String metin(Map<String, Object> govde, String ad) {
        Object v = govde.get(ad);
        if (v == null) return null;
        if (!(v instanceof String s)) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE", ad + " metin olmalı.", 400, null);
        }
        return s.isBlank() ? null : s.trim();
    }

    /** JSON gövdeden metin alanı; kolon genişliğini aşarsa 400 (DB hatası 500 olmasın). */
    protected static String metinEnFazla(Map<String, Object> govde, String ad, int enFazla) {
        String v = metin(govde, ad);
        if (v != null && v.length() > enFazla) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    ad + " en fazla " + enFazla + " karakter olabilir.", 400, null);
        }
        return v;
    }

    /** JSON gövdeden zorunlu metin alanı. */
    protected static String zorunluMetin(Map<String, Object> govde, String ad) {
        String v = metin(govde, ad);
        if (v == null) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE", ad + " parametresi zorunlu.", 400, null);
        }
        return v;
    }

    /** JSON gövdeden zorunlu tam sayı alanı. */
    protected static int zorunluSayi(Map<String, Object> govde, String ad) {
        Object v = govde.get(ad);
        if (v == null) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE", ad + " parametresi zorunlu.", 400, null);
        }
        if (v instanceof Integer i) return i;
        if (v instanceof Number n && n.doubleValue() == Math.rint(n.doubleValue())) {
            return n.intValue();
        }
        throw ApiHatasi.goster("GECERSIZ_PARAMETRE", ad + " tam sayı olmalı.", 400, null);
    }

    /**
     * Query parametrelerini okur (kodlama çözülmüş). Aynı parametre iki kez
     * gelirse sessizce birini seçmek yerine açık hata döner: hangi değerin
     * kullanıldığı istemciye göre değişen bir davranış güvenlik açığı üretir.
     */
    protected static Map<String, String> parametreler(HttpExchange ex) {
        Map<String, String> sonuc = new LinkedHashMap<>();
        String q = ex.getRequestURI().getRawQuery();
        if (q == null || q.isEmpty()) return sonuc;
        for (String parca : q.split("&")) {
            int i = parca.indexOf('=');
            if (i == 0) continue;                    // "=x" geçersiz, yok sayılır
            if (i < 0) {
                // "?limit" gibi değersiz parametre: boş değerle kaydedilir ki
                // doğrulama katmanı yakalayabilsin (sessizce yok sayılmasın).
                String ad = decode(parca);
                if (ad.isBlank()) continue;
                if (sonuc.containsKey(ad)) {
                    throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                            ad + " parametresi birden çok kez gönderilmiş.", 400, null);
                }
                sonuc.put(ad, "");
                continue;
            }
            String ad = decode(parca.substring(0, i));
            if (sonuc.containsKey(ad)) {
                throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                        ad + " parametresi birden çok kez gönderilmiş.", 400, null);
            }
            sonuc.put(ad, decode(parca.substring(i + 1)));
        }
        return sonuc;
    }

    private static String decode(String s) {
        return java.net.URLDecoder.decode(s, java.nio.charset.StandardCharsets.UTF_8);
    }
}
