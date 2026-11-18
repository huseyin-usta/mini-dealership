package tr.edu.etu.dealership.config;

/**
 * Uygulama ayarları. Yalnızca ortam değişkenlerinden okunur; repoda hiçbir
 * gizli değer (şifre, bağlantı dizesi) tutulmaz.
 *
 * <pre>
 * DB_HOST      (varsayılan localhost)
 * DB_PORT      (varsayılan 5432)
 * DB_NAME      (varsayılan mini_dealership)
 * BOT_DB_USER  bot rolü için login kullanıcısı
 * BOT_DB_PASS  bot rolü için şifre
 * HTTP_PORT    (varsayılan 8080)
 * </pre>
 */
public final class Ayarlar {

    private final String dbHost;
    private final int dbPort;
    private final String dbName;
    private final String botDbUser;
    private final String botDbPass;
    private final int httpPort;

    private Ayarlar(String dbHost, int dbPort, String dbName,
                    String botDbUser, String botDbPass, int httpPort) {
        this.dbHost = dbHost;
        this.dbPort = dbPort;
        this.dbName = dbName;
        this.botDbUser = botDbUser;
        this.botDbPass = botDbPass;
        this.httpPort = httpPort;
    }

    /** Ortam değişkenlerinden ayarları okur; zorunlu alanlar eksikse açık hata verir. */
    public static Ayarlar ortamdan() {
        return new Ayarlar(
                env("DB_HOST", "localhost"),
                Integer.parseInt(env("DB_PORT", "5432")),
                env("DB_NAME", "mini_dealership"),
                zorunlu("BOT_DB_USER"),
                zorunlu("BOT_DB_PASS"),
                Integer.parseInt(env("HTTP_PORT", "8080"))
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

    /** JDBC bağlantı adresi. Şifre burada değil, ayrı verilir. */
    public String jdbcUrl() {
        return "jdbc:postgresql://" + dbHost + ":" + dbPort + "/" + dbName;
    }

    public String botDbUser() { return botDbUser; }
    public String botDbPass() { return botDbPass; }
    public int httpPort() { return httpPort; }
}
