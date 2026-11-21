package tr.edu.etu.dealership.bot;

import java.io.IOException;
import java.util.List;
import java.util.Map;

/**
 * LLM sağlayıcı arayüzü. Sağlayıcı değiştirilebilir olsun diye tek bir sözleşme:
 * sistem talimatı + konuşma içeriği + araç bildirimleri → metin ve/veya araç çağrıları.
 *
 * <p>İçerik biçimi (Gemini'nin {@code contents} yapısı) sağlayıcıdan bağımsız
 * tutulur; her adaptör kendi tel biçimine çevirir:
 * <ul>
 *   <li>{@code {"role":"user",  "parts":[{"text":"..."}]}}</li>
 *   <li>{@code {"role":"model", "parts":[{"text":"..."},{"functionCall":{...}}]}}</li>
 *   <li>{@code {"role":"user",  "parts":[{"functionResponse":{"name":...,"response":{...}}}]}}</li>
 * </ul>
 */
public interface LlmIstemci {

    /** Modelin döndürdüğü tek bir araç çağrısı. */
    record Cagri(String ad, Map<String, Object> args) {
    }

    /**
     * Modelin yanıtı: metin, araç çağrıları ve model turunun sağlayıcıya özgü
     * ham parçaları (sonraki istekte geri gönderilir).
     */
    record Yanit(String metin, List<Cagri> cagrilar,
                 List<Map<String, Object>> hamParcalar) {
    }

    /** Anahtar yapılandırılmış mı? Değilse çağıran 503 döndürür. */
    boolean hazirMi();

    /** Sağlayıcı etiketi (log/yanıt için): "gemini/gemma-4-26b" gibi. */
    String etiket();

    Yanit uret(String sistemTalimati, List<Map<String, Object>> icerik,
               List<Map<String, Object>> araclar) throws IOException, InterruptedException;
}
