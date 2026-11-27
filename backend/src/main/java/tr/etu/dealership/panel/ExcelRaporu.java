package tr.edu.etu.dealership.panel;

import org.dhatim.fastexcel.Workbook;
import org.dhatim.fastexcel.Worksheet;
import tr.edu.etu.dealership.web.ApiHatasi;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.List;
import java.util.Map;

/**
 * Randevu raporunun .xlsx dosyası (sözleşme §12). Tek yönlüdür: yalnızca
 * DB → Excel; içe aktarma yok. {@code rapor} rolüyle, maskeli
 * {@code v_rapor_randevu} view'ından okunur — dosyaya PII çıkmaz.
 */
final class ExcelRaporu {

    private static final String ZAMAN_BICIMI = "yyyy-mm-dd hh:mm";

    /** Sütunlar: başlık ve view'daki kolon. */
    private static final String[][] SUTUNLAR = {
            {"Randevu No", "randevu_id"},
            {"Başlangıç", "baslangic"},
            {"Bitiş", "bitis"},
            {"Durum", "durum"},
            {"Kaynak", "kaynak"},
            {"Tür", "tur_adi"},
            {"Departman", "departman"},
            {"Şehir", "sehir"},
            {"Şube", "sube_adi"},
            {"Çalışan", "calisan"},
            {"Araç (VIN)", "arac_vin"},
            {"Model", "model_adi"},
            {"Paket", "paket_adi"},
            {"Müşteri (maskeli)", "musteri"},
            {"Telefon (maskeli)", "musteri_telefon"},
    };

    private ExcelRaporu() {
    }

    static byte[] uret(Connection c, RaporPanelHandler.Aralik a) throws SQLException, IOException {
        try (PreparedStatement ps = c.prepareStatement(
                "SELECT count(*) FROM v_rapor_randevu r WHERE" + RaporPanelHandler.Aralik.KOSUL)) {
            a.bagla(ps, 1);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                if (rs.getLong(1) > RaporPanelHandler.AZAMI_SATIR) {
                    throw ApiHatasi.goster("ARALIK_COK_GENIS",
                            "Rapor en fazla " + RaporPanelHandler.AZAMI_SATIR
                                    + " randevu içerebilir; aralığı daraltın.", 400, null);
                }
            }
        }

