-- Mesaj idempotency: köprü, WhatsApp mesaj kimliğini (wamid) iletir.
--
-- Aynı mesaj iki kez gelirse (köprü yeniden dener, çift tıklama, ağ tekrarı)
-- LLM ikinci kez çalışmamalı: aksi halde "randevu oluştur" aracı ikinci bir
-- randevu yazabilir. kaynak_id bu tekrarı yakalar.
--
-- NULL'a izin verilir: kaynak kimliği göndermeyen çağrılar (test, elle deneme)
-- eskisi gibi çalışır. Bu yüzden UNIQUE kısmi indekstir.

ALTER TABLE mesaj ADD COLUMN kaynak_id varchar(128);

CREATE UNIQUE INDEX uq_mesaj_kaynak_id
    ON mesaj (kaynak_id)
    WHERE kaynak_id IS NOT NULL;

COMMENT ON COLUMN mesaj.kaynak_id IS
    'Dış kaynak mesaj kimliği (ör. WhatsApp wamid); aynı kimlik ikinci kez işlenmez.';
