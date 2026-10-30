# Mini-Dealership

> BIL372 Veritabanı Sistemleri grup projesi: çok şubeli bir otomobil bayi ağı
> için WhatsApp randevu asistanı ve yönetim paneli.

## Problem

Çok şubeli bir otomobil bayisinde randevular bugün çoğunlukla telefonla, elle
yazılan WhatsApp mesajlarıyla ve şube şube tutulan Excel dosyalarıyla
yönetiliyor. Bunun sonuçları:

- Mesai dışında ya da yoğun saatte gelen mesajlar cevapsız kalıyor, müşteri
  kaçıyor
- Şubeler birbirinin müsaitliğini görmüyor; bir şube doluyken müşteri diğerine
  yönlendirilemiyor
- Aynı çalışana ya da aynı araca çakışan randevular verilebiliyor; test sürüşü
  aracının satılmış olduğu son anda fark ediliyor
- Kimin hangi işe yetkili olduğu kayıtlı değil; test sürüşü yetkisi olmayan
  birine randevu yazılabiliyor
- Veri dağınık olduğu için yönetim "hangi model çok test ediliyor ama
  satılmıyor" gibi soruları cevaplayamıyor

Bir bayi ağında her gün yüzlerce mesaj ve randevu oluşur; yıllar içinde
randevu, mesaj ve stok hareketi kayıtları yüz binlere ulaşır. Bu yüzden veriyi
tek ve tutarlı bir veritabanında toplamak gerekiyor.

## Ne yapıyoruz?

Müşteri bayiye WhatsApp'tan yazıyor:

> "Merhaba, cumartesi test sürüşü yapmak istiyorum."

Bot eksik bilgileri soruyor (hangi şehir, hangi araç, hangi saat), veritabanından
uygun saatleri bulup öneriyor, müşteri onaylayınca randevuyu kaydediyor.

Bayi çalışanları aynı veritabanını bir web panelinden yönetiyor: randevular,
araçlar, servis kayıtları, bot konuşmaları, Excel raporu ve istatistikler.

Dört parça var: **WhatsApp köprüsü**, **backend** (bot mantığı + panel
sunucusu), **panel arayüzü** ve **PostgreSQL veritabanı**. Hedef: tek komutla
(Docker Compose) ayağa kalksın.

## Bayi nasıl işliyor?

- Bayi tek markalıdır (ör. Hyundai): sattığı ve servis verdiği bütün araçlar
  aynı markadan
- Bayinin farklı şehirlerde birden çok şubesi var, her şubenin kendi mesai
  saatleri var
- Her çalışan tek bir şubede ve tek bir departmanda (satış ya da servis)
  çalışır. Ayrıca sertifika ve yetkinlikleri vardır (ör. test sürüşü yetkisi);
  bir çalışanın birden çok yetkinliği olabilir
- Her araç VIN'iyle tek bir kayıttır; stoktaki, yoldaki, satılmış ve servise
  gelen araçlar aynı yerde tutulur. Kayıtta şube, durum (yolda/stokta/satıldı),
  yoldaysa tahmini varış tarihi, satıldıysa sahibi ve plakası bulunur. Marka,
  model, donanım paketi, fiyat ve özellikler model bilgisinde durur. Periyodik
  bakım aralığı (ör. 15.000 km ya da 1 yıl, hangisi önce gelirse) ve garanti
  süresi (yıl ve km) de modele göre değişir
- Aracın durum değişiklikleri (geliş, satış, şubeler arası transfer) stok
  hareketi olarak kaydedilir
- Bizden alınmamış bir araç servise ilk geldiğinde VIN ve plakasıyla kaydedilir
- Müşteriyi telefon numarası tanımlıyor; bota gelen ve giden her mesaj
  kaydedilir

**Randevu türleri:**

