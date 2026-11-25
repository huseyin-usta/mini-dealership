package tr.edu.etu.dealership.panel;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import tr.edu.etu.dealership.config.Ayarlar;

import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Panelin bağlantı havuzu.
 *
 * <p>Login rolü ({@code PANEL_DB_USER}) {@code NOINHERIT} olarak tanımlanır ve
 * {@code personel} ile {@code rapor} rollerinin üyesidir. Bu yüzden
 * {@code SET LOCAL ROLE} yapılmadan hiçbir tabloyu okuyamaz: rol seçimi
 * unutulursa sorgu yetki hatası alır, sessizce fazla yetkiyle çalışmaz
 * (fail-closed). Rol transaction sonunda sıfırlanır; bağlantı havuza temiz döner.
 */
public final class PanelVeritabani implements AutoCloseable {

    /** Panelin kullanabileceği DB rolleri. Ad SQL'e yalnızca bu sabitlerden gider. */
    public enum Rol {
        PERSONEL("personel"),
        RAPOR("rapor");

        private final String ad;

        Rol(String ad) {
            this.ad = ad;
        }

        public String ad() {
            return ad;
        }
    }

    private final HikariDataSource ds;

    public PanelVeritabani(Ayarlar ayarlar) {
        HikariConfig cfg = new HikariConfig();
        cfg.setJdbcUrl(ayarlar.jdbcUrl());
        cfg.setUsername(ayarlar.panelDbUser());
        cfg.setPassword(ayarlar.panelDbPass());
        cfg.setMaximumPoolSize(6);
        cfg.setMinimumIdle(1);
        cfg.setPoolName("panel-pool");
        cfg.setConnectionTimeout(5_000);
        cfg.setAutoCommit(false);
        this.ds = new HikariDataSource(cfg);
    }

    /**
     * Havuzdan bağlantı alır ve transaction'ı verilen role geçirir.
     * Otomatik commit kapalıdır; çağıran commit/rollback yapar.
     */
    public Connection baglanti(Rol rol) throws SQLException {
        Connection c = ds.getConnection();
        try (Statement st = c.createStatement()) {
            st.execute("SET LOCAL ROLE " + rol.ad());
            return c;
        } catch (SQLException e) {
            c.close();
            throw e;
        }
    }

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
