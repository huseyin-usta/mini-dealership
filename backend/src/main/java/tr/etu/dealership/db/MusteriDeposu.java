package tr.edu.etu.dealership.db;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;

/**
 * Müşteri kaydı okuma/yazma.
 *
 * <p>Kimlik telefondur: oturumdaki {@code app.musteri_telefon} değişkeni hem RLS
 * politikalarının hem de bu sorguların kaynağıdır. Ad ve soyad sonradan
 * öğrenilebilir (bkz. {@code db/440_musteri_bilgisi.sql}); boş bırakılabilir.
 */
public final class MusteriDeposu {

    /** Müşterinin veritabanındaki hali. {@code ad}/{@code soyad} null olabilir. */
    public record Kayit(int musteriId, String ad, String soyad) {
    }

    private MusteriDeposu() {
    }

    /** Oturumdaki telefonun müşteri kaydı; yoksa {@code null}. */
    public static Kayit bul(Connection conn) throws SQLException {
        try (PreparedStatement ps = conn.prepareStatement("""
                SELECT musteri_id, ad, soyad
                  FROM musteri
                 WHERE telefon = current_setting('app.musteri_telefon', true)
                """)) {
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) return null;
                return new Kayit(rs.getInt("musteri_id"),
                        rs.getString("ad"), rs.getString("soyad"));
            }
        }
    }

    /**
     * Müşteriyi kaydeder: satır yoksa telefonla oluşturur, varsa yalnızca
     * verilen alanları günceller ({@code null} alan mevcut değeri korur).
     *
     * <p>Böylece bot ismi konuşma sırasında tek seferde değil, öğrendikçe yazar.
     */
    public static Kayit kaydet(Connection conn, String ad, String soyad) throws SQLException {
        // Tek statement: SELECT-sonra-INSERT yarışı kapanır. Aynı telefonla eşzamanlı
        // iki istek gelirse biri INSERT, diğeri ON CONFLICT dalını çalıştırır.
        try (PreparedStatement ps = conn.prepareStatement("""
                INSERT INTO musteri (telefon, ad, soyad)
                VALUES (current_setting('app.musteri_telefon', true), ?, ?)
                ON CONFLICT (telefon) DO UPDATE
                   SET ad    = coalesce(excluded.ad, musteri.ad),
                       soyad = coalesce(excluded.soyad, musteri.soyad)
                RETURNING musteri_id, ad, soyad
                """)) {
            ps.setString(1, ad);
            ps.setString(2, soyad);
            return oku(ps);
        }
    }

    private static Kayit oku(PreparedStatement ps) throws SQLException {
        try (ResultSet rs = ps.executeQuery()) {
            if (!rs.next()) {
                throw new SQLException("Müşteri kaydı yazılamadı (RLS kimliği yok?)");
            }
            return new Kayit(rs.getInt("musteri_id"),
                    rs.getString("ad"), rs.getString("soyad"));
        }
    }
}
