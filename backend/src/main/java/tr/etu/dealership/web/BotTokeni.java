package tr.edu.etu.dealership.web;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/**
 * Köprü ↔ backend kimlik doğrulaması.
 *
 * <p>WhatsApp köprüsü her isteğe paylaşılan sırrı ({@code BOT_TOKEN}) ekler.
 * Bu, müşteri kimliğinden ({@code X-Musteri-Telefon}) ayrı bir katmandır:
 * <ul>
 *   <li>Telefon, "hangi müşteri adına" sorusunu yanıtlar (RLS için)</li>
 *   <li>Token, "bu istek gerçekten köprüden mi geliyor" sorusunu yanıtlar</li>
 * </ul>
 *
 * <p>Token istemciye (LLM'e, müşteriye) hiçbir yoldan ulaşmaz: yalnızca köprü
 * ekler, yalnızca backend doğrular.
 *
 * <p>Karşılaştırma sabit zamanlıdır ({@link MessageDigest#isEqual}); erken çıkış
 * yapan {@code equals} zamanlama bilgisi sızdırır.
 */
public final class BotTokeni {

    /** Köprünün gönderdiği başlık. */
    public static final String BASLIK = "X-Bot-Token";

    private final byte[] beklenen;

    public BotTokeni(String botToken) {
        if (botToken == null || botToken.isBlank()) {
            throw new IllegalArgumentException("BOT_TOKEN boş olamaz");
        }
        // Yapılandırma .env'den okunurken satır sonu/boşluk kalabilir; iki taraf
        // da kırpılmış değerle karşılaştırılır (bkz. gecerliMi).
        this.beklenen = botToken.trim().getBytes(StandardCharsets.UTF_8);
    }

    /** İstekteki başlık değeri beklenen token ile birebir aynı mı? */
    public boolean gecerliMi(String gelen) {
        if (gelen == null) {
            return false;
        }
        // Köprü .env'den okurken satır sonu/boşluk kalabilir; iki taraf da
        // kırpılmış değerle karşılaştırır, aksi halde tüm istekler 401 döner.
        String kirpilmis = gelen.trim();
        if (kirpilmis.isEmpty()) {
            return false;
        }
        return MessageDigest.isEqual(beklenen, kirpilmis.getBytes(StandardCharsets.UTF_8));
    }
}
