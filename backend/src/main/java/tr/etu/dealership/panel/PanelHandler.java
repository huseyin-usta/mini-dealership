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
import java.sql.PreparedStatement;
import java.sql.ResultSet;
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

    private record Rota(String yontem, Pattern desen, Rol rol, Islem islem,
                        boolean baglantiGerekli, int govdeSiniri) {
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
        rota(yontem, desen, rol, islem, AZAMI_GOVDE, true);
    }

    /**
     * Bağlantı tutmayan / küçük gövdeli rotalar için.
     *
     * <p>{@code baglantiGerekli=false}: handler kendi kısa bağlantısını açar.
     * Girişte bcrypt, havuz bağlantısı tutulurken çalışmasın diye kullanılır.
     */
    protected final void rota(String yontem, String desen, Rol rol, Islem islem,
                              int govdeSiniri, boolean baglantiGerekli) {
        rotalar.add(new Rota(yontem, Pattern.compile(desen + "/?"), rol, islem,
                baglantiGerekli, Math.min(govdeSiniri, AZAMI_GOVDE)));
    }

    /** Giriş ucu oturum istemez; diğer her şey ister. */
    protected boolean oturumGerekli() {
        return true;
    }

    @Override
    public final void handle(HttpExchange ex) throws IOException {
        try {
            Oturumlar.Oturum oturum = null;
            String anahtar = bearer(ex);
            if (oturumGerekli()) {
                Optional<Oturumlar.Oturum> o = oturumlar.bul(anahtar);
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
            int govdeSiniri = secilen.govdeSiniri();
            byte[] govde = "POST".equals(ex.getRequestMethod())
                    ? ex.getRequestBody().readNBytes(govdeSiniri + 1)
                    : null;
            Istek istek = new Istek(ex, oturum, eslesme, govde, govdeSiniri);
            istek.parametreler();   // tekrarlanan parametre bağlantı alınmadan reddedilsin

            if (!secilen.baglantiGerekli()) {
                // Handler kendi kısa bağlantısını yönetir (giriş: bcrypt bağlantı dışında).
                yanitYaz(ex, secilen.islem().calistir(istek));
                return;
            }

            try (Connection conn = db.baglanti(secilen.rol())) {
                try {
                    istek.baglan(conn);
                    // İşten ayrılan çalışanın oturumu 8 saat yaşamasın: her istekte doğrula.
                    if (oturum != null && !calisanAktifMi(conn, secilen.rol(), oturum.calisanId())) {
                        oturumlar.kapat(anahtar);
                        throw ApiHatasi.goster("OTURUM_YOK",
                                "Oturum açılmamış veya süresi dolmuş.", 401, null);
                    }
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
            ex.getResponseHeaders().set("X-Content-Type-Options", "nosniff");
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

    /**
     * Oturumdaki çalışan hâlâ aktif mi? (ayrılan çalışanın oturumu yaşamasın)
     *
     * <p>{@code rapor} rolü {@code calisan} tablosunu okuyamaz; bu rol için
     * kontrol kısa süreliğine {@code personel} rolüyle yapılır, sonra istenen
     * role dönülür (transaction içi, commit'te sıfırlanır).
     */
    private static boolean calisanAktifMi(Connection conn, Rol rol, int calisanId) throws SQLException {
        boolean rolDegisti = rol == Rol.RAPOR;
        if (rolDegisti) setRole(conn, Rol.PERSONEL);
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT aktif_mi FROM calisan WHERE calisan_id = ?")) {
            ps.setInt(1, calisanId);
            try (ResultSet rs = ps.executeQuery()) {
                boolean aktif = rs.next() && rs.getBoolean(1);
                if (rolDegisti) setRole(conn, rol);
                return aktif;
            }
        }
    }

    private static void setRole(Connection conn, Rol rol) throws SQLException {
        try (var st = conn.createStatement()) {
            st.execute("SET LOCAL ROLE " + rol.ad());
        }
    }

    private static void hataYaz(HttpExchange ex, int durum, String kod, String mesaj, Object detay)
            throws IOException {
        ex.getResponseHeaders().set("Cache-Control", "no-store");
        JsonYanit.yaz(ex, durum, JsonYanit.hatali(kod, mesaj, true, detay));
    }
}
