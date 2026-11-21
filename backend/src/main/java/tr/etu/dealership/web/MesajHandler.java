package tr.edu.etu.dealership.web;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpExchange;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tr.edu.etu.dealership.bot.BotAraclari;
import tr.edu.etu.dealership.bot.LlmIstemci;
import tr.edu.etu.dealership.db.BotKimligi;
import tr.edu.etu.dealership.db.MusteriDeposu;
import tr.edu.etu.dealership.db.Veritabani;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.Duration;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * {@code POST /bot/mesaj} — sözleşme: docs/api/bot-sozlesmesi.md §7
 *
 * <p>Köprüden gelen müşteri mesajını kaydeder, LLM'i (araç çağrılarıyla) çalıştırır,
 * cevabı kaydeder ve köprüye döner. Köprü veritabanına dokunmaz.
 *
 * <p><b>Idempotency:</b> köprü WhatsApp mesaj kimliğini ({@code kaynak_id}) gönderir.
 * Aynı kimlikle gelen ikinci istek LLM'i yeniden çalıştırmaz; kaydedilmiş cevabı
 * döner. Bu olmadan bir ağ tekrarı "randevu oluştur" aracını ikinci kez çalıştırıp
 * çift randevu üretebilirdi.
 *
 * <p><b>İki commit:</b> gelen mesaj, LLM çağrısından önce commit edilir; model
 * hatası olsa bile "her mesaj kaydedilir" kuralı bozulmaz. Bu uçta bu yüzden iki
 * commit vardır; diğer uçlar tek transaction'da kalır.
 */
public final class MesajHandler extends BotHandler {

    private static final Logger LOG = LoggerFactory.getLogger(MesajHandler.class);

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final int AZAMI_METIN = 4000;
    private static final int GECMIS_ADET = 20;
    private static final int AZAMI_TUR = 4;
    private static final int AZAMI_ARAC_CAGRISI = 10;
    /**
     * LLM döngüsünün toplam süre bütçesi. Bağlantı ve HTTP thread'i bu süre
     * boyunca meşgul kalır; sınırsız bırakmak havuzu tıkar.
     */
    private static final Duration LLM_BUTCESI = Duration.ofSeconds(60);

    private static final ZoneId BOLGE = ZoneId.of("Europe/Istanbul");
    private static final DateTimeFormatter TARIH_BICIMI =
            DateTimeFormatter.ofPattern("d MMMM yyyy, EEEE", Locale.forLanguageTag("tr"));

    private static final String GECMIS_SQL = """
            SELECT yon, icerik
              FROM mesaj
             WHERE musteri_id = fn_aktif_musteri_id()
             ORDER BY zaman DESC, mesaj_id DESC
             LIMIT ?
            """;

    private static final String EKLE_SQL = """
            INSERT INTO mesaj (musteri_id, yon, icerik, kaynak_id)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (kaynak_id) WHERE kaynak_id IS NOT NULL DO NOTHING
            RETURNING mesaj_id
            """;

    private static final String KAYNAK_SQL = """
            SELECT mesaj_id FROM mesaj WHERE kaynak_id = ?
            """;

    /** Aynı kaynak mesajına yazılmış cevap (idempotent tekrar). */
    private static final String CEVAP_SQL = """
            SELECT icerik
              FROM mesaj
             WHERE musteri_id = fn_aktif_musteri_id()
               AND yon = 'GIDEN' AND mesaj_id > ?
             ORDER BY mesaj_id
             LIMIT 1
            """;

    private final LlmIstemci gemini;
    private final BotAraclari araclar;
    private final String sistemPromptuSablonu;

    public MesajHandler(Veritabani db, BotTokeni token,
                        LlmIstemci gemini, BotAraclari araclar) {
        super(db, token);
        this.gemini = gemini;
        this.araclar = araclar;
        this.sistemPromptuSablonu = kaynaktanOku("/sistem-promptu.md");
    }

    @Override
    protected String beklenenYontem() {
        return "POST";
    }

