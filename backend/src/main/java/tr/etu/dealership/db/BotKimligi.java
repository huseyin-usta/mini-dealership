package tr.edu.etu.dealership.db;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.util.Objects;

/**
 * Müşteri kimliğini transaction'a bağlar.
 *
 * <p>Bot rolü RLS ile korunur; hangi müşterinin satırlarını göreceği
 * {@code app.musteri_telefon} oturum değişkeninden okunur (bkz. db/400_roller.sql
 * içindeki {@code fn_aktif_musteri_id()}). Kimlik <b>her zaman</b> WhatsApp
 * JID'sinden türetilir; LLM argümanlarından asla gelmez.
 *
 * <p>Değişken {@code SET LOCAL} ile yazılır: yalnızca o transaction boyunca
 * geçerlidir, bağlantı havuza dönünce sıfırlanır. Böylece bir isteğin kimliği
 * sonraki isteğe sızmaz (fail-closed).
 */
public final class BotKimligi {

    /** Telefon E.164 biçiminde olmalı: + ile başlar, en az 8 hane. */
    private static final String TELEFON_DESENI = "^\\+[1-9]\\d{7,14}$";

    private BotKimligi() {
    }

    /**
     * Geçerli transaction'a müşteri telefonunu yazar. Geçersiz biçim reddedilir:
     * hatalı kimlikle sorgu çalıştırmak, RLS'yi boş kümeye düşürür ve sessizce
     * yanlış sonuç üretir.
     */
    public static void ata(Connection conn, String telefon) throws SQLException {
        if (telefon == null || !telefon.matches(TELEFON_DESENI)) {
            throw new IllegalArgumentException(
                    "Geçersiz müşteri telefonu (E.164 bekleniyordu)");
        }
        // set_config(..., is_local => true) == SET LOCAL: transaction sonunda sıfırlanır.
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT set_config('app.musteri_telefon', ?, true)")) {
            ps.setString(1, Objects.requireNonNull(telefon));
            ps.execute();
        }
    }
}
