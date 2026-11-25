package tr.edu.etu.dealership.panel;

import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;
import tr.edu.etu.dealership.web.ApiHatasi;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.sql.Types;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Randevu uçları (sözleşme §3–5): listeleme, ekleme, durum değişikliği.
 *
 * <p>Kurallar (mesai, tür saat penceresi, çalışan şubesi/departmanı/yetkinliği,
 * çakışma) DB'de: trigger ({@code 220_trg_randevu_dogrula}) ve EXCLUDE
 * kısıtları. Handler bunları tekrar yazmaz, DB hatasını sözleşme koduna çevirir.
 */
public final class RandevuPanelHandler extends PanelHandler {

    static final ZoneId ISTANBUL = ZoneId.of("Europe/Istanbul");
    private static final String TELEFON_DESENI = "^\\+[1-9]\\d{7,14}$";
    private static final Set<String> DURUMLAR = Set.of("PLANLANDI", "TAMAMLANDI", "IPTAL", "GELMEDI");
    private static final String EXCLUSION_VIOLATION = "23P01";
    private static final String TRIGGER_HATASI = "P0001";

    /** Liste ve tekil yanıtın ortak satır biçimi. */
    private static final String SATIR = """
            SELECT r.randevu_id, r.baslangic, r.bitis, r.durum, r.kaynak,
                   r.tur_kodu, rt.ad AS tur_adi, r.sube_id,
                   r.calisan_id, c.ad || ' ' || c.soyad AS calisan,
                   r.musteri_id, nullif(concat_ws(' ', mu.ad, mu.soyad), '') AS musteri,
                   mu.telefon, r.arac_vin, a.plaka, mo.ad AS model_adi, r.notlar
              FROM randevu r
              JOIN randevu_turu rt ON rt.tur_kodu = r.tur_kodu
              JOIN calisan c       ON c.calisan_id = r.calisan_id
              JOIN musteri mu      ON mu.musteri_id = r.musteri_id
              LEFT JOIN arac a     ON a.vin = r.arac_vin
              LEFT JOIN versiyon v ON v.versiyon_id = a.versiyon_id
              LEFT JOIN model mo   ON mo.model_id = v.model_id
            """;

    public RandevuPanelHandler(PanelVeritabani db, Oturumlar oturumlar) {
        super(db, oturumlar);
        rota("GET", "/panel/randevu", Rol.PERSONEL, this::listele);
    }

    // ---- §3 Listeleme -----------------------------------------------------------

    private Object listele(Istek i) throws Exception {
        i.yalnizca(Set.of("tarih", "sube_id", "tur_kodu", "durum", "calisan_id", "limit", "sayfa"));
        LocalDate tarih = i.tarihParam("tarih");
        if (tarih == null) tarih = LocalDate.now(ISTANBUL);
        Integer subeId = i.sayiParam("sube_id");
        if (subeId == null) subeId = i.oturum().subeId();
        String turKodu = i.metinParam("tur_kodu");
        String durum = i.secimParam("durum", DURUMLAR);
        Integer calisanId = i.sayiParam("calisan_id");
        int limit = i.limit();
        int sayfa = i.sayfa();

        String kosul = """
                 WHERE r.sube_id = ?
                   AND r.baslangic >= ? AND r.baslangic < ?
                   AND (?::varchar IS NULL OR r.tur_kodu = ?)
                   AND (?::varchar IS NULL OR r.durum = ?)
                   AND (?::int IS NULL OR r.calisan_id = ?)
                """;
        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("tarih", tarih.toString());
        veri.put("sube_id", subeId);
        try (PreparedStatement ps = i.conn().prepareStatement(
                "SELECT count(*) FROM randevu r" + kosul)) {
            listeParametreleri(ps, subeId, tarih, turKodu, durum, calisanId);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                veri.put("toplam", rs.getLong(1));
            }
        }
        try (PreparedStatement ps = i.conn().prepareStatement(
                SATIR + kosul + " ORDER BY r.baslangic, r.randevu_id LIMIT ? OFFSET ?")) {
            int n = listeParametreleri(ps, subeId, tarih, turKodu, durum, calisanId);
            ps.setInt(n++, limit);
            ps.setLong(n, (long) (sayfa - 1) * limit);
            veri.put("randevular", Satirlar.liste(ps));
        }
        return veri;
    }

    private static int listeParametreleri(PreparedStatement ps, int subeId, LocalDate tarih,
                                          String turKodu, String durum, Integer calisanId)
            throws SQLException {
        int n = 1;
        ps.setInt(n++, subeId);
        ps.setTimestamp(n++, Timestamp.valueOf(tarih.atStartOfDay()));
        ps.setTimestamp(n++, Timestamp.valueOf(tarih.plusDays(1).atStartOfDay()));
        ps.setString(n++, turKodu);
        ps.setString(n++, turKodu);
        ps.setString(n++, durum);
        ps.setString(n++, durum);
        if (calisanId == null) {
            ps.setNull(n++, Types.INTEGER);
            ps.setNull(n++, Types.INTEGER);
        } else {
            ps.setInt(n++, calisanId);
            ps.setInt(n++, calisanId);
        }
        return n;
    }

    // ---- Yardımcılar ------------------------------------------------------------------

    private static Map<String, Object> tekRandevu(Connection c, int id) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(SATIR + " WHERE r.randevu_id = ?")) {
            ps.setInt(1, id);
            List<Map<String, Object>> l = Satirlar.liste(ps);
            return l.get(0);
        }
    }

    static Integer tekSayi(Connection c, String sql, Object param) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setObject(1, param);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getInt(1) : null;
            }
        }
    }
}
