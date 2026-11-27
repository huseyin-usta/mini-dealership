// Panel API istemcisi (docs/api/panel-sozlesmesi.md)
//
// Oturum anahtarı sessionStorage'da tutulur: sekme kapanınca biter, başka
// sekmeye/kökene geçmez. Anahtar yalnızca aynı kökene (backend) gönderilir.

const ANAHTAR = 'md-oturum';

export const oturum = {
  oku() {
    try {
      return JSON.parse(sessionStorage.getItem(ANAHTAR));
    } catch {
      return null;
    }
  },
  yaz(veri) {
    try { sessionStorage.setItem(ANAHTAR, JSON.stringify(veri)); } catch { /* özel pencere */ }
  },
  sil() {
    try { sessionStorage.removeItem(ANAHTAR); } catch { /* yok say */ }
  },
};

export class ApiHatasi extends Error {
  constructor(durum, kod, mesaj, detay) {
    super(mesaj);
    this.durum = durum;
    this.kod = kod;
    this.detay = detay || null;
  }
}

/** Boş değerleri atlayarak query string üretir. */
export function sorgu(parametreler) {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(parametreler)) {
    if (v !== undefined && v !== null && v !== '') p.set(k, v);
  }
  const s = p.toString();
  return s ? `?${s}` : '';
}

/**
 * İstek atar, zarfı açar. Hata zarfı ApiHatasi olarak fırlatılır.
 * Oturum düşmüşse (401 OTURUM_YOK) yerel oturum silinir ve giriş ekranına dönülür.
 * `dosya: true` başarılı yanıtta Response'u (blob için) döndürür.
 */
export async function api(yol, { yontem = 'GET', govde, dosya = false } = {}) {
  const o = oturum.oku();
  const basliklar = {};
  if (o) basliklar.Authorization = `Bearer ${o.oturum}`;
  if (govde !== undefined) basliklar['Content-Type'] = 'application/json';

  let yanit;
  try {
    yanit = await fetch(yol, {
      method: yontem,
      headers: basliklar,
      body: govde === undefined ? undefined : JSON.stringify(govde),
      credentials: 'same-origin',
    });
  } catch {
    throw new ApiHatasi(0, 'BAGLANTI_YOK', 'Sunucuya ulaşılamadı.');
  }
  if (dosya && yanit.ok) return yanit;

  let zarf;
  try {
    zarf = await yanit.json();
  } catch {
    throw new ApiHatasi(yanit.status, 'SISTEM_HATASI', 'Sunucudan beklenmeyen yanıt geldi.');
  }
  if (!zarf.ok) {
    const h = zarf.hata || {};
    if (yanit.status === 401 && h.kod === 'OTURUM_YOK') {
      oturum.sil();
      if (location.hash !== '#/giris') location.hash = '#/giris';
    }
    throw new ApiHatasi(yanit.status, h.kod, h.mesaj || 'İşlem yapılamadı.', h.detay);
  }
  // Başarılı yazma: menü rozetleri gibi özetler tazelensin.
  if (yontem !== 'GET') window.dispatchEvent(new Event('panel-degisti'));
  return zarf.veri;
}

/** Dosya yanıtını (Excel) tarayıcıda indirir; ad Content-Disposition'dan alınır. */
export async function indir(yol, yedekAd) {
  const yanit = await api(yol, { dosya: true });
  const cd = yanit.headers.get('Content-Disposition') || '';
  const m = /filename="([^"]+)"/.exec(cd);
  const blob = await yanit.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = m ? m[1] : yedekAd;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
