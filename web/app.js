/* ─────────────────────────────────────────────────────────────────────────
 *  Maclaurin Series (MACLRN) — лендинг.
 *
 *  Зависимостей нет: ни npm, ни CDN, ни библиотек. Кодирование вызовов —
 *  четыре байта селектора плюс аргументы по 32 байта, декодирование — BigInt.
 *  Так страница работает при открытии файла локально (file://) и не выполняет
 *  ни одного стороннего скрипта: единственный внешний запрос — JSON-RPC к узлу.
 *
 *  ЕДИНСТВЕННОЕ МЕСТО, ГДЕ НАДО ЧТО-ТО МЕНЯТЬ, — объект CONFIG ниже.
 * ───────────────────────────────────────────────────────────────────────── */

'use strict';

const CONFIG = {

  /* Как называется токен на этой странице. Имя и тикер в самом контракте
     читаются с цепочки и показываются отдельной карточкой — если они разойдутся
     с этими значениями, это будет видно, а не спрятано. */
  token: { name: 'Maclaurin Series', symbol: 'MACLRN', decimals: 18 },

  chain: {
    id: 4663,
    idHex: '0x1237',                                  // 4663 = 0x1237
    name: 'Robinhood Chain',
    rpc: 'https://rpc.mainnet.chain.robinhood.com',
    explorer: 'https://robinhoodchain.blockscout.com',
    // Газовый токен сети. ЗАПОЛНИТЬ/ПРОВЕРИТЬ ПЕРЕД ПУБЛИКАЦИЕЙ: символ
    // подставляется в кошелёк при добавлении сети и в подписи полей покупки.
    currency: { name: 'Ether', symbol: 'ETH', decimals: 18 }
  },

  /* ЗАПОЛНИТЬ ПОСЛЕ ДЕПЛОЯ. Пока адрес нулевой, страница не делает по нему
     ни одного запроса и честно пишет «не задан» вместо числа. */
  contracts: {
    token:    '0x0000000000000000000000000000000000000000', // заполнить после деплоя — ERC-20 MACLRN
    emission: '0x0000000000000000000000000000000000000000', // заполнить после деплоя — контракт эмиссии
    curve:    '0x0000000000000000000000000000000000000000', // заполнить после деплоя — бондинг-кривая
    vesting:  '0x0000000000000000000000000000000000000000'  // заполнить после деплоя — вестинг казны
  },

  /* ЗАПОЛНИТЬ. Пустая строка => карточка ссылки показывается неактивной
     с пометкой «ссылка не задана», а не ведёт в никуда. */
  links: {
    repo:      '', // заполнить: URL репозитория с исходниками
    audit:     '', // заполнить: URL отчётов аудита
    specToken: '', // заполнить: URL спецификации токена (MACLAURIN-TOKEN-SPEC.md в репозитории)
    specCurve: ''  // заполнить: URL спецификации кривой (PHASE4-SPEC.md в репозитории)
  },

  ui: {
    autoRefreshMs: 60000,      // 0 — выключить автообновление
    defaultSlippagePct: '1',
    defaultDeadlineMin: '10'
  }
};

/* ── селекторы (первые 4 байта keccak256 от сигнатуры, cast sig) ────────── */

const SEL = {
  // ERC-20
  totalSupply:  '0x18160ddd', // totalSupply()
  name:         '0x06fdde03', // name()
  symbol:       '0x95d89b41', // symbol()
  decimals:     '0x313ce567', // decimals()
  balanceOf:    '0x70a08231', // balanceOf(address)
  // эмиссия
  currentEpoch: '0x76671808', // currentEpoch()
  epochAmount:  '0x2f008ecc', // epochAmount(uint256)
  epochEndsAt:  '0x8679e5c0', // epochEndsAt(uint256)
  emissionEnd:  '0x8368909c', // emissionEnd()
  totalWeight:  '0x96c82e57', // totalWeight()
  totalStaked:  '0x817b1cd2', // totalStaked()
  // кривая
  sold:         '0x02c7e7af', // sold()
  inventory:    '0xde5d547e', // INVENTORY()
  spotPrice:    '0x398482d8', // spotPrice()
  reserve:      '0xcd3293de', // reserve()
  previewBuy:   '0x48153279', // previewBuy(uint256)
  maxEthIn:     '0x3c541c74', // maxEthIn()
  buy:          '0xd6febde8', // buy(uint256,uint256)
  boughtOf:     '0xb56e1c73', // boughtOf(address)
  antiSnipeEnd: '0x0e48fb1c', // antiSnipeEnd()
  antiSnipeMax: '0xd7469371'  // ANTI_SNIPE_MAX()
};

/* Слоты EIP-1967: keccak256("eip1967.proxy.implementation") − 1 и
   keccak256("eip1967.proxy.admin") − 1. Ненулевое значение в них означает,
   что за адресом стоит обновляемый прокси. */
const EIP1967 = {
  impl:  '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc',
  admin: '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103'
};

/* Селекторы ошибок контрактов — чтобы показывать причину отказа по-русски,
   а не голый hex. */
const ERRORS = {
  '0xbc3088ef': 'Дедлайн истёк. Увеличьте срок и повторите.',
  '0x4853b987': 'Цена ушла дальше допуска по проскальзыванию. Пересчитайте котировку.',
  '0xb77867d8': 'Цена ушла дальше допуска по проскальзыванию при продаже.',
  '0x9b158fe6': 'Сумма больше остатка инвентаря. Максимум на сейчас — maxEthIn().',
  '0xb43243da': 'Продать кривой можно только то, что у неё куплено этим адресом.',
  '0x792dd007': 'Лимит первого часа: не более 10 000 000 токенов на адрес.',
  '0x1f2a2005': 'Нулевая сумма.',
  '0x9c718997': 'Запрошено больше, чем кривая вообще продала.',
  '0x6f2fb69e': 'Аргумент вне области определения кривой.'
};

