# Mini-Dealership — Analitik Sorgular ve İndeks Performans Analizi

Bu doküman, `veri/uret.py` ile üretilen **453.096 ana işlem satırı** (toplamda 650.000+ satır) üzerinde PostgreSQL 17 `EXPLAIN (ANALYZE, BUFFERS)` kullanılarak gerçekleştirilen indeks öncesi (**Baseline**) ve indeks sonrası (**Indexed**) sorgu maliyeti analizini içerir.

> [!NOTE]
> Tüm sorgular [sorgular.sql](sorgular.sql) dosyasında, indeks tanımları ise [500_indeksler.sql](../../db/500_indeksler.sql) dosyasında yer almaktadır.

---

## 1. Veri Hacmi Özeti

| Tablo | Satır Sayısı |
|---|---:|
| `mesaj` | 216.782 |
| `servis_islem` | 139.005 |
| `servis_durum_gecmisi` | 134.549 |
| `randevu` | 77.961 |
| `servis_kaydi` | 32.989 |
| `musteri` | 25.339 |
| `stok_hareketi` | 23.804 |
| `arac` | 8.064 |

---

## 2. Özet Performans Karşılaştırması

| Sorgu | Amaç | İndekssiz Süre | İndeksli Süre | Hızlanma | I/O (Buffers) Değişimi |
|---|---|---:|---:|---|---|
| **Sorgu 1** | Test Sürüşü → Satış Dönüşümü | `14.92 ms` | **`8.52 ms`** | **1.75x** | `3.308` → `1.245` blok (%62 az) |
| **Sorgu 2** | Şube & Departman Aylık Performans | `3.04 ms` | **`0.35 ms`** | **8.7x** | `1.288` → `73` blok (%94 az) |
| **Sorgu 3** | 216k Mesajda Müşteri Geçmişi | `4.82 ms` | **`0.50 ms`** | **9.6x** | `3.045` → `230` blok (%92 az) |
| **Sorgu 4** | Şube & Sebebe Göre Masraf Kırılımı | `7.94 ms` | **`2.91 ms`** | **2.7x** | `3.482` → `794` blok (%77 az) |
| **Sorgu 5** | Şube Servis Teslim Zamanlaması & Gecikme | — | **`22.44 ms`** | — | Hash Join + `shared hit=2.608` (4.440 onarım) |
| **Sorgu 6** | Garantili Araçlarda Karşılama Oranı | `111.40 ms` | **`108.81 ms`** | ~1.02x | CPU-bound (LAG window function) |
| **Sorgu 7** | Model Bazında Erken Garanti Bozulma | — | **`97.18 ms`** | — | Tüm satılan araçlarda `LAG()` + `shared hit=1.983` |
| **Sorgu 8** | Müşteri Servis Durumu (`v_musteri_servis_durumu`) | `416.88 ms` | **`0.58 ms`** | **722x** | `Seq Scan` (77.957 satır) → `Index Scan idx_randevu_musteri` |

---

## 3. İndeks Tasarımı ve Kolon Seçim Gerekçeleri

### A. `randevu` Tablosu
1. **`idx_randevu_tur_durum_baslangic ON randevu (tur_kodu, durum, baslangic)`**
   - **Neden bu kolonlar?** Sorgu 1'de `WHERE tur_kodu = 'TEST_SURUSU' AND durum = 'TAMAMLANDI' AND baslangic >= ...` filtreleri tek bir B-Tree aralığında elenir. Eşitlik kolonları (`tur_kodu`, `durum`) başa, aralık kolonu (`baslangic`) sona konmuştur.
2. **`idx_randevu_sube_baslangic ON randevu (sube_id, baslangic) INCLUDE (durum, tur_kodu)`**
   - **Neden bu kolonlar?** Paneldeki "Bugünkü randevular", botun 21 günlük `v_dolu_slot` sorgusu ve Sorgu 2/4 her zaman şube ve tarih aralığı ile başlar. `INCLUDE` sütunları sayesinde PostgreSQL tabloya (heap) gitmeden *Index-Only Scan* yapar.
