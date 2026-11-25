// Panel giriş noktası: oturum, yerleşim, menü ve hash yönlendirmesi.
//
// Rotalar: #/<sayfa>[/<parametre>]. Her sayfa ayrı bir modüldür ve
// `goster(kok, { parametre, baglam })` dışa aktarır; ilk açılışta yüklenir.

import { api, oturum, ApiHatasi } from './api.js';
import { h, yerlestir, uyari, yukleniyor } from './dom.js';

// Menü sırası. [rota, başlık, modül]
const MENU = [
  ['randevular', 'Bugünkü randevular', 'randevular'],
  ['randevu-ekle', 'Randevu ekle', 'randevu-ekle'],
  ['araclar', 'Araçlar', 'araclar'],
  ['servis', 'Servis kayıtları', 'servis'],
  ['musteriler', 'Müşteriler', 'musteriler'],
  ['raporlar', 'Raporlar', 'raporlar'],
];

// Menüde görünmeyen detay rotaları → modül ve menüde vurgulanacak öğe
const DETAY = {
  arac: ['araclar', 'araclar'],
  'servis-kaydi': ['servis', 'servis'],
  musteri: ['musteriler', 'musteriler'],
};

const kok = document.getElementById('uygulama');
let katalog = null;

function rotaCoz() {
  const [ad = '', ...kalan] = location.hash.replace(/^#\/?/, '').split('/');
  return { ad, parametre: kalan.length ? decodeURIComponent(kalan.join('/')) : null };
}

async function cizdir() {
  const { ad, parametre } = rotaCoz();
  const o = oturum.oku();
  if (!o) {
    katalog = null;
    girisEkrani();
    return;
  }
  const menu = MENU.find(([r]) => r === ad);
  const detay = DETAY[ad];
  if (!menu && !detay) {
    location.hash = `#/${MENU[0][0]}`;
    return;
  }
  const modul = menu ? menu[2] : detay[0];
  const vurgulu = menu ? menu[0] : detay[1];

  const icerik = h('main', { class: 'icerik' }, yukleniyor());
  yerlestir(kok, h('div', { class: 'kabuk' }, yanMenu(o, vurgulu), icerik));
  document.title = `${(menu || MENU.find(([r]) => r === vurgulu))[1]} · Mini Bayi`;

  try {
    if (!katalog) katalog = await api('/panel/katalog');
    const sayfa = await import(`./sayfalar/${modul}.js`);
    await sayfa.goster(icerik, { parametre, baglam: { katalog, oturum: o } });
  } catch (e) {
    if (e instanceof ApiHatasi && e.kod === 'OTURUM_YOK') return;   // giriş ekranına dönüldü
    console.error(e);
    yerlestir(icerik, uyari('hata', e instanceof ApiHatasi ? e.message : 'Sayfa yüklenemedi.'));
  }
}

function yanMenu(o, vurgulu) {
  const c = o.calisan;
  return h('nav', { class: 'yan', 'aria-label': 'Ana menü' },
    h('div', { class: 'marka' }, h('img', { src: 'logo.svg', alt: '' }), 'Mini Bayi'),
    MENU.map(([r, baslik]) => h('a', { href: `#/${r}`, class: r === vurgulu ? 'secili' : null,
      'aria-current': r === vurgulu ? 'page' : null }, baslik)),
    h('div', { class: 'alt' },
      h('div', {}, `${c.ad} ${c.soyad}`),
      h('div', { class: 'soluk' }, c.departman === 'SATIS' ? 'Satış' : 'Servis'),
      h('button', { onclick: cikis }, 'Çıkış')));
}

async function cikis() {
  try {
    await api('/panel/cikis', { yontem: 'POST' });
  } catch { /* oturum zaten düşmüş olabilir */ }
  oturum.sil();
  katalog = null;
  location.hash = '#/giris';
}

function girisEkrani() {
  document.title = 'Giriş · Mini Bayi';
  const mesaj = h('div');
  const kadi = h('input', { name: 'kullanici_adi', autocomplete: 'username', required: true, autofocus: true });
  const sifre = h('input', { name: 'sifre', type: 'password', autocomplete: 'current-password', required: true });
  const dugme = h('button', { class: 'ana', type: 'submit' }, 'Giriş yap');
  const form = h('form', {
    onsubmit: async (e) => {
      e.preventDefault();
      dugme.disabled = true;
      yerlestir(mesaj);
      try {
        const veri = await api('/panel/giris', {
          yontem: 'POST',
          govde: { kullanici_adi: kadi.value.trim(), sifre: sifre.value },
        });
        oturum.yaz(veri);
        // Kullanıcı bir sayfanın adresiyle geldiyse oraya döner; hash değişmezse
        // hashchange olayı tetiklenmez, o yüzden elle çizilir.
        const hedef = location.hash && location.hash !== '#/giris' ? location.hash : `#/${MENU[0][0]}`;
        if (location.hash === hedef) cizdir(); else location.hash = hedef;
      } catch (err) {
        yerlestir(mesaj, uyari('hata', err.message));
        sifre.value = '';
        dugme.disabled = false;
      }
    },
  },
  h('label', {}, 'Kullanıcı adı', kadi),
  h('label', {}, 'Şifre', sifre),
  mesaj,
  dugme);
  yerlestir(kok, h('div', { class: 'giris' },
    h('div', { class: 'kart' },
      h('div', { class: 'marka' }, h('img', { src: 'logo.svg', alt: '', width: 32, height: 32 }), 'Mini Bayi Paneli'),
      form)));
}

window.addEventListener('hashchange', cizdir);
cizdir();