/* ── мелкие утилиты ────────────────────────────────────────────────────── */

const ZERO_ADDR = '0x0000000000000000000000000000000000000000';
const $  = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

const isSet = (a) => typeof a === 'string' && /^0x[0-9a-fA-F]{40}$/.test(a) && a.toLowerCase() !== ZERO_ADDR;

const NBSP = ' '; // узкий неразрывный пробел для разрядов

function groupDigits(s) {
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, NBSP);
}

/** wei → строка с разделителями разрядов. */
function formatUnits(value, decimals = 18, maxFrac = decimals) {
  let v = BigInt(value);
  const neg = v < 0n;
  if (neg) v = -v;
  const base = 10n ** BigInt(decimals);
  const int = (v / base).toString();
  let frac = (v % base).toString().padStart(decimals, '0');
  if (maxFrac < decimals) frac = frac.slice(0, maxFrac);
  frac = frac.replace(/0+$/, '');
  return (neg ? '−' : '') + groupDigits(int) + (frac ? '.' + frac : '');
}

/** Строка от пользователя → базовые единицы. Никакой плавающей точки. */
function parseUnits(str, decimals = 18) {
  const s = String(str).trim().replace(',', '.').replace(/[\s  ]/g, '');
  if (!/^\d*(\.\d*)?$/.test(s) || s === '' || s === '.') throw new Error('Введите число, например 0.01');
  const [i, f = ''] = s.split('.');
  if (f.length > decimals) throw new Error(`Не более ${decimals} знаков после запятой`);
  return BigInt((i || '0') + f.padEnd(decimals, '0'));
}

const toHexQty = (v) => '0x' + BigInt(v).toString(16);
const argUint  = (v) => BigInt(v).toString(16).padStart(64, '0');
const argAddr  = (a) => a.toLowerCase().replace(/^0x/, '').padStart(64, '0');

/** hex-строку ответа режем на 32-байтовые слова. */
function words(hex) {
  const h = String(hex || '').replace(/^0x/, '');
  const out = [];
  for (let i = 0; i + 64 <= h.length; i += 64) out.push(BigInt('0x' + h.slice(i, i + 64)));
  return out;
}
const uint = (hex) => (hex && hex !== '0x' ? BigInt(hex) : 0n);

/** ABI-декодирование одиночной строки (name/symbol). */
function decodeString(hex) {
  const h = String(hex || '').replace(/^0x/, '');
  if (h.length < 128) return '';
  const off = Number(BigInt('0x' + h.slice(0, 64))) * 2;
  const len = Number(BigInt('0x' + h.slice(off, off + 64)));
  const data = h.slice(off + 64, off + 64 + len * 2);
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) bytes[i] = parseInt(data.slice(i * 2, i * 2 + 2), 16);
  return new TextDecoder().decode(bytes);
}

const shortAddr = (a) => a.slice(0, 6) + '…' + a.slice(-4);

function fmtDate(unixSeconds) {
  const d = new Date(Number(unixSeconds) * 1000);
  if (!isFinite(d.getTime())) return '—';
  try {
    return new Intl.DateTimeFormat('ru-RU', { dateStyle: 'long', timeStyle: 'short' }).format(d);
  } catch (_) {
    return d.toISOString();
  }
}
const fmtIsoUtc = (unixSeconds) => new Date(Number(unixSeconds) * 1000).toISOString().replace('.000Z', 'Z');

function humanDelta(seconds) {
  const s = Number(seconds);
  if (s <= 0) return 'уже прошёл';
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  if (d > 0) return `через ${d} дн. ${h} ч.`;
  const m = Math.floor((s % 3600) / 60);
  return `через ${h} ч. ${m} мин.`;
}

/* ── JSON-RPC ──────────────────────────────────────────────────────────── */

let rpcId = 0;

