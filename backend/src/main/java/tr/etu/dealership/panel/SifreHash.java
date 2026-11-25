package tr.edu.etu.dealership.panel;

import org.mindrot.jbcrypt.BCrypt;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

/**
 * Panel hesabı için bcrypt hash üretir (seed ve demo hesapları için).
 * Şifre komut satırından değil stdin'den okunur; kabuk geçmişine düşmesin.
 *
 * <pre>
 * printf '%s' "$SIFRE" | java -cp mini-dealership-backend.jar tr.edu.etu.dealership.panel.SifreHash
 * </pre>
 */
public final class SifreHash {

    private SifreHash() {
    }

    public static void main(String[] args) throws Exception {
        BufferedReader r = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String sifre = r.readLine();
        if (sifre == null || sifre.isEmpty()) {
            System.err.println("Şifre stdin'den okunamadı.");
            System.exit(1);
        }
        System.out.println(BCrypt.hashpw(sifre, BCrypt.gensalt(10)));
    }
}
