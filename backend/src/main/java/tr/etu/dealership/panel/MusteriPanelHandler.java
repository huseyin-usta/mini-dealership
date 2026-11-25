package tr.edu.etu.dealership.panel;

import tr.edu.etu.dealership.panel.PanelVeritabani.Rol;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Müşteri uçları (sözleşme §9–10): arama, müşteri kartı ve bot konuşmaları.
 * Mesajlar salt-okunurdur ({@code personel} rolünün {@code mesaj} tablosunda
 * yazma yetkisi yok).
 */
public final class MusteriPanelHandler extends PanelHandler {

    public MusteriPanelHandler(PanelVeritabani db, Oturumlar oturumlar) {
        super(db, oturumlar);
        rota("GET", "/panel/musteri", Rol.PERSONEL, this::listele);
        rota("GET", "/panel/musteri/(\\d+)", Rol.PERSONEL, this::detay);
    }

    /**
     * {@code ara} + veya rakamla başlıyorsa telefon öneki, değilse ad/soyad
     * içinde geçen metin. İkisinde de LIKE yok: kullanıcı girdisi joker olmasın.
     */
    private Object listele(Istek i) throws Exception {
        i.yalnizca(Set.of("ara", "limit", "sayfa"));
        String ara = i.metinParam("ara");
        String telefon = null;
        String isim = null;
        if (ara != null) {
            if (ara.length() > 64) throw Istek.gecersiz("ara en fazla 64 karakter olabilir.");
            String sade = ara.replace(" ", "");
            if (sade.matches("\\+?\\d+")) telefon = sade; else isim = ara;
        }
        int limit = i.limit();
        int sayfa = i.sayfa();
        String kosul = """
                 WHERE (?::varchar IS NULL OR left(mu.telefon, length(?)) = ?)
                   AND (?::varchar IS NULL
                        OR position(lower(?) IN lower(concat_ws(' ', mu.ad, mu.soyad))) > 0)
                """;
        Map<String, Object> veri = new LinkedHashMap<>();
        try (PreparedStatement ps = i.conn().prepareStatement("SELECT count(*) FROM musteri mu" + kosul)) {
            parametreler(ps, telefon, isim);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                veri.put("toplam", rs.getLong(1));
            }
        }
        try (PreparedStatement ps = i.conn().prepareStatement("""
                SELECT mu.musteri_id, mu.ad, mu.soyad, mu.telefon, mu.kayit_zamani,
                       sr.baslangic AS son_randevu_zamani, sr.tur_adi AS son_randevu_turu,
                       sr.durum AS son_randevu_durumu
                  FROM musteri mu
                  LEFT JOIN v_musteri_son_randevu sr ON sr.musteri_id = mu.musteri_id
                """ + kosul + " ORDER BY mu.kayit_zamani DESC, mu.musteri_id DESC LIMIT ? OFFSET ?")) {
            int n = parametreler(ps, telefon, isim);
            ps.setInt(n++, limit);
            ps.setLong(n, (long) (sayfa - 1) * limit);
            veri.put("musteriler", Satirlar.liste(ps));
        }
        return veri;
    }

    private static int parametreler(PreparedStatement ps, String telefon, String isim)
            throws SQLException {
        int n = 1;
        for (int k = 0; k < 3; k++) ps.setString(n++, telefon);
        for (int k = 0; k < 2; k++) ps.setString(n++, isim);
        return n;
    }

    private Object detay(Istek i) throws Exception {
        i.yalnizca(Set.of());
        int id = i.yolSayi(1);
        Connection c = i.conn();
        Map<String, Object> veri;
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT musteri_id, ad, soyad, telefon, kayit_zamani FROM musteri WHERE musteri_id = ?""")) {
            ps.setInt(1, id);
            veri = new LinkedHashMap<>(Satirlar.tek(ps).orElseThrow(() -> Istek.bulunamadi("Müşteri")));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT r.randevu_id, r.baslangic, r.durum, r.kaynak, rt.ad AS tur_adi,
                       s.ad AS sube_adi, c.ad || ' ' || c.soyad AS calisan, r.arac_vin
                  FROM randevu r
                  JOIN randevu_turu rt ON rt.tur_kodu = r.tur_kodu
                  JOIN sube s          ON s.sube_id = r.sube_id
                  JOIN calisan c       ON c.calisan_id = r.calisan_id
                 WHERE r.musteri_id = ?
                 ORDER BY r.baslangic DESC, r.randevu_id DESC
                 LIMIT 100""")) {
            ps.setInt(1, id);
            veri.put("randevular", Satirlar.liste(ps));
        }
        try (PreparedStatement ps = c.prepareStatement("""
                SELECT a.vin, a.plaka, mo.ad AS model_adi, v.paket_adi, a.renk
                  FROM arac a
                  JOIN versiyon v ON v.versiyon_id = a.versiyon_id
                  JOIN model mo   ON mo.model_id = v.model_id
                 WHERE a.musteri_id = ?
                 ORDER BY a.vin""")) {
            ps.setInt(1, id);
            veri.put("araclar", Satirlar.liste(ps));
        }
        return veri;
    }


}
