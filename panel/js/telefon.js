// Telefon girişi: personel numarayı yerel biçimde yazabilir (0532 123 45 67,
// 532 123 45 67, 90 532…). Ülke kodu verilmezse Türkiye (+90) varsayılır.
// Backend yalnızca E.164 kabul eder; çeviri burada, gönderimden önce yapılır.

export const E164 = /^\+[1-9]\d{7,14}$/;

// Telefon gibi görünen metin: rakam, baştaki +, boşluk ve ayraçlar.
const TELEFON_GIBI = /^\+?[\d\s().-]+$/;

export function telefonGibiMi(metin) {
  return TELEFON_GIBI.test(String(metin).trim());
}

/** Yerel ya da uluslararası yazımı E.164'e çevirir; boş metin boş kalır. */
export function telefonNormal(metin) {
  const s = String(metin).replace(/[\s().-]/g, '');
  if (s === '' || s.startsWith('+')) return s;
  if (s.startsWith('00')) return `+${s.slice(2)}`;
  if (s.startsWith('90')) return `+${s}`;
  if (s.startsWith('0')) return `+90${s.slice(1)}`;
  return `+90${s}`;
}
