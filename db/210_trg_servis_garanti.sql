-- Servis İşlem & Garanti Doğrulama Trigger'ı:
-- 1. Sebebe göre ödeme kaynağını denetler (BAKIM: MUSTERI, KAZA: MUSTERI/SIGORTA, ARIZA: MUSTERI/GARANTI).
-- 2. "GARANTI" ödemesi için aracın garanti süresi/km'sini ve periyodik bakım geçmişini (1 yıl / 15.000 km kuralı) hesaplar.
CREATE OR REPLACE FUNCTION fn_servis_islem_garanti_kontrol()
RETURNS trigger AS $$
DECLARE
    v_sebep              varchar(10);
    v_arac_vin           varchar(17);
    v_giris_km           integer;
    v_servis_zamani      timestamptz;
    v_satis_zamani       timestamptz;
    v_garanti_yil        integer;
    v_garanti_km         integer;
    v_onceki_tarih       timestamptz;
    v_onceki_km          integer;
    v_bakim              RECORD;
BEGIN
    -- 1. İlgili servis kaydı, randevu ve araç bilgilerini çek
    SELECT sk.sebep, sk.giris_kilometresi, r.baslangic, r.arac_vin
      INTO v_sebep, v_giris_km, v_servis_zamani, v_arac_vin
      FROM servis_kaydi sk
      JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id
     WHERE sk.servis_kaydi_id = NEW.servis_kaydi_id;

    -- 2. Sebebe göre ödeme kaynağı kısıtı kontrolü
    IF v_sebep = 'BAKIM' AND NEW.odeme_kaynagi <> 'MUSTERI' THEN
        RAISE EXCEPTION 'Bakım masraflarını yalnızca müşteri ödeyebilir (servis_kaydi_id: %, odeme: %)',
            NEW.servis_kaydi_id, NEW.odeme_kaynagi;
    ELSIF v_sebep = 'KAZA' AND NEW.odeme_kaynagi NOT IN ('MUSTERI', 'SIGORTA') THEN
        RAISE EXCEPTION 'Kaza masraflarını yalnızca müşteri veya sigorta ödeyebilir (servis_kaydi_id: %, odeme: %)',
            NEW.servis_kaydi_id, NEW.odeme_kaynagi;
    ELSIF v_sebep = 'ARIZA' AND NEW.odeme_kaynagi NOT IN ('MUSTERI', 'GARANTI') THEN
        RAISE EXCEPTION 'Arıza masraflarını yalnızca müşteri veya garanti ödeyebilir (servis_kaydi_id: %, odeme: %)',
            NEW.servis_kaydi_id, NEW.odeme_kaynagi;
    END IF;

    -- 3. Ödeme kaynağı GARANTI ise garanti geçerliliğini hesapla
    IF NEW.odeme_kaynagi = 'GARANTI' THEN
        -- Modelin garanti sınırlarını çek
        SELECT m.garanti_yil, m.garanti_km
          INTO v_garanti_yil, v_garanti_km
          FROM arac a
          JOIN versiyon v ON v.versiyon_id = a.versiyon_id
          JOIN model m ON m.model_id = v.model_id
         WHERE a.vin = v_arac_vin;

        -- Aracın ilk satış tarihini çek (garantinin başlangıç anı)
        SELECT sh.zaman
          INTO v_satis_zamani
          FROM stok_hareketi sh
         WHERE sh.arac_vin = v_arac_vin AND sh.hareket_turu = 'SATIS'
         ORDER BY sh.zaman ASC
         LIMIT 1;

        -- Henüz satılmamış veya satış kaydı olmayan araç garanti kapsamında işlem göremez
        IF v_satis_zamani IS NULL THEN
            RAISE EXCEPTION 'Satış kaydı bulunmayan araca garanti ödemesi girilemez (VIN: %)', v_arac_vin;
        END IF;

        -- a) Model toplam KM sınırı kontrolü
        IF v_giris_km > v_garanti_km THEN
            RAISE EXCEPTION 'Araç model garanti kilometresini aşmıştır (% km > % km). Garanti uygulanamaz.',
                v_giris_km, v_garanti_km;
        END IF;

        -- b) Model toplam YIL sınırı kontrolü
        IF v_servis_zamani > v_satis_zamani + (v_garanti_yil || ' years')::interval THEN
            RAISE EXCEPTION 'Araç model garanti süresini doldurmuştur (% yıl). Garanti uygulanamaz.',
                v_garanti_yil;
        END IF;

        -- c) Periyodik Bakım Geçmişi Kontrolü (Sabit kural: 1 yıl / 15.000 km)
        -- Başlangıç noktası: Satış tarihi ve 0 KM
        v_onceki_tarih := v_satis_zamani;
        v_onceki_km    := 0;

        FOR v_bakim IN
            SELECT r.baslangic AS bakim_tarihi, sk.giris_kilometresi AS bakim_km
              FROM servis_kaydi sk
              JOIN randevu r ON r.randevu_id = sk.acilis_randevu_id
             WHERE r.arac_vin = v_arac_vin
               AND sk.sebep = 'BAKIM'
               AND sk.servis_kaydi_id <> NEW.servis_kaydi_id
               AND r.durum NOT IN ('IPTAL', 'GELMEDI')
               AND r.baslangic <= v_servis_zamani
             ORDER BY r.baslangic ASC
        LOOP
            -- İki bakım arası süre 1 yılı (365 gün) veya 15.000 km'yi aşmış mı?
            IF v_bakim.bakim_tarihi > v_onceki_tarih + interval '1 year'
               OR (v_bakim.bakim_km - v_onceki_km) > 15000 THEN
                RAISE EXCEPTION 'Aracın garantisi aksatılan periyodik bakım nedeniyle düşmüştür. Aralık: % gün, % km (Sınır: 1 yıl / 15.000 km)',
                    EXTRACT(DAY FROM (v_bakim.bakim_tarihi - v_onceki_tarih)),
                    (v_bakim.bakim_km - v_onceki_km);
            END IF;

            v_onceki_tarih := v_bakim.bakim_tarihi;
            v_onceki_km    := v_bakim.bakim_km;
        END LOOP;

        -- Son bakımdan mevcut arıza servisine kadar olan süre/km kontrolü
        IF v_servis_zamani > v_onceki_tarih + interval '1 year'
           OR (v_giris_km - v_onceki_km) > 15000 THEN
            RAISE EXCEPTION 'Aracın periyodik bakım süresi/kilometresi dolmuş ve aksatılmıştır. Son bakımdan beri: % gün, % km (Sınır: 1 yıl / 15.000 km). Garanti uygulanamaz.',
                EXTRACT(DAY FROM (v_servis_zamani - v_onceki_tarih)),
                (v_giris_km - v_onceki_km);
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_servis_islem_garanti
BEFORE INSERT OR UPDATE ON servis_islem
FOR EACH ROW
EXECUTE FUNCTION fn_servis_islem_garanti_kontrol();

