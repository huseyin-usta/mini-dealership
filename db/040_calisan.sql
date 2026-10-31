-- Çalışan: tek şubede, tek departmanda (satış ya da servis) çalışan personel.
-- EER'deki "departmana göre ayrık kalıtım" tek tablo + departman sütunuyla çözülür
-- (ara rapor 3.3, randevu ile aynı karar).
CREATE TABLE calisan (
    calisan_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sube_id          integer      NOT NULL REFERENCES sube,
    ad               varchar(64)  NOT NULL,
    soyad            varchar(64)  NOT NULL,
    departman        varchar(10)  NOT NULL CHECK (departman IN ('SATIS', 'SERVIS')),
    eposta           varchar(254) NOT NULL UNIQUE,
    kullanici_adi    varchar(64)  NOT NULL UNIQUE,
    sifre_hash       varchar(100) NOT NULL,  -- panel girişi; hash uygulama tarafında üretilir (bcrypt), düz metin saklanmaz
    aktif_mi         boolean      NOT NULL DEFAULT true,  -- istihdam durumu (online durum değil): işten ayrılan çalışan silinemez (FK'lar), false yapılır
    ise_giris_tarihi date         NOT NULL
);
