-- Maskeli rapor view'ları: rapor rolü (Excel raporu, istatistikler) yalnızca
-- bunları okur; müşteri tablosuna doğrudan erişimi yoktur.
-- View'lar sahibinin (admin) yetkisiyle çalışır (security_invoker kapalı), bu yüzden
-- rapor rolüne base tablolarda yetki vermek gerekmez.
-- security_barrier: sorguya eklenen kullanıcı fonksiyonları/filtreleri, maskeleme
-- uygulanmadan önce ham satırlara erişip veri sızdıramaz.

-- Müşteri listesi (maskeli ad ve telefon)
CREATE VIEW v_rapor_musteri
WITH (security_barrier = true)
AS
SELECT mu.musteri_id,
       fn_maskele_ad(mu.ad)          AS ad,
       fn_maskele_ad(mu.soyad)       AS soyad,
       fn_maskele_telefon(mu.telefon) AS telefon,
       mu.kayit_zamani
  FROM musteri mu;

-- Randevu raporu: Excel'e aktarılan ana tablo (tek yönlü, DB -> Excel).
-- Model bilgisi araçtan (arac_vin) ya da doğrudan randevudaki versiyondan gelir.
CREATE VIEW v_rapor_randevu
WITH (security_barrier = true)
AS
SELECT r.randevu_id,
       r.baslangic,
       r.bitis,
       r.durum,
       r.kaynak,
       r.tur_kodu,
       rt.ad                                AS tur_adi,
       rt.departman,
       s.sube_id,
       s.sehir,
       s.ad                                 AS sube_adi,
       c.calisan_id,
       c.ad || ' ' || c.soyad               AS calisan,
       r.arac_vin,
       mo.ad                                AS model_adi,
       ve.paket_adi,
       r.musteri_id,
       fn_maskele_ad(mu.ad) || ' ' || fn_maskele_ad(mu.soyad) AS musteri,
       fn_maskele_telefon(mu.telefon)       AS musteri_telefon
  FROM randevu r
  JOIN randevu_turu rt  ON rt.tur_kodu  = r.tur_kodu
  JOIN sube s           ON s.sube_id    = r.sube_id
  JOIN calisan c        ON c.calisan_id = r.calisan_id
  JOIN musteri mu       ON mu.musteri_id = r.musteri_id
  LEFT JOIN arac a      ON a.vin = r.arac_vin
  LEFT JOIN versiyon ve ON ve.versiyon_id = coalesce(a.versiyon_id, r.versiyon_id)
  LEFT JOIN model mo    ON mo.model_id = ve.model_id;
