-- Servis Kaydı: servise gelen aracın bakım, arıza veya kaza süreci.
-- Açılış ve teslim randevuları birebirdir (UNIQUE); araç açılış randevusundan izlenir.
-- Kilometre bilgisi burada tutulur (araç tablosunda kilometre tutulmaz).
CREATE TABLE servis_kaydi (
    servis_kaydi_id        integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    acilis_randevu_id      integer     NOT NULL UNIQUE REFERENCES randevu,
    teslim_randevu_id      integer     UNIQUE REFERENCES randevu,
    sorumlu_calisan_id     integer     NOT NULL REFERENCES calisan,
    sebep                  varchar(10) NOT NULL CHECK (sebep IN ('BAKIM', 'ARIZA', 'KAZA')),
    giris_kilometresi      integer     NOT NULL CHECK (giris_kilometresi >= 0),
    cikis_kilometresi      integer,
    tahmini_teslim_tarihi  date,
    sikayet_aciklama       text,

    -- Açılış ve teslim randevusu aynı olamaz
    CHECK (teslim_randevu_id IS NULL OR teslim_randevu_id <> acilis_randevu_id),

    -- Çıkış kilometresi varsa, giriş kilometresinden küçük olamaz
    CHECK (cikis_kilometresi IS NULL OR cikis_kilometresi >= giris_kilometresi)
);

