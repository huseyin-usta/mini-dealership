package tr.edu.etu.dealership.panel;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Oturum süresi, hesap kilidi ve IP sınırı. Saat enjekte edilir: testler
 * gerçek zamana veya makinenin saat dilimine bağlı değildir.
 */
class OturumlarTest {

    /** İleri sarılabilen saat. */
    private static final class AyarlanabilirSaat extends Clock {
        private Instant an;

        AyarlanabilirSaat(Instant an) {
            this.an = an;
        }

        void ilerlet(Duration d) {
            an = an.plus(d);
        }

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return an;
        }
    }

    private static final Instant T0 = Instant.parse("2026-11-27T09:00:00Z");
    private static final Duration SURE = Duration.ofHours(8);

    @Test
    void oturumSuresiDoluncaGecersizOlur() {
        AyarlanabilirSaat saat = new AyarlanabilirSaat(T0);
        Oturumlar o = new Oturumlar(SURE, saat);
        String anahtar = o.ac(1, 1, "SATIS", "Ayşe", "Satıcı");

        assertTrue(o.bul(anahtar).isPresent());
        saat.ilerlet(SURE.minusSeconds(1));
        assertTrue(o.bul(anahtar).isPresent(), "süre dolmadan oturum geçerli");
        saat.ilerlet(Duration.ofSeconds(2));
        assertTrue(o.bul(anahtar).isEmpty(), "süre dolunca oturum düşer");
    }

    @Test
    void besHataliGirisKilitlerVeSureSonraAcilir() {
        AyarlanabilirSaat saat = new AyarlanabilirSaat(T0);
        Oturumlar o = new Oturumlar(SURE, saat);

        for (int i = 0; i < Oturumlar.AZAMI_HATA; i++) {
            assertFalse(o.kilitliMi("ayse"), "kilit sınırda başlar");
            o.hataliGiris("ayse");
        }
        assertTrue(o.kilitliMi("ayse"));
        assertFalse(o.kilitliMi("burak"), "kilit yalnız o kullanıcı adını etkiler");

        saat.ilerlet(Oturumlar.KILIT_SURESI.plusSeconds(1));
        assertFalse(o.kilitliMi("ayse"), "kilit süresi dolunca açılır");

        // Kilit sonrası ilk hata sayacı sıfırdan başlatır (hemen yeniden kilitlenmez).
        o.hataliGiris("ayse");
        assertFalse(o.kilitliMi("ayse"));
    }

    @Test
    void ipSiniriPencereIcindeUygulanir() {
        AyarlanabilirSaat saat = new AyarlanabilirSaat(T0);
        Oturumlar o = new Oturumlar(SURE, saat);

        for (int i = 0; i < Oturumlar.IP_AZAMI; i++) {
            assertTrue(o.ipIzinli("10.0.0.1"), "sınırın altındaki denemeler geçer");
        }
        assertFalse(o.ipIzinli("10.0.0.1"), "sınır aşılınca reddedilir");
        assertTrue(o.ipIzinli("10.0.0.2"), "diğer IP etkilenmez");

        saat.ilerlet(Oturumlar.IP_PENCERE.plusSeconds(1));
        assertTrue(o.ipIzinli("10.0.0.1"), "yeni pencerede tekrar izin verilir");
    }
}
