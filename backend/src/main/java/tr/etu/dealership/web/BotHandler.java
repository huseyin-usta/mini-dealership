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
            if (!tanimliYol.equals(istenenYol) && !(tanimliYol + "/").equals(istenenYol)) {
                JsonYanit.yaz(ex, 404,
                        JsonYanit.hatali("YOL_YOK", "Böyle bir kaynak bulunmuyor.", true, null));
                return;
            }

            if (!beklenenYontem().equals(ex.getRequestMethod())) {
                ex.getResponseHeaders().set("Allow", beklenenYontem());
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
                    Object veri = isle(ex, conn);
                    if (veri == null) {
                        // Sözleşme her endpoint için gövde öngörür; null dönen bir
                        // handler protokol ihlalidir. Commit'ten ÖNCE fırlatılır ki
                        // istemci 500 alırken yazma kalıcı olmasın.
                        throw new IllegalStateException("Handler gövde üretmedi: "
                                + ex.getRequestURI().getPath());
                    }
                    conn.commit();
                    JsonYanit.yaz(ex, 200, JsonYanit.basarili(veri));
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
    protected abstract Object isle(HttpExchange ex, Connection conn) throws Exception;

    /** Bu endpoint'in kabul ettiği HTTP yöntemi. Sözleşmede GET/POST olarak sabittir. */
    protected String beklenenYontem() {
        return "GET";
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
            if (i <= 0) continue;
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
