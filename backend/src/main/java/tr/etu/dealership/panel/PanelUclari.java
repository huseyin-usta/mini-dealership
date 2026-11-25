package tr.edu.etu.dealership.panel;

import com.sun.net.httpserver.HttpServer;

/** Panel uçlarını HTTP sunucusuna kaydeder (docs/api/panel-sozlesmesi.md). */
public final class PanelUclari {

    private PanelUclari() {
    }

    public static void kaydet(HttpServer sunucu, PanelVeritabani db, Oturumlar oturumlar) {
        GirisHandler giris = new GirisHandler(db, oturumlar);
        sunucu.createContext("/panel/giris", giris);
        sunucu.createContext("/panel/cikis", giris);
        sunucu.createContext("/panel/katalog", new KatalogHandler(db, oturumlar));
        sunucu.createContext("/panel/randevu", new RandevuPanelHandler(db, oturumlar));
        sunucu.createContext("/panel/arac", new AracPanelHandler(db, oturumlar));
        sunucu.createContext("/panel/servis", new ServisPanelHandler(db, oturumlar));
        sunucu.createContext("/panel/musteri", new MusteriPanelHandler(db, oturumlar));
        sunucu.createContext("/panel/rapor", new RaporPanelHandler(db, oturumlar));

        // Tanımsız /panel/* yolları: önce oturum, sonra 404 (yolların varlığı sızmasın).
        sunucu.createContext("/panel", new PanelHandler(db, oturumlar) { });
    }
}
