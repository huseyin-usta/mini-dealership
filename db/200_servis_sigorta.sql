-- Servis Sigorta: kaza nedeniyle servise alınan araçların sigorta/kasko dosya detayları.
-- Bir servis kaydının en fazla bir sigorta dosyası olur (PK: servis_kaydi_id).
-- Servis kaydı silinirse sigorta kaydı da silinir (CASCADE).
CREATE TABLE servis_sigorta (
    servis_kaydi_id integer      PRIMARY KEY REFERENCES servis_kaydi ON DELETE CASCADE,
    sirket_id       integer      NOT NULL REFERENCES sigorta_sirketi,
    dosya_no        varchar(64)  NOT NULL,
    eksper          varchar(128),
    onaylanan_tutar bigint       NOT NULL DEFAULT 0 CHECK (onaylanan_tutar >= 0),  -- tam sayı TL
    UNIQUE (sirket_id, dosya_no)
);

