-- Mini-Dealership Analitik Sorguları (Proje Tanımı gereksinimi: >= 5 karmaşık sorgu)
-- Kapsam: 3+ JOIN, CTE, Subquery, GROUP BY/HAVING ve Window Functions (RANK).

-- 1. Model Bazında Test Sürüşü vs Satış Dönüşüm Oranı (CTE + 4-way JOIN + RANK)
-- İş Sorusu (Ara Rapor 2.1): "Hangi model çok test ediliyor ama satılmıyor?"
WITH test_surusleri AS (
    SELECT v.model_id, count(*) AS test_sayisi
      FROM randevu r
      JOIN arac a     ON a.vin = r.arac_vin
      JOIN versiyon v ON v.versiyon_id = a.versiyon_id
     WHERE r.tur_kodu = 'TEST_SURUSU'
       AND r.durum = 'TAMAMLANDI'
       AND r.baslangic >= '2025-11-01'
     GROUP BY v.model_id
),
satislar AS (
    SELECT v.model_id, count(*) AS satis_sayisi
      FROM stok_hareketi sh
      JOIN arac a     ON a.vin = sh.arac_vin
      JOIN versiyon v ON v.versiyon_id = a.versiyon_id
     WHERE sh.hareket_turu = 'SATIS'
       AND sh.zaman >= '2025-11-01'
     GROUP BY v.model_id
),
test_sonrasi_alan AS (
    SELECT v.model_id, count(DISTINCT a.musteri_id) AS test_ve_satis_musteri
      FROM randevu r
      JOIN arac a          ON a.musteri_id = r.musteri_id AND a.durum = 'SATILDI'
      JOIN versiyon v      ON v.versiyon_id = a.versiyon_id
      JOIN stok_hareketi sh ON sh.arac_vin = a.vin AND sh.hareket_turu = 'SATIS'
     WHERE r.tur_kodu = 'TEST_SURUSU'
       AND r.durum = 'TAMAMLANDI'
       AND r.baslangic >= '2025-11-01'
       AND sh.zaman > r.baslangic
     GROUP BY v.model_id
)
SELECT m.ad AS model_adi,
       coalesce(t.test_sayisi, 0) AS test_surusu,
       coalesce(s.satis_sayisi, 0) AS toplam_satis,
       coalesce(ts.test_ve_satis_musteri, 0) AS test_sonrasi_alan_musteri,
       round(coalesce(ts.test_ve_satis_musteri, 0)::numeric / nullif(t.test_sayisi, 0) * 100, 2) AS test_sonrasi_donusum_yuzdesi,
       round(coalesce(s.satis_sayisi, 0)::numeric / nullif(t.test_sayisi, 0) * 100, 2) AS toplam_satis_test_orani_yuzde,
       rank() OVER (ORDER BY coalesce(t.test_sayisi, 0) DESC) AS test_sirasi
  FROM model m
  LEFT JOIN test_surusleri t    ON t.model_id = m.model_id
  LEFT JOIN satislar s          ON s.model_id = m.model_id
  LEFT JOIN test_sonrasi_alan ts ON ts.model_id = m.model_id
 ORDER BY test_sirasi ASC;

-- 2. Şube ve Departman Bazında Aylık Çalışan Performans Sıralaması (4-way JOIN + HAVING + RANK)
WITH aylik AS (
    SELECT c.calisan_id,
           c.ad || ' ' || c.soyad AS calisan,
           rt.departman,
           count(*) AS adet
      FROM randevu r
      JOIN calisan c       ON c.calisan_id = r.calisan_id
      JOIN sube s          ON s.sube_id = r.sube_id
      JOIN randevu_turu rt ON rt.tur_kodu = r.tur_kodu
     WHERE r.sube_id = 1
       AND r.durum = 'TAMAMLANDI'
       AND r.baslangic >= '2026-10-01'
       AND r.baslangic < '2026-11-01'
     GROUP BY c.calisan_id, c.ad, c.soyad, rt.departman
    HAVING count(*) >= 3
)
SELECT calisan,
       departman,
       adet AS tamamlanan_randevu,
       rank() OVER (PARTITION BY departman ORDER BY adet DESC) AS departman_sirasi
  FROM aylik
 ORDER BY departman, departman_sirasi;

