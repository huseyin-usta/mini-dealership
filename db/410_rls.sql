-- Satır bazlı güvenlik (RLS): bot yalnızca o an konuştuğu müşterinin satırlarını görür.
-- RLS açılan tabloda politikası olmayan rol hiçbir satır göremez; bu yüzden personel
-- için de açık (true) politika tanımlanır. Tablo sahibi (admin) RLS'den muaftır.
-- Müşteri kimliği: fn_aktif_musteri_id() / app.musteri_telefon (bkz. 400_roller.sql).

-- Müşteri: bot yalnızca kendi kaydını görür ve yalnızca kendi telefonuyla kayıt açar
ALTER TABLE musteri ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_musteri_personel ON musteri
    FOR ALL TO personel USING (true) WITH CHECK (true);

CREATE POLICY p_musteri_bot_oku ON musteri
    FOR SELECT TO bot
    USING (telefon = nullif(current_setting('app.musteri_telefon', true), ''));

CREATE POLICY p_musteri_bot_ekle ON musteri
    FOR INSERT TO bot
    WITH CHECK (telefon = nullif(current_setting('app.musteri_telefon', true), ''));

-- Randevu: bot kendi randevularını görür, kendi adına WhatsApp randevusu ekler,
-- yalnızca PLANLANDI randevusunu IPTAL'e çekebilir (başka durum yazamaz)
ALTER TABLE randevu ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_randevu_personel ON randevu
    FOR ALL TO personel USING (true) WITH CHECK (true);

CREATE POLICY p_randevu_bot_oku ON randevu
    FOR SELECT TO bot
    USING (musteri_id = fn_aktif_musteri_id());

CREATE POLICY p_randevu_bot_ekle ON randevu
    FOR INSERT TO bot
    WITH CHECK (musteri_id = fn_aktif_musteri_id() AND kaynak = 'WHATSAPP');

CREATE POLICY p_randevu_bot_iptal ON randevu
    FOR UPDATE TO bot
    USING (musteri_id = fn_aktif_musteri_id() AND durum = 'PLANLANDI')
    WITH CHECK (musteri_id = fn_aktif_musteri_id() AND durum = 'IPTAL');

-- Mesaj: bot yalnızca konuştuğu müşterinin geçmişini görür ve ona mesaj kaydeder;
-- personel "Bot konuşmaları" menüsü için okur
ALTER TABLE mesaj ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_mesaj_personel ON mesaj
    FOR SELECT TO personel USING (true);

CREATE POLICY p_mesaj_bot_oku ON mesaj
    FOR SELECT TO bot
    USING (musteri_id = fn_aktif_musteri_id());

CREATE POLICY p_mesaj_bot_ekle ON mesaj
    FOR INSERT TO bot
    WITH CHECK (musteri_id = fn_aktif_musteri_id());

-- Araç: bot stoktaki ve yoldaki araçları (stok sorusu, test sürüşü) ve müşterinin
-- kendi araçlarını (bakım / servis randevusu) görür; başkasının aracını görmez
ALTER TABLE arac ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_arac_personel ON arac
    FOR ALL TO personel USING (true) WITH CHECK (true);

CREATE POLICY p_arac_bot_oku ON arac
    FOR SELECT TO bot
    USING (durum IN ('STOKTA', 'YOLDA') OR musteri_id = fn_aktif_musteri_id());
