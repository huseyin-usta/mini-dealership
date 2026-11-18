package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import tr.edu.etu.dealership.db.BotKimligi;
import tr.edu.etu.dealership.db.Veritabani;

import java.io.IOException;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Map;
import java.util.logging.Level;
import java.util.logging.Logger;

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

    private static final Logger LOG = Logger.getLogger(BotHandler.class.getName());

    protected final Veritabani db;

    protected BotHandler(Veritabani db) {
        this.db = db;
    }

    @Override
    public final void handle(HttpExchange ex) throws IOException {
        try {
            if (!"GET".equals(ex.getRequestMethod()) && !"POST".equals(ex.getRequestMethod())) {
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
                    BotKimligi.ata(conn, telefon.trim());
                    Object veri = isle(ex, conn);
                    conn.commit();
                    if (veri != null) {
                        JsonYanit.yaz(ex, 200, JsonYanit.basarili(veri));
                    }
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
            LOG.log(Level.SEVERE, "Veritabanı hatası: " + ex.getRequestURI(), e);
            JsonYanit.yaz(ex, 503,
                    JsonYanit.hatali("SISTEM_HATASI", "Şu an hizmet veremiyorum.", true, null));
        } catch (Exception e) {
            LOG.log(Level.SEVERE, "Beklenmedik hata: " + ex.getRequestURI(), e);
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

    /** Query parametrelerini okur (kodlama çözülmüş). */
    protected static Map<String, String> parametreler(HttpExchange ex) {
        Map<String, String> sonuc = new HashMap<>();
        String q = ex.getRequestURI().getRawQuery();
        if (q == null || q.isEmpty()) return sonuc;
        for (String parca : q.split("&")) {
            int i = parca.indexOf('=');
            if (i <= 0) continue;
            sonuc.put(decode(parca.substring(0, i)), decode(parca.substring(i + 1)));
        }
        return sonuc;
    }

    private static String decode(String s) {
        return java.net.URLDecoder.decode(s, java.nio.charset.StandardCharsets.UTF_8);
    }
}
