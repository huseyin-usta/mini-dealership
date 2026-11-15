-- Performans indeksleri: 453k+ satırlık sentetik veri ve analitik/operasyonel
-- sorguların EXPLAIN ANALYZE ölçümlerine göre hedefli olarak tasarlanmıştır.
-- Her indeks belirli bir dar boğazı (FK taraması, tarih penceresi, partial filtre) çözer.

-- 1. Randevu: tür + durum + tarih aralığı (analitik dönüşüm ve panel filtreleri)
CREATE INDEX idx_randevu_tur_durum_baslangic
    ON randevu (tur_kodu, durum, baslangic);

-- 2. Randevu: şube + tarih aralığı (panel "Bugünkü randevular" ve bot 21 günlük v_dolu_slot)
CREATE INDEX idx_randevu_sube_baslangic
    ON randevu (sube_id, baslangic) INCLUDE (durum, tur_kodu);

-- 3. Randevu: araç bazlı tarama (garanti trigger'ı ve v_arac_garanti_durumu bakım geçmişi)
CREATE INDEX idx_randevu_arac_vin
    ON randevu (arac_vin) WHERE arac_vin IS NOT NULL;

-- 4. Mesaj: müşterinin son konuşma geçmişini sıralamadan (Sort'suz) çekmek için
CREATE INDEX idx_mesaj_musteri_zaman
    ON mesaj (musteri_id, zaman DESC);

-- 5. Mesaj: tarih aralıklı trafik analizleri (Index-Only Scan)
CREATE INDEX idx_mesaj_zaman
    ON mesaj (zaman) INCLUDE (musteri_id, yon);

-- 6. Servis İşlem: servis kaydı FK indeksi (v_servis_durumu ve fatura toplamları)
CREATE INDEX idx_servis_islem_kayit_id
    ON servis_islem (servis_kaydi_id) INCLUDE (odeme_kaynagi, ucret);

-- 7. Servis İşlem: yalnızca garanti ödemeleri için partial index
CREATE INDEX idx_servis_islem_garanti
    ON servis_islem (odeme_kaynagi) INCLUDE (servis_kaydi_id, ucret)
    WHERE odeme_kaynagi = 'GARANTI';

-- 8. Servis Kaydı: yalnızca henüz teslim edilmemiş açık kayıtlar (partial index)
CREATE INDEX idx_servis_kaydi_acik_tahmin
    ON servis_kaydi (tahmini_teslim_tarihi)
    WHERE teslim_randevu_id IS NULL;

-- 9. Stok Hareketi: araç bazlı hareket tarihçesi (garanti başlangıcı ve stok süresi)
CREATE INDEX idx_stok_hareketi_arac_zaman
    ON stok_hareketi (arac_vin, zaman);

-- 10. Stok Hareketi: hareket türü + tarih aralığı (dönemsel satış raporları)
CREATE INDEX idx_stok_hareketi_tur_zaman
    ON stok_hareketi (hareket_turu, zaman) INCLUDE (arac_vin, kaynak_sube_id);

-- 11. Araç: şube + durum (panel araç listesi ve bot stok sorguları)
CREATE INDEX idx_arac_sube_durum
    ON arac (sube_id, durum);