3. **`idx_randevu_arac_vin ON randevu (arac_vin) WHERE arac_vin IS NOT NULL`**
   - **Neden partial?** Araca bağlı olmayan (ör. genel inceleme) randevuları indeks dışında bırakır; garanti hesaplama trigger'ında (`210`) bir aracın bakım geçmişini milisaniyede getirir.

### B. `mesaj` Tablosu (216.782 satır)
4. **`idx_mesaj_musteri_zaman ON mesaj (musteri_id, zaman DESC)`**
   - **Neden bu kolonlar?** Sorgu 3'te ve WhatsApp köprüsünde belirli bir müşterinin son N mesajı çekilir. İndeks `zaman DESC` sıralı tutulduğu için PostgreSQL hem `musteri_id`'yi doğrudan bulur hem de ekstra `Sort` yapmadan ilk 20 satırı anında döner (`4.82 ms` → `0.50 ms`).
5. **`idx_mesaj_zaman ON mesaj (zaman) INCLUDE (musteri_id, yon)`**
   - **Neden bu kolonlar?** Dönemsel bot mesaj trafiği analizlerinde tablo okumadan *Index-Only Scan* sağlar.

### C. `servis_islem` ve `servis_kaydi` (139.005 satır)
6. **`idx_servis_islem_kayit_id ON servis_islem (servis_kaydi_id) INCLUDE (odeme_kaynagi, ucret)`**
   - **Neden bu kolonlar?** PostgreSQL FK'lar üzerinde otomatik indeks oluşturmaz. Bu indeks olmadan bir servis kaydının fatura kalemlerini toplamak (`v_servis_durumu`, Sorgu 4, Sorgu 5) tüm 139k satırı tarıyordu. `INCLUDE (odeme_kaynagi, ucret)` ile doğrudan indeksten toplam alınır.
7. **`idx_servis_islem_garanti ON servis_islem (odeme_kaynagi) INCLUDE (servis_kaydi_id, ucret) WHERE odeme_kaynagi = 'GARANTI'`**
   - **Neden partial?** Garanti işlemleri tüm işlemlerin yalnızca ~%5'idir. Partial indeks dev tablo yerine ufacık bir indeksi tarar.
8. **`idx_servis_kaydi_acik_tahmin ON servis_kaydi (tahmini_teslim_tarihi) WHERE teslim_randevu_id IS NULL`**
   - **Neden partial?** Kapanmış 30k+ eski servis kaydını indekslemez; yalnızca halihazırda serviste bekleyen açık kayıtları indeksler. Paneldeki "Geciken açık servisler" ekranı (`v_servis_durumu` üzerinde `135.12 ms` → `34.84 ms`, ~3.9x hızlanma) için kullanılmaktadır.

### D. `stok_hareketi` ve `arac`
9. **`idx_stok_hareketi_arac_zaman ON stok_hareketi (arac_vin, zaman)`**
   - Garanti başlangıç tarihi (ilk `SATIS` hareketi) ve aracın şube transfer geçmişi için.
10. **`idx_stok_hareketi_tur_zaman ON stok_hareketi (hareket_turu, zaman) INCLUDE (arac_vin, kaynak_sube_id)`**
    - Sorgu 1'deki dönemsel satış sayımı için *Index-Only Scan*.
11. **`idx_arac_sube_durum ON arac (sube_id, durum)`**
    - Paneldeki "Araçlar" ekranı ve bot stok sorguları için.

---

### D. Müşteri bazlı erişim (bot)

12. **`idx_arac_musteri ON arac (musteri_id) WHERE musteri_id IS NOT NULL`**
    - **Neden partial?** Yalnızca satılmış (sahibi olan) araçlar aranır; stoktaki
      602 aracın indekste yer almasına gerek yok. Bot "araclarim" ve müşterinin
      servis durumu sorguları bu indeksten faydalanır.
13. **`idx_randevu_musteri ON randevu (musteri_id, baslangic DESC)`**
    - **Neden bu kolonlar?** `v_musteri_servis_durumu` view'ı
      `WHERE musteri_id = fn_aktif_musteri_id()` ile süzülür. İkinci kolon
      (`baslangic DESC`) son randevuları sıralama maliyeti olmadan getirir.

---