async function rpc(method, params) {
  const res = await fetch(CONFIG.chain.rpc, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
    // Никаких кук и заголовков авторизации: узел не должен уметь отличать
    // одного читателя страницы от другого.
    credentials: 'omit',
    cache: 'no-store'
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} от RPC`);
  const json = await res.json();
  if (json.error) {
    const err = new Error(json.error.message || 'ошибка RPC');
    err.data = json.error.data;
    throw err;
  }
  return json.result;
}

const ethCall = (to, data) => rpc('eth_call', [{ to, data }, 'latest']);

/** Promise.allSettled по объекту задач. */
async function settle(tasks) {
  const keys = Object.keys(tasks);
  const results = await Promise.allSettled(keys.map((k) => tasks[k]));
  const out = {};
  keys.forEach((k, i) => {
    const r = results[i];
    out[k] = r.status === 'fulfilled' ? { ok: true, value: r.value } : { ok: false, error: r.reason };
  });
  return out;
}

/* ── ссылки в эксплорер ────────────────────────────────────────────────── */

const ex = {
  address: (a) => `${CONFIG.chain.explorer}/address/${a}`,
  read:    (a) => `${CONFIG.chain.explorer}/address/${a}?tab=read_contract`,
  write:   (a) => `${CONFIG.chain.explorer}/address/${a}?tab=write_contract`,
  code:    (a) => `${CONFIG.chain.explorer}/address/${a}?tab=contract`,
  token:   (a) => `${CONFIG.chain.explorer}/token/${a}`,
  tx:      (h) => `${CONFIG.chain.explorer}/tx/${h}`
};

/* ── карточки метрик ───────────────────────────────────────────────────── */

/**
 * @param id      id карточки в разметке
 * @param value   крупное число
 * @param sub     мелкая строка под ним (сырое значение, пояснение)
 * @param addr    контракт, к которому шёл вызов
 * @param sig     сигнатура вызова — для команды повтора
 * @param data    calldata вызова
 * @param kind    'call' | 'storage'
 * @param slot    слот для eth_getStorageAt
 * @param state   'ok' | 'pending' | 'error'
 */
function setCard(id, { value, sub = '', addr, sig, data, kind = 'call', slot, state = 'ok' }) {
  const card = document.getElementById(id);
  if (!card) return;

  const v = card.querySelector('[data-field="value"]');
  const s = card.querySelector('[data-field="sub"]');
  v.textContent = value;
  v.className = 'metric-value' + (state === 'pending' ? ' is-pending' : state === 'error' ? ' is-error' : '');
  s.textContent = sub;

  const links = card.querySelector('.metric-links');
  links.textContent = '';
  if (!isSet(addr)) return;

  const a = document.createElement('a');
  a.href = kind === 'storage' ? ex.address(addr) : ex.read(addr);
  a.target = '_blank';
  a.rel = 'noopener noreferrer';
  a.textContent = 'эксплорер';
  links.appendChild(a);

  const det = document.createElement('details');
  const sum = document.createElement('summary');
  sum.textContent = 'повторить вызов';
  const pre = document.createElement('pre');
  pre.className = 'code-block';
  const code = document.createElement('code');

  const body = kind === 'storage'
    ? `{"jsonrpc":"2.0","id":1,"method":"eth_getStorageAt","params":["${addr}","${slot}","latest"]}`
    : `{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"${addr}","data":"${data}"},"latest"]}`;

  const cast = kind === 'storage'
    ? `cast storage ${addr} ${slot} --rpc-url ${CONFIG.chain.rpc}`
    : `cast call ${addr} "${sig}" --rpc-url ${CONFIG.chain.rpc}`;

  code.textContent =
    `curl -s ${CONFIG.chain.rpc} \\\n  -H 'content-type: application/json' \\\n  -d '${body}'\n\n${cast}`;
  pre.appendChild(code);
  det.append(sum, pre);
  links.appendChild(det);
}

function cardUnavailable(id, reason) {
  setCard(id, { value: reason, state: 'pending' });
}

/* ── загрузка данных с цепочки ─────────────────────────────────────────── */

const state = {
  account: null,
  quote: null       // { valueWei, minTokensOut, tokensOut, minutes }
};

function setStatus(text, kind = '') {
  const el = $('#status-text');
  el.textContent = text;
  el.className = 'status-text' + (kind ? ' is-' + kind : '');
}

function pendingCards(msg) {
  ['m-epoch', 'm-epochamount', 'm-emissionend', 'm-supply', 'm-sold', 'm-price',
   'm-reserve', 'm-weight', 'm-identity', 'm-proxy'].forEach((id) => cardUnavailable(id, msg));
}

async function refresh() {
  const { token: T, emission: E, curve: C } = CONFIG.contracts;
  const anySet = isSet(T) || isSet(E) || isSet(C);

  if (!anySet) {
    pendingCards('адрес не задан');
    setStatus('Адреса контрактов не заполнены — читать нечего.', 'error');
    return;
  }

  setStatus('Чтение с цепочки…');

  const tasks = { block: rpc('eth_blockNumber') };

  if (isSet(T)) {
    tasks.totalSupply = ethCall(T, SEL.totalSupply);
    tasks.name        = ethCall(T, SEL.name);
    tasks.symbol      = ethCall(T, SEL.symbol);
    tasks.decimals    = ethCall(T, SEL.decimals);
    tasks.implSlot    = rpc('eth_getStorageAt', [T, EIP1967.impl, 'latest']);
    tasks.adminSlot   = rpc('eth_getStorageAt', [T, EIP1967.admin, 'latest']);
  }
  if (isSet(E)) {
    tasks.currentEpoch = ethCall(E, SEL.currentEpoch);
    tasks.emissionEnd  = ethCall(E, SEL.emissionEnd);
    tasks.totalWeight  = ethCall(E, SEL.totalWeight);
    tasks.totalStaked  = ethCall(E, SEL.totalStaked);
  }
  if (isSet(C)) {
    tasks.sold      = ethCall(C, SEL.sold);
    tasks.inventory = ethCall(C, SEL.inventory);
    tasks.spotPrice = ethCall(C, SEL.spotPrice);
    tasks.reserve   = ethCall(C, SEL.reserve);
  }

  let r;
  try {
    r = await settle(tasks);
  } catch (e) {
    setStatus('RPC недоступен: ' + (e.message || e), 'error');
    return;
  }

  const dec = CONFIG.token.decimals;
  const sym = CONFIG.token.symbol;
  const gas = CONFIG.chain.currency.symbol;

  /* — эпоха и награда эпохи — */
  if (isSet(E)) {
    if (r.currentEpoch.ok) {
      const n = uint(r.currentEpoch.value);
      const finished = n > 26n;
      setCard('m-epoch', {
        value: finished ? 'эмиссия завершена' : `${n} из 26`,
        sub: finished ? 'currentEpoch() = ' + n : `эпоха длится 7 дней`,
        addr: E, sig: 'currentEpoch()(uint256)', data: SEL.currentEpoch
      });

      // Награда текущей эпохи: аргумент известен только сейчас, поэтому вторым шагом.
      const nq = finished ? 26n : n;
      const dataAmt = SEL.epochAmount + argUint(nq);
      try {
        const amt = uint(await ethCall(E, dataAmt));
        setCard('m-epochamount', {
          value: `${formatUnits(amt, dec)} ${sym}`,
          sub: `${amt} базовых единиц = 10^27 / ${nq}!` + (finished ? ' (последняя эпоха с ненулевой наградой)' : ''),
          addr: E, sig: 'epochAmount(uint256)(uint256)', data: dataAmt
        });
      } catch (e) {
        setCard('m-epochamount', { value: 'ошибка вызова', sub: String(e.message || e), addr: E, sig: 'epochAmount(uint256)(uint256)', data: dataAmt, state: 'error' });
      }
    } else {
      setCard('m-epoch', { value: 'ошибка вызова', sub: String(r.currentEpoch.error.message || ''), addr: E, sig: 'currentEpoch()(uint256)', data: SEL.currentEpoch, state: 'error' });
      cardUnavailable('m-epochamount', 'нет номера эпохи');
    }

    if (r.emissionEnd.ok) {
      const t = uint(r.emissionEnd.value);
      const now = BigInt(Math.floor(Date.now() / 1000));
      setCard('m-emissionend', {
        value: fmtDate(t),
        sub: `${fmtIsoUtc(t)} · unix ${t} · ` + (t > now ? humanDelta(t - now) : 'эмиссия завершена'),
        addr: E, sig: 'emissionEnd()(uint256)', data: SEL.emissionEnd
      });
    } else {
      setCard('m-emissionend', { value: 'ошибка вызова', addr: E, sig: 'emissionEnd()(uint256)', data: SEL.emissionEnd, state: 'error' });
    }

    if (r.totalWeight.ok) {
      const w = uint(r.totalWeight.value);
      const st = r.totalStaked.ok ? uint(r.totalStaked.value) : null;
      setCard('m-weight', {
        value: formatUnits(w, dec, 6),
        sub: st === null ? `${w} базовых единиц` : `в стейкинге ${formatUnits(st, dec, 6)} ${sym} · вес ≤ тело × e`,
        addr: E, sig: 'totalWeight()(uint256)', data: SEL.totalWeight
      });
    } else {
      setCard('m-weight', { value: 'ошибка вызова', addr: E, sig: 'totalWeight()(uint256)', data: SEL.totalWeight, state: 'error' });
    }
  } else {
    ['m-epoch', 'm-epochamount', 'm-emissionend', 'm-weight'].forEach((id) => cardUnavailable(id, 'адрес эмиссии не задан'));
  }

  /* — токен — */
  if (isSet(T)) {
    if (r.totalSupply.ok) {
      const s = uint(r.totalSupply.value);
      setCard('m-supply', {
        value: `${formatUnits(s, dec)} ${sym}`,
        sub: `${s} базовых единиц · floor(e × 10^27)`,
        addr: T, sig: 'totalSupply()(uint256)', data: SEL.totalSupply
      });
    } else {
      setCard('m-supply', { value: 'ошибка вызова', addr: T, sig: 'totalSupply()(uint256)', data: SEL.totalSupply, state: 'error' });
    }

    const nm = r.name.ok ? decodeString(r.name.value) : '?';
    const sb = r.symbol.ok ? decodeString(r.symbol.value) : '?';
    const dc = r.decimals.ok ? uint(r.decimals.value) : '?';
    const matches = sb === CONFIG.token.symbol;
    setCard('m-identity', {
      value: `${nm} (${sb})`,
      sub: `decimals ${dc} · ` + (matches ? 'совпадает с заявленным на странице' : `на странице заявлен ${CONFIG.token.symbol} — расхождение`),
      addr: T, sig: 'symbol()(string)', data: SEL.symbol,
      state: matches ? 'ok' : 'error'
    });

    const impl = r.implSlot.ok ? uint(r.implSlot.value) : null;
    const adm  = r.adminSlot.ok ? uint(r.adminSlot.value) : null;
    if (impl === null) {
      setCard('m-proxy', { value: 'слот не прочитан', addr: T, kind: 'storage', slot: EIP1967.impl, state: 'error' });
    } else if (impl === 0n && (adm === null || adm === 0n)) {
      setCard('m-proxy', {
        value: '0x00…00 — прокси нет',
        sub: 'слот реализации и слот администратора пусты: контракт не обновляем',
        addr: T, kind: 'storage', slot: EIP1967.impl
      });
    } else {
      setCard('m-proxy', {
        value: 'слот не пуст',
        sub: `implementation ${r.implSlot.value} · admin ${r.adminSlot.ok ? r.adminSlot.value : '?'} — проверьте вручную`,
        addr: T, kind: 'storage', slot: EIP1967.impl, state: 'error'
      });
    }
  } else {
    ['m-supply', 'm-identity', 'm-proxy'].forEach((id) => cardUnavailable(id, 'адрес токена не задан'));
  }

  /* — кривая — */
  if (isSet(C)) {
    if (r.sold.ok && r.inventory.ok) {
      const sold = uint(r.sold.value);
      const inv  = uint(r.inventory.value);
      const pctBps = inv > 0n ? (sold * 1000000n) / inv : 0n; // доля в миллионных
      const pct = (Number(pctBps) / 10000).toFixed(4);
      setCard('m-sold', {
        value: `${pct}%`,
        sub: `${formatUnits(sold, dec, 6)} из ${formatUnits(inv, dec, 0)} ${sym}`,
        addr: C, sig: 'sold()(uint256)', data: SEL.sold
      });
    } else {
      setCard('m-sold', { value: 'ошибка вызова', addr: C, sig: 'sold()(uint256)', data: SEL.sold, state: 'error' });
    }

    if (r.spotPrice.ok) {
      const p = uint(r.spotPrice.value);
      setCard('m-price', {
        value: `${formatUnits(p, 9)} gwei`,
        sub: `${p} wei за 1 ${sym} · стартовая цена 2 gwei, конечная 5.436563656918090470 gwei`,
        addr: C, sig: 'spotPrice()(uint256)', data: SEL.spotPrice
      });
    } else {
      setCard('m-price', { value: 'ошибка вызова', addr: C, sig: 'spotPrice()(uint256)', data: SEL.spotPrice, state: 'error' });
    }

    if (r.reserve.ok) {
      const v = uint(r.reserve.value);
      setCard('m-reserve', {
        value: `${formatUnits(v, 18, 9)} ${gas}`,
        sub: `${v} wei · полная распродажа инвентаря собирает 3.718281828459045235 ${gas} (= 1 + e)`,
        addr: C, sig: 'reserve()(uint256)', data: SEL.reserve
      });
    } else {
      setCard('m-reserve', { value: 'ошибка вызова', addr: C, sig: 'reserve()(uint256)', data: SEL.reserve, state: 'error' });
    }
  } else {
    ['m-sold', 'm-price', 'm-reserve'].forEach((id) => cardUnavailable(id, 'адрес кривой не задан'));
  }

  const failed = Object.values(r).filter((x) => !x.ok).length;
  const blk = r.block.ok ? BigInt(r.block.value).toString() : '?';
  const time = new Date().toLocaleTimeString('ru-RU');
  if (failed === 0) {
    setStatus(`Обновлено ${time} · блок ${groupDigits(blk)} · ${new URL(CONFIG.chain.rpc).host}`, 'ok');
  } else if (failed === Object.keys(r).length) {
    setStatus(`RPC не ответил (${new URL(CONFIG.chain.rpc).host}). Проверьте сеть или откройте эксплорер.`, 'error');
  } else {
    setStatus(`Обновлено ${time} · блок ${groupDigits(blk)} · не прочитано вызовов: ${failed}`, 'error');
  }
}

/* ── статические подстановки: адреса, ссылки, команды проверки ──────────── */

function renderAddresses() {
  const C = CONFIG.contracts.curve;

  $('#curve-address').textContent = isSet(C) ? C : ZERO_ADDR + '  (адрес будет заполнен после деплоя)';

  const curveLinks = $('#curve-links');
  curveLinks.textContent = '';
  if (isSet(C)) {
    [['Верифицированный исходник', ex.code(C)], ['Read contract', ex.read(C)], ['Write contract', ex.write(C)]]
      .forEach(([t, href]) => {
        const a = document.createElement('a');
        a.href = href; a.target = '_blank'; a.rel = 'noopener noreferrer'; a.textContent = t;
        curveLinks.appendChild(a);
      });
  } else {
    curveLinks.textContent = 'Ссылки появятся после развёртывания и верификации контракта.';
  }

  const sellLinks = $('#sell-links');
  sellLinks.textContent = '';
  if (isSet(C) && isSet(CONFIG.contracts.token)) {
    [['approve на контракте токена', ex.write(CONFIG.contracts.token)], ['sell на контракте кривой', ex.write(C)]]
      .forEach(([t, href]) => {
        const a = document.createElement('a');
        a.href = href; a.target = '_blank'; a.rel = 'noopener noreferrer'; a.textContent = t;
        sellLinks.appendChild(a);
      });
  } else {
    sellLinks.textContent = 'Ссылки появятся после развёртывания контрактов.';
  }

  $$('[data-field="currency"]').forEach((el) => { el.textContent = CONFIG.chain.currency.symbol; });
  $$('[data-field="rpc"]').forEach((el) => { el.textContent = CONFIG.chain.rpc; });
  $$('[data-field="explorer"]').forEach((el) => { el.textContent = CONFIG.chain.explorer; });
}

function renderVerifyCommands() {
  const { token: T, emission: E, curve: C } = CONFIG.contracts;
  const rpcUrl = CONFIG.chain.rpc;
  const lines = [
    '# 1. Скачать развёрнутый байткод и поискать в нём селекторы полномочий.',
    '#    Пустой вывод grep = такой функции в контракте нет.',
    `cast code ${T} --rpc-url ${rpcUrl} > token.hex`,
    'grep -o -e 40c10f19 -e 8da5cb5b -e f2fde38b -e 3659cfe6 -e 8456cb59 token.hex',
    '',
    '# 2. Убедиться, что за адресом нет прокси (слот реализации EIP-1967).',
    `cast storage ${T} ${EIP1967.impl} --rpc-url ${rpcUrl}`,
    '',
    '# 3. Сапплай неизменен и равен floor(e × 10^27).',
    `cast call ${T} "totalSupply()(uint256)" --rpc-url ${rpcUrl}`,
    '',
    '# 4. Эмиссия обрывается сама: член ряда на эпохе 27 равен нулю.',
    `cast call ${E} "epochAmount(uint256)(uint256)" 26 --rpc-url ${rpcUrl}`,
    `cast call ${E} "epochAmount(uint256)(uint256)" 27 --rpc-url ${rpcUrl}   # 0`,
    '',
    '# 5. Множитель стейкинга не достигает e ни при каком радиусе.',
    `cast call ${E} "multiplier(uint256)(uint256)" 7 --rpc-url ${rpcUrl}`,
    `cast call ${E} "E_FIXED()(uint256)" --rpc-url ${rpcUrl}`,
    '',
    '# 6. Цена от первой до последней монеты растёт ровно в e раз.',
    `cast call ${C} "P0()(uint256)" --rpc-url ${rpcUrl}`,
    `cast call ${C} "P_FINAL()(uint256)" --rpc-url ${rpcUrl}`
  ];
  $('#verify-commands').firstElementChild.textContent = lines.join('\n');

  const box = $('#verified-sources');
  box.textContent = '';
  const items = [
    ['Исходник токена', CONFIG.contracts.token],
    ['Исходник контракта эмиссии', CONFIG.contracts.emission],
    ['Исходник кривой', CONFIG.contracts.curve],
    ['Исходник вестинга', CONFIG.contracts.vesting]
  ];
  const parts = [];
  items.forEach(([title, addr]) => {
    if (!isSet(addr)) return;
    const a = document.createElement('a');
    a.href = ex.code(addr); a.target = '_blank'; a.rel = 'noopener noreferrer';
    a.textContent = title;
    parts.push(a);
  });
  if (parts.length === 0) {
    box.textContent = 'Ссылки на верифицированные исходники появятся после развёртывания.';
  } else {
    parts.forEach((a) => box.appendChild(a));
  }
}

