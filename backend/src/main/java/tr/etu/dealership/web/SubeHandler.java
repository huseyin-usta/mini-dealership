package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import tr.edu.etu.dealership.db.Veritabani;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * {@code GET /bot/sube} — sözleşme: docs/api/bot-sozlesmesi.md
 *
 * <p>Şehir verilmezse yalnızca şehir adları; verilirse o şehirdeki şubeler.
 * Şehir adı <b>tam eşleşme</b> ile aranır; yanlış yazımda hata yanıtındaki
 * {@code detay.mevcut_sehirler} alanı LLM'in düzeltmesini sağlar.
 */
public final class SubeHandler extends BotHandler {

    private static final String SEHIR_LISTESI_SQL =
            "SELECT DISTINCT sehir FROM sube ORDER BY sehir";

    private static final String SUBE_LISTESI_SQL =
            "SELECT sube_id, ad FROM sube WHERE sehir = ? ORDER BY ad";

    public SubeHandler(Veritabani db) {
        super(db);
    }

    @Override
    protected Object isle(HttpExchange ex, Connection conn) throws Exception {
        String sehir = parametreler(ex).get("sehir");

        if (sehir == null || sehir.isBlank()) {
            return Map.of("sehirler", sehirListesi(conn));
        }

        List<Map<String, Object>> subeler = subeListesi(conn, sehir);
        if (subeler.isEmpty()) {
            throw ApiHatasi.goster(
                    "SEHIRDE_SUBE_YOK",
                    "Bu şehirde şubemiz bulunmuyor.",
                    404,
                    Map.of("mevcut_sehirler", sehirListesi(conn))
            );
        }

        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("sehir", sehir);
        veri.put("subeler", subeler);
        return veri;
    }

    private List<String> sehirListesi(Connection conn) throws Exception {
        List<String> sehirler = new ArrayList<>();
        try (PreparedStatement ps = conn.prepareStatement(SEHIR_LISTESI_SQL);
             ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                sehirler.add(rs.getString(1));
            }
        }
        return sehirler;
    }

    private List<Map<String, Object>> subeListesi(Connection conn, String sehir) throws Exception {
        List<Map<String, Object>> subeler = new ArrayList<>();
        try (PreparedStatement ps = conn.prepareStatement(SUBE_LISTESI_SQL)) {
            ps.setString(1, sehir);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    Map<String, Object> s = new LinkedHashMap<>();
                    s.put("sube_id", rs.getInt("sube_id"));
                    s.put("ad", rs.getString("ad"));
                    subeler.add(s);
                }
            }
        }
        return subeler;
    }
}
