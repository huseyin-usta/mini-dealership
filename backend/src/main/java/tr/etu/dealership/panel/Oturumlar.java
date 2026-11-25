package tr.edu.etu.dealership.panel;

import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Panel oturumları (bellekte).
 *
 * <p>Oturum anahtarı 256 bit rastgeledir ve hiçbir şey taşımaz (opak); çalışan
 * bilgisi sunucuda durur. Backend yeniden başlarsa tüm oturumlar düşer —
 * kalıcı oturum tablosu bilinçli olarak yok (sözleşme §Kimlik).
 *
 * <p>Kaba kuvvete karşı: bir kullanıcı adında art arda {@value #AZAMI_HATA}
 * hatalı girişten sonra o ad {@link #KILIT_SURESI} boyunca kilitlenir.
 */
public final class Oturumlar {

    /** Oturumdaki çalışan. Değişmez. */
    public record Oturum(int calisanId, int subeId, String departman,
                         String ad, String soyad, Instant sonKullanma) {
    }

    static final int AZAMI_HATA = 5;
    static final Duration KILIT_SURESI = Duration.ofMinutes(1);

    private final SecureRandom rastgele = new SecureRandom();
    private final Map<String, Oturum> oturumlar = new ConcurrentHashMap<>();
    private final Map<String, Deneme> denemeler = new ConcurrentHashMap<>();
    private final Duration sure;
    private final Clock saat;

    private record Deneme(int hata, Instant kilitBitis) {
    }

    public Oturumlar(Duration sure) {
        this(sure, Clock.systemUTC());
    }

    Oturumlar(Duration sure, Clock saat) {
        this.sure = sure;
        this.saat = saat;
    }

    /** Yeni oturum açar, anahtarı döner. Süresi dolmuşları da temizler. */
    public String ac(int calisanId, int subeId, String departman, String ad, String soyad) {
        Instant simdi = saat.instant();
        oturumlar.values().removeIf(o -> !o.sonKullanma().isAfter(simdi));
        byte[] ham = new byte[32];
        rastgele.nextBytes(ham);
        String anahtar = Base64.getUrlEncoder().withoutPadding().encodeToString(ham);
        oturumlar.put(anahtar, new Oturum(calisanId, subeId, departman, ad, soyad,
                simdi.plus(sure)));
        return anahtar;
    }

    /** Geçerli oturumu bulur; yoksa ya da süresi dolmuşsa boş döner. */
    public Optional<Oturum> bul(String anahtar) {
        if (anahtar == null || anahtar.isEmpty()) return Optional.empty();
        Oturum o = oturumlar.get(anahtar);
        if (o == null) return Optional.empty();
        if (!o.sonKullanma().isAfter(saat.instant())) {
            oturumlar.remove(anahtar);
            return Optional.empty();
        }
        return Optional.of(o);
    }

    public void kapat(String anahtar) {
        if (anahtar != null) oturumlar.remove(anahtar);
    }

    /** Bu kullanıcı adı şu an kilitli mi? */
    public boolean kilitliMi(String kullaniciAdi) {
        Deneme d = denemeler.get(kullaniciAdi);
        return d != null && d.kilitBitis() != null && d.kilitBitis().isAfter(saat.instant());
    }

    /** Hatalı giriş: sayacı artırır, sınırda kilitler. */
    public void hataliGiris(String kullaniciAdi) {
        Instant simdi = saat.instant();
        denemeler.compute(kullaniciAdi, (k, d) -> {
            int hata = (d == null || (d.kilitBitis() != null && !d.kilitBitis().isAfter(simdi)))
                    ? 1 : d.hata() + 1;
            return new Deneme(hata, hata >= AZAMI_HATA ? simdi.plus(KILIT_SURESI) : null);
        });
    }

    /** Başarılı giriş sayacı sıfırlar. */
    public void basariliGiris(String kullaniciAdi) {
        denemeler.remove(kullaniciAdi);
    }
}