        ByteArrayOutputStream cikti = new ByteArrayOutputStream();
        Workbook wb = new Workbook(cikti, "MiniDealership", "1.0");
        randevular(wb.newWorksheet("Randevular"), c, a);
        ozet(wb.newWorksheet("Özet"), RaporPanelHandler.ozet(c, a), a);
        wb.finish();
        return cikti.toByteArray();
    }

    private static void randevular(Worksheet ws, Connection c, RaporPanelHandler.Aralik a)
            throws SQLException {
        for (int k = 0; k < SUTUNLAR.length; k++) {
            ws.value(0, k, SUTUNLAR[k][0]);
            ws.style(0, k).bold().fillColor("DDEBF7").set();
        }
        ws.freezePane(0, 1);
        StringBuilder kolonlar = new StringBuilder();
        for (String[] s : SUTUNLAR) {
            if (kolonlar.length() > 0) kolonlar.append(", ");
            kolonlar.append("r.").append(s[1]);
        }
        try (PreparedStatement ps = c.prepareStatement("SELECT " + kolonlar
                + " FROM v_rapor_randevu r WHERE" + RaporPanelHandler.Aralik.KOSUL
                + " ORDER BY r.baslangic, r.randevu_id LIMIT "
                + (RaporPanelHandler.AZAMI_SATIR + 1))) {
            a.bagla(ps, 1);
            ps.setFetchSize(1000);   // satırlar akışla gelir, hepsi belleğe alınmaz
            try (ResultSet rs = ps.executeQuery()) {
                int satir = 1;
                while (rs.next()) {
                    // count ile select arasında satır eklenirse sınırı burada da uygula.
                    if (satir > RaporPanelHandler.AZAMI_SATIR) {
                        throw ApiHatasi.goster("ARALIK_COK_GENIS",
                                "Rapor en fazla " + RaporPanelHandler.AZAMI_SATIR
                                        + " randevu içerebilir; aralığı daraltın.", 400, null);
                    }
                    for (int k = 0; k < SUTUNLAR.length; k++) {
                        Object v = rs.getObject(k + 1);
                        if (v == null) continue;
                        if (v instanceof Timestamp t) {
                            ws.value(satir, k, t.toLocalDateTime());
                            ws.style(satir, k).format(ZAMAN_BICIMI).set();
                        } else if (v instanceof Number n) {
                            ws.value(satir, k, n);
                        } else {
                            ws.value(satir, k, v.toString());
                        }
                    }
                    satir++;
                }
            }
        }
        int[] genislik = {11, 17, 17, 12, 11, 20, 11, 12, 14, 20, 20, 12, 12, 18, 18};
        for (int k = 0; k < genislik.length; k++) ws.width(k, genislik[k]);
    }

    @SuppressWarnings("unchecked")
    private static void ozet(Worksheet ws, Map<String, Object> ozet, RaporPanelHandler.Aralik a) {
        int r = 0;
        ws.value(r, 0, "Randevu raporu");
        ws.style(r, 0).bold().fontSize(14).set();
        r++;
        ws.value(r++, 0, "Aralık: " + a.baslangic() + " – " + a.bitis()
                + (a.subeId() == null ? " (tüm şubeler)" : " (şube " + a.subeId() + ")"));
        r++;

        Map<String, Object> genel = (Map<String, Object>) ozet.get("ozet");
        r = baslik(ws, r, "Genel", "Ölçüt", "Değer");
        String[][] olcutler = {
                {"Toplam randevu", "toplam"}, {"Planlandı", "planlandi"},
                {"Tamamlandı", "tamamlandi"}, {"İptal", "iptal"}, {"Gelmedi", "gelmedi"},
                {"İptal oranı (%)", "iptal_yuzde"}, {"Gelmeme oranı (%)", "gelmeme_yuzde"},
        };
        for (String[] o : olcutler) {
            ws.value(r, 0, o[0]);
            hucre(ws, r++, 1, genel.get(o[1]));
        }
        r++;
        r = tablo(ws, r, "Şube doluluk sıralaması", (List<Map<String, Object>>) ozet.get("sube_doluluk"),
                new String[][]{{"Sıra", "sira"}, {"Şehir", "sehir"}, {"Şube", "sube_adi"},
                        {"Randevu", "randevu"}, {"Tamamlanan", "tamamlanan"}});
        r = tablo(ws, r, "Randevu türleri", (List<Map<String, Object>>) ozet.get("tur_dagilimi"),
                new String[][]{{"Tür", "tur_adi"}, {"Departman", "departman"}, {"Adet", "adet"}});
        r = tablo(ws, r, "Kaynak", (List<Map<String, Object>>) ozet.get("kaynak_dagilimi"),
                new String[][]{{"Kaynak", "kaynak"}, {"Adet", "adet"}, {"Yüzde", "yuzde"}});
        tablo(ws, r, "Test sürüşünden satışa dönüşüm (60 gün)",
                (List<Map<String, Object>>) ozet.get("test_surusu_donusum"),
                new String[][]{{"Model", "model_adi"}, {"Test sürüşü", "test_surusu"},
                        {"Satışa dönen", "satisa_donen"}});
        ws.width(0, 28);
        for (int k = 1; k < 5; k++) ws.width(k, 16);
    }

    private static int baslik(Worksheet ws, int r, String ad, String... sutunlar) {
        ws.value(r, 0, ad);
        ws.style(r, 0).bold().fontSize(12).set();
        r++;
        for (int k = 0; k < sutunlar.length; k++) {
            ws.value(r, k, sutunlar[k]);
            ws.style(r, k).bold().fillColor("DDEBF7").set();
        }
        return r + 1;
    }

    private static int tablo(Worksheet ws, int r, String ad, List<Map<String, Object>> satirlar,
                             String[][] sutunlar) {
        String[] basliklar = new String[sutunlar.length];
        for (int k = 0; k < sutunlar.length; k++) basliklar[k] = sutunlar[k][0];
        r = baslik(ws, r, ad, basliklar);
        for (Map<String, Object> s : satirlar) {
            for (int k = 0; k < sutunlar.length; k++) hucre(ws, r, k, s.get(sutunlar[k][1]));
            r++;
        }
        return r + 1;
    }

    private static void hucre(Worksheet ws, int r, int k, Object v) {
        if (v == null) return;
        if (v instanceof Number n) ws.value(r, k, n); else ws.value(r, k, v.toString());
    }
}