function renderLinkGrid() {
  const grid = $('#link-grid');
  grid.textContent = '';

  const items = [
    ['Токен MACLRN (ERC-20)', CONFIG.contracts.token, (a) => ex.token(a)],
    ['Контракт эмиссии', CONFIG.contracts.emission, (a) => ex.code(a)],
    ['Бондинг-кривая', CONFIG.contracts.curve, (a) => ex.code(a)],
    ['Вестинг казны', CONFIG.contracts.vesting, (a) => ex.code(a)],
    ['Репозиторий с исходниками', CONFIG.links.repo, (u) => u],
    ['Отчёты аудита', CONFIG.links.audit, (u) => u],
    ['Спецификация токена', CONFIG.links.specToken, (u) => u],
    ['Спецификация кривой', CONFIG.links.specCurve, (u) => u]
  ];

  items.forEach(([title, target, hrefOf]) => {
    const card = document.createElement('div');
    card.className = 'link-card';
    const known = target && (isSet(target) || /^https?:\/\//.test(target));
    if (known) {
      const a = document.createElement('a');
      a.className = 'link-title';
      a.href = hrefOf(target);
      a.target = '_blank'; a.rel = 'noopener noreferrer';
      a.textContent = title;
      const sub = document.createElement('span');
      sub.className = 'link-sub';
      sub.textContent = isSet(target) ? target : new URL(target).host;
      card.append(a, sub);
    } else {
      card.classList.add('is-missing');
      const t = document.createElement('span');
      t.className = 'link-title';
      t.textContent = title;
      const sub = document.createElement('span');
      sub.className = 'link-sub';
      sub.textContent = 'ссылка не задана — заполнить после деплоя';
      card.append(t, sub);
    }
    grid.appendChild(card);
  });
}

function renderChainBanner() {
  const anyMissing = Object.values(CONFIG.contracts).some((a) => !isSet(a));
  const b = $('#chain-banner');
  if (!anyMissing) { b.hidden = true; return; }
  b.hidden = false;
  b.textContent =
    'Контракты ещё не развёрнуты: адреса в конфигурации страницы нулевые. ' +
    'Числа ниже появятся сами, как только адреса будут заполнены, — они читаются ' +
    'с цепочки, а не вписываются в вёрстку.';
}

/* ── кошелёк ───────────────────────────────────────────────────────────── */

function buyMsg(text, kind = '') {
  const el = $('#buy-message');
  el.textContent = text;
  el.className = 'buy-message' + (kind ? ' is-' + kind : '');
}

function walletState(text) { $('#wallet-state').textContent = text; }

function hasWallet() { return typeof window !== 'undefined' && typeof window.ethereum !== 'undefined'; }

async function ensureChain() {
  const current = await window.ethereum.request({ method: 'eth_chainId' });
  if (parseInt(current, 16) === CONFIG.chain.id) return;

  try {
    await window.ethereum.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: CONFIG.chain.idHex }]
    });
  } catch (e) {
    const code = e && (e.code ?? (e.data && e.data.originalError && e.data.originalError.code));
    if (code !== 4902) throw e;
    // Сети нет в кошельке — предлагаем добавить. Параметры видны пользователю
    // в окне кошелька, и там же он их подтверждает.
    await window.ethereum.request({
      method: 'wallet_addEthereumChain',
      params: [{
        chainId: CONFIG.chain.idHex,
        chainName: CONFIG.chain.name,
        nativeCurrency: {
          name: CONFIG.chain.currency.name,
          symbol: CONFIG.chain.currency.symbol,
          decimals: CONFIG.chain.currency.decimals
        },
        rpcUrls: [CONFIG.chain.rpc],
        blockExplorerUrls: [CONFIG.chain.explorer]
      }]
    });
  }

  const after = await window.ethereum.request({ method: 'eth_chainId' });
  if (parseInt(after, 16) !== CONFIG.chain.id) {
    throw new Error(`Кошелёк остался в другой сети. Нужен chain ID ${CONFIG.chain.id}.`);
  }
}

