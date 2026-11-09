-- Servis Durum Geçmişi: bir servis kaydının geçtiği aşamaların tarihçesi
-- (kargo takip mantığı gibi kronolojik event log tutulur).
-- Servis kaydı silinirse geçmiş kayıtları da silinir (CASCADE).
CREATE TABLE servis_durum_gecmisi (
    gecmis_id       integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    servis_kaydi_id integer     NOT NULL REFERENCES servis_kaydi ON DELETE CASCADE,
    durum           varchar(32) NOT NULL 
                    CHECK (durum IN (
                        'INCELENIYOR', 
                        'PARCA_BEKLENIYOR', 
                        'EKSPERTIZ_BEKLENIYOR', 
                        'ISLEMDE', 
                        'TESLIME_HAZIR', 
                        'TAMAMLANDI'
                    )),
    zaman           timestamptz NOT NULL DEFAULT now(),
    aciklama        text,
    UNIQUE (servis_kaydi_id, zaman)
);

