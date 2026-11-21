package tr.edu.etu.dealership.web;

import com.sun.net.httpserver.HttpExchange;
import tr.edu.etu.dealership.db.MusteriDeposu;
import tr.edu.etu.dealership.db.Veritabani;

import java.sql.Connection;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * {@code POST /bot/musteri} — sözleşme: docs/api/bot-sozlesmesi.md §8
 *
 * <p>Konuşulan müşterinin ad/soyad bilgisini yazar. Kimlik {@code X-Musteri-Telefon}
 * başlığından gelir; gövdeden telefon kabul edilmez (LLM'e bırakılmaz).
 *
 * <p>Bot ismi konuşma sırasında öğrenebilir: bu yüzden ayrı endpoint'tir ve
 * alanlar tek tek gönderilebilir. Satır yoksa yalnızca telefonla oluşturulur.
 */
public final class MusteriHandler extends BotHandler {

    public MusteriHandler(Veritabani db, BotTokeni token) {
        super(db, token);
    }

    @Override
    protected String beklenenYontem() {
        return "POST";
    }

    @Override
    protected Object isle(HttpExchange ex, Connection conn, byte[] hamGovde) throws Exception {
        Map<String, Object> b = govde(hamGovde);
        String ad = metinEnFazla(b, "ad", 64);
        String soyad = metinEnFazla(b, "soyad", 64);

        if (ad == null && soyad == null) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    "En az biri gerekli: ad, soyad.", 400, null);
        }

        MusteriDeposu.Kayit kayit = MusteriDeposu.kaydet(conn, ad, soyad);

        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("musteri_id", kayit.musteriId());
        veri.put("ad", kayit.ad());
        veri.put("soyad", kayit.soyad());
        veri.put("bilgi", "Müşteri bilgisi kaydedildi.");
        return veri;
    }
}