async function connect() {
  if (!hasWallet()) { $('#no-wallet').hidden = false; buyMsg('Кошелёк в браузере не найден — инструкция ниже.', 'error'); return; }
  try {
    buyMsg('Подтвердите подключение в кошельке…');
    const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
    state.account = accounts && accounts[0] ? accounts[0] : null;
    if (!state.account) throw new Error('Кошелёк не вернул адрес');
    await ensureChain();
    await showWallet();
    buyMsg('');
  } catch (e) {
    state.account = null;
    walletState('Кошелёк не подключён');
    buyMsg(walletError(e), 'error');
  }
}

async function showWallet() {
  if (!state.account) { walletState('Кошелёк не подключён'); return; }
  let extra = '';
  if (isSet(CONFIG.contracts.curve)) {
    try {
      const bought = uint(await ethCall(CONFIG.contracts.curve, SEL.boughtOf + argAddr(state.account)));
      extra = ` · право обратного выкупа: ${formatUnits(bought, CONFIG.token.decimals, 6)} ${CONFIG.token.symbol}`;
    } catch (_) { /* не критично для покупки */ }
  }
  walletState(`${shortAddr(state.account)} · сеть ${CONFIG.chain.id}${extra}`);
}

function walletError(e) {
  if (!e) return 'Неизвестная ошибка';
  const code = e.code ?? (e.data && e.data.originalError && e.data.originalError.code);
  if (code === 4001) return 'Вы отклонили запрос в кошельке.';
  if (code === -32002) return 'Запрос уже открыт в кошельке — подтвердите его там.';
  return decodeRevert(e) || e.message || String(e);
}

