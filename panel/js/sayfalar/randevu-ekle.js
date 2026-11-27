// Randevu ekle: şubeye gelen veya telefonla arayan müşteri için (kaynak PANEL).
// Kurallar (mesai, çakışma, yetkinlik) DB'de; burada yalnızca uygun seçenekler
// süzülür ve DB'nin reddi anlaşılır bir mesaja çevrilir.

import { api, sorgu } from '../api.js';
import { h, yerlestir, alan, secim, uyari, bugun, bicim } from '../dom.js';
import { E164, telefonNormal } from '../telefon.js';

const CAKISMA = {
  CALISAN_DOLU: 'Seçilen çalışanın bu saatte başka randevusu var.',
  ARAC_DOLU: 'Araç bu saatte başka bir randevuda.',
  MUSTERI_DOLU: 'Müşterinin bu saatte başka bir randevusu var.',
};

export async function goster(kok, { parametre, baglam }) {
  const { katalog, oturum } = baglam;
  const mesaj = h('div');

  // #/randevu-ekle/<musteri_id>: müşteri kartından gelindi, bilgileri önceden doldur.
  // Adreste telefon değil kimlik taşınır (tarayıcı geçmişine PII yazılmasın).
  let onceden = null;
  if (parametre) {
    try {
      onceden = await api(`/panel/musteri/${encodeURIComponent(parametre)}`);
    } catch (e) {
      yerlestir(mesaj, uyari('hata', `Müşteri bilgisi alınamadı: ${e.message}`));
    }
  }

  // Yerel yazım (0532 123 45 67) da kabul edilir; alan çıkışında +90… biçimine çevrilir.
  const telefon = h('input', { name: 'telefon', type: 'tel', placeholder: '0532 123 45 67', required: true,
    pattern: '[0-9+ \\(\\)\\.\\-]{7,24}', title: 'Telefon numarası (ör. 0532 123 45 67 ya da +44…)', autocomplete: 'off' });
  const telefonDegeri = () => telefonNormal(telefon.value);
  const ad = h('input', { name: 'ad', maxlength: 64 });
  const soyad = h('input', { name: 'soyad', maxlength: 64 });
  const musteriBilgi = h('div', { class: 'soluk tam' });
  const sube = secim('sube_id', katalog.subeler.map((s) => [s.sube_id, `${s.sehir} – ${s.ad}`]), oturum.calisan.sube_id);
  const tur = secim('tur_kodu', katalog.turler.map((t) => [t.tur_kodu, `${t.ad} (${t.sure_dakika} dk)`]), '', { bos: 'Seçin' });
  const calisan = h('select', { name: 'calisan_id', required: true });
  const arac = h('select', { name: 'arac_vin' });
  const aracAlani = alan('Araç', arac);
  const tarih = h('input', { type: 'date', name: 'tarih', value: bugun(1), min: bugun(), required: true });
  const saat = h('input', { type: 'time', name: 'saat', value: '10:00', step: 1800, required: true });
  const saatler = h('div', { class: 'saatler tam', 'aria-live': 'polite' });
  const notlar = h('textarea', { name: 'notlar', maxlength: 1000 });
  const dugme = h('button', { class: 'ana', type: 'submit' }, 'Randevu oluştur');

  const secTur = () => katalog.turler.find((t) => t.tur_kodu === tur.value);

  function calisanlariDoldur() {
    const t = secTur();
    // Şube + departman + (gerekiyorsa) yetkinlik: DB'nin kabul edeceği çalışanlar
    const uygun = katalog.calisanlar.filter((c) => String(c.sube_id) === sube.value
      && (!t || c.departman === t.departman)
      && (!t || t.tur_kodu !== 'TEST_SURUSU' || c.yetkinlikler.includes('TEST_SURUSU')));
    yerlestir(calisan, h('option', { value: '' }, t ? 'Seçin' : 'Önce tür seçin'),
      uygun.map((c) => h('option', { value: c.calisan_id }, `${c.ad} ${c.soyad}`)));
  }

  async function araclariDoldur() {
    const t = secTur();
    aracAlani.hidden = !(t && t.arac_gerekli);
    arac.required = !aracAlani.hidden;
    if (aracAlani.hidden) {
      yerlestir(arac);
      return;
    }
    yerlestir(arac, h('option', { value: '' }, 'Yükleniyor…'));
    try {
      // Test sürüşü: şubedeki stok. Diğer araçlı türler: müşterinin kendi araçları.
      let secenekler = [];
      if (t.tur_kodu === 'TEST_SURUSU') {
        const v = await api(`/panel/arac${sorgu({ sube_id: sube.value, durum: 'STOKTA', limit: 200 })}`);
        secenekler = v.araclar;
      } else if (E164.test(telefonDegeri())) {
        const m = await musteriBul(telefonDegeri());
        if (m) secenekler = (await api(`/panel/musteri/${m.musteri_id}`)).araclar;
      }
      yerlestir(arac, h('option', { value: '' }, secenekler.length ? 'Seçin' : 'Uygun araç yok'),
        secenekler.map((a) => h('option', { value: a.vin },
          [a.model_adi, a.paket_adi, a.renk, a.plaka || a.vin].filter(Boolean).join(' · '))));
    } catch (e) {
      yerlestir(arac, h('option', { value: '' }, 'Araçlar alınamadı'));
    }
  }

  async function musteriBul(tel) {
    if (onceden && onceden.telefon === tel) return onceden;
    // Tam eşleşme: benzer numaralı müşteri "kayıtlı" sanılmasın.
    const v = await api(`/panel/musteri${sorgu({ telefon: tel })}`);
    return v.musteriler[0] || null;
  }

  async function musteriKontrol() {
    const tel = telefonDegeri();
    yerlestir(musteriBilgi);
    if (!E164.test(tel)) {
      if (tel) yerlestir(musteriBilgi, 'Telefon numarası geçersiz.');
      return;
    }
    telefon.value = tel;   // personel kaydedilecek biçimi görsün
    try {
      const m = await musteriBul(tel);
      if (m) {
        const adSoyad = [m.ad, m.soyad].filter(Boolean).join(' ');
        yerlestir(musteriBilgi, 'Kayıtlı müşteri: ', h('a', { href: `#/musteri/${m.musteri_id}` }, adSoyad || 'adı bilinmiyor'),
          adSoyad ? '' : ' — ad/soyad girerseniz kaydedilir.');
      } else {
        yerlestir(musteriBilgi, 'Yeni müşteri: ad ve soyad zorunlu.');
      }
      ad.required = !m;
      soyad.required = !m;
      if (secTur()?.arac_gerekli && secTur().tur_kodu !== 'TEST_SURUSU') araclariDoldur();
    } catch { /* bilgi amaçlı; gönderimde DB karar verir */ }
  }

  // Boş saatler: türün o günkü saat aralıkları, tür süresi adımında değil
  // 30 dakikalık adımlarla; çalışanın iptal edilmemiş randevularıyla çakışanlar
  // ve geçmiş saatler kapalı. Son karar yine DB'de (müşteri/araç çakışması dahil).
  let saatIstegi = 0;
  async function saatleriGoster() {
    const t = secTur();
    const istek = ++saatIstegi;
    if (!t || !calisan.value || !tarih.value) {
      yerlestir(saatler, h('span', { class: 'soluk' }, 'Tür, çalışan ve gün seçilince boş saatler burada görünür.'));
      return;
    }
    const gun = isoGun(tarih.value);
    const araliklar = (katalog.tur_saatleri || []).filter((a) => a.tur_kodu === t.tur_kodu && a.gun === gun);
    if (araliklar.length === 0) {
      yerlestir(saatler, h('span', { class: 'soluk' }, `${t.ad} bu gün verilmiyor.`));
      return;
    }
    yerlestir(saatler, h('span', { class: 'soluk' }, 'Boş saatler yükleniyor…'));
    let dolu;
    try {
      const v = await api(`/panel/randevu${sorgu({ tarih: tarih.value, sube_id: sube.value, calisan_id: calisan.value, limit: 200 })}`);
      dolu = v.randevular.filter((r) => r.durum !== 'IPTAL')
        .map((r) => [dakika(r.baslangic.slice(11)), dakika(r.bitis.slice(11))]);
    } catch {
      if (istek === saatIstegi) yerlestir(saatler, h('span', { class: 'soluk' }, 'Boş saatler alınamadı; saati elle girin.'));
      return;
    }
    if (istek !== saatIstegi) return;   // bu arada seçim değişti
    const simdiDk = tarih.value === bugun() ? dakika(new Date().toTimeString().slice(0, 5)) : -1;
    const dugmeler = [];
    for (const a of araliklar) {
      for (let b = dakika(a.baslangic); b + t.sure_dakika <= dakika(a.bitis); b += 30) {
        const s = b + t.sure_dakika;
        const cakisan = dolu.some(([db, ds]) => b < ds && s > db);
        const gecmis = b <= simdiDk;
        const hhmm = saatMetni(b);
        dugmeler.push(h('button', {
          type: 'button',
          class: `kucuk${saat.value === hhmm ? ' secili' : ''}`,
          disabled: cakisan || gecmis,
          title: cakisan ? 'Çalışan bu saatte dolu' : gecmis ? 'Geçmiş saat' : `${hhmm}–${saatMetni(s)}`,
          'aria-pressed': String(saat.value === hhmm),
          onclick: () => { saat.value = hhmm; saatleriGoster(); },
        }, hhmm));
      }
    }
    const bos = dugmeler.filter((d) => !d.disabled).length;
    yerlestir(saatler,
      h('div', { class: 'soluk' }, bos ? `Boş saatler (${bos}) — seçmek için tıklayın:` : 'Bu gün çalışanın boş saati yok.'),
      h('div', { class: 'dugmeler' }, dugmeler));
  }

  telefon.addEventListener('change', musteriKontrol);
  sube.addEventListener('change', () => { calisanlariDoldur(); araclariDoldur(); saatleriGoster(); });
  tur.addEventListener('change', () => { calisanlariDoldur(); araclariDoldur(); saatleriGoster(); });
  calisan.addEventListener('change', saatleriGoster);
  tarih.addEventListener('change', saatleriGoster);
  saat.addEventListener('change', saatleriGoster);
  function oncedenDoldur() {
    if (!onceden) return;
    telefon.value = onceden.telefon;
    ad.value = onceden.ad || '';
    soyad.value = onceden.soyad || '';
    musteriKontrol();
  }

  calisanlariDoldur();
  araclariDoldur();
  oncedenDoldur();
  saatleriGoster();

  const form = h('form', { class: 'form', onsubmit: gonder },
    alan('Telefon', telefon), alan('Ad', ad), alan('Soyad', soyad), musteriBilgi,
    alan('Şube', sube), alan('Randevu türü', tur), alan('Çalışan', calisan), aracAlani,
    alan('Gün', tarih), alan('Saat', saat), saatler,
    alan('Not', notlar, { sinif: 'tam' }),
    h('div', { class: 'dugmeler tam' }, dugme));

  async function gonder(e) {
    e.preventDefault();
    yerlestir(mesaj);
    const tel = telefonDegeri();
    if (!E164.test(tel)) {
      yerlestir(mesaj, uyari('hata', 'Telefon numarası geçersiz.'));
      telefon.focus();
      return;
    }
    telefon.value = tel;
    dugme.disabled = true;
    const govde = {
      telefon: tel,
      sube_id: Number(sube.value),
      tur_kodu: tur.value,
      calisan_id: Number(calisan.value),
      baslangic: `${tarih.value}T${saat.value}`,
    };
    if (ad.value.trim()) govde.ad = ad.value.trim();
    if (soyad.value.trim()) govde.soyad = soyad.value.trim();
    if (!aracAlani.hidden && arac.value) govde.arac_vin = arac.value;
    if (notlar.value.trim()) govde.notlar = notlar.value.trim();
    try {
      const r = await api('/panel/randevu', { yontem: 'POST', govde });
      yerlestir(mesaj, uyari('basari',
        `${bicim.zaman(r.baslangic)} – ${r.tur_adi} randevusu oluşturuldu (${r.musteri || r.telefon}, ${r.calisan}). `,
        h('a', { href: '#/randevular' }, 'Randevulara git')));
      form.reset();
      tarih.value = govde.baslangic.slice(0, 10);
      saat.value = govde.baslangic.slice(11, 16);
      yerlestir(musteriBilgi);
      calisanlariDoldur();
      araclariDoldur();
      oncedenDoldur();   // aynı müşteriye bir randevu daha verilebilsin
      saatleriGoster();
    } catch (err) {
      const ek = err.detay?.sebep && CAKISMA[err.detay.sebep];
      yerlestir(mesaj, uyari('hata', ek || err.message));
      if (err.detay?.sebep) saatleriGoster();   // çakışma: tabloyu tazele
    } finally {
      dugme.disabled = false;
      mesaj.scrollIntoView({ block: 'nearest' });
    }
  }

  yerlestir(kok,
    h('h1', {}, 'Randevu ekle'),
    h('p', { class: 'soluk' }, 'Şubeye gelen ya da telefonla arayan müşteri için. Mesai, tür saatleri ve çakışmalar kayıtta denetlenir.'),
    mesaj,
    h('div', { class: 'kart' }, form));
}

/** 'HH:MM' → gün içindeki dakika. */
function dakika(hhmm) {
  const [s, d] = hhmm.split(':').map(Number);
  return s * 60 + d;
}

function saatMetni(dk) {
  return `${String(Math.floor(dk / 60)).padStart(2, '0')}:${String(dk % 60).padStart(2, '0')}`;
}

/** 'YYYY-MM-DD' → ISO gün (1 = Pazartesi … 7 = Pazar), tur_saat ile aynı. */
function isoGun(tarih) {
  const [y, a, g] = tarih.split('-').map(Number);
  return new Date(y, a - 1, g).getDay() || 7;
}
