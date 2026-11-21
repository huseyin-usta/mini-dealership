package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import tr.edu.etu.dealership.db.Veritabani;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * {@code POST /bot/randevu/{id}/iptal} — sözleşme: docs/api/bot-sozlesmesi.md §6
 *
 * <p>Randevu <b>silinmez</b>: durum {@code IPTAL} olur ve o saat yeniden açılır
 * ({@code EXCLUDE} kısıtları yalnız {@code IPTAL} olmayan satırları sayar).
 *
 * <p>Yalnızca müşterinin kendi, {@code PLANLANDI} ve başlamamış randevusu iptal
 * edilebilir. Geçmişte kalmış {@code PLANLANDI} kayıt (müşteri gelmedi, personel
 * henüz işaretlemedi) iptale kapatılır: aksi halde no-show kaydı silinebilirdi.
 *
 * <p><b>İzolasyon varsayımı:</b> yarışın son sözü {@code UPDATE ... AND durum =
 * 'PLANLANDI'} koşuludur; bu, READ COMMITTED'de (PostgreSQL varsayılanı) geçerlidir.
 * REPEATABLE READ'a geçilirse eşzamanlı iptal 40001 (serialization) üretir.
 */
public final class RandevuIptalHandler extends BotHandler {

    private static final Pattern YOL = Pattern.compile("^/bot/randevu/(\\d+)/iptal/?$");

    private static final String IPTAL_SQL = """
            UPDATE randevu
               SET durum = 'IPTAL'
             WHERE randevu_id = ? AND musteri_id = fn_aktif_musteri_id()
               AND durum = 'PLANLANDI'
               AND baslangic >= (now() AT TIME ZONE 'Europe/Istanbul')
            RETURNING randevu_id
            """;

    // DİKKAT: FOR UPDATE kullanılmaz. Kilit, RLS'nin UPDATE politikasına tabidir ve
    // o politika yalnız durum='PLANLANDI' satırlarını kapsar; IPTAL/TAMAMLANDI bir
    // satır kilit sorgusunda görünmez ve yanlışlıkla 404 dönerdi.
    private static final String DURUM_SQL = """
            SELECT durum,
                   (baslangic < (now() AT TIME ZONE 'Europe/Istanbul')) AS basladi
              FROM randevu
             WHERE randevu_id = ? AND musteri_id = fn_aktif_musteri_id()
            """;

    public RandevuIptalHandler(Veritabani db, BotTokeni token) {
        super(db, token);
    }

    @Override
    protected String beklenenYontem() {
        return "POST";
    }

    @Override
    protected boolean yolGecerliMi(String tanimliYol, String istenenYol) {
        return YOL.matcher(istenenYol).matches();
    }

    @Override
    protected Object isle(HttpExchange ex, Connection conn) throws Exception {
        Matcher m = YOL.matcher(ex.getRequestURI().getPath());
        if (!m.matches()) {
            throw ApiHatasi.goster("YOL_YOK", "Böyle bir kaynak bulunmuyor.", 404, null);
        }

        long randevuId;
        try {
            randevuId = Long.parseLong(m.group(1));
        } catch (NumberFormatException e) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    "randevu id sayısal aralık dışında.", 400, null);
        }

        // Önce iptali dene: mutlu yol tek sorgu. 0 satır dönerse nedenini ara.
        try (PreparedStatement ps = conn.prepareStatement(IPTAL_SQL)) {
            ps.setLong(1, randevuId);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    return basarili(randevuId);
                }
            }
        }

        String durum = null;
        boolean basladi = false;
        try (PreparedStatement ps = conn.prepareStatement(DURUM_SQL)) {
            ps.setLong(1, randevuId);
            try (ResultSet rs = ps.executeQuery()) {
                if (rs.next()) {
                    durum = rs.getString("durum");
                    // Zaman karşılaştırması DB'de yapılır: "geçmiş" iddiası ölçülür,
                    // Java/DB saat dilimi farkından etkilenmez.
                    basladi = rs.getBoolean("basladi");
                }
            }
        }

        if (durum == null) {
            // RLS başka müşterinin satırını göstermez; "yok" ile "başkasının"
            // aynı yanıtı alır (varlık sızdırmaz).
            throw ApiHatasi.goster("RANDEVU_YOK",
                    "Böyle bir randevunuz bulunmuyor.", 404, null);
        }

        Map<String, Object> detay = new LinkedHashMap<>();
        detay.put("durum", durum);

        if (!"PLANLANDI".equals(durum)) {
            throw ApiHatasi.goster("IPTAL_EDILEMEZ",
                    "Bu randevu iptal edilemez; durumu: " + durumAdi(durum) + ".",
                    409, detay);
        }

        if (basladi) {
            // PLANLANDI ama başlangıcı geçmiş: no-show kaydı personelin işidir.
            detay.put("sebep", "GECMIS");
            throw ApiHatasi.goster("IPTAL_EDILEMEZ",
                    "Başlamış bir randevu iptal edilemez; lütfen şubeyle iletişime geçin.",
                    409, detay);
        }

        // Teorik: PLANLANDI + başlamamış ama UPDATE 0 satır (arada durum değişti).
        throw ApiHatasi.goster("IPTAL_EDILEMEZ",
                "Bu randevu iptal edilemez.", 409, detay);
    }

    private static Object basarili(long randevuId) {
        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("randevu_id", randevuId);
        veri.put("durum", "IPTAL");
        veri.put("bilgi", "Randevunuz iptal edildi; o saat yeniden müsait.");
        return veri;
    }

    private static String durumAdi(String kod) {
        if (kod == null) return "Bilinmiyor";
        return switch (kod) {
            case "PLANLANDI"  -> "Planlandı";
            case "TAMAMLANDI" -> "Tamamlandı";
            case "IPTAL"      -> "İptal edildi";
            case "GELMEDI"    -> "Gelmedi";
            default           -> kod;
        };
    }
}
