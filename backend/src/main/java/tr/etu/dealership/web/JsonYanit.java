package tr.edu.etu.dealership.web;

import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * JSON yanıt yazıcısı. Sözleşmedeki ortak zarfı (bkz. docs/api/bot-sozlesmesi.md)
 * tek yerden üretir; böylece her endpoint aynı biçimi döndürür.
 *
 * <pre>
 * Başarılı : { "ok": true,  "veri": { ... } }
 * Hatalı   : { "ok": false, "hata": { "kod", "mesaj", "kullaniciya_goster", "detay" } }
 * </pre>
 */
public final class JsonYanit {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private JsonYanit() {
    }

    public static ObjectMapper mapper() {
        return MAPPER;
    }

    /** Başarılı yanıt gövdesi. */
    public static byte[] basarili(Object veri) throws IOException {
        Map<String, Object> govde = new LinkedHashMap<>();
        govde.put("ok", true);
        govde.put("veri", veri);
        return MAPPER.writeValueAsBytes(govde);
    }

    /** Hatalı yanıt gövdesi. {@code kullaniciyaGoster=false} ise LLM hatayı müşteriye söylemez. */
    public static byte[] hatali(String kod, String mesaj, boolean kullaniciyaGoster, Object detay)
            throws IOException {
        Map<String, Object> hata = new LinkedHashMap<>();
        hata.put("kod", kod);
        hata.put("mesaj", mesaj);
        hata.put("kullaniciya_goster", kullaniciyaGoster);
        if (detay != null) {
            hata.put("detay", detay);
        }
        Map<String, Object> govde = new LinkedHashMap<>();
        govde.put("ok", false);
        govde.put("hata", hata);
        return MAPPER.writeValueAsBytes(govde);
    }

    /** Gövdeyi yazar ve HTTP durum kodunu ayarlar. Content-Type her zaman JSON. */
    public static void yaz(com.sun.net.httpserver.HttpExchange ex, int durum, byte[] govde)
            throws IOException {
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        ex.sendResponseHeaders(durum, govde.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(govde);
        }
    }

    /** Ham metin (sağlık kontrolü gibi JSON olmayan yanıtlar için). */
    public static void yazMetin(com.sun.net.httpserver.HttpExchange ex, int durum, String metin)
            throws IOException {
        byte[] govde = metin.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "text/plain; charset=utf-8");
        ex.sendResponseHeaders(durum, govde.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(govde);
        }
    }
}
