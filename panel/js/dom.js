// DOM yardımcıları. Sunucudan gelen her değer metin düğümü olarak eklenir;
// hiçbir metin HTML olarak ayrıştırılmaz (müşteri mesajı gibi veriler betik taşıyamasın).

/** Öğe oluşturur: h('a', { href: '#/x', onclick: fn }, 'metin', çocuk...) */
export function h(etiket, ozellikler = {}, ...cocuklar) {
  const el = document.createElement(etiket);
  for (const [k, v] of Object.entries(ozellikler || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k === 'value') el.value = v;
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, String(v));
  }
  ekle(el, cocuklar);
  return el;
}

function ekle(el, cocuklar) {
  for (const c of cocuklar.flat(Infinity)) {
    if (c === undefined || c === null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

/** Kökü temizleyip yeni içerik koyar. */
export function yerlestir(kok, ...cocuklar) {
  kok.replaceChildren();
  ekle(kok, cocuklar);
}

// ---- Biçimlendirme -------------------------------------------------------------------

const iki = (n) => String(n).padStart(2, '0');

export const bicim = {
  /** 'YYYY-MM-DD' → 'GG.AA.YYYY' */
  tarih(s) {
    if (!s) return '—';
    const [y, a, g] = s.slice(0, 10).split('-');
    return `${g}.${a}.${y}`;
  },
  /** 'YYYY-MM-DDTHH:MM' → 'GG.AA.YYYY SS:DD' */
  zaman(s) {
    if (!s) return '—';
    return `${bicim.tarih(s)} ${s.slice(11, 16)}`;
  },
  saat(s) {
    return s ? s.slice(11, 16) : '—';
  },
  para(n) {
    if (n === null || n === undefined) return '—';
    return `${Number(n).toLocaleString('tr-TR')} ₺`;
  },
  sayi(n) {
    if (n === null || n === undefined) return '—';
    return Number(n).toLocaleString('tr-TR');
  },
  yuzde(n) {
    return n === null || n === undefined ? '—' : `%${Number(n).toLocaleString('tr-TR')}`;
  },
  bos(s) {
    return s === null || s === undefined || s === '' ? '—' : s;
  },
};

/** Bugünün tarihi (tarayıcı saatine göre) 'YYYY-MM-DD'. */
export function bugun(gunEkle = 0) {
  const d = new Date();
  d.setDate(d.getDate() + gunEkle);
  return `${d.getFullYear()}-${iki(d.getMonth() + 1)}-${iki(d.getDate())}`;
}

// ---- Durum rozetleri ---------------------------------------------------------------------

const ROZETLER = {
  PLANLANDI: ['Planlandı', 'mavi'],
  TAMAMLANDI: ['Tamamlandı', 'yesil'],
  IPTAL: ['İptal', ''],
  GELMEDI: ['Gelmedi', 'kirmizi'],
  STOKTA: ['Stokta', 'yesil'],
  YOLDA: ['Yolda', 'sari'],
  SATILDI: ['Satıldı', 'mavi'],
  INCELENIYOR: ['İnceleniyor', 'mavi'],
  PARCA_BEKLENIYOR: ['Parça bekleniyor', 'sari'],
  EKSPERTIZ_BEKLENIYOR: ['Ekspertiz bekleniyor', 'sari'],
  ISLEMDE: ['İşlemde', 'mavi'],
  TESLIME_HAZIR: ['Teslime hazır', 'yesil'],
  GECERLI: ['Garanti geçerli', 'yesil'],
  SURE_DOLDU: ['Garanti süresi doldu', 'kirmizi'],
  KM_ASILDI: ['Garanti km aşıldı', 'kirmizi'],
  BAKIM_AKSATILDI: ['Bakım aksatıldı', 'kirmizi'],
  WHATSAPP: ['WhatsApp', 'yesil'],
  PANEL: ['Panel', ''],
  GELIS: ['Geliş', ''],
  SIPARIS: ['Sipariş', ''],
  TRANSFER: ['Transfer', 'sari'],
  SATIS: ['Satış', 'mavi'],
  BAKIM: ['Bakım', ''],
  ARIZA: ['Arıza', 'sari'],
  KAZA: ['Kaza', 'kirmizi'],
  MUSTERI: ['Müşteri', ''],
  GARANTI: ['Garanti', 'yesil'],
  SIGORTA: ['Sigorta', 'mavi'],
};

export const ETIKET = Object.fromEntries(Object.entries(ROZETLER).map(([k, [ad]]) => [k, ad]));

export function rozet(kod) {
  if (!kod) return h('span', { class: 'soluk' }, '—');
  const [ad, renk] = ROZETLER[kod] || [kod, ''];
  return h('span', { class: `rozet ${renk}` }, ad);
}

// ---- Ortak bileşenler -----------------------------------------------------------------------

export function uyari(tur, ...icerik) {
  return h('div', { class: `uyari ${tur}`, role: tur === 'hata' ? 'alert' : 'status' }, ...icerik);
}

export function yukleniyor() {
  return h('div', { class: 'yukleniyor' }, 'Yükleniyor…');
}

/**
 * Tablo. sutunlar: [{ ad, deger: (satir) => düğüm|metin, sinif }]
 * satirTik verilirse satır tıklanabilir; satirSinif satıra ek sınıf verir.
 */
export function tablo(sutunlar, satirlar, { satirTik, satirSinif, bosMetin = 'Kayıt yok.' } = {}) {
  const govde = satirlar.length === 0
    ? [h('tr', {}, h('td', { class: 'bos', colspan: sutunlar.length }, bosMetin))]
    : satirlar.map((s) => h('tr', {
      class: [satirTik ? 'tik' : null, satirSinif ? satirSinif(s) : null].filter(Boolean).join(' ') || null,
      onclick: satirTik ? (e) => { if (!e.target.closest('a, button')) satirTik(s); } : null,
    }, sutunlar.map((c) => h('td', { class: c.sinif }, c.deger(s)))));
  return h('div', { class: 'tablo-kap' },
    h('table', {},
      h('thead', {}, h('tr', {}, sutunlar.map((c) => h('th', {}, c.ad)))),
      h('tbody', {}, govde)));
}

/** "1–50 / 120" ve önceki/sonraki düğmeleri. */
export function sayfalama(toplam, limit, sayfa, git) {
  const bas = toplam === 0 ? 0 : (sayfa - 1) * limit + 1;
  const son = Math.min(toplam, sayfa * limit);
  return h('div', { class: 'sayfalama' },
    h('span', { class: 'sayi' }, `${bas}–${son} / ${toplam}`),
    h('button', { class: 'kucuk', disabled: sayfa <= 1, onclick: () => git(sayfa - 1) }, '‹ Önceki'),
    h('button', { class: 'kucuk', disabled: son >= toplam, onclick: () => git(sayfa + 1) }, 'Sonraki ›'));
}

/** <select> seçenekleri: [[değer, ad], ...]; ilk seçenek isteğe bağlı boş. */
export function secim(ad, secenekler, secili, { bos } = {}) {
  return h('select', { name: ad },
    bos !== undefined ? h('option', { value: '' }, bos) : null,
    secenekler.map(([d, a]) => h('option', { value: d, selected: String(d) === String(secili ?? '') }, a)));
}

/** Metni panoya kopyalar; Clipboard API yoksa ya da izin verilmezse seçip kopyalar. */
async function panoyaKopyala(metin) {
  try {
    await navigator.clipboard.writeText(metin);
    return true;
  } catch {
    const ta = h('textarea', { readonly: true, 'aria-hidden': 'true', class: 'pano-yedek' });
    ta.value = metin;
    document.body.append(ta);
    ta.select();
    let tamam = false;
    try { tamam = document.execCommand('copy'); } catch { /* desteklenmiyor */ }
    ta.remove();
    return tamam;
  }
}

/**
 * Telefon: tıklanınca arar (tel:). `tam: true` yanına WhatsApp'ta açma
 * bağlantısı ve kopyalama düğmesi ekler.
 */
export function telefon(tel, { tam = false } = {}) {
  if (!tel) return '—';
  const ara = h('a', { href: `tel:${tel}`, class: 'sayi', title: 'Ara' }, tel);
  if (!tam) return ara;
  const kopyala = h('button', {
    type: 'button',
    class: 'kucuk',
    onclick: async (e) => {
      const d = e.currentTarget;
      d.textContent = (await panoyaKopyala(tel)) ? 'Kopyalandı' : 'Kopyalanamadı';
      setTimeout(() => { d.textContent = 'Kopyala'; }, 1500);
    },
  }, 'Kopyala');
  return h('span', { class: 'telefon' }, ara,
    h('a', { href: `https://wa.me/${tel.replace(/\D/g, '')}`, target: '_blank', rel: 'noopener noreferrer',
      class: 'kucuk-bag' }, 'WhatsApp'),
    kopyala);
}

export function alan(etiket, girdi, { sinif } = {}) {
  return h('label', { class: sinif }, etiket, girdi);
}