| Tür | Süre | Departman | Not |
|-----|------|-----------|-----|
| Test sürüşü | 1 saat | Satış (test sürüşü yetkisi) | Stoktaki bir araca bağlı |
| Araç inceleme | 1 saat | Satış | |
| Satın alım | 1 saat | Satış | Ödeme şubede yüz yüze alınır |
| Yeni araç teslimi | 1 saat | Satış | Satılan araca bağlı |
| Periyodik bakım | 1 saat | Servis | Servis kaydı açar; araç başta alınır, sonda geri verilir |
| Servise giriş | 30 dk | Servis | Servis kaydı açar |
| Servisten teslim | 30 dk | Servis | Masraf ve ödeme burada kapanır |

**Randevu kuralları:**

- Her tür belirli bir departman, gerekiyorsa bir yetkinlik de ister; çalışanı
  müşteri değil sistem atar
- Her türün kendi saat aralıkları var ve bunlar mesainin alt kümesi
  (ör. mesai 08–17, test sürüşü 10–12 ve 14–16)
- Bir saat ancak o şubede uygun ve boş bir çalışan varsa müsaittir; test
  sürüşüyse araç da o şubede stokta ve boş olmalı. Biri eksikse bot alternatif
  önerir. Ayrı bir kapasite sınırı yoktur; kapasiteyi mesai ve çalışanlar
  belirler
