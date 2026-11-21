-- Müşteri bilgisi: kimlik telefondur, ad/soyad sonradan öğrenilebilir.
--
-- Ara rapor: "Müşteriyi telefon numarası tanımlar". Bot konuşma sırasında önce
-- isim, sonra soyad öğrenebilir; bu yüzden ad/soyad zorunlu değildir.
--
-- Bu dosya mühürlü şema dosyalarını (010–430) değiştirmez; yalnızca gereken
-- gevşetmeyi ve bot yetkisini ekler.

-- 1) Ad/soyad artık NULL olabilir (telefonla kayıt açılabilir).
ALTER TABLE musteri ALTER COLUMN ad    DROP NOT NULL;
ALTER TABLE musteri ALTER COLUMN soyad DROP NOT NULL;

-- 2) Bot, konuştuğu müşterinin ad/soyadını güncelleyebilir.
--    Yalnız bu iki kolon: telefon (kimlik) ve kayıt zamanı değiştirilemez.
GRANT UPDATE (ad, soyad) ON musteri TO bot;

-- 3) RLS: bot yalnızca kendi telefonunun satırını güncelleyebilir.
--    WITH CHECK aynı koşulu doğrular: güncelleme satırın sahibini değiştiremez.
DROP POLICY IF EXISTS p_musteri_bot_guncelle ON musteri;
CREATE POLICY p_musteri_bot_guncelle ON musteri
    FOR UPDATE TO bot
    USING  (telefon = nullif(current_setting('app.musteri_telefon', true), ''))
    WITH CHECK (telefon = nullif(current_setting('app.musteri_telefon', true), ''));
