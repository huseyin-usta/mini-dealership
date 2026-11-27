// Randevu ekle: şubeye gelen veya telefonla arayan müşteri için (kaynak PANEL).
// Kurallar (mesai, çakışma, yetkinlik) DB'de; burada yalnızca uygun seçenekler
// süzülür ve DB'nin reddi anlaşılır bir mesaja çevrilir.

import { api, sorgu } from '../api.js';
import { h, yerlestir, alan, secim, uyari, bugun, bicim } from '../dom.js';

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

  const telefon = h('input', { name: 'telefon', placeholder: '+905321234567', required: true,
    pattern: '\\+[1-9][0-9]{7,14}', title: '+ ile başlayan uluslararası biçim', autocomplete: 'off' });
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
      } else if (/^\+[1-9]\d{7,14}$/.test(telefon.value.trim())) {
        const m = await musteriBul(telefon.value.trim());
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
    const tel = telefon.value.trim();
    yerlestir(musteriBilgi);
    if (!/^\+[1-9]\d{7,14}$/.test(tel)) return;
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

  telefon.addEventListener('change', musteriKontrol);
  sube.addEventListener('change', () => { calisanlariDoldur(); araclariDoldur(); });
  tur.addEventListener('change', () => { calisanlariDoldur(); araclariDoldur(); });
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

  const form = h('form', { class: 'form', onsubmit: gonder },
    alan('Telefon', telefon), alan('Ad', ad), alan('Soyad', soyad), musteriBilgi,
    alan('Şube', sube), alan('Randevu türü', tur), alan('Çalışan', calisan), aracAlani,
    alan('Gün', tarih), alan('Saat', saat),
    alan('Not', notlar, { sinif: 'tam' }),
    h('div', { class: 'dugmeler tam' }, dugme));

  async function gonder(e) {
    e.preventDefault();
    yerlestir(mesaj);
    dugme.disabled = true;
    const govde = {
      telefon: telefon.value.trim(),
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
    } catch (err) {
      const ek = err.detay?.sebep && CAKISMA[err.detay.sebep];
      yerlestir(mesaj, uyari('hata', ek || err.message));
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