- Tek WhatsApp hattı tüm bayi ağına hizmet verir. Bot şehri sorar, istenen gün
  ve saatte o şehirdeki müsait ve dolu şubeleri listeler; müşteri bir şube ya
  da başka bir tarih seçer. Müşterinin geçmiş randevuları varsa bot bunları
  görür ve ona göre önerir (ör. "son randevunuz Çankaya'daydı, yine orası mı
  olsun?")
- Stok sorulduğunda bot stoktaki ve yoldaki araçları (tahmini varış tarihiyle)
  söyler; ikisi de yoksa müşteriyi satış danışmanına yönlendirir
- Şubeye gelen müşterilerin ve yüz yüze verilen randevuların (ör. ödeme
  sonrası yeni araç teslimi) kaydını personel panelden, aynı kurallarla girer.
  Randevunun nereden geldiği (WhatsApp / şube) kaydedilir
- Yoldaki bir aracın teslim randevusu, aracın varış tarihinden önce verilemez
- İptal edilen randevu silinmez, durumu değişir; o saat yeniden açılır
- Müşteri sadece kendi randevusunu görür ve iptal eder

**Servis süreci:**

- Periyodik bakım ve servise giriş randevularında bir servis kaydı açılır ve
  aracın kilometresi kaydedilir. Kaydın bir sebebi vardır (bakım / arıza /
  kaza) ve durum geçmişi tutulur: inceleniyor, parça bekleniyor, ekspertiz
  raporu bekleniyor, işlem yapılıyor, teslime hazır...
- İnceleme bitince servis personeli tahmini teslim tarihini girer ve müşteriye
  kendisi bildirir; sistem bildirim göndermez, sadece kaydeder. Tahmin tarih
  olarak saklanır, "kaç hafta kaldı" ekranda hesaplanır
- Yapılan işlemler ve masraflar kayda yazılır. Ödeme kaynağı sebebe göre
  sınırlıdır: bakımı müşteri öder; kazada müşteri ya da kasko/sigorta, arızada
  müşteri ya da garanti öder. Sigorta karşılıyorsa kayıt bir sigorta şirketine
  bağlanır (dosya numarası, eksper, onaylanan tutar)
- Servis bitince araç, servisten teslim randevusuyla müşteriye verilir

**Garanti:**

- Garanti aracın teslim tarihinde başlar ve modelin garanti süresi (yıl ve km)
  boyunca geçerlidir
- Mini-world kuralı: araçlarımızın bakımı yalnızca bayi ağımızda yapılır.
  Teslimden itibaren her bakım, bir öncekinden en geç modelin bakım aralığı
  kadar sonra yapılmalıdır; bakımı aksatılan aracın garantisi düşer
- Garanti durumu saklanmaz; teslim tarihi, kilometreler ve bakım geçmişinden
  hesaplanır
- Garantisi düşmüş bir araç için ödeme kaynağı "garanti" girilemez; bunu
  veritabanında bir trigger engeller
- Kullanıcı hatası gibi hesaplanamayan durumlarda karar servis personelinindir:
  garanti talebini reddederse sebebini kaydeder

**Veritabanı rolleri:** uygulamanın her parçası (panel, bot, raporlar)
veritabanına kendi rolüyle bağlanır, yetkiler GRANT/REVOKE ile verilir.

- **admin:** şemanın sahibi, tam yetki
- **personel:** panel bu rolle bağlanır; randevu, araç, müşteri ve servis
  kayıtlarını okur, ekler ve günceller
- **bot:** müşteri adına çalışır; şube, araç ve müsaitlik bilgisini okur, yeni
  müşteriyi ve randevuyu kaydeder, iptal için sadece durum alanını
  değiştirebilir, mesajları kaydeder. Satır bazlı güvenlik (RLS) sayesinde
  sadece o an konuştuğu müşterinin randevularını görür
- **rapor:** sadece view'ları okur (Excel raporu, istatistikler)

Hiçbir uygulama rolünün DELETE yetkisi yoktur; "iptal edilen randevu silinmez"
kuralı böylece veritabanı seviyesinde garanti edilir.

Kişisel veriler (ad, telefon) korunur: rapor rolü müşteri tablosunu doğrudan
okuyamaz, bu bilgileri maskeli view'lardan görür (ör. 0532 *** ** 67). Bot da
müsaitlik bakarken başka müşterilerin kişisel bilgilerini hiç görmez, yani bu
bilgiler LLM'e ulaşmaz.

Bu kurallar LLM'e bırakılmaz, kodda ve veritabanında garanti edilir. EER
diyagramı ve kısıtlar bu kurallardan çıkarılacak. EER'de doğal adaylar:

- **Kalıtım (specialization):** randevu → test sürüşü (stoktaki araca bağlı) /
  teslim (yeni araç ya da servisten; araca bağlı) / servise giriş ve bakım
  (müşterinin aracına bağlı; ikisi de bir servis kaydı açar) / satın alım ve
  inceleme; çalışan → satış / servis (departmana göre, ayrık)
- **Çoka-çok ilişki:** çalışanlar ve yetkinlikler
- **İlişki niteliği:** servis kaydı ile sigorta şirketi arasındaki ilişkide
  dosya numarası, eksper ve onaylanan tutar
- **Türetilmiş nitelikler:** müşterinin son randevusu, servisteki aracın kalan
  süresi, aracın garanti durumu (ayrıca saklanmaz, hesaplanır)

## Panel menüleri

- **Giriş:** kullanıcı adı ve şifre
- **Bugünkü randevular:** şube, tür ve duruma göre filtre
- **Randevu ekle:** şubeye gelen müşteriler ve yüz yüze verilen randevular
- **Araçlar:** stoktaki ve yoldaki araçlar, VIN/plaka arama, özellikler,
  garanti durumu
- **Servis kayıtları:** durum geçmişi, tahmini teslim tarihi, masraflar
- **Müşteriler:** iletişim bilgileri ve randevu geçmişi
- **Bot konuşmaları:** müşteri bazında mesaj kaydı
- **Raporlar:** istatistikler ve randevuların Excel'e aktarımı (tek yönlü)

## Teknoloji

Java (backend) · Node.js + Baileys (WhatsApp köprüsü) · Gemini (LLM) ·
PostgreSQL · HTML/JS panel

- **Backend Java:** ekipçe bildiğimiz dil; veritabanına dersin istediği gibi
  JDBC ile bağlanır. SQL'i doğrudan yazıyoruz, SQL'i gizleyen bir ORM
  (Hibernate/JPA) kullanmıyoruz
- **WhatsApp köprüsü Node.js:** Baileys sadece Node'da var. Köprü mesajı alıp
  backend'e iletir, cevabı müşteriye gönderir; veritabanına hiç dokunmaz
- **PostgreSQL:** dersin istediği veritabanı rolleri (GRANT/REVOKE) ve sorgu
  maliyeti analizi (EXPLAIN ANALYZE) için

Bot, Hüseyin'in çalışan bir projesinden uyarlanıyor: WhatsApp köprüsü olduğu
gibi alınıyor, bot mantığı Java'ya taşınıyor.

## Ders hedefleri

Rehberin özellikle istediği ve projede göstereceğimiz şeyler:

- **Normalizasyon:** tablolar BCNF'ye kadar normalize edilir (model/VIN ayrımı
  bunun bir örneği)
