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

    /**
     * IP başına giriş denemesi sınırı. Kullanıcı adı kilidi tek başına yetmez:
     * saldırgan her istekte farklı ad gönderirse her istekte bcrypt çalışır.
     * Testler tek IP'den ~20 giriş yapar; sınır onların üstünde tutuldu.
     */
    static final int IP_AZAMI = 60;
    static final Duration IP_PENCERE = Duration.ofMinutes(1);

    /** Terk edilmiş sayaç kayıtları bu süre sonra silinir (bellek sınırsız büyümesin). */
    static final Duration TEMIZLIK_SURESI = Duration.ofHours(1);

    /** IP sayaç haritasının üst sınırı: aşılırsa süresi dolanlar temizlenir. */
    private static final int IP_HARITA_TAVANI = 10_000;

    private final SecureRandom rastgele = new SecureRandom();
    private final Map<String, Oturum> oturumlar = new ConcurrentHashMap<>();
    private final Map<String, Deneme> denemeler = new ConcurrentHashMap<>();
    private final Map<String, IpDeneme> ipDenemeler = new ConcurrentHashMap<>();
    private final Duration sure;
    private final Clock saat;

    private record Deneme(int hata, Instant kilitBitis, Instant sonDeneme) {
    }

    private record IpDeneme(int sayi, Instant pencereBaslangic) {
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
        // Terk edilmiş sayaçları at: rastgele adlarla sınırsız kayıt birikemez.
        denemeler.values().removeIf(d -> d.sonDeneme().plus(TEMIZLIK_SURESI).isBefore(simdi));
        denemeler.compute(kullaniciAdi, (k, d) -> {
            int hata = (d == null || (d.kilitBitis() != null && !d.kilitBitis().isAfter(simdi)))
                    ? 1 : d.hata() + 1;
            return new Deneme(hata, hata >= AZAMI_HATA ? simdi.plus(KILIT_SURESI) : null, simdi);
        });
    }

    /**
     * IP başına pencere sınırı. Kullanıcı adı ne olursa olsun, tek IP'den
     * dakikada {@value #IP_AZAMI} giriş denemesinden fazlası bcrypt'e ulaşmaz.
     */
    public boolean ipIzinli(String ip) {
        Instant simdi = saat.instant();
        IpDeneme d = ipDenemeler.compute(ip == null ? "?" : ip, (k, v) ->
                v == null || !v.pencereBaslangic().plus(IP_PENCERE).isAfter(simdi)
                        ? new IpDeneme(1, simdi)
                        : new IpDeneme(v.sayi() + 1, v.pencereBaslangic()));
        if (ipDenemeler.size() > IP_HARITA_TAVANI) {
            ipDenemeler.values().removeIf(v -> !v.pencereBaslangic().plus(IP_PENCERE).isAfter(simdi));
        }
        return d.sayi() <= IP_AZAMI;
    }

    /** Başarılı giriş sayacı sıfırlar. */
    public void basariliGiris(String kullaniciAdi) {
        denemeler.remove(kullaniciAdi);
    }
}
