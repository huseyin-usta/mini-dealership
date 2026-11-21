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
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Mistral platformu (OpenAI uyumlu {@code /v1/chat/completions}) istemcisi.
 *
 * <p>Mistral yalnız kendi modellerini değil, platformda barındırdığı üçüncü taraf
 * modelleri de (Z.ai GLM, DeepSeek) aynı API ile sunar; bu yüzden model adı
 * yapılandırmadan gelir.
 *
 * <p>İçerik biçimi {@link LlmIstemci} ile aynıdır; burada OpenAI biçimine çevrilir:
 * <ul>
 *   <li>{@code model} turu → {@code assistant} (metin + {@code tool_calls})</li>
 *   <li>{@code functionResponse} → {@code tool} mesajı; çağrı kimliği bir önceki
 *       assistant turundaki sırayla eşleştirilir</li>
 * </ul>
 */
public final class MistralIstemci implements LlmIstemci {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Duration ZAMAN_ASIMI = Duration.ofSeconds(30);
    private static final String VARSAYILAN_URL = "https://api.mistral.ai/v1";

    private final HttpClient http = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
    private final String apiKey;
    private final String model;
    private final String url;
    private final String efor;

    public MistralIstemci(Ayarlar ayarlar) {
        this.apiKey = ayarlar.mistralApiKey();
        this.model = ayarlar.mistralModel();
        String u = ayarlar.mistralUrl();
        this.url = (u == null || u.isBlank() ? VARSAYILAN_URL : u).replaceAll("/+$", "");
        this.efor = ayarlar.mistralEfor();
    }

    @Override
    public boolean hazirMi() {
        return apiKey != null && !apiKey.isBlank();
    }

    @Override
    public String etiket() {
        return "mistral/" + model;
    }