## 4. Analitik Sorgu Çıktıları (453.096 Ana Satır Üzerinden)

Aşağıdaki çıktılar [sorgular.sql](sorgular.sql) dosyasının `veri/uret.py` ile üretilen veri seti üzerindeki gerçek `psql` sonuçlarıdır.

### Sorgu 1 — Model Bazında Test Sürüşü vs Satış Dönüşüm Oranı

| model_adi | test_surusu | toplam_satis | test_sonrasi_alan_musteri | test_sonrasi_donusum_yuzdesi | toplam_satis_test_orani_yuzde | test_sirasi |
|---|---:|---:|---:|---:|---:|---:|
| Ioniq 5 | 850 | 86 | 48 | 5.65 | 10.12 | 1 |
| Tucson | 847 | 279 | 168 | 19.83 | 32.94 | 2 |
| i20 | 630 | 328 | 182 | 28.89 | 52.06 | 3 |
| Elantra | 616 | 272 | 164 | 26.62 | 44.16 | 4 |
| Kona | 582 | 187 | 116 | 19.93 | 32.13 | 5 |
| Bayon | 545 | 245 | 159 | 29.17 | 44.95 | 6 |
| i10 | 439 | 225 | 141 | 32.12 | 51.25 | 7 |
| Santa Fe | 324 | 62 | 43 | 13.27 | 19.14 | 8 |

### Sorgu 2 — Şube 1 Ekim 2026 Departman Bazında Çalışan Performans Sıralaması

| calisan | departman | tamamlanan_randevu | departman_sirasi |
|---|---|---:|---:|
| Ömer Taş | SATIS | 37 | 1 |
| Tolga Koç | SATIS | 36 | 2 |
| Kaan Aslan | SATIS | 36 | 2 |
| İbrahim Demir | SATIS | 13 | 4 |
| Emre Güneş | SATIS | 11 | 5 |
| Kerem Demir | SATIS | 10 | 6 |
| Tuğba Aslan | SATIS | 9 | 7 |
| Eren Keskin | SERVIS | 24 | 1 |
| Fatma Avcı | SERVIS | 22 | 2 |
| Merve Yıldırım | SERVIS | 22 | 2 |
| Emre Yıldız | SERVIS | 21 | 4 |
| Tuğba Kaya | SERVIS | 21 | 4 |
| Onur Yıldırım | SERVIS | 20 | 6 |
| Ece Karaca | SERVIS | 17 | 7 |
| Hatice Bulut | SERVIS | 16 | 8 |
| Gamze Akın | SERVIS | 9 | 9 |

### Sorgu 3 — Müşterinin (`musteri_id = 1500`) Son 20 WhatsApp Mesaj Geçmişi

