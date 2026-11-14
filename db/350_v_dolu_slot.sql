-- Dolu slotlar: iptal edilmemiş randevuların yalnızca zaman/kaynak bilgisi.
-- Bot müsaitlik hesaplarken başka müşterilerin randevularını görmek zorundadır
-- (çalışan ve araç meşgul mü?), ama RLS yüzünden randevu tablosunda yalnızca
-- konuştuğu müşterinin satırlarını görür. Bu view sahibinin (admin) yetkisiyle
-- çalışır ve müşteri kimliği içermez; böylece müsaitlik bilgisi PII'siz verilir.
-- Son savunma yine randevu tablosundaki EXCLUDE kısıtlarıdır.
CREATE VIEW v_dolu_slot
WITH (security_barrier = true)
AS
SELECT r.sube_id,
       r.calisan_id,
       r.arac_vin,
       r.baslangic,
       r.bitis
  FROM randevu r
 WHERE r.durum <> 'IPTAL';
