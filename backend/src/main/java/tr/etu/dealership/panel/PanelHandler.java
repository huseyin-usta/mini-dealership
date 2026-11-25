package tr.edu.etu.dealership.panel;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;
import tr.edu.etu.dealership.web.ApiHatasi;
import tr.edu.etu.dealership.web.JsonYanit;

import java.io.IOException;
import java.io.OutputStream;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Panel uçlarının ortak iskeleti (docs/api/panel-sozlesmesi.md).
 *
 * <p>Alt sınıf yalnızca rotalarını ({@link #rota}) tanımlar. Bu sınıf şunları
 * garanti eder:
 * <ul>
 *   <li>Oturum her şeyden önce doğrulanır: geçersizse hiçbir sorgu çalışmaz ve
 *       yolun/yöntemin varlığı hakkında bilgi verilmez</li>
 *   <li>Her rota kendi DB rolüyle ({@code personel} / {@code rapor}) çalışır</li>
 *   <li>İş biter → commit; hata → rollback</li>
 *   <li>{@link ApiHatasi} sözleşmedeki zarfa çevrilir; beklenmedik hata loglanır,
 *       istemciye yalnızca SISTEM_HATASI gider</li>
 * </ul>
 */
public abstract class PanelHandler implements HttpHandler {

    private static final Logger LOG = LoggerFactory.getLogger(PanelHandler.class);
    private static final int AZAMI_GOVDE = 64 * 1024;

    /** Bir rotanın iş mantığı. */
    @FunctionalInterface
    protected interface Islem {
        Object calistir(Istek istek) throws Exception;
    }

    /** Varsayılan 200 dışında durum kodu gerektiren yanıt (ör. 201). */
    protected record Yanit(int durum, Object veri) {
    }

    /** JSON zarfı olmayan dosya yanıtı (Excel). */
    protected record Dosya(byte[] icerik, String turu, String ad) {
    }

    private record Rota(String yontem, Pattern desen, Rol rol, Islem islem) {
    }

    protected final PanelVeritabani db;
    protected final Oturumlar oturumlar;
    private final List<Rota> rotalar = new ArrayList<>();

    protected PanelHandler(PanelVeritabani db, Oturumlar oturumlar) {
        this.db = db;
        this.oturumlar = oturumlar;
    }

    /**
     * Rota tanımlar. {@code desen} yolun tamamıyla eşleşir; sondaki eğik çizgi
     * kabul edilir. Gruplar {@link Istek#yolSayi(int)} ile okunur.
     */
    protected final void rota(String yontem, String desen, Rol rol, Islem islem) {
        rotalar.add(new Rota(yontem, Pattern.compile(desen + "/?"), rol, islem));
    }

    /** Giriş ucu oturum istemez; diğer her şey ister. */
    protected boolean oturumGerekli() {
        return true;
    }

    @Override
    public final void handle(HttpExchange ex) throws IOException {
        try {
            Oturumlar.Oturum oturum = null;
            if (oturumGerekli()) {
                Optional<Oturumlar.Oturum> o = oturumlar.bul(bearer(ex));
                if (o.isEmpty()) {
                    hataYaz(ex, 401, "OTURUM_YOK", "Oturum açılmamış veya süresi dolmuş.", null);
                    return;
                }
                oturum = o.get();
            }

            String yol = ex.getRequestURI().getPath();
            Set<String> izinli = new LinkedHashSet<>();
            Rota secilen = null;
            Matcher eslesme = null;
            for (Rota r : rotalar) {
                Matcher m = r.desen().matcher(yol);
                if (!m.matches()) continue;
                izinli.add(r.yontem());
                if (secilen == null && r.yontem().equals(ex.getRequestMethod())) {
                    secilen = r;
                    eslesme = m;
                }
            }
            if (izinli.isEmpty()) {
                hataYaz(ex, 404, "YOL_YOK", "Böyle bir kaynak bulunmuyor.", null);
                return;
            }
            if (secilen == null) {
                ex.getResponseHeaders().set("Allow", String.join(", ", izinli));
                hataYaz(ex, 405, "YONTEM_DESTEKLENMIYOR", "Bu yöntem desteklenmiyor.", null);
                return;
            }

            // Gövde bağlantı alınmadan önce okunur: yavaş istemci havuzu meşgul etmesin.
            byte[] govde = "POST".equals(ex.getRequestMethod())
                    ? ex.getRequestBody().readNBytes(AZAMI_GOVDE + 1)
                    : null;
            Istek istek = new Istek(ex, oturum, eslesme, govde, AZAMI_GOVDE);
            istek.parametreler();   // tekrarlanan parametre bağlantı alınmadan reddedilsin

            try (Connection conn = db.baglanti(secilen.rol())) {
                try {
                    istek.baglan(conn);
                    Object sonuc = secilen.islem().calistir(istek);
                    conn.commit();
                    yanitYaz(ex, sonuc);
                } catch (ApiHatasi e) {
                    conn.rollback();
                    hataYaz(ex, e.httpDurum(), e.kod(), e.getMessage(), e.detay());
                } catch (Exception e) {
                    conn.rollback();
                    throw e;
                }
            }
        } catch (ApiHatasi e) {
            hataYaz(ex, e.httpDurum(), e.kod(), e.getMessage(), e.detay());
        } catch (SQLException e) {
            LOG.error("Veritabanı hatası: {} {}", ex.getRequestMethod(), ex.getRequestURI().getPath(), e);
            hataYaz(ex, 500, "SISTEM_HATASI", "Beklenmedik bir hata oluştu.", null);
        } catch (Exception e) {
            LOG.error("Beklenmedik hata: {} {}", ex.getRequestMethod(), ex.getRequestURI().getPath(), e);
            hataYaz(ex, 500, "SISTEM_HATASI", "Beklenmedik bir hata oluştu.", null);
        } finally {
            ex.close();
        }
    }

    /** {@code Authorization: Bearer <anahtar>} başlığından anahtarı okur. */
    static String bearer(HttpExchange ex) {
        String b = ex.getRequestHeaders().getFirst("Authorization");
        if (b == null || !b.regionMatches(true, 0, "Bearer ", 0, 7)) return null;
        String anahtar = b.substring(7).trim();
        return anahtar.isEmpty() ? null : anahtar;
    }

    private static void yanitYaz(HttpExchange ex, Object sonuc) throws IOException {
        ex.getResponseHeaders().set("Cache-Control", "no-store");
        if (sonuc instanceof Dosya d) {
            ex.getResponseHeaders().set("Content-Type", d.turu());
            ex.getResponseHeaders().set("Content-Disposition",
                    "attachment; filename=\"" + d.ad() + "\"");
            ex.sendResponseHeaders(200, d.icerik().length);
            try (OutputStream os = ex.getResponseBody()) {
                os.write(d.icerik());
            }
            return;
        }
        int durum = 200;
        Object veri = sonuc;
        if (sonuc instanceof Yanit y) {
            durum = y.durum();
            veri = y.veri();
        }
        JsonYanit.yaz(ex, durum, JsonYanit.basarili(veri));
    }

    private static void hataYaz(HttpExchange ex, int durum, String kod, String mesaj, Object detay)
            throws IOException {
        ex.getResponseHeaders().set("Cache-Control", "no-store");
        JsonYanit.yaz(ex, durum, JsonYanit.hatali(kod, mesaj, true, detay));
    }
}