| mesaj_id | yon | zaman | ozet | son_randevu |
|---:|---|---|---|---|
| 173792 | GIDEN | 2026-05-22 03:17:30+00 | Randevunuz oluşturuldu: Bornova, 30.05.2 | 2026-05-30 14:00:00 |
| 173791 | GELEN | 2026-05-22 03:15:23+00 | Evet, onaylıyorum | 2026-05-30 14:00:00 |
| 173790 | GIDEN | 2026-05-22 03:13:03+00 | Bornova şubemizde 30.05.2026 saat 14:00 | 2026-05-30 14:00:00 |
| 173789 | GELEN | 2026-05-22 03:11:03+00 | Merhaba, periyodik bakım için randevu al | 2026-05-30 14:00:00 |
| 117518 | GIDEN | 2025-08-30 10:59:21+00 | Randevunuz oluşturuldu: Bornova, 01.09.2 | 2026-05-30 14:00:00 |
| 117517 | GELEN | 2025-08-30 10:57:14+00 | Evet, onaylıyorum | 2026-05-30 14:00:00 |
| 117516 | GIDEN | 2025-08-30 10:55:05+00 | Bornova şubemizde 01.09.2025 saat 09:30 | 2026-05-30 14:00:00 |
| 117515 | GELEN | 2025-08-30 10:54:35+00 | İzmir | 2026-05-30 14:00:00 |
| 117514 | GIDEN | 2025-08-30 10:52:18+00 | Merhaba! Hangi şehirdesiniz? | 2026-05-30 14:00:00 |
| 117513 | GELEN | 2025-08-30 10:50:13+00 | Merhaba, periyodik bakım için randevu al | 2026-05-30 14:00:00 |
| 74374 | GIDEN | 2025-01-20 12:32:46+00 | Randevunuz oluşturuldu: Bornova, 30.01.2 | 2026-05-30 14:00:00 |
| 74373 | GELEN | 2025-01-20 12:30:23+00 | Evet | 2026-05-30 14:00:00 |
| 74372 | GIDEN | 2025-01-20 12:29:21+00 | Bornova şubemizde 30.01.2025 saat 14:30 | 2026-05-30 14:00:00 |
| 74371 | GELEN | 2025-01-20 12:27:58+00 | Merhaba, test sürüşü için randevu almak | 2026-05-30 14:00:00 |
| 55130 | GIDEN | 2024-10-05 23:07:46+00 | Randevunuz oluşturuldu: Bornova, 07.10.2 | 2026-05-30 14:00:00 |
| 55129 | GELEN | 2024-10-05 23:07:09+00 | Evet | 2026-05-30 14:00:00 |
| 55128 | GIDEN | 2024-10-05 23:05:36+00 | Bornova şubemizde 07.10.2024 saat 10:00 | 2026-05-30 14:00:00 |
| 55127 | GELEN | 2024-10-05 23:04:21+00 | İzmir | 2026-05-30 14:00:00 |
| 55125 | GIDEN | 2024-10-05 23:03:01+00 | Merhaba! Hangi şehirdesiniz? | 2026-05-30 14:00:00 |
| 55123 | GELEN | 2024-10-05 23:00:40+00 | Merhaba, periyodik bakım için randevu al | 2026-05-30 14:00:00 |

### Sorgu 4 — Şube 1 Ekim 2026 Sebebe Göre Servis Masraf Kırılımı (TL + %)

| sebep | dosya_sayisi | toplam_fatura | musteri_payi | musteri_yuzde | garanti_payi | garanti_yuzde | sigorta_payi | sigorta_yuzde |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| BAKIM | 128 | 1121940 | 1121940 | 100.00 | 0 | 0.00 | 0 | 0.00 |
| ARIZA | 17 | 479750 | 266660 | 55.58 | 213090 | 44.42 | 0 | 0.00 |
| KAZA | 5 | 173880 | 84400 | 48.54 | 0 | 0.00 | 89480 | 51.46 |

### Sorgu 5 — Şube Bazında Servis Teslim Zamanlaması ve Gecikme Analizi (`ARIZA` + `KAZA`)

| sube | toplam_onarim | zamaninda_yuzde | ort_sapma_gun | geciken_adet | geciken_ort_gecikme_gun |
|---|---:|---:|---:|---:|---:|
| Çankaya | 706 | 58.50 | 0.83 | 293 | 3.47 |
| Muratpaşa | 409 | 58.68 | 0.89 | 169 | 3.66 |
| Ataşehir | 530 | 58.68 | 0.68 | 219 | 3.09 |
| Yenimahalle | 535 | 58.69 | 0.91 | 221 | 3.58 |
| Beşiktaş | 607 | 60.13 | 0.72 | 242 | 3.41 |
| Nilüfer | 399 | 60.65 | 0.86 | 157 | 3.80 |
| Bornova | 525 | 60.76 | 0.68 | 206 | 3.26 |
| Kadıköy | 729 | 60.77 | 0.68 | 286 | 3.30 |

### Sorgu 6 — Garantisi Geçerli Araçlarda Arıza Masraflarının Garanti Karşılama Oranı

| model_adi | ariza_islem_sayisi | garanti_karsilanan | musteri_odenen | garanti_karsilama_yuzde |
|---|---:|---:|---:|---:|
| Ioniq 5 | 257 | 1856990 | 114750 | 94.18 |
| i10 | 469 | 3664980 | 290680 | 92.65 |
| Kona | 364 | 2746610 | 232750 | 92.19 |
| i20 | 647 | 5036130 | 434830 | 92.05 |
| Bayon | 486 | 3746400 | 422710 | 89.86 |
| Tucson | 577 | 4522020 | 571070 | 88.79 |
| Santa Fe | 92 | 870510 | 125410 | 87.41 |
| Elantra | 532 | 3981510 | 761230 | 83.95 |

