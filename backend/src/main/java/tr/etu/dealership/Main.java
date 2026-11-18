package tr.edu.etu.dealership;

import com.sun.net.httpserver.HttpServer;
import tr.edu.etu.dealership.config.Ayarlar;
import tr.edu.etu.dealership.db.Veritabani;
import tr.edu.etu.dealership.web.HttpYardimci;
import tr.edu.etu.dealership.web.SlotHandler;
import tr.edu.etu.dealership.web.SubeHandler;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.concurrent.Executors;
import java.util.logging.Logger;

/** Uygulama giriş noktası: bağlantı havuzunu ve HTTP sunucusunu kurar. */
public final class Main {

    private static final Logger LOG = Logger.getLogger(Main.class.getName());

    public static void main(String[] args) throws IOException {
        Ayarlar ayarlar = Ayarlar.ortamdan();
        Veritabani db = new Veritabani(ayarlar);

        if (!db.hazirMi()) {
            LOG.severe("Veritabanına bağlanılamadı: " + ayarlar.jdbcUrl());
            db.close();
            System.exit(1);
        }

        HttpServer sunucu = HttpServer.create(new InetSocketAddress(ayarlar.httpPort()), 0);
        sunucu.setExecutor(Executors.newFixedThreadPool(8));

        // Bot API (docs/api/bot-sozlesmesi.md)
        sunucu.createContext("/bot/sube", new SubeHandler(db));
        sunucu.createContext("/bot/slot", new SlotHandler(db));
        sunucu.createContext("/saglik", HttpYardimci.saglik(db));

        sunucu.start();
        LOG.info("Backend dinliyor: http://localhost:" + ayarlar.httpPort());

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            LOG.info("Kapatılıyor...");
            sunucu.stop(0);
            db.close();
        }));
    }
}