/** Достаём человекочитаемую причину revert из ответа узла/кошелька. */
function decodeRevert(e) {
  const raw =
    (e && e.data && typeof e.data === 'string' && e.data) ||
    (e && e.data && e.data.data) ||
    (e && e.error && e.error.data) || '';
  if (typeof raw !== 'string' || !raw.startsWith('0x') || raw.length < 10) return '';
  const sel = raw.slice(0, 10).toLowerCase();
  if (ERRORS[sel]) return ERRORS[sel];
  if (sel === '0x08c379a0') {
    try { return 'Контракт отказал: ' + decodeString('0x' + raw.slice(10)); } catch (_) { /* ignore */ }
  }
  return '';
}

/* ── котировка и покупка ───────────────────────────────────────────────── */

function readInputs() {
  const valueWei = parseUnits($('#in-amount').value, CONFIG.chain.currency.decimals);
  if (valueWei <= 0n) throw new Error('Сумма должна быть больше нуля');

  const slipBps = parseUnits($('#in-slippage').value || '0', 2); // 1.25% → 125 bps
  if (slipBps >= 10000n) throw new Error('Проскальзывание должно быть меньше 100%');

  const minutes = Number(String($('#in-deadline').value).trim());
  if (!Number.isFinite(minutes) || minutes <= 0 || minutes > 1440) throw new Error('Дедлайн — от 1 до 1440 минут');

  return { valueWei, slipBps, minutes };
}

