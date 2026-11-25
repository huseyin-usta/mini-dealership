package tr.edu.etu.dealership.panel;

import org.mindrot.jbcrypt.BCrypt;
import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;
import tr.edu.etu.dealership.web.ApiHatasi;

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
 */
public final class GirisHandler extends PanelHandler {

    /** Var olmayan kullanıcı için zamanlama dengesi: geçerli biçimde, hiçbir şifreye uymayan hash. */
    private static final String SAHTE_HASH = BCrypt.hashpw("kullanilmayan", BCrypt.gensalt(10));
    private static final DateTimeFormatter ZAMAN =
            DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm").withZone(ZoneId.of("Europe/Istanbul"));

    public GirisHandler(PanelVeritabani db, Oturumlar oturumlar) {
        super(db, oturumlar);
        rota("POST", "/panel/giris", Rol.PERSONEL, this::giris);
        rota("POST", "/panel/cikis", Rol.PERSONEL, this::cikis);
    }

    @Override
    protected boolean oturumGerekli() {
        return false;
    }

    private Object giris(Istek i) throws Exception {
        i.alanlar(Set.of("kullanici_adi", "sifre"));
        String kadi = i.zorunluMetin("kullanici_adi", 64);
        String sifre = i.zorunluMetin("sifre", 72);   // bcrypt 72 bayttan sonrasını yok sayar

        if (oturumlar.kilitliMi(kadi)) {
            throw ApiHatasi.goster("COK_DENEME",
                    "Çok fazla hatalı giriş. Bir dakika sonra tekrar deneyin.", 429, null);
        }

        Integer calisanId = null;
        int subeId = 0;
        String departman = null;
        String hash = SAHTE_HASH;
        try (PreparedStatement ps = i.conn().prepareStatement(
                "SELECT calisan_id, sube_id, departman, sifre_hash FROM fn_panel_giris(?)")) {
            ps.setString(1, kadi);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    calisanId = rs.getInt(1);
                    subeId = rs.getInt(2);
                    departman = rs.getString(3);
                    hash = rs.getString(4);
                }
            }
        }

        boolean dogru = sifreDogruMu(sifre, hash) && calisanId != null;
        if (!dogru) {
            oturumlar.hataliGiris(kadi);
            throw ApiHatasi.goster("GIRIS_HATALI", "Kullanıcı adı veya şifre hatalı.", 401, null);
        }
        oturumlar.basariliGiris(kadi);

        String ad;
        String soyad;
        try (PreparedStatement ps = i.conn().prepareStatement(
                "SELECT ad, soyad FROM calisan WHERE calisan_id = ?")) {
            ps.setInt(1, calisanId);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                ad = rs.getString(1);
                soyad = rs.getString(2);
            }
        }

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
}
