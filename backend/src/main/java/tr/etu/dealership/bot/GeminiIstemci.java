package tr.edu.etu.dealership.bot;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import tr.edu.etu.dealership.config.Ayarlar;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Gemini {@code generateContent} istemcisi (SDK yok; düz HTTP + Jackson).
 *
 * <p>Yalnız ihtiyaç duyduğumuz alanları kullanır: sistem talimatı, konuşma
 * içeriği, araç (function declaration) bildirimleri ve yanıttaki metin/çağrı
 * parçaları.
 */
public final class GeminiIstemci {

    /** Modelin döndürdüğü tek bir araç çağrısı. */
    public record Cagri(String ad, Map<String, Object> args) {
    }

    /**
     * Modelin yanıtı: metin, araç çağrıları ve model turunun ham parçaları.
     * Ham parçalar sonraki istekte geri gönderilir; Gemini kendi functionCall
     * parçalarını konuşma geçmişinde görmeyi bekler.
     */
    public record Yanit(String metin, List<Cagri> cagrilar,
                        List<Map<String, Object>> hamParcalar) {
    }

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Duration ZAMAN_ASIMI = Duration.ofSeconds(30);

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
    private final String apiKey;
    private final String model;
    private final String url;

    public GeminiIstemci(Ayarlar ayarlar) {
        this.apiKey = ayarlar.geminiApiKey();
        this.model = ayarlar.geminiModel();
        this.url = ayarlar.geminiUrl();
    }

    public boolean hazirMi() {
        return apiKey != null && !apiKey.isBlank();
    }

    /** Model adı (yanıt etiketlerinde kullanılır). */
    public String modelAdi() {
        return model;
    }

    /**
     * Tek bir tur atar: modelin metin veya araç çağrısı yanıtını döndürür.
     *
     * @param sistemTalimati sistem promptu (her turda yeniden gönderilir)
     * @param icerik         konuşma geçmişi + son mesaj (Gemini {@code contents} biçimi)
     * @param araclar        function declaration listesi (boş olabilir)
     */
    public Yanit uret(String sistemTalimati, List<Map<String, Object>> icerik,
                      List<Map<String, Object>> araclar) throws IOException, InterruptedException {
        ObjectNode govde = MAPPER.createObjectNode();
        ObjectNode sistem = govde.putObject("systemInstruction");
        sistem.putArray("parts").addObject().put("text", sistemTalimati);

        ArrayNode contents = govde.putArray("contents");
        for (Map<String, Object> c : icerik) {
            contents.add(MAPPER.valueToTree(c));
        }

        if (!araclar.isEmpty()) {
            govde.putArray("tools").addObject()
                    .set("functionDeclarations", MAPPER.valueToTree(araclar));
        }

        ObjectNode uretim = govde.putObject("generationConfig");
        uretim.put("temperature", 0.3);
        uretim.put("maxOutputTokens", 2048);

        // Anahtar URL'e değil başlığa konur: ters proxy/CDN erişim log'ları URL'i
        // kaydeder, başlığı kaydetmez.
        String adres = url + "/models/" + model + ":generateContent";
        HttpRequest istek = HttpRequest.newBuilder(URI.create(adres))
                .timeout(ZAMAN_ASIMI)
                .header("Content-Type", "application/json; charset=utf-8")
                .header("x-goog-api-key", apiKey)
                .POST(HttpRequest.BodyPublishers.ofString(
                        MAPPER.writeValueAsString(govde), StandardCharsets.UTF_8))
                .build();

        // 429/5xx geçici olabilir ("high demand" dalgaları). Kısa backoff ile
        // iki kez daha dene; kalıcıysa çağıran 503 LLM_UNAVAILABLE üretir.
        HttpResponse<String> yanit = null;
        for (int deneme = 0; deneme < 3; deneme++) {
            yanit = http.send(istek, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            int kod = yanit.statusCode();
            if (kod == 200) break;
            if (kod != 429 && kod < 500) {
                throw new IOException("Gemini HTTP " + kod + ": " + kirp(yanit.body(), 300));
            }
            if (deneme < 2) {
                try {
                    Thread.sleep(400L * (deneme + 1));
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    throw ie;
                }
            }
        }
        if (yanit == null || yanit.statusCode() != 200) {
            throw new IOException("Gemini HTTP " + (yanit == null ? "?" : yanit.statusCode())
                    + ": " + kirp(yanit == null ? "" : yanit.body(), 300));
        }

        JsonNode kok = MAPPER.readTree(yanit.body());
        JsonNode adayKok = kok.path("candidates").path(0);
        String finish = adayKok.path("finishReason").asText("");
        if ("SAFETY".equals(finish) || "RECITATION".equals(finish)) {
            throw new IOException("Gemini yanıtı engellendi: " + finish);
        }
        JsonNode aday = adayKok.path("content");
        if (aday.isMissingNode()) {
            throw new IOException("Gemini yanıtında içerik yok (finishReason=" + finish + ")");
        }

        StringBuilder metin = new StringBuilder();
        List<Cagri> cagrilar = new ArrayList<>();
        for (JsonNode parca : aday.path("parts")) {
            // "thought" parçaları modelin iç muhakemesidir; müşteriye gitmez.
            // (Gemma 4 ve Gemini "thinking" modelleri bu parçayı döndürür.)
            if (parca.hasNonNull("text") && !parca.path("thought").asBoolean(false)) {
                metin.append(parca.get("text").asText());
            }
            JsonNode fc = parca.get("functionCall");
            if (fc != null && fc.hasNonNull("name")) {
                @SuppressWarnings("unchecked")
                Map<String, Object> args = MAPPER.convertValue(
                        fc.path("args"), Map.class);
                cagrilar.add(new Cagri(fc.get("name").asText(), args));
            }
        }

        @SuppressWarnings("unchecked")
        List<Map<String, Object>> hamParcalar = aday.path("parts").isArray()
                ? MAPPER.convertValue(aday.path("parts"), List.class)
                : List.of();
        return new Yanit(metin.toString().trim(), cagrilar, hamParcalar);
    }

    private static String kirp(String s, int n) {
        if (s == null) return "";
        return s.length() <= n ? s : s.substring(0, n) + "…";
    }
}