async function quote(silent = false) {
  const C = CONFIG.contracts.curve;
  if (!isSet(C)) { buyMsg('Адрес кривой не задан: контракт ещё не развёрнут.', 'error'); return null; }

  let inp;
  try { inp = readInputs(); } catch (e) { buyMsg(e.message, 'error'); return null; }

  if (!silent) buyMsg('Считаем котировку…');

  try {
    // previewBuy обязателен: без него нет ни котировки, ни minTokensOut.
    // Остальное — справочное, поэтому читается через settle и не роняет расчёт.
    const previewRaw = await ethCall(C, SEL.previewBuy + argUint(inp.valueWei));
    const aux = await settle({
      maxIn:   ethCall(C, SEL.maxEthIn),
      antiEnd: ethCall(C, SEL.antiSnipeEnd),
      antiMax: ethCall(C, SEL.antiSnipeMax)
    });

    const [tokensOut, fee, netIn] = words(previewRaw);
    const maxIn = aux.maxIn.ok ? uint(aux.maxIn.value) : null;
    const minTokensOut = (tokensOut * (10000n - inp.slipBps)) / 10000n;
    if (minTokensOut <= 0n) throw new Error('Слишком маленькая сумма: расчётное количество токенов равно нулю');

    const gas = CONFIG.chain.currency.symbol;
    const sym = CONFIG.token.symbol;
    const dec = CONFIG.token.decimals;
    const effective = tokensOut > 0n ? (netIn * 10n ** 18n) / tokensOut : 0n; // wei за 1 целый токен

    const rows = [
      ['Получите (сейчас)', `${formatUnits(tokensOut, dec, 8)} ${sym}`],
      ['Минимум при исполнении', `${formatUnits(minTokensOut, dec, 8)} ${sym}`],
      ['Комиссия 1%', `${formatUnits(fee, 18, 9)} ${gas}`],
      ['В резерв кривой', `${formatUnits(netIn, 18, 9)} ${gas}`],
      ['Средняя цена сделки', `${formatUnits(effective, 9)} gwei за 1 ${sym}`]
    ];
    if (maxIn !== null) rows.push(['Максимум прямо сейчас', `${formatUnits(maxIn, 18, 9)} ${gas} (maxEthIn)`]);

    const out = $('#quote-out');
    out.hidden = false;
    out.textContent = '';
    const dl = document.createElement('dl');
    rows.forEach(([k, v]) => {
      const dt = document.createElement('dt'); dt.textContent = k;
      const dd = document.createElement('dd'); dd.textContent = v;
      dl.append(dt, dd);
    });
    out.appendChild(dl);

    const warnings = [];
    if (maxIn !== null && inp.valueWei > maxIn) {
      warnings.push(`Сумма больше остатка инвентаря: buy() отревертит. Максимум прямо сейчас — ${formatUnits(maxIn, 18, 9)} ${gas}.`);
    }
    // Лимит первого часа читается с цепочки, а не берётся из текста страницы:
    // окно могло уже закрыться, и тогда предупреждать не о чем.
    if (aux.antiEnd.ok && aux.antiMax.ok) {
      const antiEnd = uint(aux.antiEnd.value);
      const antiMax = uint(aux.antiMax.value);
      const now = BigInt(Math.floor(Date.now() / 1000));
      if (now < antiEnd && tokensOut > antiMax) {
        warnings.push(`Действует лимит первого часа: не более ${formatUnits(antiMax, dec, 0)} ${sym} на адрес. Покупка на эту сумму отревертит AntiSnipeLimit.`);
      }
    }
    if (warnings.length) {
      const p = document.createElement('p');
      p.className = 'footnote';
      p.textContent = warnings.join(' ');
      out.appendChild(p);
    }

    state.quote = { valueWei: inp.valueWei, minTokensOut, tokensOut, minutes: inp.minutes };
    $('#do-buy').disabled = false;

    const deadline = BigInt(Math.floor(Date.now() / 1000) + inp.minutes * 60);
    $('#calldata-preview').textContent =
      `to:    ${C}\n` +
      `value: ${inp.valueWei} wei (${formatUnits(inp.valueWei, 18, 18)} ${gas})\n` +
      `data:  ${SEL.buy}\n` +
      `       ${argUint(minTokensOut)}   // minTokensOut\n` +
      `       ${argUint(deadline)}   // deadline (unix, пересчитывается при отправке)`;

    if (!silent) buyMsg('Котировка действительна на текущий блок. Перед отправкой она пересчитывается заново.', '');
    return state.quote;
  } catch (e) {
    state.quote = null;
    $('#do-buy').disabled = true;
    buyMsg(decodeRevert(e) || `Не удалось получить котировку: ${e.message || e}`, 'error');
    return null;
  }
}

