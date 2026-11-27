package tr.edu.etu.dealership;

import com.sun.net.httpserver.HttpServer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tr.edu.etu.dealership.config.Ayarlar;
import tr.edu.etu.dealership.db.Veritabani;
import tr.edu.etu.dealership.web.AracHandler;
import tr.edu.etu.dealership.bot.BotAraclari;
import tr.edu.etu.dealership.bot.GeminiIstemci;
import tr.edu.etu.dealership.bot.LlmIstemci;
import tr.edu.etu.dealership.bot.MistralIstemci;
import tr.edu.etu.dealership.web.BotTokeni;
import tr.edu.etu.dealership.web.MusteriHandler;
import tr.edu.etu.dealership.web.RandevuHandler;
import tr.edu.etu.dealership.web.MesajHandler;
import tr.edu.etu.dealership.web.RandevuIptalHandler;
import tr.edu.etu.dealership.web.HttpYardimci;
import tr.edu.etu.dealership.web.SlotHandler;
import tr.edu.etu.dealership.web.SubeHandler;

import tr.edu.etu.dealership.panel.Oturumlar;
import tr.edu.etu.dealership.panel.PanelUclari;
import tr.edu.etu.dealership.panel.PanelVeritabani;

import java.io.IOException;
import java.time.Duration;
import java.net.InetSocketAddress;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Uygulama giriş noktası: bağlantı havuzunu ve HTTP sunucusunu kurar. */
public final class Main {

    private static final Logger LOG = LoggerFactory.getLogger(Main.class);

    public static void main(String[] args) throws IOException {
        Ayarlar ayarlar = Ayarlar.ortamdan();
        Veritabani db = new Veritabani(ayarlar);
        BotTokeni token = new BotTokeni(ayarlar.botToken());

        if (!db.hazirMi()) {
            LOG.error("Veritabanına bağlanılamadı: {}", ayarlar.jdbcUrl());
            db.close();
            System.exit(1);
        }

        // Bind adresi env'den gelir; varsayılan yalnızca yerel arayüz (127.0.0.1).
        // Yavaş gövde (slowloris): JDK HttpServer varsayılan olarak istek okumasını
        // süresiz bekler. Panel girişi oturumsuz okunduğu için üst sınır koyulur.
        System.setProperty("sun.net.httpserver.maxReqTime", "30");
        HttpServer sunucu = HttpServer.create(
                new InetSocketAddress(ayarlar.bindAdresi(), ayarlar.httpPort()), 0);
        ExecutorService havuz = Executors.newFixedThreadPool(8);
        sunucu.setExecutor(havuz);

        // Bot API (docs/api/bot-sozlesmesi.md)
        sunucu.createContext("/bot/sube", new SubeHandler(db, token));
        sunucu.createContext("/bot/slot", new SlotHandler(db, token));
        sunucu.createContext("/bot/arac", new AracHandler(db, token));
        sunucu.createContext("/bot/musteri", new MusteriHandler(db, token));
        RandevuHandler randevuHandler = new RandevuHandler(db, token);
        RandevuIptalHandler randevuIptalHandler = new RandevuIptalHandler(db, token);
        sunucu.createContext("/bot/randevu", randevuHandler);
        // Daha uzun önek kazandığı için /bot/randevu/ ayrı context'tir. Tam bu yol
        // (`/bot/randevu/`) liste/oluşturma ucudur; geri kalanı iptal ucudur.
        sunucu.createContext("/bot/randevu/", ex -> {
            if ("/bot/randevu/".equals(ex.getRequestURI().getPath())) {
                randevuHandler.handle(ex);
            } else {
                randevuIptalHandler.handle(ex);
            }
        });
        // LLM: köprü mesajı buraya bırakır; backend kendi API'sini araç olarak çağırır.
        LlmIstemci llm = switch (ayarlar.llmSaglayici()) {
            case "gemini" -> new GeminiIstemci(ayarlar);
            case "mistral" -> new MistralIstemci(ayarlar);
            default -> throw new IllegalStateException(
                    "LLM_SAGLAYICI geçersiz: " + ayarlar.llmSaglayici()
                            + " (gemini | mistral)");
        };
        BotAraclari araclar = new BotAraclari(ayarlar.kendiUrl(), ayarlar.botToken());
        if (!llm.hazirMi()) {
            LOG.warn("LLM anahtarı tanımlı değil ({}): /bot/mesaj 503 dönecek", llm.etiket());
        } else {
            LOG.info("LLM: {}", llm.etiket());
        }
        sunucu.createContext("/bot/mesaj", new MesajHandler(db, token, llm, araclar));

        sunucu.createContext("/saglik", HttpYardimci.saglik(db));

        // Panel API (docs/api/panel-sozlesmesi.md): panel login rolü tanımlıysa açılır.
        PanelVeritabani panelDb = null;
        if (ayarlar.panelAcikMi()) {
            panelDb = new PanelVeritabani(ayarlar);
            if (!panelDb.hazirMi()) {
                LOG.error("Panel veritabanı rolüyle bağlanılamadı ({})", ayarlar.panelDbUser());
                panelDb.close();
                db.close();
                System.exit(1);
            }
            PanelUclari.kaydet(sunucu, panelDb,
                    new Oturumlar(Duration.ofSeconds(ayarlar.panelOturumSaniye())));
            LOG.info("Panel uçları açık");
        } else {
            LOG.warn("PANEL_DB_USER tanımlı değil: panel uçları kapalı");
        }
        PanelVeritabani panelDbSon = panelDb;

        sunucu.start();
        LOG.info("Backend dinliyor: http://{}:{}", ayarlar.bindAdresi(), ayarlar.httpPort());

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            LOG.info("Kapatılıyor...");
            sunucu.stop(0);
            havuz.shutdown();
            db.close();
            if (panelDbSon != null) panelDbSon.close();
        }));
    }
}
