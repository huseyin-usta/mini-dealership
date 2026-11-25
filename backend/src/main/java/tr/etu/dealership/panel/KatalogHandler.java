package tr.edu.etu.dealership.panel;

import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;

import java.sql.PreparedStatement;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * {@code GET /panel/katalog} (sözleşme §2): panelin açılır listeleri tek
 * seferde. Yalnızca aktif çalışanlar döner; şifre hash'i hiçbir zaman.
 */
public final class KatalogHandler extends PanelHandler {

    /** Araç gerektiren türler: randevu tablosundaki CHECK kısıtıyla aynı küme. */
    static final Set<String> ARAC_GEREKEN_TURLER = Set.of(
            "TEST_SURUSU", "TESLIMAT", "PERIYODIK_BAKIM", "SERVIS_GIRIS", "SERVIS_TESLIM");

    public KatalogHandler(PanelVeritabani db, Oturumlar oturumlar) {
        super(db, oturumlar);
        rota("GET", "/panel/katalog", Rol.PERSONEL, this::katalog);
    }

    private Object katalog(Istek i) throws Exception {
        i.yalnizca(Set.of());
        Map<String, Object> veri = new LinkedHashMap<>();
        try (PreparedStatement ps = i.conn().prepareStatement(
                "SELECT sube_id, sehir, ad FROM sube ORDER BY sehir, ad")) {
            veri.put("subeler", Satirlar.liste(ps));
        }
        try (PreparedStatement ps = i.conn().prepareStatement("""
                SELECT tur_kodu, ad, sure_dakika, departman,
                       tur_kodu = ANY (?) AS arac_gerekli
                  FROM randevu_turu
                 ORDER BY departman, ad""")) {
            ps.setArray(1, i.conn().createArrayOf("varchar", ARAC_GEREKEN_TURLER.toArray()));
            veri.put("turler", Satirlar.liste(ps));
        }
        try (PreparedStatement ps = i.conn().prepareStatement("""
                SELECT c.calisan_id, c.ad, c.soyad, c.sube_id, c.departman,
                       coalesce(array_agg(y.kod ORDER BY y.kod)
                                FILTER (WHERE y.kod IS NOT NULL), '{}') AS yetkinlikler
                  FROM calisan c
                  LEFT JOIN calisan_yetkinlik cy
                         ON cy.calisan_id = c.calisan_id
                        AND (cy.bitis_tarihi IS NULL OR cy.bitis_tarihi >= current_date)
                  LEFT JOIN yetkinlik y ON y.yetkinlik_id = cy.yetkinlik_id
                 WHERE c.aktif_mi
                 GROUP BY c.calisan_id
                 ORDER BY c.sube_id, c.departman, c.ad, c.soyad""")) {
            veri.put("calisanlar", Satirlar.liste(ps));
        }
        try (PreparedStatement ps = i.conn().prepareStatement(
                "SELECT model_id, ad FROM model ORDER BY ad")) {
            veri.put("modeller", Satirlar.liste(ps));
        }
        return veri;
    }
}