    @Override
    protected Object isle(HttpExchange ex, Connection conn, byte[] hamGovde) throws Exception {
        Map<String, Object> b = govde(hamGovde);
        String metin = zorunluMetin(b, "metin");
        if (metin.length() > AZAMI_METIN) {
            throw ApiHatasi.goster("GECERSIZ_PARAMETRE",
                    "metin en fazla " + AZAMI_METIN + " karakter olabilir.", 400, null);
        }
        String kaynakId = metinEnFazla(b, "kaynak_id", 128);
        if (!gemini.hazirMi()) {
            throw ApiHatasi.goster("LLM_UNAVAILABLE",
                    "Şu an yanıt veremiyorum, birazdan tekrar deneyin.", 503, null);
        }

        String telefon = ex.getRequestHeaders().getFirst("X-Musteri-Telefon").trim();
        long basla = System.nanoTime();

        MusteriDeposu.Kayit musteri = MusteriDeposu.kaydet(conn, null, null);

        long gelenId;
        boolean yeniMesaj = true;
        if (kaynakId == null) {
            gelenId = mesajEkle(conn, musteri.musteriId(), "GELEN", metin, null);
        } else {
            Long eklenen = mesajEkleVeyaBul(conn, musteri.musteriId(), metin, kaynakId);
            if (eklenen == null) {
                // Aynı kaynak mesajı zaten işlenmiş: cevabı varsa onu döndür.
                Long onceki = kaynakMesajId(conn, kaynakId);
                String cevap = onceki == null ? null : cevapBul(conn, onceki);
                if (cevap != null) {
                    Map<String, Object> veri = new LinkedHashMap<>();
                    veri.put("cevap", cevap);
                    veri.put("mesaj_id", onceki);
                    veri.put("tekrar", true);
                    veri.put("arac_cagrisi", 0);
                    veri.put("sure_ms", 0);
                    return veri;
                }
                // Önceki deneme cevap üretmeden düşmüş: işlemeye devam et.
                gelenId = onceki == null ? 0 : onceki;
                yeniMesaj = false;
            } else {
                gelenId = eklenen;
            }
        }

        // LLM yavaş olabilir; gelen mesaj kaydı şimdi garantiye alınır.
        conn.commit();
        // DİKKAT: SET LOCAL transaction kapsamlıdır; commit kimliği sıfırlar.
        // Yeniden yazılmazsa sonraki mesaj INSERT'i RLS'e takılır.
        BotKimligi.ata(conn, telefon);

        List<Map<String, Object>> icerik = gecmis(conn);
        String cevap = null;
        int cagriSayisi = 0;
        long bitis = System.nanoTime() + LLM_BUTCESI.toNanos();

        try {
            for (int tur = 0; tur < AZAMI_TUR; tur++) {
                if (System.nanoTime() > bitis) {
                    throw new IOException("LLM süre bütçesi aşıldı");
                }
                LlmIstemci.Yanit yanit = gemini.uret(
                        sistemPromptu(), icerik, BotAraclari.bildirimler());

                if (yanit.cagrilar().isEmpty()) {
                    cevap = yanit.metin();
                    break;
                }

                icerik.add(Map.of("role", "model", "parts", yanit.hamParcalar()));

                List<Map<String, Object>> fnParcalari = new ArrayList<>();
                for (LlmIstemci.Cagri cagri : yanit.cagrilar()) {
                    if (++cagriSayisi > AZAMI_ARAC_CAGRISI) {
                        throw new IOException("Araç çağrısı bütçesi aşıldı");
                    }
                    String govde = araclar.calistir(cagri.ad(), cagri.args(), telefon);
                    fnParcalari.add(Map.of("functionResponse", Map.of(
                            "name", cagri.ad(),
                            "response", aracYaniti(govde))));
                }
                // Araç sonuçları "user" turunda gönderilir: Gemma yalnız
                // user/model rollerini kabul ediyor (role:"function" 400 verir).
                icerik.add(Map.of("role", "user", "parts", fnParcalari));
            }
        } catch (IOException | InterruptedException e) {
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            // Anahtar/URL yazmadan yalnız sınıf + kısa mesaj: teşhis için yeter.
            LOG.warn("LLM turu başarısız: {} — {}", e.getClass().getSimpleName(), e.getMessage());
            throw ApiHatasi.goster("LLM_UNAVAILABLE",
                    "Şu an yanıt veremiyorum, birazdan tekrar deneyin.", 503, null);
        }

        if (cevap == null || cevap.isBlank()) {
            LOG.warn("LLM boş yanıt döndü (telefon={}, tur={})", maskeli(telefon), cagriSayisi);
            throw ApiHatasi.goster("LLM_UNAVAILABLE",
                    "Şu an yanıt veremiyorum, birazdan tekrar deneyin.", 503, null);
        }

        long gidenId = mesajEkle(conn, musteri.musteriId(), "GIDEN", cevap, null);

        Map<String, Object> veri = new LinkedHashMap<>();
        veri.put("cevap", cevap);
        veri.put("mesaj_id", gidenId);
        veri.put("arac_cagrisi", cagriSayisi);
        veri.put("sure_ms", (System.nanoTime() - basla) / 1_000_000);
        return veri;
    }

