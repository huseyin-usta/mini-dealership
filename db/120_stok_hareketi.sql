-- Stok hareketi: aracın geliş, satış ve şubeler arası transfer kaydı.
-- Tür semantiği: SIPARIS ve GELIS'te kaynak NULL (fabrika); TRANSFER'de ikisi de dolu;
-- SATIS'ta kaynak şube dolu, hedef NULL (araç ağdan çıktı).
CREATE TABLE stok_hareketi (
    hareket_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    arac_vin        varchar(17) NOT NULL REFERENCES arac (vin),
    hareket_turu    varchar(10) NOT NULL CHECK (hareket_turu IN ('SIPARIS', 'GELIS', 'TRANSFER', 'SATIS')),
    zaman           timestamptz NOT NULL DEFAULT now(),
    kaynak_sube_id  integer REFERENCES sube,
    hedef_sube_id   integer REFERENCES sube,
    CHECK (hareket_turu <> 'TRANSFER' OR (kaynak_sube_id IS NOT NULL AND hedef_sube_id IS NOT NULL AND kaynak_sube_id <> hedef_sube_id)),
    CHECK (hareket_turu NOT IN ('SIPARIS', 'GELIS') OR (kaynak_sube_id IS NULL AND hedef_sube_id IS NOT NULL)),
    CHECK (hareket_turu <> 'SATIS' OR (kaynak_sube_id IS NOT NULL AND hedef_sube_id IS NULL))
);