-- 3. Müşterinin Son 20 WhatsApp Mesaj Geçmişi ve Son Aktif Randevu Tarihi (216k mesaj + Correlated Subquery)
SELECT m.mesaj_id,
       m.yon,
       m.zaman,
       left(m.icerik, 40) AS ozet,
       (SELECT max(r.baslangic)
          FROM randevu r
         WHERE r.musteri_id = mu.musteri_id AND r.durum <> 'IPTAL') AS son_randevu
  FROM mesaj m
  JOIN musteri mu ON mu.musteri_id = m.musteri_id
 WHERE m.musteri_id = 1500
 ORDER BY m.zaman DESC
 LIMIT 20;

-- 4. Şube ve Sebebe Göre Servis Masraf Kırılımı (4-way JOIN + FILTER + HAVING, TL + %)
SELECT sk.sebep,
       count(DISTINCT sk.servis_kaydi_id) AS dosya_sayisi,
       sum(si.ucret) AS toplam_fatura,
       sum(si.ucret) FILTER (WHERE si.odeme_kaynagi = 'MUSTERI') AS musteri_payi,
       round(coalesce(sum(si.ucret) FILTER (WHERE si.odeme_kaynagi = 'MUSTERI'), 0)::numeric / nullif(sum(si.ucret), 0) * 100, 2) AS musteri_yuzde,
       sum(si.ucret) FILTER (WHERE si.odeme_kaynagi = 'GARANTI') AS garanti_payi,
       round(coalesce(sum(si.ucret) FILTER (WHERE si.odeme_kaynagi = 'GARANTI'), 0)::numeric / nullif(sum(si.ucret), 0) * 100, 2) AS garanti_yuzde,
       sum(si.ucret) FILTER (WHERE si.odeme_kaynagi = 'SIGORTA') AS sigorta_payi,
       round(coalesce(sum(si.ucret) FILTER (WHERE si.odeme_kaynagi = 'SIGORTA'), 0)::numeric / nullif(sum(si.ucret), 0) * 100, 2) AS sigorta_yuzde
  FROM randevu r
  JOIN servis_kaydi sk ON sk.acilis_randevu_id = r.randevu_id
  JOIN servis_islem si ON si.servis_kaydi_id = sk.servis_kaydi_id
  JOIN sube s          ON s.sube_id = r.sube_id
 WHERE r.sube_id = 1
   AND r.baslangic >= '2026-10-01'
   AND r.baslangic < '2026-11-01'
 GROUP BY sk.sebep
HAVING sum(si.ucret) > 0
 ORDER BY toplam_fatura DESC;

-- 5. Şube Bazında Servis Teslim Zamanlaması ve Gecikme Analizi (ARIZA + KAZA, CTE + 5-way JOIN + FILTER)
-- Not: Demo ad-hoc örneğinde şube+model kırılımı için SELECT ve GROUP BY'a `m.ad` eklenebilir.
WITH hazir AS (
    SELECT sk.servis_kaydi_id,
           r.sube_id,
           m.ad AS model_adi,
           sk.tahmini_teslim_tarihi,
           min(g.zaman)::date AS hazir_tarihi
      FROM servis_kaydi sk
      JOIN randevu r              ON r.randevu_id = sk.acilis_randevu_id
      JOIN arac a                 ON a.vin = r.arac_vin
      JOIN versiyon v             ON v.versiyon_id = a.versiyon_id
      JOIN model m                ON m.model_id = v.model_id
      JOIN servis_durum_gecmisi g ON g.servis_kaydi_id = sk.servis_kaydi_id
     WHERE g.durum = 'TESLIME_HAZIR'
       AND sk.tahmini_teslim_tarihi IS NOT NULL
       AND sk.sebep IN ('ARIZA', 'KAZA')
     GROUP BY sk.servis_kaydi_id, r.sube_id, m.ad, sk.tahmini_teslim_tarihi
)
SELECT s.ad AS sube,
       count(*) AS toplam_onarim,
       round(count(*) FILTER (WHERE hazir_tarihi <= tahmini_teslim_tarihi)::numeric / count(*) * 100, 2) AS zamaninda_yuzde,
       round(avg(hazir_tarihi - tahmini_teslim_tarihi)::numeric, 2) AS ort_sapma_gun,
       count(*) FILTER (WHERE hazir_tarihi > tahmini_teslim_tarihi) AS geciken_adet,
       round(avg(hazir_tarihi - tahmini_teslim_tarihi) FILTER (WHERE hazir_tarihi > tahmini_teslim_tarihi)::numeric, 2) AS geciken_ort_gecikme_gun
  FROM hazir h
  JOIN sube s ON s.sube_id = h.sube_id
 GROUP BY s.ad
 ORDER BY zamaninda_yuzde ASC;

