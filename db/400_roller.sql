-- Veritabanı rolleri: uygulamanın her parçası kendi rolüyle bağlanır.
--   admin    : şemanın sahibi, tam yetki (migration / bakım)
--   personel : panel; randevu, araç, müşteri ve servis kayıtlarını okur, ekler, günceller
--   bot      : WhatsApp botu; müşteri adına çalışır, RLS ile yalnızca o müşteriyi görür
--   rapor    : yalnızca (maskeli) view'ları okur
-- Hiçbir role DELETE verilmez: iptal = durum değişikliği.
--
-- Roller NOLOGIN grup rolleridir; şifre repoda tutulmaz. Kurulumda (Docker Compose
-- init) şifreleri env'den gelen login kullanıcıları oluşturulup bu rollere üye yapılır:
--   CREATE ROLE panel_app LOGIN PASSWORD '...' IN ROLE personel;
-- Roller cluster genelidir; dosya tekrar çalıştırılabilir olsun diye varlık kontrolü yapılır.
DO $$
DECLARE
    v_rol text;
BEGIN
    FOREACH v_rol IN ARRAY ARRAY['admin', 'personel', 'bot', 'rapor'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_rol) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOBYPASSRLS', v_rol);
        END IF;
    END LOOP;
END $$;

-- Botun konuştuğu müşteri: backend her transaction'da WhatsApp JID'sinden çıkardığı
-- telefonu oturum değişkenine yazar (LLM argümanından ASLA):
--   SET LOCAL app.musteri_telefon = '+905321234567';
-- Değişken yoksa NULL döner -> RLS hiçbir satır göstermez (fail-closed).
-- SECURITY DEFINER: müşteri tablosundaki RLS'ye takılmadan id'yi bulur; yalnızca
-- oturumdaki telefonun kendi id'sini döndürdüğü için başka bilgi sızdırmaz.
CREATE OR REPLACE FUNCTION fn_aktif_musteri_id()
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT musteri_id
      FROM musteri
     WHERE telefon = nullif(current_setting('app.musteri_telefon', true), '')
$$;

-- Panel girişi: personel rolü calisan.sifre_hash kolonunu okuyamaz (kolon yetkisi);
-- giriş için yalnızca verilen kullanıcı adının hash'i bu fonksiyonla alınır.
-- bcrypt doğrulaması backend'de (Java) yapılır.
CREATE OR REPLACE FUNCTION fn_panel_giris(p_kullanici_adi text)
RETURNS TABLE (calisan_id integer, sube_id integer, departman varchar, sifre_hash varchar)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT c.calisan_id, c.sube_id, c.departman, c.sifre_hash
      FROM calisan c
     WHERE c.kullanici_adi = p_kullanici_adi
       AND c.aktif_mi
$$;
