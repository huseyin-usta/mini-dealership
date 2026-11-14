-- Yetkiler (GRANT / REVOKE). Bu dosya en son çalışır: tüm tablo, view ve
-- fonksiyonlar oluşmuş olmalıdır. Hiçbir role DELETE / TRUNCATE verilmez.

-- 1. Sahiplik: şemadaki tüm tablo, view ve (extension dışı) fonksiyonlar admin'e geçer.
--    View'lar sahibinin yetkisiyle çalıştığından maskeli view'lar admin adına okur;
--    tablo sahibi olarak admin RLS'den muaftır.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.relname, c.relkind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm')
    LOOP
        EXECUTE format('ALTER %s public.%I OWNER TO admin',
                       CASE r.relkind WHEN 'v' THEN 'VIEW'
                                      WHEN 'm' THEN 'MATERIALIZED VIEW'
                                      ELSE 'TABLE' END,
                       r.relname);
    END LOOP;

    FOR r IN
        SELECT p.oid::regprocedure AS imza
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND NOT EXISTS (SELECT 1 FROM pg_depend d     -- btree_gist gibi extension fonksiyonları hariç
                            WHERE d.objid = p.oid AND d.deptype = 'e')
    LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO admin', r.imza);
    END LOOP;
END $$;

-- 2. Doğrulama trigger'ları çağıranın yetkisiyle değil, admin yetkisiyle çalışır.
--    Aksi halde bot RLS yüzünden başka müşterinin aracını göremez, trigger aracı
--    NULL okur ve "test sürüşü aracı STOKTA olmalı" kontrolü atlanırdı.
ALTER FUNCTION fn_randevu_dogrula()              SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION fn_servis_islem_garanti_kontrol() SECURITY DEFINER SET search_path = public, pg_temp;

-- 3. Şema: varsayılan PUBLIC yetkileri kaldırılır, yalnızca uygulama rolleri kullanır
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO admin;
GRANT USAGE ON SCHEMA public TO personel, bot, rapor;

-- Fonksiyonlarda EXECUTE varsayılan olarak PUBLIC'tedir; kimlik fonksiyonları kısıtlanır
REVOKE EXECUTE ON FUNCTION fn_aktif_musteri_id()  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_panel_giris(text)   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fn_maskele_telefon(text), fn_maskele_ad(text) FROM PUBLIC;

-- 4. personel (panel)
--    Okuma: tüm tablolar; ancak çalışanın şifre hash'i hariç (kolon yetkisi)
GRANT SELECT ON sube, mesai, yetkinlik, calisan_yetkinlik, model, versiyon,
                versiyon_ozellik, musteri, mesaj, arac, stok_hareketi, randevu_turu,
                tur_saat, randevu, servis_kaydi, servis_durum_gecmisi, servis_islem,
                sigorta_sirketi, servis_sigorta
      TO personel;
GRANT SELECT (calisan_id, sube_id, ad, soyad, departman, eposta, kullanici_adi,
              aktif_mi, ise_giris_tarihi)
      ON calisan TO personel;

--    Ekleme + güncelleme: randevu, araç, müşteri ve servis kayıtları
GRANT INSERT, UPDATE ON musteri, arac, randevu, servis_kaydi, servis_islem,
                        servis_sigorta, sigorta_sirketi
      TO personel;
--    Olay kayıtları (log) yalnızca eklenir, geçmiş değiştirilemez
GRANT INSERT ON stok_hareketi, servis_durum_gecmisi TO personel;

GRANT SELECT ON v_musteri_son_randevu, v_servis_durumu, v_arac_garanti_durumu, v_dolu_slot
      TO personel;
GRANT EXECUTE ON FUNCTION fn_panel_giris(text) TO personel;

-- 5. bot (WhatsApp, müşteri adına)
--    Katalog ve müsaitlik bilgisi (PII içermez)
GRANT SELECT ON sube, mesai, yetkinlik, calisan_yetkinlik, model, versiyon,
                versiyon_ozellik, randevu_turu, tur_saat
      TO bot;
--    Çalışan ataması için yalnızca kimlik/şube/departman; ad, e-posta, hash görünmez
GRANT SELECT (calisan_id, sube_id, departman, aktif_mi) ON calisan TO bot;
--    RLS'li tablolar: yalnızca konuşulan müşterinin satırları
GRANT SELECT, INSERT ON musteri, mesaj, randevu TO bot;
GRANT SELECT ON arac TO bot;
--    İptal: yalnızca durum kolonu güncellenebilir (RLS ayrıca yalnızca IPTAL'e izin verir)
GRANT UPDATE (durum) ON randevu TO bot;

GRANT SELECT ON v_dolu_slot, v_musteri_son_randevu TO bot;
GRANT EXECUTE ON FUNCTION fn_aktif_musteri_id() TO bot;   -- RLS politikaları çağırır

-- 6. rapor (Excel raporu, istatistikler): yalnızca view'lar; müşteri tablosuna erişim yok
GRANT SELECT ON v_rapor_musteri, v_rapor_randevu, v_servis_durumu, v_arac_garanti_durumu
      TO rapor;
GRANT EXECUTE ON FUNCTION fn_maskele_telefon(text), fn_maskele_ad(text) TO rapor;