- **Yabancı anahtar kuralları:** silme/güncelleme davranışı iş mantığına göre
  seçilir (ör. randevusu olan müşteri silinemez, silinen modelin özellik
  kayıtları da silinir)
- **Veri hacmi:** ana işlem tablolarında (randevular, mesajlar, stok
  hareketleri, servis durum geçmişi) en az 250.000 satır sentetik veri.
  Mockaroo'nun ücretsiz sürümü dosya başına 1.000 satırla sınırlı olduğu için
  veriyi bir script üretip toplu yükler; üretilen veri de kısıtlara uymak
  zorunda (çakışan randevu olmamalı)
- **İndeks ve sorgu maliyeti:** indekslerin etkisi EXPLAIN ANALYZE ile öncesi ve
  sonrası karşılaştırılarak gösterilir. Türetilmiş veriyi saklama kararı da böyle
  verilir: önce ölçülür, gerçekten yavaşsa materialized view kullanılır
- **Analitik sorgular:** en az 5 tane; en az 3 tablolu JOIN, alt sorgu ve
  GROUP BY/HAVING veya window function içerir. Adaylar: model bazında test
  sürüşünden satışa dönüşüm oranı, şube doluluk sıralaması, bir şehirde müsait
  şube bulma, çalışan başına aylık randevu sıralaması, tahmini teslim tarihi
  geçmiş servis kayıtları, garantisi düşmüş araçlar (ardışık bakımlar
  arasındaki farkı window function ile hesaplar)
- **View'lar:** panel raporları, maskeli rapor view'ları, müşterinin son
  randevusu
- **Transaction:** birden çok tabloyu birlikte güncelleyen işlemler tek
  transaction'da yapılır. Örnek: satışta araç "satıldı" olur, stok hareketi
  eklenir, randevu "tamamlandı" olur; biri başarısız olursa hiçbiri olmaz

## Durum ve takvim

- **Hazır olan:** başka bir projede çalışan WhatsApp bot altyapısı (Baileys +
  Gemini) ve bu dokümandaki domain ve iş kuralları
- **Yapılacak:** EER ve şema, 250.000 satırlık veri üretimi, sorgular ve indeks
  analizi, Java backend, panel
- **Takvim:** ara rapor 19 Ekim 2026, son rapor 3 Aralık 2026, dönem sonunda
  demo
- **Ekip:** rehbere göre 2–3 kişi; herkes tasarımdan koda her aşamada görev
  alır

## Görev dağılımı

Ortak:

- EER → ilişkisel şema → DDL aktarımı ve review
- Analitik sorgular (≥5) + EXPLAIN ANALYZE / indeks analizi
- Son rapor yazımı + demo hazırlığı

Hüseyin Yiğit USTA:

- WhatsApp köprüsü (Baileys)
- Backend bot mantığı (müsaitlik hesabı, randevu, iptal)
- Docker Compose / altyapı
- Transaction yönetimi (satış akışı)

Şevda Yağmur ASAL:

- Panel (HTML/JS) + panel menüleri
- View'lar (maskeli rapor view'ları, müşteri son randevusu) + Excel raporu (tek yönlü)
- Veri üretici

## Genişletme fikirleri

Temel sistem oturduktan sonra proje bu yönlerde büyütülebilir:

- **Uzmanlıklar:** serviste usta/çırak ayrımı olabilir. Ustalar her arızaya
  bakar, çıraklar lastik basıncı veya fren balatası gibi işlere. Elektrikli
  araçlara sadece EV ustası bakar
- **Parça siparişleri:** parçalar ayrı takip edilir; parça gelince bot
  müşteriye WhatsApp'tan kendisi yazıp randevu önerir
- **Servis otoparkı:** bazı araçlar parça gelene kadar serviste kalır.
  Yürümeyen, çekiciyle gelen araç kalmak zorundadır; kimi müşteri (ör. tamponu
  çizik) aracını bırakmayı tercih eder, kimi o süre boyunca kullanmak ister