-- 6. Garantisi Geçerli Araçlarda Arıza Masraflarının Garanti Karşılama Oranı (View + 4-way JOIN + HAVING)
SELECT gd.model_adi,
       count(si.islem_id) AS ariza_islem_sayisi,
       sum(si.ucret) FILTER (WHERE si.odeme_kaynagi = 'GARANTI') AS garanti_karsilanan,
       sum(si.ucret) FILTER (WHERE si.odeme_kaynagi = 'MUSTERI') AS musteri_odenen,
       round(
           coalesce(sum(si.ucret) FILTER (WHERE si.odeme_kaynagi = 'GARANTI'), 0)::numeric
           / nullif(sum(si.ucret), 0) * 100, 2
       ) AS garanti_karsilama_yuzde
  FROM servis_islem si
  JOIN servis_kaydi sk          ON sk.servis_kaydi_id = si.servis_kaydi_id
  JOIN randevu r                ON r.randevu_id = sk.acilis_randevu_id
  JOIN v_arac_garanti_durumu gd ON gd.vin = r.arac_vin
 WHERE sk.sebep = 'ARIZA'
   AND gd.garanti_durumu = 'GECERLI'
 GROUP BY gd.model_adi
HAVING count(si.islem_id) > 10
 ORDER BY garanti_karsilama_yuzde DESC;

-- 7. Model Bazında Erken Garanti Bozulma Analizi (View + CTE + Koşullu Oranlar)
-- Not: Garanti son yılında (son_bakim_tarihi + 1 yıl >= garanti_bitis) bakım yapılmaması
-- garanti zaten biteceği için "erken bozulma" sayılmaz.
WITH arac_analiz AS (
    SELECT gd.model_adi,
           m.garanti_yil,
           (gd.garanti_durumu = 'BAKIM_AKSATILDI'
            AND (gd.son_bakim_tarihi + interval '1 year')::date < gd.garanti_bitis) AS erken_bozuldu,
           round(
               (extract(epoch FROM ((gd.son_bakim_tarihi + interval '1 year')::timestamp - gd.garanti_baslangic::timestamp))
               / (365.25 * 86400))::numeric, 2
           ) AS bozulma_yili
      FROM v_arac_garanti_durumu gd
      JOIN model m ON m.ad = gd.model_adi
)
SELECT model_adi,
       garanti_yil,
       count(*) AS toplam_satilan_arac,
       count(*) FILTER (WHERE erken_bozuldu) AS erken_bozan_arac,
       round(count(*) FILTER (WHERE erken_bozuldu)::numeric / nullif(count(*), 0) * 100, 2) AS erken_bozulma_yuzde,
       round(count(*) FILTER (WHERE erken_bozuldu AND bozulma_yili <= 3)::numeric / nullif(count(*), 0) * 100, 2) AS ilk_3_yil_yuzde,
       round(count(*) FILTER (WHERE erken_bozuldu AND bozulma_yili <= 5)::numeric / nullif(count(*), 0) * 100, 2) AS ilk_5_yil_yuzde,
       round(avg(bozulma_yili) FILTER (WHERE erken_bozuldu), 2) AS ort_bozulma_yili
  FROM arac_analiz
 GROUP BY model_adi, garanti_yil
 ORDER BY erken_bozulma_yuzde DESC;

