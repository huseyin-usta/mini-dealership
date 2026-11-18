package tr.edu.etu.dealership.web;

import java.util.Map;

/**
 * İstemciye (LLM'e / köprüye) dönen, anlamlı iş hatası.
 *
 * <p>Sözleşmedeki hata kodlarını taşır. HTTP durum kodu da buradadır; böylece
 * handler'lar yalnızca iş kuralını düşünür, zarf/durum eşleşmesini burada bulur.
 *
 * <p>{@code kullaniciyaGoster=false} → LLM hatayı müşteriye söylemez, kendi
 * içinde alternatif arar (ör. {@code YETKI_YOK}, {@code SERVIS_KAPALI}).
 */
public final class ApiHatasi extends RuntimeException {

    private final String kod;
    private final int httpDurum;
    private final boolean kullaniciyaGoster;
    private final Map<String, Object> detay;

    public ApiHatasi(String kod, String mesaj, int httpDurum,
                     boolean kullaniciyaGoster, Map<String, Object> detay) {
        super(mesaj);
        this.kod = kod;
        this.httpDurum = httpDurum;
        this.kullaniciyaGoster = kullaniciyaGoster;
        this.detay = detay;
    }

    /** Kullanıcıya gösterilen, 4xx ile dönen hata. */
    public static ApiHatasi goster(String kod, String mesaj, int httpDurum,
                                   Map<String, Object> detay) {
        return new ApiHatasi(kod, mesaj, httpDurum, true, detay);
    }

    /** LLM içi hata: müşteriye söylenmez, LLM alternatif arar. */
    public static ApiHatasi gizli(String kod, String mesaj, int httpDurum,
                                  Map<String, Object> detay) {
        return new ApiHatasi(kod, mesaj, httpDurum, false, detay);
    }

    public String kod() { return kod; }
    public int httpDurum() { return httpDurum; }
    public boolean kullaniciyaGoster() { return kullaniciyaGoster; }
    public Map<String, Object> detay() { return detay; }
}