    // --- yardımcılar --------------------------------------------------------

    private static long mesajEkle(Connection conn, int musteriId, String yon,
                                  String icerik, String kaynakId) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(EKLE_SQL)) {
            ps.setInt(1, musteriId);
            ps.setString(2, yon);
            ps.setString(3, icerik);
            ps.setString(4, kaynakId);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                return rs.getLong("mesaj_id");
            }
        }
    }

    /** Yeni mesaj eklendiyse id'sini, aynı kaynak zaten varsa {@code null} döner. */
    private static Long mesajEkleVeyaBul(Connection conn, int musteriId,
                                         String icerik, String kaynakId) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(EKLE_SQL)) {
            ps.setInt(1, musteriId);
            ps.setString(2, "GELEN");
            ps.setString(3, icerik);
            ps.setString(4, kaynakId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getLong("mesaj_id") : null;
            }
        }
    }

    private static Long kaynakMesajId(Connection conn, String kaynakId) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(KAYNAK_SQL)) {
            ps.setString(1, kaynakId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getLong("mesaj_id") : null;
            }
        }
    }

    private static String cevapBul(Connection conn, long gelenId) throws Exception {
        try (PreparedStatement ps = conn.prepareStatement(CEVAP_SQL)) {
            ps.setLong(1, gelenId);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getString("icerik") : null;
            }
        }
    }

    /** Son mesajlar (eskiden yeniye); son satır az önce kaydedilen mesajdır. */
    private static List<Map<String, Object>> gecmis(Connection conn) throws Exception {
        List<String[]> satirlar = new ArrayList<>();
        try (PreparedStatement ps = conn.prepareStatement(GECMIS_SQL)) {
            ps.setInt(1, GECMIS_ADET);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    satirlar.add(new String[]{rs.getString("yon"), rs.getString("icerik")});
                }
            }
        }
        List<Map<String, Object>> icerik = new ArrayList<>();
        for (int i = satirlar.size() - 1; i >= 0; i--) {
            String rol = "GELEN".equals(satirlar.get(i)[0]) ? "user" : "model";
            icerik.add(Map.of("role", rol,
                    "parts", List.of(Map.of("text", satirlar.get(i)[1]))));
        }
        return icerik;
    }

    /** Araç yanıtı gövdesini Gemini'nin beklediği nesneye çevirir. */
    private static Object aracYaniti(String govde) {
        try {
            Object cozulen = MAPPER.readValue(govde, Object.class);
            return cozulen instanceof Map ? cozulen : Map.of("sonuc", cozulen);
        } catch (IOException e) {
            return Map.of("sonuc", govde == null ? "" : govde);
        }
    }

    private String sistemPromptu() {
        return sistemPromptuSablonu.replace("{{BUGUN}}",
                LocalDate.now(BOLGE).format(TARIH_BICIMI));
    }

    /** Log'da telefonun tamamı görünmesin. */
    private static String maskeli(String telefon) {
        if (telefon == null || telefon.length() < 4) return "***";
        return "***" + telefon.substring(telefon.length() - 4);
    }

    private static String kaynaktanOku(String yol) {
        try (InputStream in = MesajHandler.class.getResourceAsStream(yol)) {
            if (in == null) {
                throw new IllegalStateException("Sistem promptu bulunamadı: " + yol);
            }
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("Sistem promptu okunamadı: " + yol, e);
        }
    }
}
