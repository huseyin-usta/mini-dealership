package tr.edu.etu.dealership;

import com.sun.net.httpserver.HttpServer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tr.edu.etu.dealership.config.Ayarlar;
import tr.edu.etu.dealership.db.Veritabani;
import tr.edu.etu.dealership.web.AracHandler;
import tr.edu.etu.dealership.web.BotTokeni;
import tr.edu.etu.dealership.web.MusteriHandler;
import tr.edu.etu.dealership.web.RandevuHandler;
import tr.edu.etu.dealership.web.HttpYardimci;
import tr.edu.etu.dealership.web.SlotHandler;
import tr.edu.etu.dealership.web.SubeHandler;

import java.io.IOException;
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
        HttpServer sunucu = HttpServer.create(
                new InetSocketAddress(ayarlar.bindAdresi(), ayarlar.httpPort()), 0);
        ExecutorService havuz = Executors.newFixedThreadPool(8);
        sunucu.setExecutor(havuz);

        // Bot API (docs/api/bot-sozlesmesi.md)
        sunucu.createContext("/bot/sube", new SubeHandler(db, token));
        sunucu.createContext("/bot/slot", new SlotHandler(db, token));
        sunucu.createContext("/bot/arac", new AracHandler(db, token));
        sunucu.createContext("/bot/musteri", new MusteriHandler(db, token));
        sunucu.createContext("/bot/randevu", new RandevuHandler(db, token));
        sunucu.createContext("/saglik", HttpYardimci.saglik(db));

        sunucu.start();
        LOG.info("Backend dinliyor: http://{}:{}", ayarlar.bindAdresi(), ayarlar.httpPort());

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            LOG.info("Kapatılıyor...");
            sunucu.stop(0);
            havuz.shutdown();
            db.close();
        }));
    }
}