async function doBuy() {
  const C = CONFIG.contracts.curve;
  if (!isSet(C)) { buyMsg('Адрес кривой не задан.', 'error'); return; }
  if (!hasWallet()) { $('#no-wallet').hidden = false; buyMsg('Кошелёк не найден.', 'error'); return; }

  try {
    if (!state.account) await connect();
    if (!state.account) return;
    await ensureChain();

    // Котировка пересчитывается прямо перед отправкой: между «Рассчитать» и
    // «Купить» могли пройти чужие сделки, а minTokensOut обязан отражать
    // актуальную цену, иначе защита от проскальзывания бессмысленна.
    const q = await quote(true);
    if (!q) return;

    const deadline = BigInt(Math.floor(Date.now() / 1000) + q.minutes * 60);
    const data = SEL.buy + argUint(q.minTokensOut) + argUint(deadline);

    buyMsg('Проверьте адрес получателя и сумму в окне кошелька и подтвердите.');

    const hash = await window.ethereum.request({
      method: 'eth_sendTransaction',
      params: [{
        from: state.account,
        to: C,
        value: toHexQty(q.valueWei),
        data: '0x' + data.replace(/^0x/, '')
      }]
    });

    const el = $('#buy-message');
    el.className = 'buy-message is-ok';
    el.textContent = 'Транзакция отправлена: ';
    const a = document.createElement('a');
    a.href = ex.tx(hash); a.target = '_blank'; a.rel = 'noopener noreferrer';
    a.textContent = hash;
    el.appendChild(a);

    setTimeout(() => { refresh(); showWallet(); }, 8000);
  } catch (e) {
    buyMsg(walletError(e), 'error');
  }
}

/* ── копирование адреса ────────────────────────────────────────────────── */

async function copyFrom(btn) {
  const target = document.getElementById(btn.dataset.copyTarget);
  if (!target) return;
  const text = target.textContent.trim().split(/\s+/)[0];
  try {
    await navigator.clipboard.writeText(text);
  } catch (_) {
    // file:// и старые браузеры: показываем выделение, копирует пользователь.
    const range = document.createRange();
    range.selectNodeContents(target);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }
  const prev = btn.textContent;
  btn.textContent = 'Скопировано';
  setTimeout(() => { btn.textContent = prev; }, 1500);
}

/* ── инициализация ─────────────────────────────────────────────────────── */

function init() {
  $('#in-slippage').value = CONFIG.ui.defaultSlippagePct;
  $('#in-deadline').value = CONFIG.ui.defaultDeadlineMin;

  renderChainBanner();
  renderAddresses();
  renderVerifyCommands();
  renderLinkGrid();

  $('#refresh').addEventListener('click', () => refresh());
  $('#connect').addEventListener('click', () => connect());
  $('#quote').addEventListener('click', () => quote());
  $('#do-buy').addEventListener('click', () => doBuy());
  $('#copy-curve').addEventListener('click', (e) => copyFrom(e.currentTarget));

  if (!hasWallet()) {
    $('#no-wallet').hidden = false;
    $('#connect').disabled = true;
    walletState('Расширение-кошелёк не обнаружено');
  } else {
    window.ethereum.on && window.ethereum.on('accountsChanged', (accs) => {
      state.account = accs && accs[0] ? accs[0] : null;
      showWallet();
    });
    window.ethereum.on && window.ethereum.on('chainChanged', () => { showWallet(); });
  }

  refresh();

  if (CONFIG.ui.autoRefreshMs > 0) {
    setInterval(() => {
      if (document.visibilityState === 'visible') refresh();
    }, CONFIG.ui.autoRefreshMs);
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
