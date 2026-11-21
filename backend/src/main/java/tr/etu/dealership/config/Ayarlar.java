package tr.edu.etu.dealership.config;

/**
 * Uygulama ayarları. Yalnızca ortam değişkenlerinden okunur; repoda hiçbir
 * gizli değer (şifre, token, bağlantı dizesi) tutulmaz.
 *
 * <pre>
 * DB_HOST      (varsayılan localhost)
 * DB_PORT      (varsayılan 5432)
 * DB_NAME      (varsayılan mini_dealership)
 * BOT_DB_USER  bot rolü için login kullanıcısı          (zorunlu)
 * BOT_DB_PASS  bot rolü için şifre                      (zorunlu)
 * BOT_TOKEN    köprü ↔ backend paylaşılan sırrı         (zorunlu)
 * BIND_ADRESI  dinlenecek arayüz (varsayılan 127.0.0.1)
 * HTTP_PORT    (varsayılan 8080)
 * GEMINI_API_KEY  LLM anahtarı; yoksa /bot/mesaj 503 döner (zorunlu değil)
 * GEMINI_MODEL    (varsayılan gemini-2.0-flash)
 * GEMINI_URL      (varsayılan https://generativelanguage.googleapis.com/v1beta)
 * KENDI_URL       backend'in kendi adresi; LLM araçları buraya çağrılır
 *                 (varsayılan http://127.0.0.1:HTTP_PORT)
 * LLM_SAGLAYICI   gemini | mistral (varsayılan gemini)
 * MISTRAL_API_KEY Mistral platformu anahtarı (mistral seçilirse zorunlu)
 * MISTRAL_MODEL   (varsayılan ministral-3b-latest)
 * MISTRAL_URL     (varsayılan https://api.mistral.ai/v1)
 * MISTRAL_EFOR    reasoning_effort: none|low|medium|high (boşsa gönderilmez;
 *                 desteklemeyen modellerde 400 döner)
 * </pre>
 *
 * <p>Güvenli varsayılan: yalnızca yerel arayüz. Docker'da köprü ayrı bir
 * konteynerde çalıştığı için {@code BIND_ADRESI=0.0.0.0} verilir; o durumda
 * portu dışarı <b>publish etmemek</b> ve {@code BOT_TOKEN}'ı korumak gerekir.
 */
public final class Ayarlar {

    private final String dbHost;
    private final int dbPort;
    private final String dbName;
    private final String botDbUser;
    private final String botDbPass;
    private final String botToken;
    private final String bindAdresi;
    private final int httpPort;
    private final String geminiApiKey;
    private final String geminiModel;
    private final String geminiUrl;
    private final String kendiUrl;
    private final String llmSaglayici;
    private final String mistralApiKey;
    private final String mistralModel;
    private final String mistralUrl;
    private final String mistralEfor;

    private Ayarlar(String dbHost, int dbPort, String dbName,
                    String botDbUser, String botDbPass, String botToken,
                    String bindAdresi, int httpPort,
                    String geminiApiKey, String geminiModel,
                    String geminiUrl, String kendiUrl,
                    String llmSaglayici, String mistralApiKey, String mistralModel,
                    String mistralUrl, String mistralEfor) {
        this.dbHost = dbHost;
        this.dbPort = dbPort;
        this.dbName = dbName;
        this.botDbUser = botDbUser;
        this.botDbPass = botDbPass;
        this.botToken = botToken;
        this.bindAdresi = bindAdresi;
        this.httpPort = httpPort;
        this.geminiApiKey = geminiApiKey;
        this.geminiModel = geminiModel;
        this.geminiUrl = geminiUrl;
        this.kendiUrl = kendiUrl;
        this.llmSaglayici = llmSaglayici;
        this.mistralApiKey = mistralApiKey;
        this.mistralModel = mistralModel;
        this.mistralUrl = mistralUrl;
        this.mistralEfor = mistralEfor;
    }

    /** Ortam değişkenlerinden ayarları okur; zorunlu alanlar eksikse açık hata verir. */
    public static Ayarlar ortamdan() {
        int httpPort = sayi("HTTP_PORT", "8080");
        return new Ayarlar(
                env("DB_HOST", "localhost"),
                sayi("DB_PORT", "5432"),
                env("DB_NAME", "mini_dealership"),
                zorunlu("BOT_DB_USER"),
                zorunlu("BOT_DB_PASS"),
                gizli("BOT_TOKEN", 32),
                env("BIND_ADRESI", "127.0.0.1"),
                httpPort,
                env("GEMINI_API_KEY", null),
                env("GEMINI_MODEL", "gemini-2.0-flash"),
                env("GEMINI_URL", "https://generativelanguage.googleapis.com/v1beta"),
                env("KENDI_URL", "http://127.0.0.1:" + httpPort),
                env("LLM_SAGLAYICI", "gemini").toLowerCase(java.util.Locale.ROOT),
                env("MISTRAL_API_KEY", null),
                env("MISTRAL_MODEL", "ministral-3b-latest"),
                env("MISTRAL_URL", "https://api.mistral.ai/v1"),
                env("MISTRAL_EFOR", null)
        );
    }

    private static String env(String ad, String varsayilan) {
        String v = System.getenv(ad);
        return (v == null || v.isBlank()) ? varsayilan : v.trim();
    }

    /** Gizli değer: eksikse uygulama başlamamalı, varsayılan asla kullanılmamalı. */
    private static String zorunlu(String ad) {
        String v = System.getenv(ad);
        if (v == null || v.isBlank()) {
            throw new IllegalStateException(
                    ad + " ortam değişkeni tanımlı değil. Güvenlik nedeniyle varsayılan yok.");
        }
        return v.trim();
    }

    /**
     * Gizli değer, en az {@code enAz} karakter. Kısa bir sır sessizce zayıf kalır;
     * demo ortamında fark edilmez, sunucuda token katmanını işe yaramaz hale getirir.
     */
    private static String gizli(String ad, int enAz) {
        String v = zorunlu(ad);
        if (v.length() < enAz) {
            throw new IllegalStateException(
                    ad + " en az " + enAz + " karakter olmalı (openssl rand -hex 16 ile üretin).");
        }
        return v;
    }

    private static int sayi(String ad, String varsayilan) {
        String v = env(ad, varsayilan);
        try {
            return Integer.parseInt(v);
        } catch (NumberFormatException e) {
            throw new IllegalStateException(ad + " sayısal olmalı, gelen: " + v, e);
        }
    }

    /** JDBC bağlantı adresi. Şifre burada değil, ayrı verilir. */
    public String jdbcUrl() {
        return "jdbc:postgresql://" + dbHost + ":" + dbPort + "/" + dbName;
    }

    public String botDbUser() { return botDbUser; }
    public String botDbPass() { return botDbPass; }
    public String botToken() { return botToken; }
    public String bindAdresi() { return bindAdresi; }
    public int httpPort() { return httpPort; }
    public String geminiApiKey() { return geminiApiKey; }
    public String geminiModel() { return geminiModel; }
    public String geminiUrl() { return geminiUrl; }
    public String kendiUrl() { return kendiUrl; }
    public String llmSaglayici() { return llmSaglayici; }
    public String mistralApiKey() { return mistralApiKey; }
    public String mistralModel() { return mistralModel; }
    public String mistralUrl() { return mistralUrl; }
    public String mistralEfor() { return mistralEfor; }
}