    @Override
    public Yanit uret(String sistemTalimati, List<Map<String, Object>> icerik,
                      List<Map<String, Object>> araclar) throws IOException, InterruptedException {
        ObjectNode govde = MAPPER.createObjectNode();
        govde.put("model", model);
        govde.put("temperature", 0.3);
        govde.put("max_tokens", 1024);

        // Reasoning yalnız yapılandırıldıysa ve model destekliyorsa gönderilir;
        // desteklemeyen modelde 400 döner (bkz. MISTRAL_EFOR notu).
        if (efor != null && !efor.isBlank()) {
            govde.put("reasoning_effort", efor);
        }

        ArrayNode mesajlar = govde.putArray("messages");
        mesajlar.addObject().put("role", "system").put("content", sistemTalimati);
        mesajlariCevir(icerik, mesajlar);

        if (!araclar.isEmpty()) {
            ArrayNode tools = govde.putArray("tools");
            for (Map<String, Object> a : araclar) {
                ObjectNode arac = tools.addObject();
                arac.put("type", "function");
                arac.set("function", MAPPER.valueToTree(a));
            }
            govde.put("tool_choice", "auto");
        }

        HttpRequest istek = HttpRequest.newBuilder(URI.create(url + "/chat/completions"))
                .timeout(ZAMAN_ASIMI)
                .header("Content-Type", "application/json; charset=utf-8")
                .header("Authorization", "Bearer " + apiKey)
                .POST(HttpRequest.BodyPublishers.ofString(
                        MAPPER.writeValueAsString(govde), StandardCharsets.UTF_8))
                .build();

        // 429/5xx geçici olabilir: kısa backoff ile iki kez daha dene.
        HttpResponse<String> yanit = null;
        for (int deneme = 0; deneme < 3; deneme++) {
            yanit = http.send(istek, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            int kod = yanit.statusCode();
            if (kod == 200) break;
            if (kod != 429 && kod < 500) {
                throw new IOException("Mistral HTTP " + kod + ": " + kirp(yanit.body()));
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
            throw new IOException("Mistral HTTP "
                    + (yanit == null ? "?" : yanit.statusCode()) + ": "
                    + kirp(yanit == null ? "" : yanit.body()));
        }

        JsonNode kok = MAPPER.readTree(yanit.body());
        JsonNode mesaj = kok.path("choices").path(0).path("message");
        if (mesaj.isMissingNode()) {
            throw new IOException("Mistral yanıtında mesaj yok");
        }

        String metin = metinCikar(mesaj.get("content"));
        List<Cagri> cagrilar = new ArrayList<>();
        for (JsonNode tc : mesaj.path("tool_calls")) {
            String ad = tc.path("function").path("name").asText("");
            String argsJson = tc.path("function").path("arguments").asText("{}");
            Map<String, Object> args;
            try {
                @SuppressWarnings("unchecked")
                Map<String, Object> cozulen = MAPPER.readValue(argsJson, Map.class);
                args = cozulen;
            } catch (IOException e) {
                args = Map.of();
            }
            if (!ad.isBlank()) cagrilar.add(new Cagri(ad, args));
        }

        // Assistant mesajı olduğu gibi saklanır: sonraki istekte aynen geri
        // gönderilir (tool_call kimlikleri korunsun).
        @SuppressWarnings("unchecked")
        Map<String, Object> ham = MAPPER.convertValue(mesaj, Map.class);
        List<Map<String, Object>> hamParcalar =
                List.of(Map.of(MistralIstemci.class.getSimpleName(), ham));

        return new Yanit(metin.trim(), cagrilar, hamParcalar);
    }

    /**
     * Bazı modeller (ör. Z.ai GLM) {@code content} alanını blok dizisi olarak
     * döndürür: thinking + text. Yalnız text blokları birleştirilir; düşünme
     * parçaları müşteriye gitmez.
     */
    private static String metinCikar(JsonNode icerik) {
        if (icerik == null || icerik.isNull()) return "";
        if (icerik.isTextual()) return icerik.asText("");
        if (!icerik.isArray()) return "";
        StringBuilder sb = new StringBuilder();
        for (JsonNode blok : icerik) {
            if ("text".equals(blok.path("type").asText())
                    && blok.path("text").isTextual()) {
                sb.append(blok.get("text").asText());
            }
        }
        return sb.toString();
    }

    /** Sağlayıcıdan bağımsız içeriği OpenAI mesaj listesine çevirir. */
    private void mesajlariCevir(List<Map<String, Object>> icerik, ArrayNode hedef) {
        // functionResponse → tool mesajı eşleşmesi için assistant turundaki
        // araç çağrısı kimlikleri sırayla saklanır.
        Deque<String> bekleyenIdler = new ArrayDeque<>();

        for (Map<String, Object> tur : icerik) {
            String rol = String.valueOf(tur.get("role"));
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> parcalar = (List<Map<String, Object>>) tur.get("parts");
            if (parcalar == null) continue;

            if ("model".equals(rol)) {
                Map<String, Object> ham = hamMistral(parcalar);
                if (ham != null) {
                    ObjectNode m = (ObjectNode) MAPPER.valueToTree(ham);
                    hedef.add(m);
                    kaydetToolIdleri(m, bekleyenIdler);
                    continue;
                }

                ObjectNode m = hedef.addObject();
                m.put("role", "assistant");
                StringBuilder metin = new StringBuilder();
                ArrayNode toolCalls = m.putArray("tool_calls");
                int sira = 0;
                for (Map<String, Object> parca : parcalar) {
                    Object t = parca.get("text");
                    if (t instanceof String s) metin.append(s);
                    Object fc = parca.get("functionCall");
                    if (fc instanceof Map<?, ?> cagri) {
                        String ad = String.valueOf(cagri.get("name"));
                        String id = "call_" + (sira++);
                        ObjectNode tc = toolCalls.addObject();
                        tc.put("id", id);
                        tc.put("type", "function");
                        ObjectNode fn = tc.putObject("function");
                        fn.put("name", ad);
                        try {
                            fn.put("arguments", MAPPER.writeValueAsString(cagri.get("args")));
                        } catch (IOException e) {
                            fn.put("arguments", "{}");
                        }
                        bekleyenIdler.add(id);
                    }
                }
                if (metin.length() > 0) {
                    m.put("content", metin.toString());
                } else {
                    m.putNull("content");
                }
                if (toolCalls.isEmpty()) m.remove("tool_calls");
                continue;
            }

            // user turu: ya düz metin ya araç sonuçları
            boolean aracSonucu = parcalar.stream().anyMatch(p -> p.containsKey("functionResponse"));
            if (aracSonucu) {
                for (Map<String, Object> parca : parcalar) {
                    Object fr = parca.get("functionResponse");
                    if (!(fr instanceof Map<?, ?> sonuc)) continue;
                    ObjectNode m = hedef.addObject();
                    m.put("role", "tool");
                    String id = bekleyenIdler.poll();
                    m.put("tool_call_id", id == null ? "call_0" : id);
                    m.put("name", String.valueOf(sonuc.get("name")));
                    try {
                        m.put("content", MAPPER.writeValueAsString(sonuc.get("response")));
                    } catch (IOException e) {
                        m.put("content", "{}");
                    }
                }
            } else {
                StringBuilder metin = new StringBuilder();
                for (Map<String, Object> parca : parcalar) {
                    Object t = parca.get("text");
                    if (t instanceof String s) metin.append(s);
                }
                hedef.addObject().put("role", "user").put("content", metin.toString());
            }
        }
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> hamMistral(List<Map<String, Object>> parcalar) {
        for (Map<String, Object> p : parcalar) {
            Object v = p.get(MistralIstemci.class.getSimpleName());
            if (v instanceof Map<?, ?> m) return (Map<String, Object>) m;
        }
        return null;
    }

    private static void kaydetToolIdleri(ObjectNode assistant, Deque<String> bekleyen) {
        JsonNode tc = assistant.path("tool_calls");
        for (JsonNode c : tc) {
            String id = c.path("id").asText("");
            if (!id.isBlank()) bekleyen.add(id);
        }
    }

    private static String kirp(String s) {
        if (s == null) return "";
        return s.length() <= 300 ? s : s.substring(0, 300) + "…";
    }
}
