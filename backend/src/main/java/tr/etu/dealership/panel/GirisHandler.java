package tr.edu.etu.dealership.panel;

import org.mindrot.jbcrypt.BCrypt;
import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;
import tr.edu.etu.dealership.web.ApiHatasi;

import java.net.InetSocketAddress;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * {@code POST /panel/giris} ve {@code POST /panel/cikis} (sözleşme §1).
 *
 * <p>Şifre hash'i {@code fn_panel_giris()} (SECURITY DEFINER) ile okunur:
 * {@code personel} rolü {@code calisan.sifre_hash} kolonunu doğrudan okuyamaz.
 * Kullanıcı adı yoksa da bcrypt çalıştırılır; yanıt süresinden hangi adların
 * var olduğu anlaşılmasın.
 *
 * <p>DoS sertleştirmesi: IP başına deneme sınırı (429), giriş gövdesi 4 KB,
 * bcrypt kısa DB bağlantısı kapandıktan sonra çalışır (havuz meşgul edilmez).
 */
public final class GirisHandler extends PanelHandler {

    /** Var olmayan kullanıcı için zamanlama dengesi: geçerli biçimde, hiçbir şifreye uymayan hash. */
    private static final String SAHTE_HASH = BCrypt.hashpw("kullanilmayan", BCrypt.gensalt(10));
    private static final DateTimeFormatter ZAMAN =
            DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm").withZone(ZoneId.of("Europe/Istanbul"));
    private static final int GIRIS_GOVDE_SINIRI = 4 * 1024;

    public GirisHandler(PanelVeritabani db, Oturumlar oturumlar) {
        super(db, oturumlar);
        // Bu iki rota kendi bağlantısını yönetir: bcrypt açık bağlantı tutmadan çalışsın.
        rota("POST", "/panel/giris", Rol.PERSONEL, this::giris, GIRIS_GOVDE_SINIRI, false);
        rota("POST", "/panel/cikis", Rol.PERSONEL, this::cikis, 1024, false);
    }

    @Override
    protected boolean oturumGerekli() {
        return false;
    }

    private Object giris(Istek i) throws Exception {
        // Kullanıcı adından bağımsız sınır: her istek bcrypt çalıştırmasın.
        if (!oturumlar.ipIzinli(istemciIp(i.exchange()))) {
            throw ApiHatasi.goster("COK_DENEME",
                    "Çok fazla giriş denemesi. Bir dakika sonra tekrar deneyin.", 429, null);
        }

        i.alanlar(Set.of("kullanici_adi", "sifre"));
        String kadi = i.zorunluMetin("kullanici_adi", 64);
        // Şifre trim edilmez: boşluk anlamlıdır (bcrypt 72 bayttan sonrasını yok sayar).
        String sifre = i.hamZorunluMetin("sifre", 72);

        if (oturumlar.kilitliMi(kadi)) {
            throw ApiHatasi.goster("COK_DENEME",
                    "Çok fazla hatalı giriş. Bir dakika sonra tekrar deneyin.", 429, null);
        }

        Integer calisanId = null;
        int subeId = 0;
        String departman = null;
        String ad = null;
        String soyad = null;
        String hash = SAHTE_HASH;

        // Kısa bağlantı: sorgular bitince kapanır, bcrypt havuz dışında çalışır.
        try (Connection conn = db.baglanti(Rol.PERSONEL)) {
            try (PreparedStatement ps = conn.prepareStatement(
                    "SELECT g.calisan_id, g.sube_id, g.departman, g.sifre_hash, c.ad, c.soyad"
                            + "  FROM fn_panel_giris(?) g"
                            + "  JOIN calisan c ON c.calisan_id = g.calisan_id")) {
                ps.setString(1, kadi);
                try (ResultSet rs = ps.executeQuery()) {
                    if (rs.next()) {
                        calisanId = rs.getInt(1);
                        subeId = rs.getInt(2);
                        departman = rs.getString(3);
                        hash = rs.getString(4);
                        ad = rs.getString(5);
                        soyad = rs.getString(6);
                    }
                }
            }
            conn.commit();
        }

        boolean dogru = sifreDogruMu(sifre, hash) && calisanId != null;
        if (!dogru) {
            oturumlar.hataliGiris(kadi);
            throw ApiHatasi.goster("GIRIS_HATALI", "Kullanıcı adı veya şifre hatalı.", 401, null);
        }
        oturumlar.basariliGiris(kadi);

        String anahtar = oturumlar.ac(calisanId, subeId, departman, ad, soyad);
        Oturumlar.Oturum o = oturumlar.bul(anahtar).orElseThrow();

        Map<String, Object> calisan = new LinkedHashMap<>();
        calisan.put("calisan_id", calisanId);
        calisan.put("ad", ad);
        calisan.put("soyad", soyad);
        calisan.put("sube_id", subeId);
        calisan.put("departman", departman);
        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("oturum", anahtar);
        veri.put("son_kullanma", ZAMAN.format(o.sonKullanma()));
        veri.put("calisan", calisan);
        return veri;
    }

    private Object cikis(Istek i) {
        oturumlar.kapat(bearer(i.exchange()));
        return Map.of("cikis", true);
    }

    /** Bozuk/sahte hash (ör. sentetik veri) istisna değil, yanlış şifre sayılır. */
    private static boolean sifreDogruMu(String sifre, String hash) {
        try {
            return hash != null && BCrypt.checkpw(sifre, hash);
        } catch (IllegalArgumentException e) {
            return false;
        }
    }

    /** İstemci IP'si; ters vekil yok (panel doğrudan dinler). */
    private static String istemciIp(com.sun.net.httpserver.HttpExchange ex) {
        InetSocketAddress uzak = ex.getRemoteAddress();
        return uzak == null || uzak.getAddress() == null
                ? "?" : uzak.getAddress().getHostAddress();
    }
}
