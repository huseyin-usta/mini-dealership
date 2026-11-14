-- Servis kaydının güncel durumu ve kalan süresi (türetilmiş nitelik, saklanmaz).
-- Panelin "Servis kayıtları" ekranı ve "tahmini teslim tarihi geçmiş kayıtlar"
-- raporu bu view'dan beslenir. Tahmin tarih olarak saklanır; kalan gün burada,
-- "kaç hafta kaldı" gösterimi panelde hesaplanır.
-- PII içermez (müşteri yalnızca musteri_id ile).
CREATE VIEW v_servis_durumu AS
SELECT sk.servis_kaydi_id,
       r.sube_id,
       r.arac_vin,
       r.musteri_id,
       sk.sorumlu_calisan_id,
       sk.sebep,
       sk.giris_kilometresi,
       r.baslangic                AS giris_zamani,
       son.durum                  AS son_durum,
       son.zaman                  AS son_durum_zamani,
       (sk.teslim_randevu_id IS NOT NULL
        OR son.durum IS NOT DISTINCT FROM 'TAMAMLANDI') AS kapandi_mi,
       sk.tahmini_teslim_tarihi,
       sk.tahmini_teslim_tarihi - current_date AS kalan_gun,  -- tahmin girilmediyse NULL
       -- Kapanmamış, tahmini tarihi geçmiş kayıt: gecikmede (tahmin yoksa false)
       coalesce(sk.tahmini_teslim_tarihi < current_date, false)
        AND sk.teslim_randevu_id IS NULL
        AND son.durum IS DISTINCT FROM 'TAMAMLANDI' AS gecikti_mi,
       coalesce(m.toplam_masraf, 0)   AS toplam_masraf,
       coalesce(m.musteri_payi, 0)    AS musteri_payi,
       coalesce(m.garanti_payi, 0)    AS garanti_payi,
       coalesce(m.sigorta_payi, 0)    AS sigorta_payi
  FROM servis_kaydi sk
  JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id
  LEFT JOIN LATERAL (
        SELECT g.durum, g.zaman
          FROM servis_durum_gecmisi g
         WHERE g.servis_kaydi_id = sk.servis_kaydi_id
         ORDER BY g.zaman DESC
         LIMIT 1
       ) son ON true
  LEFT JOIN LATERAL (
        SELECT sum(i.ucret)                                              AS toplam_masraf,
               sum(i.ucret) FILTER (WHERE i.odeme_kaynagi = 'MUSTERI')   AS musteri_payi,
               sum(i.ucret) FILTER (WHERE i.odeme_kaynagi = 'GARANTI')   AS garanti_payi,
               sum(i.ucret) FILTER (WHERE i.odeme_kaynagi = 'SIGORTA')   AS sigorta_payi
          FROM servis_islem i
         WHERE i.servis_kaydi_id = sk.servis_kaydi_id
       ) m ON true;
