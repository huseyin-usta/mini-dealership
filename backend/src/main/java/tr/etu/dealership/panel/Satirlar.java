package tr.edu.etu.dealership.panel;

import java.sql.Date;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.sql.Types;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * SQL sonuçlarını JSON'a hazır satırlara çevirir. Kolon adı = JSON alan adı
 * (SQL'de {@code AS} ile verilir). Zamanlar sözleşmedeki biçime çevrilir:
 * tarih {@code YYYY-MM-DD}, zaman {@code YYYY-MM-DDTHH:MM} (Europe/Istanbul).
 */
public final class Satirlar {

    private static final ZoneId ISTANBUL = ZoneId.of("Europe/Istanbul");
    private static final DateTimeFormatter ZAMAN = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm");

    private Satirlar() {
    }

    /** Sorguyu çalıştırır, tüm satırları döner. */
    public static List<Map<String, Object>> liste(PreparedStatement ps) throws SQLException {
        try (ResultSet rs = ps.executeQuery()) {
            ResultSetMetaData md = rs.getMetaData();
            List<Map<String, Object>> sonuc = new ArrayList<>();
            while (rs.next()) {
                sonuc.add(satir(rs, md));
            }
            return sonuc;
        }
    }

    /** Tek satır bekleyen sorgu; satır yoksa boş. */
    public static Optional<Map<String, Object>> tek(PreparedStatement ps) throws SQLException {
        List<Map<String, Object>> l = liste(ps);
        return l.isEmpty() ? Optional.empty() : Optional.of(l.get(0));
    }

    private static Map<String, Object> satir(ResultSet rs, ResultSetMetaData md) throws SQLException {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 1; i <= md.getColumnCount(); i++) {
            m.put(md.getColumnLabel(i), deger(rs, i, md));
        }
        return m;
    }

    private static Object deger(ResultSet rs, int i, ResultSetMetaData md) throws SQLException {
        String tur = md.getColumnTypeName(i);
        switch (md.getColumnType(i)) {
            case Types.DATE -> {
                Date d = rs.getDate(i);
                return d == null ? null : d.toLocalDate().toString();
            }
            case Types.TIMESTAMP -> {
                if ("timestamptz".equals(tur)) {
                    OffsetDateTime o = rs.getObject(i, OffsetDateTime.class);
                    return o == null ? null : o.atZoneSameInstant(ISTANBUL).format(ZAMAN);
                }
                Timestamp t = rs.getTimestamp(i);
                return t == null ? null : t.toLocalDateTime().format(ZAMAN);
            }
            case Types.TIMESTAMP_WITH_TIMEZONE -> {
                OffsetDateTime o = rs.getObject(i, OffsetDateTime.class);
                return o == null ? null : o.atZoneSameInstant(ISTANBUL).format(ZAMAN);
            }
            case Types.NUMERIC -> {
                java.math.BigDecimal b = rs.getBigDecimal(i);
                return b == null ? null : b.stripTrailingZeros().scale() <= 0
                        ? (Object) b.longValueExact() : b.doubleValue();
            }
            case Types.ARRAY -> {
                java.sql.Array a = rs.getArray(i);
                return a == null ? null : List.of((Object[]) a.getArray());
            }
            default -> {
                return rs.getObject(i);
            }
        }
    }
}
