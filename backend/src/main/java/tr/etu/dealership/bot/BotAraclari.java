package tr.edu.etu.dealership.bot;

import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * LLM'in çağırabileceği işlemler. Her araç, sözleşmedeki bir HTTP ucuna
 * ({@code docs/api/bot-sozlesmesi.md}) karşılık gelir; backend kendi API'sini
 * localhost üzerinden çağırır. Böylece tek doğruluk kaynağı sözleşmedir:
 * LLM'in gördüğü araç ile dışarıya açılan uç aynı şeydir.
 */
public final class BotAraclari {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Duration ZAMAN_ASIMI = Duration.ofSeconds(15);
    /** Tek araç yanıtının modele giden üst sınırı (karakter). */
    private static final int AZAMI_YANIT = 16_000;

    private static final HttpClient HTTP = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(3))
            .build();

    /** Araç kimliği: ad, HTTP yöntemi, yol (path template) ve izinli alanlar. */
    private record Tanim(String ad, String yontem, String yol,
                         Set<String> govdeAlanlari, Set<String> sorguAlanlari) {
    }

    private static final List<Tanim> TANIMLAR = List.of(
            new Tanim("sube_listele", "GET", "/bot/sube", Set.of(), Set.of("sehir")),
            new Tanim("musait_slotlar", "GET", "/bot/slot", Set.of(),
                    Set.of("sube_id", "tur_kodu", "tarih", "arac_vin")),
            new Tanim("arac_listele", "GET", "/bot/arac", Set.of(),
                    Set.of("model", "sehir", "sube_id", "kapsam")),
            new Tanim("randevularim", "GET", "/bot/randevu", Set.of(), Set.of("limit")),
            new Tanim("randevu_olustur", "POST", "/bot/randevu",
                    Set.of("sube_id", "tur_kodu", "tarih", "baslangic", "model", "ad", "soyad"),
                    Set.of()),
            new Tanim("randevu_iptal", "POST", "/bot/randevu/{id}/iptal", Set.of(), Set.of()),
            new Tanim("musteri_bilgisi", "POST", "/bot/musteri", Set.of("ad", "soyad"), Set.of())
    );

    private final String tabanUrl;
    private final String botToken;

    public BotAraclari(String tabanUrl, String botToken) {
        this.tabanUrl = tabanUrl.endsWith("/")
                ? tabanUrl.substring(0, tabanUrl.length() - 1) : tabanUrl;
        this.botToken = botToken;
    }

    /** Gemini'ye gönderilecek function declaration listesi. */
    public static List<Map<String, Object>> bildirimler() {
        return List.of(
                arac("sube_listele",
                        "Hizmet verilen şubeleri listeler. Parametresiz çağrılırsa yalnızca "
                                + "şehir adlarını döner. Şehir verilirse o şehirdeki şubeleri "
                                + "döner; yoksa hata döner. Şubelere ulaşmak için şehir gerekir.",
                        Map.of("sehir", metin("Şehir adı (ör. Ankara)")), List.of()),

                arac("musait_slotlar",
                        "Bir şubede belirli bir gün için müsait randevu saatlerini ve o saatte "
                                + "müsait araçları listeler. Boş liste dönerse o gün uygun saat "
                                + "yoktur; bilgi alanındaki saat aralığını söyle ve başka gün öner.",
                        Map.of(
                                "sube_id", tamSayi("Şube kimliği"),
                                "tur_kodu", metin("Randevu türü kodu (ör. TEST_SURUSU)"),
                                "tarih", metin("Tarih, YYYY-MM-DD; bugünden en fazla 21 gün ileri"),
                                "arac_vin", metin("Yalnız belirli bir araç soruluyorsa VIN")),
                        List.of("sube_id", "tur_kodu", "tarih")),

                arac("arac_listele",
                        "Stoktaki ve yoldaki araçları listeler. Parametresiz: model bazında "
                                + "toplam. model: şehir+paket kırılımı. sehir: şube kırılımı. "
                                + "sube_id: paket ve renk kırılımı. kapsam=benim: müşterinin "
                                + "kendi araçları (VIN ve plaka). Fiyat dönmez; fiyat sorulursa "
                                + "web sitesine yönlendir.",
                        Map.of(
                                "model", metin("Model adı (ör. Ioniq 5)"),
                                "sehir", metin("Şehir adı; sube_id ile birlikte kullanılamaz"),
                                "sube_id", tamSayi("Şube kimliği; sehir ile kullanılamaz"),
                                "kapsam", metin("Yalnızca 'benim' (müşterinin kendi araçları)")),
                        List.of()),

                arac("randevularim",
                        "Müşterinin randevularını getirir: yaklasan (planlanmış), gecmis (son N) "
                                + "ve son_bakim (en yeni tamamlanmış periyodik bakım). 'Randevum "
                                + "ne zaman?', 'son bakımım ne zamandı?' sorularında kullan.",
                        Map.of("limit", tamSayi("Geçmiş listesi uzunluğu (1-50, varsayılan 10)")),
                        List.of()),

                arac("randevu_olustur",
                        "Randevu oluşturur. Çalışanı ve aracı sistem atar; sen kimseyi seçme. "
                                + "Önce musait_slotlar ile saati doğrula ve müşteri onaylasın. "
                                + "Test sürüşünde müşteri belirli model istediyse model alanını "
                                + "doldur. Müşteri yeni ise ad ve soyad ver. SLOT_DOLU dönerse "
                                + "başka saat öner.",
                        Map.of(
                                "sube_id", tamSayi("Şube kimliği"),
                                "tur_kodu", metin("Randevu türü kodu"),
                                "tarih", metin("YYYY-MM-DD"),
                                "baslangic", metin("HH:MM; musait_slotlar'dan alınan saat"),
                                "model", metin("Yalnız araç gerektiren türlerde, müşteri istediyse"),
                                "ad", metin("Müşteri adı"),
                                "soyad", metin("Müşteri soyadı")),
                        List.of("sube_id", "tur_kodu", "tarih", "baslangic")),

                arac("randevu_iptal",
                        "Müşterinin kendi randevusunu iptal eder. Yalnız PLANLANDI ve henüz "
                                + "başlamamış randevular iptal edilebilir. randevu_id, "
                                + "randevularim yanıtından alınır.",
                        Map.of("id", tamSayi("İptal edilecek randevunun kimliği")),
                        List.of("id")),

                arac("musteri_bilgisi",
                        "Müşterinin adını ve/veya soyadını kaydeder. İsim öğrenildiğinde veya "
                                + "hitap için sorulduğunda kullan. Alanlar tek tek gönderilebilir.",
                        Map.of("ad", metin("Müşteri adı"), "soyad", metin("Müşteri soyadı")),
                        List.of())
        );
    }

    /**
     * Aracı çalıştırır ve sözleşme zarfını (JSON) olduğu gibi döndürür.
     * İş hatası (4xx) fırlatılmaz: LLM hatayı görüp alternatif üretmelidir.
     * Yalnız taşıma hatası istisna olur.
     */
    public String calistir(String ad, Map<String, Object> args, String musteriTelefon)
            throws IOException, InterruptedException {
        Tanim tanim = TANIMLAR.stream().filter(t -> t.ad().equals(ad)).findFirst()
                .orElse(null);
        if (tanim == null) {
            // Model uydurmuş olabilir: turu düşürmek yerine modelin görüp
            // düzeltebileceği bir araç hatası döndür.
            return "{\"ok\":false,\"hata\":{\"kod\":\"ARAC_YOK\","
                    + "\"mesaj\":\"Bilinmeyen araç. Yalnız tanımlı araçları kullan.\"}}";
        }

        Map<String, Object> temiz = args == null ? Map.of() : args;
        String yol = tanim.yol();
        Map<String, String> sorgu = new LinkedHashMap<>();

        if (yol.contains("{id}")) {
            long id;
            try {
                id = Long.parseLong(String.valueOf(temiz.get("id")));
            } catch (NumberFormatException e) {
                return "{\"ok\":false,\"hata\":{\"kod\":\"GECERSIZ_PARAMETRE\","
                        + "\"mesaj\":\"id tam sayı olmalı.\"}}";
            }
            if (id <= 0) {
                return "{\"ok\":false,\"hata\":{\"kod\":\"GECERSIZ_PARAMETRE\","
                        + "\"mesaj\":\"id pozitif olmalı.\"}}";
            }
            yol = yol.replace("{id}", Long.toString(id));
        }

        HttpRequest.Builder istek = HttpRequest.newBuilder()
                .timeout(ZAMAN_ASIMI)
                .header("X-Bot-Token", botToken)
                .header("X-Musteri-Telefon", musteriTelefon);

        if (tanim.yontem().equals("GET")) {
            for (Map.Entry<String, Object> e : temiz.entrySet()) {
                if (e.getValue() == null) continue;
                if (!tanim.sorguAlanlari().contains(e.getKey())) continue;
                sorgu.put(e.getKey(), String.valueOf(e.getValue()));
            }
            String qs = sorgu.isEmpty() ? "" : "?" + urlEncode(sorgu);
            istek.uri(URI.create(tabanUrl + yol + qs)).GET();
        } else {
            Map<String, Object> govde = new LinkedHashMap<>();
            for (Map.Entry<String, Object> e : temiz.entrySet()) {
                if (e.getValue() == null) continue;
                if (tanim.govdeAlanlari().contains(e.getKey())) {
                    govde.put(e.getKey(), e.getValue());
                }
            }
            istek.uri(URI.create(tabanUrl + yol))
                    .header("Content-Type", "application/json; charset=utf-8")
                    .POST(HttpRequest.BodyPublishers.ofString(
                            MAPPER.writeValueAsString(govde), StandardCharsets.UTF_8));
        }

        HttpResponse<String> yanit = HTTP.send(istek.build(),
                HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        String govde = yanit.body();
        // Modele giden yanıtı sınırla: dev bir gövde Gemini isteğini şişirmesin.
        if (govde != null && govde.length() > AZAMI_YANIT) {
            return govde.substring(0, AZAMI_YANIT);
        }
        return govde;
    }

    // --- bildirim yardımcıları ---------------------------------------------

    private static Map<String, Object> arac(String ad, String aciklama,
                                            Map<String, Object> ozellikler,
                                            List<String> zorunlu) {
        Map<String, Object> parametreler = new LinkedHashMap<>();
        parametreler.put("type", "object");
        parametreler.put("properties", ozellikler);
        if (!zorunlu.isEmpty()) {
            parametreler.put("required", new ArrayList<>(zorunlu));
        }
        Map<String, Object> arac = new LinkedHashMap<>();
        arac.put("name", ad);
        arac.put("description", aciklama);
        arac.put("parameters", parametreler);
        return arac;
    }

    private static Map<String, Object> metin(String aciklama) {
        return Map.of("type", "string", "description", aciklama);
    }

    private static Map<String, Object> tamSayi(String aciklama) {
        return Map.of("type", "integer", "description", aciklama);
    }

    private static String urlEncode(Map<String, String> parametreler) {
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<String, String> e : parametreler.entrySet()) {
            if (sb.length() > 0) sb.append('&');
            sb.append(URLEncoder.encode(e.getKey(), StandardCharsets.UTF_8))
              .append('=')
              .append(URLEncoder.encode(e.getValue(), StandardCharsets.UTF_8));
        }
        return sb.toString();
    }
}
