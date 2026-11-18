package tr.edu.etu.dealership.db;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import tr.edu.etu.dealership.config.Ayarlar;

import java.sql.Connection;
import java.sql.SQLException;

/**
 * Bot rolüyle bağlanan bağlantı havuzu.
 *
 * <p>Her bağlantı bot rolüyle açılır; satır bazlı güvenlik (RLS) bu rolde
 * etkindir. Müşteri kimliği transaction başına {@link BotKimligi} ile verilir.
 */
public final class Veritabani implements AutoCloseable {

    private final HikariDataSource ds;
    private final String jdbcUrl;
    private final String kullanici;
    private final String sifre;

    public Veritabani(Ayarlar ayarlar) {
        this.jdbcUrl = ayarlar.jdbcUrl();
        this.kullanici = ayarlar.botDbUser();
        this.sifre = ayarlar.botDbPass();

        HikariConfig cfg = new HikariConfig();
        cfg.setJdbcUrl(jdbcUrl);
        cfg.setUsername(kullanici);
        cfg.setPassword(sifre);
        cfg.setMaximumPoolSize(10);
        cfg.setMinimumIdle(2);
        cfg.setPoolName("bot-pool");
        // Bot transaction'ları kısa; uzun bekleme bir hatayı gizler.
        cfg.setConnectionTimeout(5_000);
        // Otomatik commit kapalı: her işlem açıkça transaction yönetir.
        cfg.setAutoCommit(false);
        this.ds = new HikariDataSource(cfg);
    }

    /**
     * Havuzdan bot rolüyle bir bağlantı alır. Otomatik commit kapalıdır;
     * çağıran taraf commit/rollback yapmalıdır.
     */
    public Connection baglanti() throws SQLException {
        return ds.getConnection();
    }

    /** Sağlık kontrolü: veritabanı erişilebiliyor mu? */
    public boolean hazirMi() {
        try (Connection c = ds.getConnection()) {
            return c.isValid(2);
        } catch (SQLException e) {
            return false;
        }
    }

    @Override
    public void close() {
        ds.close();
    }
}
