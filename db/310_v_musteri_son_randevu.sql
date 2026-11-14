-- Müşterinin son randevusu (türetilmiş nitelik, saklanmaz).
-- Bot "son randevunuz Çankaya'daydı, yine orası mı olsun?" önerisini buradan yapar.
-- İptal edilen randevular sayılmaz; geçmiş veya gelecek fark etmez, en geç başlangıç alınır.
--
-- PII içermez (yalnızca musteri_id). security_invoker: view, sorgulayan rolün
-- yetkileri ve RLS politikalarıyla çalışır; böylece bot rolü RLS altında yalnızca
-- konuştuğu müşterinin satırını görür (view sahibinin yetkisiyle RLS delinmez).
CREATE VIEW v_musteri_son_randevu
WITH (security_invoker = true)
AS
SELECT DISTINCT ON (r.musteri_id)
       r.musteri_id,
       r.randevu_id,
       r.tur_kodu,
       rt.ad       AS tur_adi,
       r.sube_id,
       s.sehir,
       s.ad        AS sube_adi,
       r.baslangic,
       r.durum
  FROM randevu r
  JOIN randevu_turu rt ON rt.tur_kodu = r.tur_kodu
  JOIN sube s          ON s.sube_id   = r.sube_id
 WHERE r.durum <> 'IPTAL'
 ORDER BY r.musteri_id, r.baslangic DESC, r.randevu_id DESC;
