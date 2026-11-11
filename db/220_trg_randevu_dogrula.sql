-- Randevu Doğrulama Trigger'ı:
-- Randevu oluşturulurken veya güncellenirken tüm miniworld kurallarını denetler:
-- 1. Çalışan şube ve aktiflik kontrolü
-- 2. Çalışan departman ve yetkinlik sertifikası kontrolü
-- 3. Yoldaki araç varış tarihi ve stoktaki araç şube kontrolü
-- 4. Randevu süresi ve tür_saat penceresi uyumluluğu
CREATE OR REPLACE FUNCTION fn_randevu_dogrula()
RETURNS trigger AS $$
DECLARE
    v_calisan_sube_id    integer;
    v_calisan_departman  varchar(10);
    v_calisan_aktif      boolean;
    v_tur_departman      varchar(10);
    v_tur_sure           smallint;
    v_tur_yetkinlik_id   integer;
    v_arac_sube_id       integer;
    v_arac_durum         varchar(10);
    v_arac_varis_tarihi  date;
    v_gun                smallint;
    v_sure_dk            integer;
    v_yetkinlik_var_mi   boolean;
    v_saat_uygun_mu      boolean;
BEGIN
    -- Sadece aktif (iptal edilmemiş) randevularda doğrulama yap
    IF NEW.durum = 'IPTAL' THEN
        RETURN NEW;
    END IF;

    -- 1. Çalışan bilgilerini çek ve şube/aktiflik kontrolü yap
    SELECT sube_id, departman, aktif_mi
      INTO v_calisan_sube_id, v_calisan_departman, v_calisan_aktif
      FROM calisan
     WHERE calisan_id = NEW.calisan_id;

    IF NOT v_calisan_aktif THEN
        RAISE EXCEPTION 'İşten ayrılmış / pasif bir çalışana randevu atanamaz (calisan_id: %)', NEW.calisan_id;
    END IF;

    IF v_calisan_sube_id <> NEW.sube_id THEN
        RAISE EXCEPTION 'Çalışanın şubesi (%) ile randevu şubesi (%) uyuşmuyor.', v_calisan_sube_id, NEW.sube_id;
    END IF;

    -- 2. Randevu türü bilgilerini çek ve departman kontrolü yap
    SELECT departman, sure_dakika, yetkinlik_id
      INTO v_tur_departman, v_tur_sure, v_tur_yetkinlik_id
      FROM randevu_turu
     WHERE tur_kodu = NEW.tur_kodu;

    IF v_calisan_departman <> v_tur_departman THEN
        RAISE EXCEPTION 'Çalışanın departmanı (%) ile randevu türünün departmanı (%) uyuşmuyor.',
            v_calisan_departman, v_tur_departman;
    END IF;

    -- Yetkinlik şartı varsa çalışanın bu yetkinliğe sahip olduğunu doğrula
    IF v_tur_yetkinlik_id IS NOT NULL THEN
        SELECT EXISTS (
            SELECT 1 FROM calisan_yetkinlik
             WHERE calisan_id = NEW.calisan_id
               AND yetkinlik_id = v_tur_yetkinlik_id
               AND verilis_tarihi <= NEW.baslangic::date
               AND (bitis_tarihi IS NULL OR bitis_tarihi >= NEW.baslangic::date)
        ) INTO v_yetkinlik_var_mi;

        IF NOT v_yetkinlik_var_mi THEN
            RAISE EXCEPTION 'Çalışanın bu randevu türü için gereken yetkinlik sertifikası bulunmamaktadır (calisan_id: %, yetkinlik_id: %)',
                NEW.calisan_id, v_tur_yetkinlik_id;
        END IF;
    END IF;

    -- 3. Süre kontrolü (dakika cinsinden tam uyuşmalı)
    v_sure_dk := EXTRACT(EPOCH FROM (NEW.bitis - NEW.baslangic)) / 60;
    IF v_sure_dk <> v_tur_sure THEN
        RAISE EXCEPTION 'Randevu süresi (% dk) bu randevu türünün standart süresine (% dk) eşit olmalıdır.',
            v_sure_dk, v_tur_sure;
    END IF;

    -- 4. Tür saat penceresi kontrolü (randevu izin verilen saat aralığında mı?)
    -- ISO gün: 1 = Pazartesi ... 7 = Pazar
    v_gun := EXTRACT(ISODOW FROM NEW.baslangic);

    SELECT EXISTS (
        SELECT 1 FROM tur_saat
         WHERE tur_kodu = NEW.tur_kodu
           AND gun = v_gun
           AND baslangic <= NEW.baslangic::time
           AND bitis >= NEW.bitis::time
    ) INTO v_saat_uygun_mu;

    IF NOT v_saat_uygun_mu THEN
        RAISE EXCEPTION 'Randevu saati (% - %) haftanın %. günü için % türünde tanımlanmış geçerli saat aralıklarında değildir.',
            NEW.baslangic::time, NEW.bitis::time, v_gun, NEW.tur_kodu;
    END IF;

    -- 5. Araç kuralları kontrolü (arac_vin doluysa)
    IF NEW.arac_vin IS NOT NULL THEN
        SELECT sube_id, durum, tahmini_varis_tarihi
          INTO v_arac_sube_id, v_arac_durum, v_arac_varis_tarihi
          FROM arac
         WHERE vin = NEW.arac_vin;

        -- a) Test sürüşünde araç randevu şubesinde ve STOKTA olmalı
        IF NEW.tur_kodu = 'TEST_SURUSU' THEN
            IF v_arac_durum <> 'STOKTA' OR v_arac_sube_id <> NEW.sube_id THEN
                RAISE EXCEPTION 'Test sürüşü aracı randevu şubesinde ve STOKTA olmalıdır (Araç Şube: %, Durum: %)',
                    v_arac_sube_id, v_arac_durum;
            END IF;
        END IF;

        -- b) Yeni araç teslimatında yoldaki araç varış tarihinden önce teslim edilemez
        IF NEW.tur_kodu = 'TESLIMAT' AND v_arac_durum = 'YOLDA' THEN
            IF NEW.baslangic::date < v_arac_varis_tarihi THEN
                RAISE EXCEPTION 'Yoldaki aracın teslim randevusu varış tarihinden (%) önce verilemez (Randevu: %)',
                    v_arac_varis_tarihi, NEW.baslangic::date;
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_randevu_dogrula
BEFORE INSERT OR UPDATE ON randevu
FOR EACH ROW
EXECUTE FUNCTION fn_randevu_dogrula();