### Sorgu 7 — Model Bazında Erken Garanti Bozulma Analizi

| model_adi | garanti_yil | toplam_satilan_arac | erken_bozan_arac | erken_bozulma_yuzde | ilk_3_yil_yuzde | ilk_5_yil_yuzde | ort_bozulma_yili |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ioniq 5 | 5 | 362 | 12 | 3.31 | 0.55 | 3.31 | 3.83 |
| i10 | 3 | 1024 | 27 | 2.64 | 2.64 | 2.64 | 2.20 |
| Bayon | 3 | 1080 | 24 | 2.22 | 2.22 | 2.22 | 2.16 |
| Tucson | 3 | 1273 | 28 | 2.20 | 2.20 | 2.20 | 2.40 |
| Kona | 3 | 792 | 17 | 2.15 | 2.15 | 2.15 | 1.85 |
| Elantra | 3 | 1207 | 25 | 2.07 | 2.07 | 2.07 | 2.35 |
| i20 | 3 | 1464 | 24 | 1.64 | 1.64 | 1.64 | 2.35 |
| Santa Fe | 3 | 260 | 4 | 1.54 | 1.54 | 1.54 | 2.18 |



---

## 5. Sorgu 8 — Müşteri Servis Durumu (`v_musteri_servis_durumu`)

### Amaç

WhatsApp botu, müşteri "arabam ne durumda?" diye sorduğunda o müşterinin açık
servis kaydını ve son durumunu gösterir. View, `fn_aktif_musteri_id()` ile
süzülür; oturum değişkeni (`app.musteri_telefon`) yoksa hiçbir satır döndürmez
(fail-closed). Masraf ve çalışan bilgisi view'da yoktur.

```sql
BEGIN;
SELECT set_config('app.musteri_telefon', '+90555…', true);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM v_musteri_servis_durumu;
ROLLBACK;
```

### Ölçüm (453.096 ana satır, 77.961 randevu)

| Durum | Süre | Plan | Okunan blok |
|---|---:|---|---:|
| **İndekssiz** | `416.88 ms` | `Seq Scan on randevu` (77.957 satır taranıp 28 kaldı) | ~2.700 |
| **İndeksli** | **`0.58 ms`** | `Index Scan using idx_randevu_musteri` (28 satır) | ~90 |

**Hızlanma: ~722x.** Bu ölçüm, indeks kararının "önce ölç, sonra ekle"
ilkesine uygun olarak yapıldı: view önce indekssiz yazıldı, maliyet ölçüldü,
`idx_randevu_musteri` + `idx_arac_musteri` eklendi ve tekrar ölçüldü.

### Neden `idx_randevu_musteri` yeterli?

View `v_servis_durumu` üzerinden `randevu` tablosuna iner; filtre
`randevu.musteri_id` üzerindedir. `EXISTS`/`IN` yerine doğrudan indeks
koşulu kullanılabildiği için planner `Seq Scan`'i tamamen bırakır. `arac`
tablosuna yapılan join `vin` üzerinden yürür ve `arac_pkey` kullanılır;
`idx_arac_musteri` ise botun doğrudan "araçlarım" sorgusu içindir.

---

## 6. Tekrarlanabilir ölçüm

`scripts/indeks-analiz.sh`, yukarıdaki ölçümleri tek bir komutla yeniden
üretir. Script geçici bir PostgreSQL 16 konteyneri açar, indekssiz şemayı
kurar ve veriyi yükler. Ardından [sorgular.sql](sorgular.sql) içindeki
Sorgu 1–7'yi `EXPLAIN (ANALYZE, BUFFERS)` ile 5'er kez çalıştırıp medyan
süreyi alır. `500_indeksler.sql` uygulandıktan sonra ölçümü tekrarlar.
Sonuçlar ve planlar [olcum/](olcum/olcum.md) altına yazılır.

