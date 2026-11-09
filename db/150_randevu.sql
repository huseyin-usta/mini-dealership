-- PostgreSQL'de skaler tiplerle (integer, varchar) GiST aralık kısıtları için gereklidir
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- Randevu: tüm randevu türlerinin (test sürüşü, servis, teslimat vb.)
-- toplandığı ana işlem tablosu (kalıtım tek tabloda düzleştirilmiştir).
CREATE TABLE randevu (
    randevu_id  integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    musteri_id  integer     NOT NULL REFERENCES musteri ON DELETE RESTRICT,
    sube_id     integer     NOT NULL REFERENCES sube,
    tur_kodu    varchar(32) NOT NULL REFERENCES randevu_turu,
    calisan_id  integer     NOT NULL REFERENCES calisan,
    arac_vin    varchar(17) REFERENCES arac(vin),
    versiyon_id integer     REFERENCES versiyon,
    baslangic   timestamp   NOT NULL,
    bitis       timestamp   NOT NULL,
    durum       varchar(16) NOT NULL DEFAULT 'PLANLANDI'
                            CHECK (durum IN ('PLANLANDI', 'TAMAMLANDI', 'IPTAL', 'GELMEDI')),
    kaynak      varchar(10) NOT NULL CHECK (kaynak IN ('WHATSAPP', 'PANEL')),
    notlar      text,

    CHECK (baslangic < bitis),

    -- Türe göre zorunlu alanlar (ara rapor 3.3 kalıtım kuralı):
    -- Fiziksel araç gerektiren türlerde arac_vin zorunludur
    CHECK (
        tur_kodu NOT IN ('TEST_SURUSU', 'TESLIMAT', 'PERIYODIK_BAKIM', 'SERVIS_GIRIS', 'SERVIS_TESLIM')
        OR arac_vin IS NOT NULL
    ),

    -- Çakışma kısıtları (ara rapor Tablo 2, iptal edilenler hariç):
    -- 1. Aynı çalışan aynı anda birden fazla randevuda olamaz
    EXCLUDE USING gist (
        calisan_id WITH =,
        tsrange(baslangic, bitis) WITH &&
    ) WHERE (durum <> 'IPTAL'),

    -- 2. Aynı araç aynı anda birden fazla randevuda olamaz
    EXCLUDE USING gist (
        arac_vin WITH =,
        tsrange(baslangic, bitis) WITH &&
    ) WHERE (arac_vin IS NOT NULL AND durum <> 'IPTAL'),

    -- 3. Aynı müşteri aynı anda birden fazla randevuda olamaz
    EXCLUDE USING gist (
        musteri_id WITH =,
        tsrange(baslangic, bitis) WITH &&
    ) WHERE (durum <> 'IPTAL')
);