- **JIT kapalıdır.** Maliyet tahmini `jit_above_cost` eşiğini aşan
  sorgularda yaklaşık 1 saniyelik JIT derleme süresi ölçüme karışıyor ve
  önce/sonra karşılaştırmasını bozuyordu.
- Mutlak süreler makineye ve PostgreSQL sürümüne göre değişir (bu bölümdeki
  ölçümler WSL2 üzerinde PG 16 ile alındı). Karşılaştırmada önce/sonra oranı
  esas alınmalı.
- Sorgu 8 (`v_musteri_servis_durumu`) script'e dahil değildir, çünkü oturum
  değişkeni (`app.musteri_telefon`) gerektiriyor. Bu sorgunun davranışı
  `scripts/test-db.sh` ile test ediliyor.

## 7. Bulgu ve çözüm: `v_arac_garanti_durumu` filtreyi içeri almıyordu

Panelin araç detay ekranında tek bir aracın garanti durumu
`SELECT * FROM v_arac_garanti_durumu WHERE vin = ...` sorgusuyla okunuyor.
İndeksler uygulandıktan sonra bile bu sorgu ~134 ms sürüyordu; indekssiz
hali ~141 ms.

**Neden:** View'daki CTE'ler (`satis`, `gecerli_servis`) birden fazla yerde
kullanıldığı için PostgreSQL bunları materialize ediyor (planda
`CTE Scan`). Bu yüzden `vin` filtresi CTE'lerin içine inemiyor ve tek bir
araç sorulsa bile **tüm araçların** satış ve servis geçmişi hesaplanıyor.
`idx_randevu_arac_vin` ve `idx_stok_hareketi_arac_zaman` indeksleri bu
sorguda hiç kullanılmıyor. Aynı view'ı kullanan Sorgu 6 ve 7'nin
(~370–470 ms) maliyetinin büyük kısmı da buradan geliyor.

**Denenen iki çözüm.** Aynı sentetik veride (7.462 satılmış araç; en çok
servis geçmişi olan araç `KMHI1000000000673`) PG 17, JIT kapalı, 7 tekrarın
medyanı:

| Sürüm | Tek araç (`WHERE vin = …`) | Tüm araçlar |
|---|---:|---:|
| Eski: CTE'ler materialize | 168 ms | 462 ms |
| A: araç başına `LATERAL` alt sorgular | 4,1 ms | 2.581 ms |
| **B: CTE'ler `NOT MATERIALIZED`** (seçilen) | **4,1 ms** | **568 ms** |

- **A** tek araçta hızlı, ama tüm araçlar istendiğinde her araç için ayrı
  indeks taraması yaptığı için 5,5 kat yavaşladı. Bu yol, view'ı tüm
  araçlar üzerinden kullanan analitik Sorgu 6 ve 7'yi yavaşlatırdı.
- **B**'de mantık aynen kaldı; yalnızca iki CTE'ye `NOT MATERIALIZED`
  eklendi. CTE'ler sorgunun içine katılınca planlayıcı `vin` eşitliğini
  `GROUP BY arac_vin` ve `PARTITION BY arac_vin` üzerinden içeri taşıyabiliyor.
  Tek araç planında `CTE Scan` ve `Seq Scan on randevu` kalktı; yerlerine
  `idx_stok_hareketi_arac_zaman` ve `arac_vin` üzerindeki randevu indeksi
  kullanılıyor (1 satırlık okuma). Tüm araçlar sorgusu ~%20 yavaşladı, çünkü
  `satis` iki yerde ayrı ayrı hesaplanıyor; panelin sorduğu tek araç
  sorgusu ise ~40 kat hızlandı.

**Doğruluk:** Eski ve yeni view'ın sonuç kümeleri aynı veride `EXCEPT ALL`
ile iki yönlü karşılaştırıldı: fark 0 satır (garanti durumu dağılımı:
GECERLI 4.564, SURE_DOLDU 2.654, BAKIM_AKSATILDI 244).
`scripts/test-db.sh`'teki garanti senaryoları ve panel HTTP testleri
(araç detayı bu view'ı kullanır) değişiklikten sonra da geçiyor. Bot
kodu bu view'ı kullanmaz.
