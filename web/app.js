/* ─────────────────────────────────────────────────────────────────────────
 *  Maclaurin Series (MACLRN) — лендинг.
 *
 *  Зависимостей нет: ни npm, ни CDN, ни библиотек. Кодирование вызовов —
 *  четыре байта селектора плюс аргументы по 32 байта, декодирование — BigInt.
 *  Так страница работает при открытии файла локально (file://) и не выполняет
 *  ни одного стороннего скрипта: единственный внешний запрос — JSON-RPC к узлу.
 *
 *  Весь текст страницы живёт в объекте I18N ниже; в разметке — только ключи
 *  в data-i18n. Переключение языка перерисовывает DOM из уже прочитанных
 *  данных и не ходит в сеть заново.
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

    /* Порядок важен: первый — официальный узел сети, остальные — страховка.
       Страница молча переходит к следующему, если предыдущий не ответил,
       и НИКОГДА не доверяет эндпоинту, пока не сверила его eth_chainId
       с CONFIG.chain.id: иначе подменённый URL показал бы чужие цифры
       как наши.

       ВНИМАНИЕ, ПРОВЕРЕНО ИЗ БРАУЗЕРА: оба хоста drpc.org без API-ключа
       отвечают ТОЛЬКО на eth_chainId (0x1237, сеть верная), а на eth_call,
       eth_getStorageAt и eth_blockNumber отдают -32601 «method does not
       exist/is not available». То есть как резерв для чтения они сейчас
       не работают: страница их корректно пропускает, но реальной
       избыточности они не дают. Чтобы резерв стал настоящим, нужен либо
       ключ dRPC в URL, либо другой публичный узел с полным набором
       методов. */
    // Сейчас узел ровно один, и это честное состояние, а не недосмотр.
    //
    // Механика перебора ниже рабочая: она пробует эндпоинты по порядку,
    // сверяет eth_chainId до того, как поверить ответам, и переключается
    // на транспортных сбоях. Не хватает только того, что перебирать.
    //
    // Проверенные и отвергнутые кандидаты (все — 2026-08-03):
    //   robinhood.drpc.org, robinhood-mainnet.drpc.org — отвечают ТОЛЬКО на
    //     eth_chainId; на eth_call дают -32601 «method does not exist».
    //     То есть проверку «живой, сеть та» проходят, а ни одной цифры со
    //     страницы отдать не могут — как резерв бесполезны;
    //   4663.rpc.thirdweb.com — «Invalid chain»;
    //   rpc.ankr.com/robinhood, blockpi — требуют API-ключ;
    //   tenderly, blastapi — не отвечают.
    //
    // Чтобы резерв стал настоящим, сюда нужен эндпоинт с ключом (Alchemy,
    // QuickNode, dRPC — у всех есть бесплатный тариф). Ключ в публичном
    // фронтенде виден всем, поэтому брать только тот, что ограничен доменом
    // и правом на чтение.
    rpcs: [
      'https://rpc.mainnet.chain.robinhood.com'
    ],

    explorer: 'https://robinhoodchain.blockscout.com',
    // Газовый токен сети. ЗАПОЛНИТЬ/ПРОВЕРИТЬ ПЕРЕД ПУБЛИКАЦИЕЙ: символ
    // подставляется в кошелёк при добавлении сети и в подписи полей покупки.
    currency: { name: 'Ether', symbol: 'ETH', decimals: 18 }
  },

  /* ЗАПОЛНИТЬ ПОСЛЕ ДЕПЛОЯ. Пока адрес нулевой, страница не делает по нему
     ни одного запроса и честно пишет «не задан» вместо числа. */
  contracts: {
    token:    '' // ERC-20 MACLRN on Pons (will be set after launch)
  },

  /* ЗАПОЛНИТЬ. Пустая строка => карточка ссылки показывается неактивной
     с пометкой «ссылка не задана», а не ведёт в никуда. */
  links: {
    repo:      'https://github.com/nonbrainkid/Maclaurin',
    audit:     'https://github.com/nonbrainkid/Maclaurin/blob/master/README.md#свойства-безопасности',
    specToken: 'https://github.com/nonbrainkid/Maclaurin/blob/master/MACLAURIN-TOKEN-SPEC.md',

    /* Pons page */
    pons:   '',

    telegram:  'https://t.me/MaclaurinRHC',
    x:         'https://x.com/MaclaurinRHC'
  },

  /* Единый хэндл для показа рядом с иконками. */
  handle: '@MaclaurinRHC',

  /* График. Свечи строятся из событий Bought/Sold самой кривой, прочитанных
     через eth_getLogs. Ни бэкенда, ни индексатора, ни стороннего API: если
     сделок нет, будет честно пусто, а не нарисованная «история».

     curveDeployBlock — блок, в котором развёрнута кривая. Раньше него событий
     не бывает, а сканировать сеть с нуля незачем. */
  chart: {
    curveDeployBlock: 0,
    tokenDeployBlock: 0,
    logChunk: 100000,
    defaultTf: '1h'
  },

  /* Курс газового токена к доллару.
     ЕДИНСТВЕННЫЙ запрос страницы не к узлу сети — и единственное место, где
     приходится доверять постороннему сервису. Он же видит IP каждого, кто
     открыл страницу. Пустой url полностью выключает доллары: все величины
     останутся в ETH, ничего больше не сломается. */
  price: {
    url: 'https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd',
    path: ['ethereum', 'usd'],
    ttlMs: 300000,
    source: 'CoinGecko'
  },

  ui: {
    autoRefreshMs: 60000,      // 0 — выключить автообновление
    defaultSlippagePct: '1',
    defaultDeadlineMin: '10',
    rpcTimeoutMs: 7000         // зависший эндпоинт не должен морозить страницу
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
  antiSnipeMax: '0xd7469371', // ANTI_SNIPE_MAX()
  priceAt:      '0x9dab2054', // priceAt(uint256)
  previewSell:  '0xfb3dd95f', // previewSell(uint256)
  sell:         '0xd3c9727c', // sell(uint256,uint256,uint256)
  // ERC-20, нужны для продажи: разрешение выдаётся ровно на продаваемое
  // количество, поэтому allowance читается перед каждой сделкой.
  approve:      '0x095ea7b3', // approve(address,uint256)
  allowance:    '0xdd62ed3e', // allowance(address,address)
  // Admin fees
  feeRecipient: '0x46904840', // feeRecipient()
  feesAccrued:  '0x94db0595', // feesAccrued()
  withdrawFees: '0x476343ee'  // withdrawFees()
};

/* Топики событий кривой = keccak256 от сигнатуры события (cast keccak).
   Bought(address indexed buyer, uint256 ethIn, uint256 fee, uint256 tokensOut, uint256 newSold)
   Sold  (address indexed seller, uint256 tokensIn, uint256 fee, uint256 ethOut, uint256 newSold) */
const EVENTS = {
  bought: '0x27330bd7589580547b6437e08f9c60653de63691d2d2b2c13bff9ee67da2a68d',
  sold:   '0x490fdc1c23c0f3a84bf80a0384eaadcb9188c9ef71b9430da391a0e4c4c39bf6',
  // Transfer(address indexed from, address indexed to, uint256 value)
  transfer: '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
};

/** Адрес сожжения. Токены на нём есть, но ключа к ним нет ни у кого. */
const DEAD_ADDR = '0x000000000000000000000000000000000000dead';

/* Секунды в одном интервале свечи. Ключи — то, что написано на кнопках.
   Секундные интервалы здесь осмысленны: блок в этой сети идёт примерно раз
   в 0.1 с, так что одна секунда — это уже несколько блоков, а не пустота. */
const TIMEFRAMES = {
  '1s': 1,
  '15s': 15,
  '1m': 60,
  '5m': 300,
  '15m': 900,
  '1h': 3600,
  '4h': 14400,
  '1d': 86400
};

const TF_MIN = 1;
const TF_MAX = 30 * 86400;

/** «45s», «2m», «1.5h», «1d» или просто число секунд → секунды. */
function parseTimeframe(str) {
  const s = String(str || '').trim().toLowerCase().replace(',', '.');
  const m = /^(\d+(?:\.\d+)?)\s*(s|sec|m|min|h|hr|d)?$/.exec(s);
  if (!m) return null;
  const value = parseFloat(m[1]);
  if (!(value > 0)) return null;
  const mult = { s: 1, sec: 1, m: 60, min: 60, h: 3600, hr: 3600, d: 86400 }[m[2] || 's'];
  const sec = Math.round(value * mult);
  return sec >= TF_MIN && sec <= TF_MAX ? sec : null;
}

/** Секунды → короткая подпись: 90 → «90s», 300 → «5m», 3600 → «1h». */
function timeframeLabel(sec) {
  if (sec % 86400 === 0) return sec / 86400 + 'd';
  if (sec % 3600 === 0) return sec / 3600 + 'h';
  if (sec % 60 === 0) return sec / 60 + 'm';
  return sec + 's';
}

/* Слоты EIP-1967: keccak256("eip1967.proxy.implementation") − 1 и
   keccak256("eip1967.proxy.admin") − 1. Ненулевое значение в них означает,
   что за адресом стоит обновляемый прокси. */
const EIP1967 = {
  impl:  '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc',
  admin: '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103'
};

/* Селекторы ошибок контрактов — чтобы показывать причину отказа словами,
   а не голый hex. Значение — ключ в словаре переводов. */
const ERRORS = {
  '0xbc3088ef': 'err.deadline',
  '0x4853b987': 'err.slipBuy',
  '0xb77867d8': 'err.slipSell',
  '0x9b158fe6': 'err.inventory',
  '0xb43243da': 'err.notBought',
  '0x792dd007': 'err.antiSnipe',
  '0x1f2a2005': 'err.zeroAmount',
  '0x9c718997': 'err.moreThanSold',
  '0x6f2fb69e': 'err.domain'
};

/* ─────────────────────────────────────────────────────────────────────────
 *  СЛОВАРЬ. Ключи — по смыслу, не по месту в вёрстке. Значения могут
 *  содержать разметку: они подставляются в элементы с data-i18n-html и
 *  приходят только отсюда, из статического файла, — не из сети и не от
 *  пользователя.
 *
 *  Числа и адреса в обоих языках одинаковы: их не переводят.
 * ───────────────────────────────────────────────────────────────────────── */

const I18N = {

  /* ───────────────────────────  ENGLISH  ──────────────────────────────── */
  en: {
    'meta.title': 'Maclaurin Series (MACLRN) — supply is e, emission is 1/n!',
    'meta.description': 'An ERC-20 whose issuance schedule is literally the Maclaurin series for e. Supply is bounded by arithmetic, not by policy: 2 718 281 828.459045235360287471 tokens. Emission stops on its own at epoch 27.',

    'skip': 'Skip to on-chain data',

    'nav.aria': 'Sections',
    'nav.live': 'Live data',
    'nav.mechanics': 'Mechanics',
    'nav.immutable': 'Immutability',
    'nav.buy': 'Buy',
    'nav.risks': 'Risks',

    'lang.aria': 'Language',
    'lang.en.aria': 'Switch the page to English',
    'lang.ru.aria': 'Switch the page to Russian',

    'nav.contracts': 'Contracts',

    'social.tg.aria': 'Telegram channel, opens in a new tab',
    'social.x.aria': 'X profile, opens in a new tab',
    'social.gh.aria': 'Source code on GitHub, opens in a new tab',

    /* — надзаголовки разделов — */
    'eyebrow.live': '01 — On-chain',
    'eyebrow.mech': '02 — Mechanics',
    'eyebrow.imm': '03 — Immutability',
    'eyebrow.buy': '04 — Buy',
    'eyebrow.activity': '05 — Activity',
    'eyebrow.contracts': '06 — Contracts',
    'eyebrow.risks': '07 — Risks',
    'eyebrow.links': '08 — Verify',

    /* — сводка рынка — */
    'market.price': 'Price',
    'market.mcap': 'Market cap',
    'market.mcap.na': 'a balance did not read',
    'market.fdv': 'FDV',
    'market.liquidity': 'Liquidity',
    'market.vol24': 'Volume 24h',
    'market.volAll': 'Volume, all time',
    'market.vol.na': 'trade log not read',
    'market.note': 'Market cap counts circulating supply only: total supply less the burn, the undistributed emission, the locked treasury and the curve\'s unsold inventory. FDV counts the whole supply. Liquidity is the curve reserve — the ETH that backs buy-backs, not a pool: the curve repurchases only what it sold, and only from the address that bought it.',
    'market.usd.src': 'Dollars are converted at {rate} per {gas}, quoted by {src} — the only request this page makes outside the network. Everything else is read from the chain.',
    'market.usd.failed': 'The dollar rate did not load, so the figures are in {gas} only.',
    'market.usd.off': 'Dollar conversion is switched off in the page configuration.',

    /* — журнал операций — */
    'nav.activity': 'Activity',
    'act.h2': 'Every transaction with the token',
    'act.lede': 'The full <code>Transfer</code> log of the token, read from the chain with <span class="mono">eth_getLogs</span>. Every movement of MACLRN is here — genesis, the burn, and each purchase and sale on the curve. Rows that are curve trades carry the price and the amount of ETH, taken from the curve\'s own event in the same transaction, so nothing is counted twice.',
    'act.filter.aria': 'Filter',
    'act.filter.all': 'All',
    'act.filter.trades': 'Trades',
    'act.filter.transfers': 'Transfers',
    'act.reload': 'Reload',
    'act.th.time': 'Time',
    'act.th.type': 'Type',
    'act.th.amount': 'Amount',
    'act.th.value': 'Value',
    'act.th.price': 'Price',
    'act.th.from': 'From',
    'act.th.to': 'To',
    'act.th.tx': 'Tx',
    'act.loading': 'Reading the transfer log from the chain…',
    'act.empty': 'Nothing under this filter.',
    'act.failed': 'Could not read the transfer log: {reason}',
    'act.noToken': 'The token address is not set.',
    'act.status': '{shown} of {total}',
    'act.more': 'Show {n} more',
    'act.block': 'block {n}',
    'act.kind.buy': 'Buy',
    'act.kind.sell': 'Sell',
    'act.kind.mint': 'Genesis',
    'act.kind.burn': 'Burn',
    'act.kind.transfer': 'Transfer',
    'act.who.zero': 'Zero address',
    'act.who.burn': 'Burn address',
    'act.link.all': 'All transfers in the explorer',
    'act.link.curve': 'Curve transactions',

    'ago.s': '{n}s ago',
    'ago.m': '{n}m ago',
    'ago.h': '{n}h ago',
    'ago.d': '{n}d ago',

    /* — панель продажи — */
    'sale.h': 'Bonding curve sale',
    'sale.price': 'Spot price',
    'sale.sold': 'Inventory sold',
    'sale.remaining': 'Remaining inventory',
    'sale.reserve': 'Curve reserve',
    'sale.epoch': 'Emission epoch',
    'sale.cta': 'Open the buy panel',
    'sale.foot': 'Read from the contracts on every page load, not written into the markup.',
    'sale.epochDone': 'complete',
    'sale.epochOf': '{n} / 26',

    /* — контракты — */
    'contracts.h2': 'Contract addresses',
    'contracts.lede': 'All four contracts are deployed and verified on the explorer. Copy an address from here and compare it with the one your wallet shows before you sign anything.',
    'contracts.footnote': 'Verification means the explorer matched the deployed bytecode against the source. An unverified contract is an unchecked contract, whatever a website says about it.',
    'contract.desc.token': 'ERC-20 · fixed supply, no mint function',
    'contract.desc.emission': 'Epoch table, staking, locks',
    'contract.desc.curve': 'Sale and buy-back',
    'contract.desc.vesting': 'Treasury under a time lock',
    'contract.pending': 'address not set',
    'contract.copy': 'Copy',
    'contract.explorer': 'Explorer',

    /* — hero — */
    'hero.badge': 'Live on Robinhood Chain · chain ID 4663',
    'hero.cta.buy': 'Buy through the curve',
    'hero.cta.verify': 'Verify on-chain',
    'hero.title': 'Supply is <span class="mono">e</span>. Emission is <span class="mono">1/n!</span>.',
    'hero.lede': 'An ERC-20 whose issuance schedule is not a team decision but the partial sums of a series. Total supply equals the number <span class="mono">e</span> to 18 decimal places. Emission decays factorially and terminates on its own: not on a roadmap date, but at the epoch where the next term of the series first falls below one base unit of the token.',
    'hero.why': '<strong>Why “Maclaurin”.</strong> A Maclaurin series is a Taylor series expanded at zero. The expansion <span class="mono">e<sup>x</sup> = Σ x<sup>n</sup>/n!</span> used here is built around the point <span class="mono">x = 0</span> and taken at <span class="mono">x = 1</span>, which yields <span class="mono">e = Σ 1/n!</span>. The expansion point is not arbitrary, it is zero — so this is a Maclaurin series, and the project name describes the mechanism literally rather than by analogy.',
    'hero.fact.supply.dt': 'Total supply',
    'hero.fact.supply.sub': '= floor(e × 10<sup>27</sup>) base units, 18 decimals',
    'hero.fact.reward.dt': 'Epoch n reward',
    'hero.fact.reward.sub': 'an epoch is 7 days; emission runs from n = 2 through n = 26',
    'hero.fact.end.dt': 'End of emission',
    'hero.fact.end.sub': '10<sup>27</sup>/27! = 0 under integer division',

    /* — live — */
    'live.h2': 'On-chain data',
    'live.lede': 'Everything below is read straight from the contracts with <span class="mono">eth_call</span> against a public Robinhood Chain RPC endpoint when the page loads. None of these numbers live in the markup — markup can be forged, a node\'s answer cannot. Next to every number is a link to the same call in the explorer and the exact command that reproduces it. Several endpoints are configured: if the first one does not answer, the page silently moves to the next, after checking its chain ID first.',
    'live.refresh': 'Refresh',
    'live.footnote': 'The “explorer” link opens the <em>Read contract</em> tab, where the same call runs in your own browser. The “reproduce this call” block expands into a ready-made <span class="mono">curl</span> command and its <span class="mono">cast</span> equivalent: the node\'s answer depends neither on this page nor on its author.',

    'card.epoch.h': 'Current epoch',
    'card.epoch.note': '<code>currentEpoch()</code> — emission contract',
    'card.epochAmount.h': 'Current epoch reward',
    'card.epochAmount.note': '<code>epochAmount(n)</code> — exactly 10<sup>27</sup>/n! base units',
    'card.emissionEnd.h': 'End of emission',
    'card.emissionEnd.note': '<code>emissionEnd()</code> — the moment after which issuance is impossible',
    'card.supply.h': 'Total supply',
    'card.supply.note': '<code>totalSupply()</code> — fixed at deployment',
    'card.sold.h': 'Sold by the curve',
    'card.sold.note': '<code>sold()</code> / <code>INVENTORY()</code>',
    'card.price.h': 'Spot price',
    'card.price.note': '<code>spotPrice()</code> — price of one whole token',
    'card.reserve.h': 'Curve reserve',
    'card.reserve.note': '<code>reserve()</code> — backing for buy-backs',
    'card.weight.h': 'Total staking weight',
    'card.weight.note': '<code>totalWeight()</code> — the reward divisor; <code>totalStaked()</code> — deposit principal',
    'card.identity.h': 'Name and ticker in the contract',
    'card.identity.note': '<code>name()</code>, <code>symbol()</code>, <code>decimals()</code> — as written in the bytecode',
    'card.proxy.h': 'Proxy slot (EIP-1967)',
    'card.proxy.note': '<code>eth_getStorageAt</code> on the implementation slot: zero means there is no proxy behind the contract',

    /* — mechanics — */
    'mech.h2': 'The mechanics, no maths background required',
    'mech.supply.h': '1. The supply is a number, not a round figure',
    'mech.supply.p1': 'Supply is normally chosen: a billion, because a billion looks good. Here it is the base of the natural logarithm scaled by 10<sup>27</sup>:',
    'mech.supply.p2': 'The series <span class="mono">e = 1/0! + 1/1! + 1/2! + 1/3! + …</span> converges. Converging means that no matter how many terms you add, the sum never exceeds <span class="mono">e</span>. The supply is bounded by a property of the series, not by a promise to issue no more than some amount.',
    'mech.supply.p3': 'The first two terms (<span class="mono">1/0! + 1/1! = 2</span>) are 2 000 000 000 tokens, 73.576% of supply. They exist from block zero and cannot be farmed. The remaining 26.424% (718 281 828.459045235360287471 tokens) sit in the emission contract and are handed out epoch by epoch.',

    'mech.decay.h': '2. Emission decays factorially',
    'mech.decay.p1': 'An epoch lasts 7 days. Epoch <span class="mono">n</span> issues exactly <span class="mono">10<sup>27</sup>/n!</span> base units: epoch 2 issues one half, epoch 3 one sixth, epoch 4 one twenty-fourth. Each portion is smaller than the previous one not by percentage points but by whole factors, and the gap keeps widening.',
    'mech.decay.p2': 'The practical consequence: the first five epochs release 99.97% of the emission pool. The tail is not cut off — it continues, it simply becomes negligible very quickly. This is the opposite of halving, where every step divides the reward exactly in two, forever.',
    'mech.table.summary': 'Full epoch table (constants hardcoded in the contract)',
    'mech.table.th.units': 'base units',
    'mech.table.th.tokens': 'tokens',
    'mech.table.th.pct': '% of supply',
    'mech.table.final': '0 — emission complete',
    'mech.table.footnote': 'Epochs 2…26 sum to 718 281 828 459 045 235 360 287 457 base units. The floor-rounding remainder — 14 units — stays in the emission contract forever. That is not a loss but a buffer: paying out more than exists is arithmetically impossible, without a single check in the code.',

    'mech.end.h': '3. Emission terminates on its own',
    'mech.end.p1': 'At epoch 27 the term of the series is <span class="mono">10<sup>27</sup>/27!</span>. 27! is roughly <span class="mono">1.089 × 10<sup>28</sup></span>, which is larger than the numerator. EVM arithmetic is integer-only, with no fractions: the division yields zero. Not “rounded to zero for display” — it is zero.',
    'mech.end.callout': 'The end of emission is a property of uint256 arithmetic, not a multisig decision. Nobody votes to stop issuance and nobody can extend it: no function capable of doing so exists in the contract.',

    'mech.stake.h': '4. Staking: radius of convergence',
    'mech.stake.p1': 'Every series converges only inside its own radius. A staker picks a radius <span class="mono">R</span> — the number of epochs the position is locked for. The reward multiplier is the partial sum of that same series up to the <span class="mono">R</span>-th term.',
    'mech.stake.th.lock': 'Lock',
    'mech.stake.th.mult': 'Multiplier',
    'mech.stake.th.delta': 'Increment over previous',
    'mech.stake.d7': '7 days',
    'mech.stake.d14': '14 days',
    'mech.stake.d21': '21 days',
    'mech.stake.d28': '28 days',
    'mech.stake.d35': '35 days',
    'mech.stake.d42': '42 days',
    'mech.stake.d49': '49 days',
    'mech.stake.unreachable': 'unreachable',
    'mech.stake.p2': 'The ceiling is the number <span class="mono">e</span> itself, and it is unreachable by construction: a partial sum of the series is strictly less than the sum of the series. This is not a marketing cap that a vote could lift, but a property of a convergent series with positive terms. The constant <span class="mono">E_FIXED</span> sits in the contract precisely so that this unreachability can be checked on-chain.',
    'mech.stake.p3': 'Rewards are split by weight rather than by deposit size: <span class="mono">weight = staked × multiplier(R)</span>. The deposit principal is tracked by a separate counter and plays no part in the multiplier.',

    'mech.locks.h': '5. What is locked and what is not',
    'mech.locks.claim': '<strong><code>claim()</code> is closed until the lock expires.</strong> Before <span class="mono">unlockTime</span> the call reverts with <code>StillLocked</code>. Otherwise the multiplier would be drained as rewards every epoch, and by the time somebody exited early there would be nothing left to take back.',
    'mech.locks.unstake': '<strong><code>unstake()</code> is always open</strong>, including during an active lock. The deposit principal comes back in full, down to the last base unit. The rule “never touch the principal, under any circumstances” is not broken.',
    'mech.locks.forfeit': '<strong>Exiting early forfeits the reward.</strong> Everything accrued is zeroed and goes to the remainder-term treasury — in full, even on a partial exit. Proportional forfeiture would look fairer, but it would let somebody withdraw 99.99% of the principal and sit out the rest of the lock with a speck of dust, keeping the reward earned on the full principal.',
    'mech.locks.nokeepers': '<strong>No keepers, no oracles.</strong> The only external input to the emission contract is <span class="mono">block.timestamp</span>. There is no price fed from outside, no bot that payouts depend on, no signature without which nothing works.',

    /* — immutability — */
    'imm.h2': 'Why nobody can print tokens here',
    'imm.p1': 'The most common way to rug a token is not an exploit but a perfectly legitimate <code>mint(address,uint256) onlyOwner</code>. The owner prints themselves a trillion tokens and sells. An audit passes a contract like that: there is no vulnerability in it, there is a documented privilege. The only defence against it is for the function not to be in the bytecode at all.',
    'imm.mint': '<strong>There is no <code>mint</code> function in the bytecode.</strong> The entire supply was issued once, in the token constructor. After the constructor there is no function in the contract that changes supply.',
    'imm.owner': '<strong>There is no owner.</strong> <code>Ownable</code> is not used in any of the contracts — there is no ownership to renounce, and no need to. No <code>owner()</code>, no roles, no privileged multisig.',
    'imm.proxy': '<strong>There is no proxy.</strong> An upgradeable token is the same <code>mint</code>, only hidden behind a proxy. The EIP-1967 implementation slot is read on this very page: it is zero.',
    'imm.plain': '<strong>No pause, no blacklist, no transfer tax, no hooks.</strong> A plain OpenZeppelin ERC-20 with nothing bolted on.',
    'imm.reserve': '<strong>The deployer has no access to the curve reserve.</strong> No function that would move <code>reserve</code> anywhere other than to a seller exists in the contract; the fee lives in a separate counter and never mixes with the reserve.',
    'imm.verify.h': 'Check it yourself, without trusting this site',
    'imm.verify.p': 'Below are commands that search the deployed bytecode for the selectors of privileged functions. Empty <span class="mono">grep</span> output means the function is not in the contract. Addresses are substituted automatically from this page\'s configuration, but they are worth checking against the link to the verified source.',
    'imm.verify.footnote': '<code>40c10f19</code> = <code>mint(address,uint256)</code>, <code>8da5cb5b</code> = <code>owner()</code>, <code>f2fde38b</code> = <code>transferOwnership(address)</code>, <code>3659cfe6</code> = <code>upgradeTo(address)</code>, <code>8456cb59</code> = <code>pause()</code>. Selectors are the first 4 bytes of the keccak256 hash of the signature — you can derive them yourself with <span class="mono">cast sig</span>.',

    /* — buy — */
    'buy.h2': 'Buying through the bonding curve',
    'buy.p1': 'There is no liquidity pool: a pool needs capital the project does not have, and at shallow depth a few dollars of buying moves the price by tens of percent. In its place is a curve contract that holds an inventory of 1 000 000 000 tokens (half of genesis, laid out along the geometric series 2 = 1 + 1/2 + 1/4 + …) and sells them at a linearly rising price.',
    'buy.rule.trapezoid': '<strong>The price rises linearly, so the cost of a purchase is the area of a trapezoid.</strong> Integer multiplication and division only, no exponential approximations. The formula can be recomputed on paper.',
    'buy.rule.ratio': '<strong>From the first token to the last, the price rises by exactly a factor of <span class="mono">e</span>:</strong> from 2 gwei to 5.436563656918090470 gwei per whole token. The ratio can be verified on-chain with a single division, because the arithmetic is integer.',
    'buy.rule.fee': '<strong>A flat 1% fee in ETH</strong> — a constant, not a variable. It is taken before the reserve is credited on a buy, and out of the already-reduced amount on a sell, so the reserve never funds the fee.',
    'buy.rule.buyback': '<strong>The curve is not an exchange: you can only sell back to it what you bought from it.</strong> The purchase right is tied to the address (<code>boughtOf(address)</code>) and does not travel with an ordinary transfer. Otherwise a holder of free genesis tokens or staking rewards would walk off with the buyers\' ETH. Tokens acquired anywhere other than the curve are sold on a secondary market, not here.',
    'buy.rule.nodiscretion': '<strong>Nothing in the sell path depends on anyone\'s decision:</strong> only your balance, your own slippage protection and a deadline that has not expired. No pauses, no lists, no cooldown.',
    'buy.rule.antisnipe': '<strong>The anti-snipe window has already expired.</strong> It capped purchases at 10 000 000 tokens per address for the first hour after the curve was deployed (<code>antiSnipeEnd()</code> — check it on-chain). That hour is over and no purchase was made during it, so the cap applies to nothing: right now a single transaction can buy the entire remaining inventory. The cap was a mitigation rather than a defence in any case — several wallets bypass it trivially.',
    'buy.addr.h': 'Curve contract address',
    'buy.addr.hint': 'Check it against the address shown in your wallet before you confirm the transaction. No other address is the sale contract.',
    'buy.addr.copy': 'Copy',
    'buy.addr.copied': 'Copied',
    'buy.connect': 'Connect wallet',
    'buy.field.amount': 'Amount in <span data-field="currency">ETH</span>',
    'buy.field.slippage': 'Slippage, %',
    'buy.field.deadline': 'Deadline, minutes',
    'buy.action.quote': 'Get quote',
    'buy.action.buy': 'Buy',
    'buy.quick.max': 'Max',
    'buy.quick.maxHint': 'Fill in maxEthIn() — the largest purchase the remaining inventory allows at this moment',
    'buy.quick.maxFailed': 'Could not read maxEthIn(): {reason}',

    /* — график — */
    'chart.last': 'Last trade price',
    'chart.aria': 'Price chart',
    'chart.tf.aria': 'Timeframe',
    'chart.mode.aria': 'Chart mode',
    'chart.mode.candles': 'Candles',
    'chart.mode.curve': 'Curve',
    'chart.reload': 'Reload trades',
    'chart.loading': 'Reading the trade log from the chain…',
    'chart.empty': 'No trades in the log yet. Candles are built only from the curve\'s own Bought and Sold events — until there is a trade there is nothing to draw, and nothing is invented to fill the space.',
    'chart.noCurve': 'The curve address is not set.',
    'chart.failed': 'Could not read the trade log: {reason}',
    'chart.status': '{trades} trades · {candles} candles · {tf} · scanned from block {block}',
    'chart.curveNote': 'Price as a function of tokens sold — a pure function of the contract, not a history. The marker is where the curve stands right now.',
    'chart.curveWait': 'Waiting for on-chain data…',
    'chart.axisSold': 'tokens sold',
    'chart.vol': 'Vol',
    'chart.hint': 'Scroll to zoom · drag to pan · drag the price or time axis to scale it · double-click to reset',
    'chart.custom.aria': 'Custom timeframe',
    'chart.custom.hint': 'Custom candle interval: 45s, 2m, 1.5h, 3d — or a plain number of seconds. From 1 second to 30 days.',
    'chart.truncated': 'trimmed to the last {from} at this interval',
    'chart.noneInView': 'No trades in this window. There are {n} in the series — zoom out, or double-click to fit them.',

    /* — вкладки и продажа — */
    'trade.sell': 'Sell',
    'trade.tabs.aria': 'Buy or sell',
    'sell.field.amount': 'Amount in <span data-field="token">MACLRN</span>',
    'sell.limit.none': 'Connect a wallet to see how much the curve owes this address a buy-back for.',
    'sell.limit': 'The curve will buy back up to {amount} {sym} from this address · balance {bal} {sym}',
    'sell.limit.zero': 'This address has bought nothing from the curve, so it has nothing to sell back here.',
    'sell.quick.maxHint': 'Fill in the smaller of the token balance and the buy-back right',
    'sell.approveNote': 'Selling takes two transactions: an allowance for exactly the amount being sold, then the sale itself. An unlimited approve is never requested — if the sale falls through, the contract keeps no standing right to move the rest of the balance.',
    'sell.row.out': 'You receive',
    'sell.row.min': 'Minimum on execution',
    'sell.row.fee': 'Fee, 1%',
    'sell.row.avg': 'Average price of this trade',
    'sell.overLimit': 'More than this address may sell back to the curve. The ceiling is {amount} {sym}.',
    'sell.overBalance': 'More than the token balance of this address.',
    'sell.approving': 'Approving exactly {amount} {sym} — confirm in the wallet…',
    'sell.approveWait': 'Waiting for the allowance to be mined…',
    'sell.approveFailed': 'The allowance transaction did not confirm in time. Check it in the explorer, then try again.',
    'sell.confirmTx': 'Now confirm the sale itself in the wallet.',
    'sell.sent': 'Sale sent: ',
    'buy.sig.summary': 'What the wallet actually signs',
    'buy.sig.p': 'The call is <code>buy(uint256 minTokensOut, uint256 deadline)</code>, with the amount passed as the transaction\'s <span class="mono">value</span>. <span class="mono">minTokensOut</span> is derived from the <code>previewBuy(ethIn)</code> quote minus the slippage you set: if the price moves further than that between quoting and execution, the transaction reverts instead of filling at a worse price. Overpaying beyond the remaining inventory is not refunded as change — it reverts — which is why <code>maxEthIn()</code> exists, the exact upper bound at this moment.',
    'buy.sell.summary': 'How to sell back to the curve',
    'buy.sell.p1': 'The Sell tab above does this for you, but the site is not required for it: the same two calls are available in the explorer, and the allowance is for exactly the amount being sold — never an unlimited <code>approve</code>. The order is:',
    'buy.sell.step1': '<code>approve(curve address, amount)</code> on the token contract — grant an allowance for exactly the amount being sold;',
    'buy.sell.step2': '<code>sell(amount, minEthOut, deadline)</code> on the curve contract.',
    'buy.sell.p2': 'Both calls are available in the explorer\'s <em>Write contract</em> tab, which also shows the function body. <code>boughtOf(your address)</code> shows how many tokens the curve is obliged to buy back.',

    'nowallet.h': 'No wallet in this browser',
    'nowallet.p1': 'The page found no wallet: neither an EIP-6963 announcement nor <span class="mono">window.ethereum</span>. That means no wallet extension is installed or it is disabled for this site. What you can do:',
    'nowallet.step1': 'install any EVM wallet that supports custom networks (MetaMask or Rabby, for example) from your browser\'s official extension store;',
    'nowallet.step2': 'add the network by hand: <span class="mono">Chain ID 4663</span>, RPC <span class="mono" data-field="rpc"></span>, explorer <span class="mono" data-field="explorer"></span>;',
    'nowallet.step3': 'fund the address with a little of the network\'s gas token and come back — the connect button will appear on its own.',
    'nowallet.p2': 'Mobile browsers usually do not support extensions: there you need to open this page inside your wallet\'s built-in browser. A purchase can equally be made by hand from the explorer\'s <em>Write contract</em> tab — this site is not required for it.',

    /* — risks — */
    'risks.h2': 'Risks. Read this before buying',
    'risks.liquidity': '<strong>Liquidity is thin and the price is volatile.</strong> Selling the entire inventory collects roughly 3.72 ETH into the reserve — that is the order of magnitude of the whole mechanism, not the size of a market. Any sizeable trade moves the price noticeably in either direction. This is a working demonstration of a full cycle, not a deep market.',
    'risks.notExchange': '<strong>The curve is not an exchange.</strong> It buys back only what was bought from it, and only from the address that bought it. Tokens obtained by any other route cannot be sold to the curve. There may be no secondary market at all.',
    'risks.exitPrice': '<strong>The curve buys back at its current price, not at the price you paid.</strong> The reserve always covers every outstanding buy-back, so <code>sell()</code> can never fail for lack of funds — but the amount of ETH it returns depends on how much has been sold at that moment, not on your entry. If other buyers exit before you do, the price falls back along the curve and you receive less than you put in — in the worst case (you bought at the top of the inventory, everyone else sold first) about 63% less, which is the factor <span class="mono">e</span> the price spans. This is a first-in-best-out mechanism, not a refund.',
    'risks.concentration': '<strong>The whole inventory costs about 3.76 ETH, and one address can take all of it.</strong> That is small enough that a single actor can buy the entire billion-token inventory in one transaction, stake it, collect essentially the whole 718 281 828-token emission pool — rewards are split by weight, and their weight would be the divisor — then sell the inventory back to the curve at the same average price and recover the ETH. The round trip costs only the two 1% fees. Nothing in the contracts prevents this, and staking alongside such a position yields a proportionally negligible share.',
    'risks.experimental': '<strong>The project is experimental.</strong> The contracts are immutable: a bug cannot be patched and there is no upgrade path. That is at once the principal guarantee and the principal risk.',
    'risks.audit': '<strong>An audit is not insurance.</strong> Tests, static analysis and independent review lower the probability of a bug but do not prove its absence. Only some of the properties are formally proven.',
    'risks.noYield': '<strong>The token has no yield and owes you nothing.</strong> Staking rewards are a redistribution of a pre-issued emission pool, not profit from any activity. Nobody promises price appreciation and nobody can deliver it.',
    'risks.network': '<strong>The network is new.</strong> Robinhood Chain, its public RPC endpoints and its explorer are external infrastructure the project does not control. If they become unavailable, so does this page and any work with the contracts from a browser.',
    'risks.legal': '<strong>The legal status is unsettled.</strong> A token with a reward-distribution mechanism may qualify as a security in a number of jurisdictions. A direct sale from a website by the asset\'s author is not the same thing as providing liquidity on a DEX. This is not legal advice; compliance with your local law is your responsibility.',
    'risks.size': '<strong>Buy only an amount you are prepared to lose in full.</strong> Nothing on this page is investment advice.',

    /* — links, footer — */
    'links.h2': 'Verify',
    'links.footnote': 'Contract links point to verified sources in the explorer: that is where the bytecode is matched and where you read the same code that sits in the repository. Treat an unverified contract as unchecked, whatever a website says about it.',
    'footer.p1': 'Maclaurin Series (MACLRN). The narrative is built around 18th-century mathematics, not around a public figure: no real person\'s name or likeness and no company name is used, and no endorsement is implied.',
    'footer.p2': 'The page is static: no backend, no analytics, no third-party scripts or fonts. Almost every request goes to the network\'s public RPC endpoints, whose addresses are visible in the configuration in <span class="mono">web/app.js</span>. There is exactly one exception: the ETH/USD rate behind the dollar figures is quoted by an outside service, which therefore sees the address you connect from. That service is named in the configuration and can be switched off there — with it off the page shows every figure in the network\'s own token and nothing else changes. Transactions are signed by your wallet; the page never sees your keys and never asks for them.',

    /* — динамика: статус чтения — */
    'status.loading': 'Loading…',
    'status.reading': 'Reading from the chain…',
    'status.noAddresses': 'Contract addresses are not filled in — there is nothing to read.',
    'status.updated': 'Updated {time} · block {block} · {host}',
    'status.partial': 'Updated {time} · block {block} · calls that failed: {failed}',
    'status.allDown': 'Could not fetch on-chain data: none of the {count} RPC endpoints answered. The figures below are missing, not zero.',
    'status.stale': 'Could not refresh: none of the {count} RPC endpoints answered. The figures below are as of {time} and may be out of date.',

    'chain.banner': 'The contracts are not deployed yet: the addresses in this page\'s configuration are zero. The numbers below will appear on their own once the addresses are filled in — they are read from the chain, not typed into the markup.',

    /* — динамика: карточки — */
    'card.link.explorer': 'explorer',
    'card.link.repeat': 'reproduce this call',
    'card.na.address': 'address not set',
    'card.na.emission': 'emission address not set',
    'card.na.token': 'token address not set',
    'card.na.curve': 'curve address not set',
    'card.na.epoch': 'no epoch number',
    'card.err.call': 'call failed',
    'card.err.noData': 'no data',

    'epoch.done': 'emission complete',
    'epoch.of': '{n} of 26',
    'epoch.len': 'an epoch lasts 7 days',
    'epoch.raw': 'currentEpoch() = {n}',
    'epochAmount.sub': '{raw} base units = 10^27 / {n}!',
    'epochAmount.last': ' (last epoch with a non-zero reward)',
    'emissionEnd.done': 'emission complete',
    'supply.sub': '{raw} base units · floor(e × 10^27)',
    'weight.sub.raw': '{raw} base units',
    'weight.sub.staked': '{staked} {sym} staked · weight ≤ principal × e',
    'identity.sub.match': 'decimals {dec} · matches what this page claims',
    'identity.sub.mismatch': 'decimals {dec} · this page claims {sym} — mismatch',
    'proxy.unread': 'slot not read',
    'proxy.none': '0x00…00 — no proxy',
    'proxy.none.sub': 'implementation slot and admin slot are both empty: the contract is not upgradeable',
    'proxy.present': 'slot is not empty',
    'proxy.present.sub': 'implementation {impl} · admin {admin} — check by hand',
    'sold.sub': '{sold} of {inv} {sym}',
    'price.sub': '{raw} wei per 1 {sym} · start price 2 gwei, final price 5.436563656918090470 gwei',
    'reserve.sub': '{raw} wei · a full sell-out of the inventory collects 3.718281828459045235 {gas} (= 1 + e)',

    'time.passed': 'already passed',
    'time.dh': 'in {d}d {h}h',
    'time.hm': 'in {h}h {m}m',

    /* — динамика: адреса и ссылки — */
    'addr.pending': '  (the address will be filled in after deployment)',
    'link.source': 'Verified source',
    'link.read': 'Read contract',
    'link.write': 'Write contract',
    'link.curvePending': 'The links will appear once the contract is deployed and verified.',
    'link.approve': 'approve on the token contract',
    'link.sell': 'sell on the curve contract',
    'link.sellPending': 'The links will appear once the contracts are deployed.',
    'src.token': 'Token source',
    'src.emission': 'Emission contract source',
    'src.curve': 'Curve source',
    'src.vesting': 'Vesting source',
    'src.pending': 'Links to the verified sources will appear after deployment.',

    'grid.token': 'MACLRN token (ERC-20)',
    'grid.emission': 'Emission contract',
    'grid.curve': 'Bonding curve',
    'grid.vesting': 'Treasury vesting',
    'grid.repo': 'Source repository',
    'grid.audit': 'Audit reports',
    'grid.specToken': 'Token specification',
    'grid.specCurve': 'Curve specification',
    'grid.telegram': 'Telegram channel',
    'grid.x': 'X profile',
    'grid.missing': 'link not set — to be filled in after deployment',
    'footer.tagline': 'Supply is e. Emission is 1/n!.',

    /* — команды проверки — */
    'verify.c1a': '# 1. Download the deployed bytecode and grep it for privileged-function selectors.',
    'verify.c1b': '#    Empty grep output = the function is not in the contract.',
    'verify.c2': '# 2. Confirm there is no proxy behind the address (EIP-1967 implementation slot).',
    'verify.c3': '# 3. Supply is fixed and equal to floor(e × 10^27).',
    'verify.c4': '# 4. Emission cuts itself off: the term of the series at epoch 27 is zero.',
    'verify.c5': '# 5. The staking multiplier never reaches e at any radius.',
    'verify.c6': '# 6. From the first coin to the last, the price rises by exactly a factor of e.',

    /* — выбор кошелька (EIP-6963) — */
    'wm.title': 'Choose a wallet',
    'wm.subtitle': 'Wallets that announced themselves to this page (EIP-6963).',
    'wm.close': 'Close',
    'wm.none.h': 'No wallet detected',
    'wm.none.p': 'Nothing answered the EIP-6963 request and there is no window.ethereum in this browser. Install an EVM wallet extension, or open this page inside your wallet\'s built-in browser on mobile.',
    'wm.foot': 'The page never sees your keys. Connecting only shares your address; every transaction is signed in the wallet itself.',
    'wm.tag.legacy': 'legacy',
    'wm.tag.last': 'last used',
    'wm.connecting': 'Connecting to {name}…',
    'wm.legacyName': 'Browser wallet',
    'wm.legacyRdns': 'window.ethereum — no EIP-6963 announcement',

    /* — кошелёк — */
    'wallet.none': 'Wallet not connected',
    'wallet.noExt': 'No wallet extension detected',
    'wallet.connected': '{addr} · chain {chain}',
    'wallet.named': '{name} · {addr} · chain {chain}',
    'wallet.disconnect': 'Disconnect',
    'wallet.forgotten': 'The page has forgotten the connection. Your wallet still lists this site among its connected sites — remove it there for a full disconnect.',
    'wallet.buyback': ' · buy-back right: {amount} {sym}',
    'wallet.notFound': 'No wallet found in this browser — instructions below.',
    'wallet.confirm': 'Confirm the connection in your wallet…',
    'wallet.noAddress': 'The wallet returned no address',
    'wallet.rejected': 'You rejected the request in your wallet.',
    'wallet.pending': 'A request is already open in your wallet — confirm it there.',
    'wallet.wrongChain': 'The wallet stayed on a different network. Chain ID {chain} is required.',
    'wallet.unknown': 'Unknown error',
    'wallet.reverted': 'The contract refused: {reason}',

    /* — ввод и котировка — */
    'input.number': 'Enter a number, for example 0.01',
    'input.decimals': 'No more than {n} decimal places',
    'input.positive': 'The amount must be greater than zero',
    'input.slippage': 'Slippage must be below 100%',
    'input.deadline': 'Deadline must be between 1 and 1440 minutes',

    'quote.noCurve': 'The curve address is not set: the contract is not deployed yet.',
    'quote.working': 'Fetching the quote…',
    'quote.tooSmall': 'The amount is too small: the computed token output is zero',
    'quote.row.out': 'You receive (now)',
    'quote.row.min': 'Minimum on execution',
    'quote.row.fee': 'Fee, 1%',
    'quote.row.net': 'Into the curve reserve',
    'quote.row.avg': 'Average price of this trade',
    'quote.row.max': 'Maximum right now',
    'quote.avg': '{price} gwei per 1 {sym}',
    'quote.max': '{amount} {gas} (maxEthIn)',
    'quote.warn.inventory': 'The amount exceeds the remaining inventory: buy() would revert. The maximum right now is {amount} {gas}.',
    'quote.warn.antiSnipe': 'The anti-snipe window is open: at most {amount} {sym} per address. A purchase of this size would revert with AntiSnipeLimit.',
    'quote.ok': 'The quote holds for the current block. It is recomputed from scratch before the transaction is sent.',
    'quote.failed': 'Could not get a quote: {reason}',
    'quote.deadlineNote': '// deadline (unix, recomputed when sent)',

    /* — покупка — */
    'buy.noCurve': 'The curve address is not set.',
    'buy.noWallet': 'No wallet found.',
    'buy.confirmTx': 'Check the recipient address and the amount in the wallet window, then confirm.',
    'buy.sent': 'Transaction sent: ',

    /* — ошибки контрактов — */
    'err.deadline': 'The deadline has expired. Increase it and try again.',
    'err.slipBuy': 'The price moved beyond your slippage tolerance. Request a new quote.',
    'err.slipSell': 'The price moved beyond your slippage tolerance on the sell side.',
    'err.inventory': 'The amount is larger than the remaining inventory. The ceiling right now is maxEthIn().',
    'err.notBought': 'You can only sell back to the curve what this address bought from it.',
    'err.antiSnipe': 'Anti-snipe window: at most 10 000 000 tokens per address.',
    'err.zeroAmount': 'Zero amount.',
    'err.moreThanSold': 'More was requested than the curve has ever sold.',
    'err.domain': 'The argument is outside the curve\'s domain.',

    /* — RPC — */
    'rpc.failed': 'RPC unavailable: {reason}',
    'rpc.allFailed': 'none of the {count} RPC endpoints answered'
  },

  /* ───────────────────────────  РУССКИЙ  ──────────────────────────────── */
  ru: {
    'meta.title': 'Maclaurin Series (MACLRN) — сапплай равен e, эмиссия равна 1/n!',
    'meta.description': 'ERC-20, у которого график эмиссии буквально является рядом Маклорена для e. Сапплай ограничен математически: 2 718 281 828.459045235360287471 токена. Эмиссия заканчивается сама на 27-й эпохе.',

    'skip': 'К данным с цепочки',

    'nav.aria': 'Разделы',
    'nav.live': 'Данные',
    'nav.mechanics': 'Механика',
    'nav.immutable': 'Неизменяемость',
    'nav.buy': 'Покупка',
    'nav.risks': 'Риски',

    'lang.aria': 'Язык',
    'lang.en.aria': 'Переключить страницу на английский',
    'lang.ru.aria': 'Переключить страницу на русский',

    'nav.contracts': 'Контракты',

    'social.tg.aria': 'Телеграм-канал, откроется в новой вкладке',
    'social.x.aria': 'Профиль в X, откроется в новой вкладке',
    'social.gh.aria': 'Исходный код на GitHub, откроется в новой вкладке',

    /* — надзаголовки разделов — */
    'eyebrow.live': '01 — Цепочка',
    'eyebrow.mech': '02 — Механика',
    'eyebrow.imm': '03 — Неизменяемость',
    'eyebrow.buy': '04 — Покупка',
    'eyebrow.activity': '05 — Операции',
    'eyebrow.contracts': '06 — Контракты',
    'eyebrow.risks': '07 — Риски',
    'eyebrow.links': '08 — Проверка',

    /* — сводка рынка — */
    'market.price': 'Цена',
    'market.mcap': 'Капитализация',
    'market.mcap.na': 'баланс не прочитан',
    'market.fdv': 'FDV',
    'market.liquidity': 'Ликвидность',
    'market.vol24': 'Объём за 24 ч',
    'market.volAll': 'Объём за всё время',
    'market.vol.na': 'журнал сделок не прочитан',
    'market.note': 'Капитализация считается только по обращению: сапплай минус сожжённое, минус нераспределённая эмиссия, минус казна под замком, минус нераспроданный инвентарь кривой. FDV — по всему сапплаю. Ликвидность здесь — резерв кривой, то есть ETH, которым обеспечен обратный выкуп, а не пул: кривая выкупает только то, что продала, и только у того адреса, который покупал.',
    'market.usd.src': 'Доллары пересчитаны по курсу {rate} за {gas} от {src} — это единственный запрос страницы за пределы сети. Всё остальное читается с цепочки.',
    'market.usd.failed': 'Курс доллара не загрузился, поэтому величины показаны только в {gas}.',
    'market.usd.off': 'Пересчёт в доллары выключен в конфигурации страницы.',

    /* — журнал операций — */
    'nav.activity': 'Операции',
    'act.h2': 'Все операции с токеном',
    'act.lede': 'Полный лог <code>Transfer</code> токена, прочитанный с цепочки через <span class="mono">eth_getLogs</span>. Здесь всё движение MACLRN — genesis, сожжение и каждая покупка и продажа на кривой. У строк, которые являются сделками кривой, проставлены цена и сумма в ETH из её собственного события в той же транзакции, поэтому ничего не считается дважды.',
    'act.filter.aria': 'Фильтр',
    'act.filter.all': 'Все',
    'act.filter.trades': 'Сделки',
    'act.filter.transfers': 'Переводы',
    'act.reload': 'Обновить',
    'act.th.time': 'Когда',
    'act.th.type': 'Тип',
    'act.th.amount': 'Количество',
    'act.th.value': 'Сумма',
    'act.th.price': 'Цена',
    'act.th.from': 'Откуда',
    'act.th.to': 'Куда',
    'act.th.tx': 'Транзакция',
    'act.loading': 'Читаем лог переводов с цепочки…',
    'act.empty': 'По этому фильтру ничего нет.',
    'act.failed': 'Не удалось прочитать лог переводов: {reason}',
    'act.noToken': 'Адрес токена не задан.',
    'act.status': '{shown} из {total}',
    'act.more': 'Показать ещё {n}',
    'act.block': 'блок {n}',
    'act.kind.buy': 'Покупка',
    'act.kind.sell': 'Продажа',
    'act.kind.mint': 'Genesis',
    'act.kind.burn': 'Сожжение',
    'act.kind.transfer': 'Перевод',
    'act.who.zero': 'Нулевой адрес',
    'act.who.burn': 'Адрес сожжения',
    'act.link.all': 'Все переводы в эксплорере',
    'act.link.curve': 'Транзакции кривой',

    'ago.s': '{n} с назад',
    'ago.m': '{n} мин назад',
    'ago.h': '{n} ч назад',
    'ago.d': '{n} дн назад',

    /* — панель продажи — */
    'sale.h': 'Продажа через кривую',
    'sale.price': 'Текущая цена',
    'sale.sold': 'Инвентарь распродан',
    'sale.remaining': 'Остаток инвентаря',
    'sale.reserve': 'Резерв кривой',
    'sale.epoch': 'Эпоха эмиссии',
    'sale.cta': 'К панели покупки',
    'sale.foot': 'Читается из контрактов при каждой загрузке, а не вписано в вёрстку.',
    'sale.epochDone': 'завершена',
    'sale.epochOf': '{n} / 26',

    /* — контракты — */
    'contracts.h2': 'Адреса контрактов',
    'contracts.lede': 'Все четыре контракта развёрнуты и верифицированы в эксплорере. Скопируйте адрес отсюда и сверьте с тем, что показывает кошелёк, прежде чем что-либо подписывать.',
    'contracts.footnote': 'Верификация означает, что эксплорер сверил развёрнутый байткод с исходником. Неверифицированный контракт — непроверенный контракт, что бы ни было написано на сайте.',
    'contract.desc.token': 'ERC-20 · фиксированный сапплай, функции mint нет',
    'contract.desc.emission': 'Таблица эпох, стейкинг, локи',
    'contract.desc.curve': 'Продажа и обратный выкуп',
    'contract.desc.vesting': 'Казна под временным замком',
    'contract.pending': 'адрес не задан',
    'contract.copy': 'Копировать',
    'contract.explorer': 'Эксплорер',

    /* — hero — */
    'hero.badge': 'В мейннете Robinhood Chain · chain ID 4663',
    'hero.cta.buy': 'Купить через кривую',
    'hero.cta.verify': 'Проверить на цепочке',
    'hero.title': 'Сапплай равен <span class="mono">e</span>. Эмиссия равна <span class="mono">1/n!</span>.',
    'hero.lede': 'ERC-20, у которого график выпуска — не решение команды, а частичные суммы ряда. Общий сапплай равен числу <span class="mono">e</span> с точностью до 18 знаков после запятой. Эмиссия затухает факториально и заканчивается сама: не на дате из дорожной карты, а на эпохе, где очередной член ряда впервые оказывается меньше одной базовой единицы токена.',
    'hero.why': '<strong>Почему «Маклорен».</strong> Ряд Маклорена — это ряд Тейлора, разложенный в нуле. Наше разложение <span class="mono">e<sup>x</sup> = Σ x<sup>n</sup>/n!</span> построено вокруг точки <span class="mono">x = 0</span> и взято при <span class="mono">x = 1</span>, что и даёт <span class="mono">e = Σ 1/n!</span>. Точка разложения здесь не произвольная, а нулевая — значит, это ряд Маклорена, а название проекта описывает механику буквально, а не по мотивам.',
    'hero.fact.supply.dt': 'Общий сапплай',
    'hero.fact.supply.sub': '= floor(e × 10<sup>27</sup>) базовых единиц, 18 знаков',
    'hero.fact.reward.dt': 'Награда эпохи n',
    'hero.fact.reward.sub': 'эпоха — 7 дней, эмиссия идёт с n = 2 по n = 26',
    'hero.fact.end.dt': 'Конец эмиссии',
    'hero.fact.end.sub': '10<sup>27</sup>/27! = 0 при целочисленном делении',

    /* — live — */
    'live.h2': 'Данные с цепочки',
    'live.lede': 'Всё ниже читается прямо из контрактов через <span class="mono">eth_call</span> к публичному RPC сети Robinhood Chain при открытии страницы. В вёрстке этих чисел нет — вёрстку можно подделать, ответ узла нельзя. Рядом с каждым числом — ссылка на тот же вызов в эксплорере и точная команда, которой его повторить. Эндпоинтов несколько: если первый не отвечает, страница молча переходит к следующему, предварительно сверив его chain ID.',
    'live.refresh': 'Обновить',
    'live.footnote': 'Ссылка «эксплорер» ведёт на вкладку <em>Read contract</em>, где тот же вызов выполняется в браузере. Блок «повторить вызов» разворачивается в готовую команду <span class="mono">curl</span> и её эквивалент на <span class="mono">cast</span>: ответ узла не зависит ни от этой страницы, ни от её автора.',

    'card.epoch.h': 'Текущая эпоха',
    'card.epoch.note': '<code>currentEpoch()</code> — контракт эмиссии',
    'card.epochAmount.h': 'Награда текущей эпохи',
    'card.epochAmount.note': '<code>epochAmount(n)</code> — ровно 10<sup>27</sup>/n! базовых единиц',
    'card.emissionEnd.h': 'Конец эмиссии',
    'card.emissionEnd.note': '<code>emissionEnd()</code> — момент, после которого выпуск невозможен',
    'card.supply.h': 'Общий сапплай',
    'card.supply.note': '<code>totalSupply()</code> — неизменен после развёртывания',
    'card.sold.h': 'Распродано кривой',
    'card.sold.note': '<code>sold()</code> / <code>INVENTORY()</code>',
    'card.price.h': 'Текущая цена',
    'card.price.note': '<code>spotPrice()</code> — цена одного целого токена',
    'card.reserve.h': 'Резерв кривой',
    'card.reserve.note': '<code>reserve()</code> — обеспечение обратного выкупа',
    'card.weight.h': 'Суммарный вес стейкинга',
    'card.weight.note': '<code>totalWeight()</code> — делитель наград; <code>totalStaked()</code> — тело депозитов',
    'card.identity.h': 'Имя и тикер в контракте',
    'card.identity.note': '<code>name()</code>, <code>symbol()</code>, <code>decimals()</code> — как записано в байткоде',
    'card.proxy.h': 'Слот прокси (EIP-1967)',
    'card.proxy.note': '<code>eth_getStorageAt</code> по слоту реализации: ноль = за контрактом нет прокси',

    /* — механика — */
    'mech.h2': 'Механика без математического образования',
    'mech.supply.h': '1. Сапплай — это число, а не круглая цифра',
    'mech.supply.p1': 'Обычно сапплай выбирают: миллиард, потому что красиво. Здесь он равен основанию натурального логарифма, домноженному на 10<sup>27</sup>:',
    'mech.supply.p2': 'Ряд <span class="mono">e = 1/0! + 1/1! + 1/2! + 1/3! + …</span> сходится. Сходится — значит, сколько членов ни складывай, сумма не превысит <span class="mono">e</span>. Сапплай ограничен свойством ряда, а не обещанием выпустить не больше некоторой суммы.',
    'mech.supply.p3': 'Первые два члена (<span class="mono">1/0! + 1/1! = 2</span>) — это 2 000 000 000 токенов, 73.576% сапплая. Они существуют с нулевого блока и не фармятся. Остальные 26.424% (718 281 828.459045235360287471 токена) лежат в контракте эмиссии и раздаются по эпохам.',

    'mech.decay.h': '2. Эмиссия затухает факториально',
    'mech.decay.p1': 'Эпоха длится 7 дней. Эпоха <span class="mono">n</span> выпускает ровно <span class="mono">10<sup>27</sup>/n!</span> базовых единиц: эпоха 2 — половину, эпоха 3 — шестую часть, эпоха 4 — двадцать четвёртую. Каждая следующая порция меньше предыдущей не на проценты, а в разы, и разрыв растёт.',
    'mech.decay.p2': 'Практическое следствие: за первые пять эпох выпускается 99.97% пула эмиссии. Хвост при этом не обрывается — он продолжается, просто быстро становится незначимым. Это противоположность халвингу, где каждый шаг делит награду ровно надвое бесконечно долго.',
    'mech.table.summary': 'Полная таблица эпох (константы, захардкоженные в контракте)',
    'mech.table.th.units': 'базовых единиц',
    'mech.table.th.tokens': 'токенов',
    'mech.table.th.pct': '% сапплая',
    'mech.table.final': '0 — эмиссия завершена',
    'mech.table.footnote': 'Сумма эпох 2…26 = 718 281 828 459 045 235 360 287 457 базовых единиц. Остаток от округления вниз — 14 единиц — навсегда остаётся в контракте эмиссии. Это не потеря, а запас: выплатить больше, чем есть, невозможно арифметически, без единой проверки в коде.',

    'mech.end.h': '3. Эмиссия заканчивается сама',
    'mech.end.p1': 'На эпохе 27 член ряда равен <span class="mono">10<sup>27</sup>/27!</span>. 27! — это примерно <span class="mono">1.089 × 10<sup>28</sup></span>, то есть больше числителя. В целочисленной арифметике EVM дробей нет: результат деления равен нулю. Не «округляется до нуля при отображении», а именно равен нулю.',
    'mech.end.callout': 'Конец эмиссии — свойство арифметики uint256, а не решение мультисига. Никто не голосует за прекращение выпуска, никто не может его продлить: функции, способной это сделать, в контракте не существует.',

    'mech.stake.h': '4. Стейкинг: радиус сходимости',
    'mech.stake.p1': 'Каждый ряд сходится лишь внутри своего радиуса. Стейкер выбирает радиус <span class="mono">R</span> — на сколько эпох лочится позиция. Множитель наград равен частичной сумме того же самого ряда до <span class="mono">R</span>-го члена.',
    'mech.stake.th.lock': 'Лок',
    'mech.stake.th.mult': 'Множитель',
    'mech.stake.th.delta': 'Прирост к предыдущему',
    'mech.stake.d7': '7 дней',
    'mech.stake.d14': '14 дней',
    'mech.stake.d21': '21 день',
    'mech.stake.d28': '28 дней',
    'mech.stake.d35': '35 дней',
    'mech.stake.d42': '42 дня',
    'mech.stake.d49': '49 дней',
    'mech.stake.unreachable': 'недостижим',
    'mech.stake.p2': 'Потолок — само число <span class="mono">e</span>, и он недостижим по построению: частичная сумма ряда строго меньше его суммы. Это не маркетинговое ограничение, которое можно снять голосованием, а свойство сходящегося ряда с положительными членами. Константа <span class="mono">E_FIXED</span> лежит в контракте именно затем, чтобы недостижимость проверялась на цепочке.',
    'mech.stake.p3': 'Награда делится не по размеру депозита, а по весу: <span class="mono">weight = staked × multiplier(R)</span>. Тело депозита при этом учитывается отдельным счётчиком и в расчёте множителя не участвует никак.',

    'mech.locks.h': '5. Что заперто, а что нет',
    'mech.locks.claim': '<strong><code>claim()</code> закрыт до конца лока.</strong> До <span class="mono">unlockTime</span> вызов ревертит <code>StillLocked</code>. Иначе множитель выводился бы наградами каждую эпоху, и к моменту досрочного выхода отбирать было бы уже нечего.',
    'mech.locks.unstake': '<strong><code>unstake()</code> открыт всегда</strong>, включая активный лок. Тело депозита возвращается целиком, до последней базовой единицы. Правило «не трогать принципал ни при каких условиях» не нарушается.',
    'mech.locks.forfeit': '<strong>Досрочный выход сжигает награду.</strong> Накопленное обнуляется и уходит в казну остаточного члена — целиком, даже при частичном выходе. Пропорциональное сжигание выглядело бы справедливее, но позволяло бы выйти телом на 99.99% и досидеть лок пылинкой, сохранив награду за полное тело.',
    'mech.locks.nokeepers': '<strong>Никаких киперов и оракулов.</strong> Единственный внешний вход контракта эмиссии — <span class="mono">block.timestamp</span>. Нет цены извне, нет бота, от которого зависят выплаты, нет подписи, без которой ничего не работает.',

    /* — неизменяемость — */
    'imm.h2': 'Почему здесь нельзя напечатать токены',
    'imm.p1': 'Самый частый способ рагпула — не эксплойт, а вполне легальная функция <code>mint(address,uint256) onlyOwner</code>. Владелец печатает себе триллион токенов и продаёт. Аудит такой контракт пропускает: там нет уязвимости, там есть задокументированное полномочие. Единственная защита от этого — чтобы такой функции физически не было в байткоде.',
    'imm.mint': '<strong>Функции <code>mint</code> не существует в байткоде.</strong> Весь сапплай выпущен один раз, в конструкторе токена. После конструктора функций, меняющих сапплай, в контракте нет.',
    'imm.owner': '<strong>Владельца нет.</strong> <code>Ownable</code> не используется ни в одном контракте — отказываться от владения нечем и не нужно. Нет <code>owner()</code>, нет ролей, нет мультисига с полномочиями.',
    'imm.proxy': '<strong>Прокси нет.</strong> Апгрейдимый токен — это тот же <code>mint</code>, только спрятанный за прокси. Слот реализации EIP-1967 читается прямо на этой странице: он равен нулю.',
    'imm.plain': '<strong>Нет пауз, блэклистов, налога на трансфер и хуков.</strong> Обычный ERC-20 из OpenZeppelin без единой надстройки.',
    'imm.reserve': '<strong>У создателя нет доступа к резерву кривой.</strong> Функции, которая перевела бы <code>reserve</code> куда-либо, кроме продавца, в контракте не существует; комиссия живёт в отдельном счётчике и с резервом не смешивается.',
    'imm.verify.h': 'Проверить это самому, не доверяя сайту',
    'imm.verify.p': 'Ниже — команды, которые ищут селекторы привилегированных функций прямо в развёрнутом байткоде. Пустой вывод <span class="mono">grep</span> означает, что такой функции в контракте нет. Адреса подставляются автоматически из конфигурации этой страницы, но проверять их стоит по ссылке на верифицированный исходник.',
    'imm.verify.footnote': '<code>40c10f19</code> = <code>mint(address,uint256)</code>, <code>8da5cb5b</code> = <code>owner()</code>, <code>f2fde38b</code> = <code>transferOwnership(address)</code>, <code>3659cfe6</code> = <code>upgradeTo(address)</code>, <code>8456cb59</code> = <code>pause()</code>. Селекторы считаются как первые 4 байта keccak256 от сигнатуры — их можно получить самому через <span class="mono">cast sig</span>.',

    /* — покупка — */
    'buy.h2': 'Покупка через бондинг-кривую',
    'buy.p1': 'Пула ликвидности нет: он требует капитала, которого у проекта нет, и при маленькой глубине покупка на несколько долларов двигает цену на десятки процентов. Вместо него — контракт-кривая, который держит инвентарь в 1 000 000 000 токенов (это половина genesis, разложенная по геометрическому ряду 2 = 1 + 1/2 + 1/4 + …) и продаёт их по линейно растущей цене.',
    'buy.rule.trapezoid': '<strong>Цена растёт линейно, стоимость покупки — площадь трапеции.</strong> Только умножение и деление целых чисел, никаких приближений экспоненты. Формулу можно пересчитать на бумаге.',
    'buy.rule.ratio': '<strong>От первого токена до последнего цена вырастает ровно в <span class="mono">e</span> раз:</strong> с 2 gwei до 5.436563656918090470 gwei за целый токен. Отношение проверяется одним делением на цепочке, потому что арифметика целочисленная.',
    'buy.rule.fee': '<strong>Комиссия 1% в ETH</strong> — константа, не переменная. Берётся до зачисления в резерв при покупке и из уже вычтенной суммы при продаже, поэтому резерв никогда не финансирует комиссию.',
    'buy.rule.buyback': '<strong>Кривая — не биржа: продать ей можно ровно то, что у неё куплено.</strong> Право выкупа именное (<code>boughtOf(адрес)</code>) и не переносится обычным трансфером. Иначе держатель бесплатных токенов из genesis или наград стейкинга забрал бы ETH покупателей. Токены, купленные не у кривой, продаются на вторичном рынке, а не сюда.',
    'buy.rule.nodiscretion': '<strong>У продажи нет ни одного условия, зависящего от чьего-либо решения:</strong> только баланс, собственная защита от проскальзывания и не истёкший дедлайн. Ни пауз, ни списков, ни кулдауна.',
    'buy.rule.antisnipe': '<strong>Окно анти-снайпа уже истекло.</strong> Лимит 10 000 000 токенов на адрес действовал первый час после развёртывания кривой (<code>antiSnipeEnd()</code> — проверяется на цепочке). Этот час прошёл, и ни одной покупки в нём не было, то есть лимит не применился ни разу: прямо сейчас одна транзакция может выкупить весь остаток инвентаря. Смягчением, а не защитой, он был и до этого — обходится несколькими кошельками.',
    'buy.addr.h': 'Адрес контракта кривой',
    'buy.addr.hint': 'Сверьте его с адресом в кошельке перед подтверждением транзакции. Ни один другой адрес не является контрактом продажи.',
    'buy.addr.copy': 'Скопировать',
    'buy.addr.copied': 'Скопировано',
    'buy.connect': 'Подключить кошелёк',
    'buy.field.amount': 'Сумма, <span data-field="currency">ETH</span>',
    'buy.field.slippage': 'Проскальзывание, %',
    'buy.field.deadline': 'Дедлайн, минут',
    'buy.action.quote': 'Рассчитать',
    'buy.action.buy': 'Купить',
    'buy.quick.max': 'Максимум',
    'buy.quick.maxHint': 'Подставить maxEthIn() — самую крупную покупку, которую позволяет остаток инвентаря прямо сейчас',
    'buy.quick.maxFailed': 'Не удалось прочитать maxEthIn(): {reason}',

    /* — график — */
    'chart.last': 'Цена последней сделки',
    'chart.aria': 'График цены',
    'chart.tf.aria': 'Интервал',
    'chart.mode.aria': 'Режим графика',
    'chart.mode.candles': 'Свечи',
    'chart.mode.curve': 'Кривая',
    'chart.reload': 'Перечитать сделки',
    'chart.loading': 'Читаем журнал сделок с цепочки…',
    'chart.empty': 'Сделок в журнале пока нет. Свечи строятся только из событий Bought и Sold самой кривой — пока сделки не было, рисовать нечего, и пустота ничем не заполняется.',
    'chart.noCurve': 'Адрес кривой не задан.',
    'chart.failed': 'Не удалось прочитать журнал сделок: {reason}',
    'chart.status': 'сделок: {trades} · свечей: {candles} · {tf} · просмотр с блока {block}',
    'chart.curveNote': 'Цена как функция проданного объёма — чистая функция контракта, а не история. Маркер показывает, где кривая стоит сейчас.',
    'chart.curveWait': 'Ждём данные с цепочки…',
    'chart.axisSold': 'продано токенов',
    'chart.vol': 'Объём',
    'chart.hint': 'Колесо — масштаб · протяжка — сдвиг · протяжка по шкале цены или времени — масштаб по этой оси · двойной клик — сброс',
    'chart.custom.aria': 'Свой интервал',
    'chart.custom.hint': 'Свой интервал свечи: 45s, 2m, 1.5h, 3d — или просто число секунд. От 1 секунды до 30 дней.',
    'chart.truncated': 'обрезано до последних {from} на этом интервале',
    'chart.noneInView': 'В этом окне сделок нет. Всего их в серии {n} — отдалите колесом или сбросьте двойным кликом.',

    /* — вкладки и продажа — */
    'trade.sell': 'Продать',
    'trade.tabs.aria': 'Покупка или продажа',
    'sell.field.amount': 'Количество, <span data-field="token">MACLRN</span>',
    'sell.limit.none': 'Подключите кошелёк, чтобы увидеть, сколько кривая обязана выкупить у этого адреса.',
    'sell.limit': 'Кривая выкупит у этого адреса до {amount} {sym} · баланс {bal} {sym}',
    'sell.limit.zero': 'Этот адрес ничего не покупал у кривой, поэтому продавать ей нечего.',
    'sell.quick.maxHint': 'Подставить меньшее из баланса токенов и права обратного выкупа',
    'sell.approveNote': 'Продажа — две транзакции: разрешение ровно на продаваемое количество и сама продажа. Неограниченный approve не запрашивается никогда: если сделка сорвётся, у контракта не останется постоянного права двигать остаток баланса.',
    'sell.row.out': 'Получите',
    'sell.row.min': 'Минимум при исполнении',
    'sell.row.fee': 'Комиссия 1%',
    'sell.row.avg': 'Средняя цена сделки',
    'sell.overLimit': 'Больше, чем этот адрес может продать кривой. Потолок — {amount} {sym}.',
    'sell.overBalance': 'Больше, чем баланс токенов на этом адресе.',
    'sell.approving': 'Выдаём разрешение ровно на {amount} {sym} — подтвердите в кошельке…',
    'sell.approveWait': 'Ждём, пока разрешение попадёт в блок…',
    'sell.approveFailed': 'Транзакция разрешения не подтвердилась вовремя. Проверьте её в эксплорере и повторите.',
    'sell.confirmTx': 'Теперь подтвердите в кошельке саму продажу.',
    'sell.sent': 'Продажа отправлена: ',
    'buy.sig.summary': 'Что именно подписывает кошелёк',
    'buy.sig.p': 'Вызывается <code>buy(uint256 minTokensOut, uint256 deadline)</code>, сумма передаётся как <span class="mono">value</span> транзакции. <span class="mono">minTokensOut</span> считается из котировки <code>previewBuy(ethIn)</code> с вычетом заданного проскальзывания: если между расчётом и исполнением цена уйдёт дальше, транзакция откатится, а не исполнится по худшей цене. Переплата сверх остатка инвентаря не возвращается сдачей, а ревертит — поэтому есть <code>maxEthIn()</code>, точная верхняя граница на текущий момент.',
    'buy.sell.summary': 'Как продать обратно кривой',
    'buy.sell.p1': 'Вкладка «Продать» выше делает это за вас, но сайт для этого не нужен: те же два вызова доступны в эксплорере, а разрешение выдаётся ровно на продаваемое количество — <code>approve</code> на неограниченную сумму не запрашивается никогда. Порядок такой:',
    'buy.sell.step1': '<code>approve(адрес кривой, amount)</code> на контракте токена — выдать разрешение ровно на продаваемое количество;',
    'buy.sell.step2': '<code>sell(amount, minEthOut, deadline)</code> на контракте кривой.',
    'buy.sell.p2': 'Оба вызова доступны во вкладке <em>Write contract</em> эксплорера — там же видно тело функции. <code>boughtOf(ваш адрес)</code> показывает, сколько токенов кривая обязана выкупить обратно.',

    'nowallet.h': 'Кошелька в браузере нет',
    'nowallet.p1': 'Страница не нашла ни одного кошелька: ни объявления по EIP-6963, ни <span class="mono">window.ethereum</span>. Значит, расширение-кошелёк не установлено или отключено для этого сайта. Что можно сделать:',
    'nowallet.step1': 'установить любой EVM-кошелёк с поддержкой произвольных сетей (например, MetaMask или Rabby) из официального магазина расширений браузера;',
    'nowallet.step2': 'добавить сеть вручную: <span class="mono">Chain ID 4663</span>, RPC <span class="mono" data-field="rpc"></span>, эксплорер <span class="mono" data-field="explorer"></span>;',
    'nowallet.step3': 'завести на адрес немного газового токена сети и вернуться сюда — кнопка подключения появится сама.',
    'nowallet.p2': 'Мобильный браузер обычно не поддерживает расширения: там страницу нужно открыть во встроенном браузере кошелька. Покупку можно совершить и вручную из эксплорера, вкладка <em>Write contract</em> — сайт для этого не нужен.',

    /* — риски — */
    'risks.h2': 'Риски. Прочитайте до покупки',
    'risks.liquidity': '<strong>Ликвидность мала, цена волатильна.</strong> Полная распродажа инвентаря собирает в резерв около 3.72 ETH — это порядок величины всего механизма, а не размер рынка. Любая заметная сделка ощутимо сдвигает цену в обе стороны. Это работающая демонстрация полного цикла, а не глубокий рынок.',
    'risks.notExchange': '<strong>Кривая — не биржа.</strong> Она выкупает обратно только то, что у неё куплено, и только у того адреса, который покупал. Токены, полученные любым другим путём, кривой не продаются. Вторичного рынка может не быть вообще.',
    'risks.exitPrice': '<strong>Кривая выкупает по своей текущей цене, а не по той, по которой вы купили.</strong> Резерв всегда покрывает все непогашенные права выкупа, поэтому <code>sell()</code> не может отказать из-за нехватки денег — но сколько ETH он вернёт, зависит от того, сколько продано на этот момент, а не от вашей точки входа. Если другие покупатели выйдут раньше вас, цена скатится обратно по кривой и вы получите меньше, чем вложили: в худшем случае (вы купили на вершине инвентаря, все остальные продали первыми) примерно на 63% меньше — это и есть множитель <span class="mono">e</span>, на который расходится цена. Это механизм «кто первый вышел, тот и в плюсе», а не возврат денег.',
    'risks.concentration': '<strong>Весь инвентарь стоит около 3.76 ETH, и один адрес может забрать его целиком.</strong> Это достаточно мало, чтобы один участник выкупил весь миллиард токенов одной транзакцией, застейкал его, собрал практически весь пул эмиссии в 718 281 828 токенов — награда делится по весу, а его вес и будет делителем — а потом продал инвентарь обратно кривой по той же средней цене и вернул ETH. Круг обходится только двумя комиссиями по 1%. В контрактах нет ничего, что этому мешает, а стейкинг рядом с такой позицией даёт пропорционально ничтожную долю.',
    'risks.experimental': '<strong>Проект экспериментальный.</strong> Контракты неизменяемы: ошибку нельзя исправить патчем, апгрейда не существует. Это одновременно и главная гарантия, и главный риск.',
    'risks.audit': '<strong>Аудит не является страховкой.</strong> Тесты, статический анализ и независимое ревью снижают вероятность ошибки, но не доказывают её отсутствие. Формально доказана только часть свойств.',
    'risks.noYield': '<strong>У токена нет доходности и нет обязательств перед вами.</strong> Награды стейкинга — это перераспределение заранее выпущенного пула эмиссии, а не прибыль от какой-либо деятельности. Никто не обещает роста цены и не может его обеспечить.',
    'risks.network': '<strong>Сеть новая.</strong> Robinhood Chain, публичные RPC и эксплорер — внешняя инфраструктура, на которую проект не влияет. Её недоступность сделает недоступной и эту страницу, и работу с контрактами из браузера.',
    'risks.legal': '<strong>Правовой статус не определён.</strong> Токен с механикой распределения наград может квалифицироваться как ценная бумага в ряде юрисдикций. Прямая продажа с сайта автором актива — не то же самое, что предоставление ликвидности на DEX. Это не юридическая консультация; соответствие местному праву — ваша ответственность.',
    'risks.size': '<strong>Покупайте только на сумму, потерю которой вы готовы принять полностью.</strong> Ничто на этой странице не является инвестиционной рекомендацией.',

    /* — ссылки, подвал — */
    'links.h2': 'Проверить',
    'links.footnote': 'Ссылки на контракты ведут на верифицированные исходники в эксплорере: там сверяется байткод и читается тот же код, что лежит в репозитории. Неверифицированный контракт стоит считать непроверенным независимо от того, что написано на сайте.',
    'footer.p1': 'Maclaurin Series (MACLRN). Нарратив построен вокруг математики XVIII века, а не вокруг публичного лица: имена, изображения и названия компаний реальных людей не используются и ничьё одобрение не подразумевается.',
    'footer.p2': 'Страница статическая: без бэкенда, без аналитики, без сторонних скриптов и шрифтов. Почти все запросы идут к публичным RPC сети, адреса которых видны в конфигурации <span class="mono">web/app.js</span>. Исключение ровно одно: курс ETH/USD, по которому пересчитаны долларовые величины, берётся у стороннего сервиса — и он видит адрес, с которого вы зашли. Сервис назван в той же конфигурации и там же выключается: без него все величины показываются в токене сети, больше ничего не меняется. Транзакции подписывает ваш кошелёк, ключи страница не видит и не запрашивает.',

    /* — динамика: статус чтения — */
    'status.loading': 'Загрузка…',
    'status.reading': 'Чтение с цепочки…',
    'status.noAddresses': 'Адреса контрактов не заполнены — читать нечего.',
    'status.updated': 'Обновлено {time} · блок {block} · {host}',
    'status.partial': 'Обновлено {time} · блок {block} · не прочитано вызовов: {failed}',
    'status.allDown': 'Не удалось получить данные с цепочки: ни один из {count} RPC-эндпоинтов не ответил. Значений ниже нет — это не нули.',
    'status.stale': 'Не удалось обновить: ни один из {count} RPC-эндпоинтов не ответил. Значения ниже — на {time}, они могли устареть.',

    'chain.banner': 'Контракты ещё не развёрнуты: адреса в конфигурации страницы нулевые. Числа ниже появятся сами, как только адреса будут заполнены, — они читаются с цепочки, а не вписываются в вёрстку.',

    /* — динамика: карточки — */
    'card.link.explorer': 'эксплорер',
    'card.link.repeat': 'повторить вызов',
    'card.na.address': 'адрес не задан',
    'card.na.emission': 'адрес эмиссии не задан',
    'card.na.token': 'адрес токена не задан',
    'card.na.curve': 'адрес кривой не задан',
    'card.na.epoch': 'нет номера эпохи',
    'card.err.call': 'ошибка вызова',
    'card.err.noData': 'данных нет',

    'epoch.done': 'эмиссия завершена',
    'epoch.of': '{n} из 26',
    'epoch.len': 'эпоха длится 7 дней',
    'epoch.raw': 'currentEpoch() = {n}',
    'epochAmount.sub': '{raw} базовых единиц = 10^27 / {n}!',
    'epochAmount.last': ' (последняя эпоха с ненулевой наградой)',
    'emissionEnd.done': 'эмиссия завершена',
    'supply.sub': '{raw} базовых единиц · floor(e × 10^27)',
    'weight.sub.raw': '{raw} базовых единиц',
    'weight.sub.staked': 'в стейкинге {staked} {sym} · вес ≤ тело × e',
    'identity.sub.match': 'decimals {dec} · совпадает с заявленным на странице',
    'identity.sub.mismatch': 'decimals {dec} · на странице заявлен {sym} — расхождение',
    'proxy.unread': 'слот не прочитан',
    'proxy.none': '0x00…00 — прокси нет',
    'proxy.none.sub': 'слот реализации и слот администратора пусты: контракт не обновляем',
    'proxy.present': 'слот не пуст',
    'proxy.present.sub': 'implementation {impl} · admin {admin} — проверьте вручную',
    'sold.sub': '{sold} из {inv} {sym}',
    'price.sub': '{raw} wei за 1 {sym} · стартовая цена 2 gwei, конечная 5.436563656918090470 gwei',
    'reserve.sub': '{raw} wei · полная распродажа инвентаря собирает 3.718281828459045235 {gas} (= 1 + e)',

    'time.passed': 'уже прошёл',
    'time.dh': 'через {d} дн. {h} ч.',
    'time.hm': 'через {h} ч. {m} мин.',

    /* — динамика: адреса и ссылки — */
    'addr.pending': '  (адрес будет заполнен после деплоя)',
    'link.source': 'Верифицированный исходник',
    'link.read': 'Read contract',
    'link.write': 'Write contract',
    'link.curvePending': 'Ссылки появятся после развёртывания и верификации контракта.',
    'link.approve': 'approve на контракте токена',
    'link.sell': 'sell на контракте кривой',
    'link.sellPending': 'Ссылки появятся после развёртывания контрактов.',
    'src.token': 'Исходник токена',
    'src.emission': 'Исходник контракта эмиссии',
    'src.curve': 'Исходник кривой',
    'src.vesting': 'Исходник вестинга',
    'src.pending': 'Ссылки на верифицированные исходники появятся после развёртывания.',

    'grid.token': 'Токен MACLRN (ERC-20)',
    'grid.emission': 'Контракт эмиссии',
    'grid.curve': 'Бондинг-кривая',
    'grid.vesting': 'Вестинг казны',
    'grid.repo': 'Репозиторий с исходниками',
    'grid.audit': 'Отчёты аудита',
    'grid.specToken': 'Спецификация токена',
    'grid.specCurve': 'Спецификация кривой',
    'grid.telegram': 'Телеграм-канал',
    'grid.x': 'Профиль в X',
    'grid.missing': 'ссылка не задана — заполнить после деплоя',
    'footer.tagline': 'Сапплай равен e. Эмиссия равна 1/n!.',

    /* — команды проверки — */
    'verify.c1a': '# 1. Скачать развёрнутый байткод и поискать в нём селекторы полномочий.',
    'verify.c1b': '#    Пустой вывод grep = такой функции в контракте нет.',
    'verify.c2': '# 2. Убедиться, что за адресом нет прокси (слот реализации EIP-1967).',
    'verify.c3': '# 3. Сапплай неизменен и равен floor(e × 10^27).',
    'verify.c4': '# 4. Эмиссия обрывается сама: член ряда на эпохе 27 равен нулю.',
    'verify.c5': '# 5. Множитель стейкинга не достигает e ни при каком радиусе.',
    'verify.c6': '# 6. Цена от первой до последней монеты растёт ровно в e раз.',

    /* — выбор кошелька (EIP-6963) — */
    'wm.title': 'Выберите кошелёк',
    'wm.subtitle': 'Кошельки, которые сами объявились этой странице (EIP-6963).',
    'wm.close': 'Закрыть',
    'wm.none.h': 'Кошелёк не обнаружен',
    'wm.none.p': 'На запрос EIP-6963 никто не ответил, и window.ethereum в этом браузере нет. Установите расширение-кошелёк для EVM или откройте страницу во встроенном браузере кошелька на телефоне.',
    'wm.foot': 'Ключи страница не видит. Подключение передаёт только адрес; каждую транзакцию подписывает сам кошелёк.',
    'wm.tag.legacy': 'legacy',
    'wm.tag.last': 'последний',
    'wm.connecting': 'Подключаемся к {name}…',
    'wm.legacyName': 'Кошелёк в браузере',
    'wm.legacyRdns': 'window.ethereum — без объявления по EIP-6963',

    /* — кошелёк — */
    'wallet.none': 'Кошелёк не подключён',
    'wallet.noExt': 'Расширение-кошелёк не обнаружено',
    'wallet.connected': '{addr} · сеть {chain}',
    'wallet.named': '{name} · {addr} · сеть {chain}',
    'wallet.disconnect': 'Отключить',
    'wallet.forgotten': 'Страница забыла подключение. В самом кошельке сайт остаётся в списке подключённых — уберите его там, если нужно отключиться полностью.',
    'wallet.buyback': ' · право обратного выкупа: {amount} {sym}',
    'wallet.notFound': 'Кошелёк в браузере не найден — инструкция ниже.',
    'wallet.confirm': 'Подтвердите подключение в кошельке…',
    'wallet.noAddress': 'Кошелёк не вернул адрес',
    'wallet.rejected': 'Вы отклонили запрос в кошельке.',
    'wallet.pending': 'Запрос уже открыт в кошельке — подтвердите его там.',
    'wallet.wrongChain': 'Кошелёк остался в другой сети. Нужен chain ID {chain}.',
    'wallet.unknown': 'Неизвестная ошибка',
    'wallet.reverted': 'Контракт отказал: {reason}',

    /* — ввод и котировка — */
    'input.number': 'Введите число, например 0.01',
    'input.decimals': 'Не более {n} знаков после запятой',
    'input.positive': 'Сумма должна быть больше нуля',
    'input.slippage': 'Проскальзывание должно быть меньше 100%',
    'input.deadline': 'Дедлайн — от 1 до 1440 минут',

    'quote.noCurve': 'Адрес кривой не задан: контракт ещё не развёрнут.',
    'quote.working': 'Считаем котировку…',
    'quote.tooSmall': 'Слишком маленькая сумма: расчётное количество токенов равно нулю',
    'quote.row.out': 'Получите (сейчас)',
    'quote.row.min': 'Минимум при исполнении',
    'quote.row.fee': 'Комиссия 1%',
    'quote.row.net': 'В резерв кривой',
    'quote.row.avg': 'Средняя цена сделки',
    'quote.row.max': 'Максимум прямо сейчас',
    'quote.avg': '{price} gwei за 1 {sym}',
    'quote.max': '{amount} {gas} (maxEthIn)',
    'quote.warn.inventory': 'Сумма больше остатка инвентаря: buy() отревертит. Максимум прямо сейчас — {amount} {gas}.',
    'quote.warn.antiSnipe': 'Действует лимит первого часа: не более {amount} {sym} на адрес. Покупка на эту сумму отревертит AntiSnipeLimit.',
    'quote.ok': 'Котировка действительна на текущий блок. Перед отправкой она пересчитывается заново.',
    'quote.failed': 'Не удалось получить котировку: {reason}',
    'quote.deadlineNote': '// deadline (unix, пересчитывается при отправке)',

    /* — покупка — */
    'buy.noCurve': 'Адрес кривой не задан.',
    'buy.noWallet': 'Кошелёк не найден.',
    'buy.confirmTx': 'Проверьте адрес получателя и сумму в окне кошелька и подтвердите.',
    'buy.sent': 'Транзакция отправлена: ',

    /* — ошибки контрактов — */
    'err.deadline': 'Дедлайн истёк. Увеличьте срок и повторите.',
    'err.slipBuy': 'Цена ушла дальше допуска по проскальзыванию. Пересчитайте котировку.',
    'err.slipSell': 'Цена ушла дальше допуска по проскальзыванию при продаже.',
    'err.inventory': 'Сумма больше остатка инвентаря. Максимум на сейчас — maxEthIn().',
    'err.notBought': 'Продать кривой можно только то, что у неё куплено этим адресом.',
    'err.antiSnipe': 'Лимит первого часа: не более 10 000 000 токенов на адрес.',
    'err.zeroAmount': 'Нулевая сумма.',
    'err.moreThanSold': 'Запрошено больше, чем кривая вообще продала.',
    'err.domain': 'Аргумент вне области определения кривой.',

    /* — RPC — */
    'rpc.failed': 'RPC недоступен: {reason}',
    'rpc.allFailed': 'ни один из {count} RPC-эндпоинтов не ответил'
  }
};

/* ── слой перевода ─────────────────────────────────────────────────────── */

const LS_LANG = 'maclrn.lang';
const LOCALE = { en: 'en-GB', ru: 'ru-RU' };

let LANG = 'en';

function lsGet(key) {
  // file:// в части браузеров отдаёт непрозрачный origin и бросает на доступе
  // к localStorage. Отсутствие памяти о выборе — не повод ронять страницу.
  try { return localStorage.getItem(key); } catch (_) { return null; }
}
function lsSet(key, value) {
  try { localStorage.setItem(key, value); } catch (_) { /* приватный режим, file:// */ }
}

function detectLang() {
  const saved = lsGet(LS_LANG);
  if (saved === 'ru' || saved === 'en') return saved;
  return 'en';
}

/** Перевод по ключу. Плейсхолдеры вида {name} подставляются из params. */
function t(key, params) {
  const dict = I18N[LANG] || I18N.en;
  let s = dict[key];
  if (s === undefined) s = I18N.en[key];
  if (s === undefined) return key;                    // видно сразу, что ключ забыт
  if (!params) return s;
  return s.replace(/\{(\w+)\}/g, (m, k) => (params[k] === undefined ? m : String(params[k])));
}

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
  const s = String(str).trim().replace(',', '.').replace(/[\s  ]/g, '');
  if (!/^\d*(\.\d*)?$/.test(s) || s === '' || s === '.') throw new Error(t('input.number'));
  const [i, f = ''] = s.split('.');
  if (f.length > decimals) throw new Error(t('input.decimals', { n: decimals }));
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
    return new Intl.DateTimeFormat(LOCALE[LANG], { dateStyle: 'long', timeStyle: 'short' }).format(d);
  } catch (_) {
    return d.toISOString();
  }
}
const fmtIsoUtc = (unixSeconds) => new Date(Number(unixSeconds) * 1000).toISOString().replace('.000Z', 'Z');
const fmtClock = (date) => {
  try { return date.toLocaleTimeString(LOCALE[LANG]); } catch (_) { return date.toISOString().slice(11, 19); }
};

function humanDelta(seconds) {
  const s = Number(seconds);
  if (s <= 0) return t('time.passed');
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  if (d > 0) return t('time.dh', { d, h });
  const m = Math.floor((s % 3600) / 60);
  return t('time.hm', { h, m });
}

/* ── JSON-RPC с перебором эндпоинтов ───────────────────────────────────── *
 *
 *  Правила:
 *   • эндпоинту не верим, пока его eth_chainId не совпал с CONFIG.chain.id —
 *     иначе подменённый URL показал бы данные чужой сети как наши;
 *   • транспортная ошибка (сеть, таймаут, HTTP 4xx/5xx, пустой result) —
 *     молча идём к следующему эндпоинту;
 *   • ответ узла с JSON-RPC error — это ответ, а не отказ: так приходит
 *     revert, и его причина нужна пользователю. Исключение — рейт-лимит
 *     и «метода нет»: это про эндпоинт, а не про контракт, тут перебор;
 *   • рабочий эндпоинт запоминается на сессию и пробуется первым.
 * ─────────────────────────────────────────────────────────────────────── */

let rpcId = 0;
let activeRpc = null;                 // эндпоинт, ответивший последним
const endpointState = new Map();      // url → 'ok' | 'wrong-chain' | 'limited'
const endpointProbe = new Map();      // url → Promise<boolean>, чтобы не сверять chainId 12 раз подряд

const rpcList = () => CONFIG.chain.rpcs.filter((u) => typeof u === 'string' && u);

/** Эндпоинт для показа в командах curl/cast: тот, который реально отвечает. */
const rpcUrl = () => activeRpc || rpcList()[0] || '';

function rpcOrder() {
  const all = rpcList();
  if (!activeRpc) return all;
  return [activeRpc].concat(all.filter((u) => u !== activeRpc));
}

async function rpcOnce(url, method, params) {
  const ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timer = ctrl ? setTimeout(() => ctrl.abort(), CONFIG.ui.rpcTimeoutMs) : null;
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
      // Никаких кук и заголовков авторизации: узел не должен уметь отличать
      // одного читателя страницы от другого.
      credentials: 'omit',
      cache: 'no-store',
      signal: ctrl ? ctrl.signal : undefined
    });
    // Тело читаем ДО проверки статуса: JSON-RPC ошибка (в том числе revert
    // с его data) приезжает и с HTTP 400 — так отвечает часть шлюзов. Если
    // сначала бросить по статусу, причина отказа контракта потеряется.
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch (_) { /* не JSON — значит, не узел ответил */ }

    if (json && json.error) {
      const err = new Error(json.error.message || 'RPC error');
      err.data = json.error.data;
      err.code = json.error.code;
      err.fromNode = true;
      throw err;
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    if (!json || json.result === undefined || json.result === null) throw new Error('empty result');
    return json.result;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Ответ узла, который говорит о самом узле, а не о контракте. */
function isEndpointFault(e) {
  if (!e || !e.fromNode) return false;
  if (e.code === -32005 || e.code === -32029 || e.code === -32601 || e.code === -32603 || e.code === 429) return true;
  return /rate.?limit|too many requests|quota|capacity|exceeded|try again|forbidden/i.test(String(e.message || ''));
}

/** Сверка chain ID. Результат кэшируется на сессию; сетевой сбой не клеймит эндпоинт навсегда. */
function probeEndpoint(url) {
  const known = endpointState.get(url);
  if (known === 'ok') return Promise.resolve(true);
  // 'wrong-chain' — чужая сеть, доверять нельзя;
  // 'limited'     — сеть та, но нужных методов у эндпоинта нет (см. dRPC выше):
  //                 достаточно узнать это один раз, а не на каждом из ~15 вызовов.
  if (known === 'wrong-chain' || known === 'limited') return Promise.resolve(false);
  if (!endpointProbe.has(url)) {
    endpointProbe.set(url, (async () => {
      try {
        const id = await rpcOnce(url, 'eth_chainId', []);
        const ok = /^0x[0-9a-fA-F]+$/.test(String(id)) && parseInt(id, 16) === CONFIG.chain.id;
        endpointState.set(url, ok ? 'ok' : 'wrong-chain');
        return ok;
      } catch (_) {
        endpointProbe.delete(url);   // мог моргнуть интернет — дадим шанс позже
        return false;
      }
    })());
  }
  return endpointProbe.get(url);
}

async function rpc(method, params) {
  let lastErr = null;
  for (const url of rpcOrder()) {
    let usable;
    try { usable = await probeEndpoint(url); } catch (_) { usable = false; }
    if (!usable) { lastErr = lastErr || new Error('endpoint unusable'); continue; }

    try {
      const result = await rpcOnce(url, method, params);
      activeRpc = url;
      return result;
    } catch (e) {
      if (e && e.fromNode && !isEndpointFault(e)) { activeRpc = url; throw e; } // это ответ контракта
      // «метода нет» — свойство эндпоинта, а не разовый сбой: запоминаем,
      // чтобы остальные вызовы этого обновления его не дёргали.
      if (e && e.fromNode && e.code === -32601) endpointState.set(url, 'limited');
      lastErr = e;
      if (activeRpc === url) activeRpc = null;
    }
  }
  const err = new Error(t('rpc.allFailed', { count: rpcList().length }));
  err.allEndpointsDown = true;
  err.cause = lastErr;
  throw err;
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

/* ─────────────────────────────────────────────────────────────────────────
 *  СОСТОЯНИЕ ОТРИСОВКИ.
 *
 *  Всё, что нарисовано из данных, хранится здесь в сыром виде. Переключение
 *  языка вызывает те же функции отрисовки заново — сеть при этом не трогаем,
 *  и уже прочитанные значения не теряются.
 * ───────────────────────────────────────────────────────────────────────── */

const state = {
  account: null,
  quote: null,      // { valueWei, minTokensOut, tokensOut, minutes } — для отправки транзакции
  sellQuote: null   // { amount, minEthOut, minutes }
};

const view = {
  chain:     null,  // { kind: 'data' | 'noAddresses' | 'allDown', … }
  status:    null,  // { key, params, kind }
  quote:     null,  // сырая котировка покупки для перерисовки
  sellQuote: null,  // то же для продажи
  sellLimit: null,  // { bought, balance, max }
  msg:       null,  // сообщение под панелью
  wallet:    null   // { account, bought } | { key }
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
  a.textContent = t('card.link.explorer');
  links.appendChild(a);

  const det = document.createElement('details');
  const sum = document.createElement('summary');
  sum.textContent = t('card.link.repeat');
  const pre = document.createElement('pre');
  pre.className = 'code-block';
  const code = document.createElement('code');

  const url = rpcUrl();

  const body = kind === 'storage'
    ? `{"jsonrpc":"2.0","id":1,"method":"eth_getStorageAt","params":["${addr}","${slot}","latest"]}`
    : `{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"${addr}","data":"${data}"},"latest"]}`;

  const cast = kind === 'storage'
    ? `cast storage ${addr} ${slot} --rpc-url ${url}`
    : `cast call ${addr} "${sig}" --rpc-url ${url}`;

  code.textContent =
    `curl -s ${url} \\\n  -H 'content-type: application/json' \\\n  -d '${body}'\n\n${cast}`;
  pre.appendChild(code);
  det.append(sum, pre);
  links.appendChild(det);
}

const CARD_IDS = ['m-epoch', 'm-epochamount', 'm-emissionend', 'm-supply', 'm-sold', 'm-price',
                  'm-reserve', 'm-weight', 'm-identity', 'm-proxy'];

function cardUnavailable(id, reason) {
  setCard(id, { value: reason, state: 'pending' });
}

function pendingCards(msg) {
  CARD_IDS.forEach((id) => cardUnavailable(id, msg));
}

function failedCards(msg) {
  CARD_IDS.forEach((id) => setCard(id, { value: msg, state: 'error' }));
}

/* ── статус чтения ─────────────────────────────────────────────────────── */

function renderStatus() {
  const el = $('#status-text');
  if (!el) return;
  if (!view.status) { el.textContent = ''; el.className = 'status-text'; return; }
  el.textContent = t(view.status.key, view.status.params);
  el.className = 'status-text' + (view.status.kind ? ' is-' + view.status.kind : '');
}

function setStatus(key, params = null, kind = '') {
  view.status = { key, params, kind };
  renderStatus();
}

/* ── чтение с цепочки ──────────────────────────────────────────────────── */

async function refresh() {
  const { token: T, emission: E, curve: C, vesting: V } = CONFIG.contracts;
  const anySet = isSet(T) || isSet(E) || isSet(C);

  if (!anySet) {
    view.chain = { kind: 'noAddresses' };
    renderChain();
    return;
  }

  setStatus('status.reading');

  const tasks = { block: rpc('eth_blockNumber') };

  if (isSet(T)) {
    tasks.totalSupply = ethCall(T, SEL.totalSupply);
    tasks.name        = ethCall(T, SEL.name);
    tasks.symbol      = ethCall(T, SEL.symbol);
    tasks.decimals    = ethCall(T, SEL.decimals);
    tasks.implSlot    = rpc('eth_getStorageAt', [T, EIP1967.impl, 'latest']);
    tasks.adminSlot   = rpc('eth_getStorageAt', [T, EIP1967.admin, 'latest']);

    /* Балансы, которые НЕ находятся в обращении: сожжённое, нераспределённая
       эмиссия, казна под замком и остаток инвентаря кривой. Обращение — это
       сапплай минус они, а не весь сапплай: иначе капитализация посчиталась
       бы по монетам, которых ни у кого нет. */
    tasks.balDead = ethCall(T, SEL.balanceOf + argAddr(DEAD_ADDR));
    if (isSet(E)) tasks.balEmission = ethCall(T, SEL.balanceOf + argAddr(E));
    if (isSet(C)) tasks.balCurve    = ethCall(T, SEL.balanceOf + argAddr(C));
    if (isSet(V)) tasks.balVesting  = ethCall(T, SEL.balanceOf + argAddr(V));
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
    setStatus('rpc.failed', { reason: e.message || String(e) }, 'error');
    return;
  }

  /* Награда текущей эпохи: аргумент известен только после currentEpoch(),
     поэтому вторым шагом и до отрисовки — чтобы карточки обновлялись разом. */
  let epochAmt = null;
  if (isSet(E) && r.currentEpoch && r.currentEpoch.ok) {
    const n = uint(r.currentEpoch.value);
    const nq = n > 26n ? 26n : n;
    const data = SEL.epochAmount + argUint(nq);
    try {
      epochAmt = { ok: true, nq, data, value: uint(await ethCall(E, data)) };
    } catch (e) {
      epochAmt = { ok: false, nq, data, error: e };
    }
  }

  const total  = Object.keys(r).length;
  const failed = Object.values(r).filter((x) => !x.ok).length;

  if (failed === total) {
    // Ни один вызов не прошёл. Показывать нули или прочерки нельзя: ноль в поле
    // «распродано» читается как факт. Если прошлые данные есть — оставляем их,
    // но честно помечаем, что это не сейчас.
    if (view.chain && view.chain.kind === 'data') {
      view.chain.stale = true;
    } else {
      view.chain = { kind: 'allDown' };
    }
    renderChain();
    return;
  }

  view.chain = {
    kind: 'data',
    r, epochAmt,
    at: new Date(),
    endpoint: rpcUrl(),
    total, failed,
    stale: false
  };
  renderChain();
  renderVerifyCommands();   // эндпоинт в примерах команд — тот, который ответил
}

function renderChain() {
  const ch = view.chain;
  if (!ch) return;

  // Панель продажи и сводка живут из тех же данных, что и карточки, —
  // считаем их первыми, чтобы ранние выходы ниже не оставили прошлые числа.
  renderSale();
  renderMarket();

  if (ch.kind === 'noAddresses') {
    pendingCards(t('card.na.address'));
    setStatus('status.noAddresses', null, 'error');
    return;
  }

  if (ch.kind === 'allDown') {
    failedCards(t('card.err.noData'));
    setStatus('status.allDown', { count: rpcList().length }, 'error');
    return;
  }

  const { token: T, emission: E, curve: C } = CONFIG.contracts;
  const r   = ch.r;
  const dec = CONFIG.token.decimals;
  const sym = CONFIG.token.symbol;
  const gas = CONFIG.chain.currency.symbol;

  /* — эпоха и награда эпохи — */
  if (isSet(E)) {
    if (r.currentEpoch.ok) {
      const n = uint(r.currentEpoch.value);
      const finished = n > 26n;
      setCard('m-epoch', {
        value: finished ? t('epoch.done') : t('epoch.of', { n }),
        sub: finished ? t('epoch.raw', { n }) : t('epoch.len'),
        addr: E, sig: 'currentEpoch()(uint256)', data: SEL.currentEpoch
      });

      const ea = ch.epochAmt;
      if (ea && ea.ok) {
        setCard('m-epochamount', {
          value: `${formatUnits(ea.value, dec)} ${sym}`,
          sub: t('epochAmount.sub', { raw: ea.value, n: ea.nq }) + (finished ? t('epochAmount.last') : ''),
          addr: E, sig: 'epochAmount(uint256)(uint256)', data: ea.data
        });
      } else if (ea) {
        setCard('m-epochamount', {
          value: t('card.err.call'), sub: String((ea.error && ea.error.message) || ea.error || ''),
          addr: E, sig: 'epochAmount(uint256)(uint256)', data: ea.data, state: 'error'
        });
      } else {
        cardUnavailable('m-epochamount', t('card.na.epoch'));
      }
    } else {
      setCard('m-epoch', {
        value: t('card.err.call'), sub: String((r.currentEpoch.error && r.currentEpoch.error.message) || ''),
        addr: E, sig: 'currentEpoch()(uint256)', data: SEL.currentEpoch, state: 'error'
      });
      cardUnavailable('m-epochamount', t('card.na.epoch'));
    }

    if (r.emissionEnd.ok) {
      const ts = uint(r.emissionEnd.value);
      const now = BigInt(Math.floor(Date.now() / 1000));
      setCard('m-emissionend', {
        value: fmtDate(ts),
        sub: `${fmtIsoUtc(ts)} · unix ${ts} · ` + (ts > now ? humanDelta(ts - now) : t('emissionEnd.done')),
        addr: E, sig: 'emissionEnd()(uint256)', data: SEL.emissionEnd
      });
    } else {
      setCard('m-emissionend', { value: t('card.err.call'), addr: E, sig: 'emissionEnd()(uint256)', data: SEL.emissionEnd, state: 'error' });
    }

    if (r.totalWeight.ok) {
      const w = uint(r.totalWeight.value);
      const st = r.totalStaked.ok ? uint(r.totalStaked.value) : null;
      setCard('m-weight', {
        value: formatUnits(w, dec, 6),
        sub: st === null
          ? t('weight.sub.raw', { raw: w })
          : t('weight.sub.staked', { staked: formatUnits(st, dec, 6), sym }),
        addr: E, sig: 'totalWeight()(uint256)', data: SEL.totalWeight
      });
    } else {
      setCard('m-weight', { value: t('card.err.call'), addr: E, sig: 'totalWeight()(uint256)', data: SEL.totalWeight, state: 'error' });
    }
  } else {
    ['m-epoch', 'm-epochamount', 'm-emissionend', 'm-weight'].forEach((id) => cardUnavailable(id, t('card.na.emission')));
  }

  /* — токен — */
  if (isSet(T)) {
    if (r.totalSupply.ok) {
      const s = uint(r.totalSupply.value);
      setCard('m-supply', {
        value: `${formatUnits(s, dec)} ${sym}`,
        sub: t('supply.sub', { raw: s }),
        addr: T, sig: 'totalSupply()(uint256)', data: SEL.totalSupply
      });
    } else {
      setCard('m-supply', { value: t('card.err.call'), addr: T, sig: 'totalSupply()(uint256)', data: SEL.totalSupply, state: 'error' });
    }

    const nm = r.name.ok ? decodeString(r.name.value) : '?';
    const sb = r.symbol.ok ? decodeString(r.symbol.value) : '?';
    const dc = r.decimals.ok ? uint(r.decimals.value) : '?';
    const matches = sb === CONFIG.token.symbol;
    setCard('m-identity', {
      value: `${nm} (${sb})`,
      sub: matches
        ? t('identity.sub.match', { dec: dc })
        : t('identity.sub.mismatch', { dec: dc, sym: CONFIG.token.symbol }),
      addr: T, sig: 'symbol()(string)', data: SEL.symbol,
      state: matches ? 'ok' : 'error'
    });

    const impl = r.implSlot.ok ? uint(r.implSlot.value) : null;
    const adm  = r.adminSlot.ok ? uint(r.adminSlot.value) : null;
    if (impl === null) {
      setCard('m-proxy', { value: t('proxy.unread'), addr: T, kind: 'storage', slot: EIP1967.impl, state: 'error' });
    } else if (impl === 0n && (adm === null || adm === 0n)) {
      setCard('m-proxy', {
        value: t('proxy.none'),
        sub: t('proxy.none.sub'),
        addr: T, kind: 'storage', slot: EIP1967.impl
      });
    } else {
      setCard('m-proxy', {
        value: t('proxy.present'),
        sub: t('proxy.present.sub', { impl: r.implSlot.value, admin: r.adminSlot.ok ? r.adminSlot.value : '?' }),
        addr: T, kind: 'storage', slot: EIP1967.impl, state: 'error'
      });
    }
  } else {
    ['m-supply', 'm-identity', 'm-proxy'].forEach((id) => cardUnavailable(id, t('card.na.token')));
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
        sub: t('sold.sub', { sold: formatUnits(sold, dec, 6), inv: formatUnits(inv, dec, 0), sym }),
        addr: C, sig: 'sold()(uint256)', data: SEL.sold
      });
    } else {
      setCard('m-sold', { value: t('card.err.call'), addr: C, sig: 'sold()(uint256)', data: SEL.sold, state: 'error' });
    }

    if (r.spotPrice.ok) {
      const p = uint(r.spotPrice.value);
      setCard('m-price', {
        value: `${formatUnits(p, 9)} gwei`,
        sub: t('price.sub', { raw: p, sym }),
        addr: C, sig: 'spotPrice()(uint256)', data: SEL.spotPrice
      });
    } else {
      setCard('m-price', { value: t('card.err.call'), addr: C, sig: 'spotPrice()(uint256)', data: SEL.spotPrice, state: 'error' });
    }

    if (r.reserve.ok) {
      const v = uint(r.reserve.value);
      setCard('m-reserve', {
        value: `${formatUnits(v, 18, 9)} ${gas}`,
        sub: t('reserve.sub', { raw: v, gas }),
        addr: C, sig: 'reserve()(uint256)', data: SEL.reserve
      });
    } else {
      setCard('m-reserve', { value: t('card.err.call'), addr: C, sig: 'reserve()(uint256)', data: SEL.reserve, state: 'error' });
    }
  } else {
    ['m-sold', 'm-price', 'm-reserve'].forEach((id) => cardUnavailable(id, t('card.na.curve')));
  }

  /* — строка статуса — */
  const time = fmtClock(ch.at);
  if (ch.stale) {
    setStatus('status.stale', { count: rpcList().length, time }, 'error');
    return;
  }
  const blk = ch.r.block.ok ? groupDigits(BigInt(ch.r.block.value).toString()) : '?';
  let host = '?';
  try { host = new URL(ch.endpoint).host; } catch (_) { host = ch.endpoint || '?'; }
  if (ch.failed === 0) {
    setStatus('status.updated', { time, block: blk, host }, 'ok');
  } else {
    setStatus('status.partial', { time, block: blk, failed: ch.failed }, 'error');
  }
}

/* ── статические подстановки: адреса, ссылки, команды проверки ──────────── */

function linkEl(text, href) {
  const a = document.createElement('a');
  a.href = href;
  a.target = '_blank';
  a.rel = 'noopener noreferrer';
  a.textContent = text;
  return a;
}

function renderAddresses() {
  const C = CONFIG.contracts.curve;

  $('#curve-address').textContent = isSet(C) ? C : ZERO_ADDR + t('addr.pending');

  const curveLinks = $('#curve-links');
  curveLinks.textContent = '';
  if (isSet(C)) {
    [[t('link.source'), ex.code(C)], [t('link.read'), ex.read(C)], [t('link.write'), ex.write(C)]]
      .forEach(([text, href]) => curveLinks.appendChild(linkEl(text, href)));
  } else {
    curveLinks.textContent = t('link.curvePending');
  }

  const sellLinks = $('#sell-links');
  sellLinks.textContent = '';
  if (isSet(C) && isSet(CONFIG.contracts.token)) {
    [[t('link.approve'), ex.write(CONFIG.contracts.token)], [t('link.sell'), ex.write(C)]]
      .forEach(([text, href]) => sellLinks.appendChild(linkEl(text, href)));
  } else {
    sellLinks.textContent = t('link.sellPending');
  }

  $$('[data-field="currency"]').forEach((el) => { el.textContent = CONFIG.chain.currency.symbol; });
  $$('[data-field="token"]').forEach((el) => { el.textContent = CONFIG.token.symbol; });
  $$('[data-field="rpc"]').forEach((el) => { el.textContent = rpcList()[0] || ''; });
  $$('[data-field="explorer"]').forEach((el) => { el.textContent = CONFIG.chain.explorer; });

  // Соцсети и хэндл — из CONFIG.links, чтобы адрес канала правился в одном
  // месте, а не в шести ссылках разметки.
  const social = [['#social-tg', CONFIG.links.telegram], ['#social-x', CONFIG.links.x], ['#social-gh', CONFIG.links.repo]];
  social.forEach(([sel, href]) => { const el = $(sel); if (el && href) el.href = href; });
  $$('a.social-pill').forEach((a) => {
    const svg = a.querySelector('use');
    const id = svg ? svg.getAttribute('href') : '';
    const href = id === '#i-tg' ? CONFIG.links.telegram : id === '#i-x' ? CONFIG.links.x : CONFIG.links.repo;
    if (href) a.href = href;
  });
  $$('.social-pill .handle').forEach((el) => { el.textContent = CONFIG.handle; });
}

function renderVerifyCommands() {
  const { token: T, emission: E, curve: C } = CONFIG.contracts;
  const url = rpcUrl();
  const lines = [
    t('verify.c1a'),
    t('verify.c1b'),
    `cast code ${T} --rpc-url ${url} > token.hex`,
    'grep -o -e 40c10f19 -e 8da5cb5b -e f2fde38b -e 3659cfe6 -e 8456cb59 token.hex',
    '',
    t('verify.c2'),
    `cast storage ${T} ${EIP1967.impl} --rpc-url ${url}`,
    '',
    t('verify.c3'),
    `cast call ${T} "totalSupply()(uint256)" --rpc-url ${url}`,
    '',
    t('verify.c4'),
    `cast call ${E} "epochAmount(uint256)(uint256)" 26 --rpc-url ${url}`,
    `cast call ${E} "epochAmount(uint256)(uint256)" 27 --rpc-url ${url}   # 0`,
    '',
    t('verify.c5'),
    `cast call ${E} "multiplier(uint256)(uint256)" 7 --rpc-url ${url}`,
    `cast call ${E} "E_FIXED()(uint256)" --rpc-url ${url}`,
    '',
    t('verify.c6'),
    `cast call ${C} "P0()(uint256)" --rpc-url ${url}`,
    `cast call ${C} "P_FINAL()(uint256)" --rpc-url ${url}`
  ];
  $('#verify-commands').firstElementChild.textContent = lines.join('\n');

  const box = $('#verified-sources');
  box.textContent = '';
  const items = [
    [t('src.token'), CONFIG.contracts.token],
    [t('src.emission'), CONFIG.contracts.emission],
    [t('src.curve'), CONFIG.contracts.curve],
    [t('src.vesting'), CONFIG.contracts.vesting]
  ];
  const parts = [];
  items.forEach(([title, addr]) => {
    if (!isSet(addr)) return;
    parts.push(linkEl(title, ex.code(addr)));
  });
  if (parts.length === 0) {
    box.textContent = t('src.pending');
  } else {
    parts.forEach((a) => box.appendChild(a));
  }
}

function renderLinkGrid() {
  const grid = $('#link-grid');
  grid.textContent = '';

  const items = [
    [t('grid.token'), CONFIG.contracts.token, (a) => ex.token(a)],
    [t('grid.emission'), CONFIG.contracts.emission, (a) => ex.code(a)],
    [t('grid.curve'), CONFIG.contracts.curve, (a) => ex.code(a)],
    [t('grid.vesting'), CONFIG.contracts.vesting, (a) => ex.code(a)],
    [t('grid.repo'), CONFIG.links.repo, (u) => u],
    [t('grid.audit'), CONFIG.links.audit, (u) => u],
    [t('grid.specToken'), CONFIG.links.specToken, (u) => u],
    [t('grid.specCurve'), CONFIG.links.specCurve, (u) => u],
    [t('grid.telegram'), CONFIG.links.telegram, (u) => u],
    [t('grid.x'), CONFIG.links.x, (u) => u]
  ];

  items.forEach(([title, target, hrefOf]) => {
    const card = document.createElement('div');
    card.className = 'link-card';
    const known = target && (isSet(target) || /^https?:\/\//.test(target));
    if (known) {
      const a = linkEl(title, hrefOf(target));
      a.className = 'link-title';
      const sub = document.createElement('span');
      sub.className = 'link-sub';
      // Для ссылки показываем host + путь без хвостового слэша: «t.me» само по
      // себе ничего не говорит, а «t.me/MaclaurinRHC» — говорит.
      sub.textContent = isSet(target)
        ? target
        : (new URL(target).host + new URL(target).pathname).replace(/\/$/, '');
      card.append(a, sub);
    } else {
      card.classList.add('is-missing');
      const el = document.createElement('span');
      el.className = 'link-title';
      el.textContent = title;
      const sub = document.createElement('span');
      sub.className = 'link-sub';
      sub.textContent = t('grid.missing');
      card.append(el, sub);
    }
    grid.appendChild(card);
  });
}

function renderChainBanner() {
  const anyMissing = Object.values(CONFIG.contracts).some((a) => !isSet(a));
  const b = $('#chain-banner');
  if (!anyMissing) { b.hidden = true; return; }
  b.hidden = false;
  b.textContent = t('chain.banner');
}

/* ── список контрактов ─────────────────────────────────────────────────── *
   Четыре адреса в одном месте, каждый с копированием и ссылкой на
   верифицированный исходник. Адреса берутся из CONFIG, а не из вёрстки:
   править их надо в одной строке, а не в четырёх местах разметки. */

const CONTRACT_ROWS = [
  ['token',    'grid.token',    'contract.desc.token'],
  ['emission', 'grid.emission', 'contract.desc.emission'],
  ['curve',    'grid.curve',    'contract.desc.curve'],
  ['vesting',  'grid.vesting',  'contract.desc.vesting']
];

function renderContracts() {
  const box = $('#contract-list');
  if (!box) return;
  box.textContent = '';

  CONTRACT_ROWS.forEach(([key, nameKey, descKey]) => {
    const addr = CONFIG.contracts[key];

    const row = document.createElement('div');
    row.className = 'contract-row';

    const name = document.createElement('div');
    name.className = 'contract-name';
    const n = document.createElement('span'); n.className = 'n'; n.textContent = t(nameKey);
    const d = document.createElement('span'); d.className = 'd'; d.textContent = t(descKey);
    name.append(n, d);

    const code = document.createElement('code');
    code.className = 'contract-addr';
    code.id = 'addr-' + key;
    code.textContent = isSet(addr) ? addr : t('contract.pending');

    const acts = document.createElement('div');
    acts.className = 'contract-acts';
    if (isSet(addr)) {
      const copy = document.createElement('button');
      copy.type = 'button';
      copy.className = 'btn btn-ghost';
      copy.dataset.copyTarget = code.id;
      copy.textContent = t('contract.copy');
      const link = linkEl(t('contract.explorer'), key === 'token' ? ex.token(addr) : ex.code(addr));
      link.className = 'btn btn-ghost';
      acts.append(copy, link);
    }

    row.append(name, code, acts);
    box.appendChild(row);
  });
}

/* ── панель продажи в hero ─────────────────────────────────────────────── *
   Тот же приём, что и в карточках: если данных нет, стоит прочерк, а не ноль.
   Ноль в поле «остаток инвентаря» читался бы как «всё распродано». */

function setLiveDot(kind) {
  const dot = $('#live-dot');
  if (!dot) return;
  dot.className = 'dot' + (kind ? ' is-' + kind : '');
}

function setProgress(pct) {
  const bar = $('#sale-progress');
  const fill = $('#sale-progress-fill');
  if (!bar || !fill) return;
  if (pct === null) {
    fill.style.width = '0%';
    bar.removeAttribute('aria-valuenow');
    return;
  }
  const clamped = Math.max(0, Math.min(100, pct));
  fill.style.width = clamped + '%';
  bar.setAttribute('aria-valuenow', clamped.toFixed(2));
}

function renderSale() {
  const set = (sel, text) => { const el = $(sel); if (el) el.textContent = text; };
  const DASH = '—';

  const chainEl = $('#sale-chain');
  if (chainEl) chainEl.textContent = 'chain ' + CONFIG.chain.id;

  const ch = view.chain;
  if (!ch || ch.kind !== 'data') {
    ['#sale-price-value', '#sale-progress-pct', '#sale-remaining', '#sale-reserve', '#sale-epoch']
      .forEach((s) => set(s, DASH));
    set('#sale-price-unit', '');
    setProgress(null);
    setLiveDot(ch && (ch.kind === 'allDown' || ch.kind === 'noAddresses') ? 'down' : null);
    return;
  }

  const r = ch.r;
  const dec = CONFIG.token.decimals;
  const sym = CONFIG.token.symbol;
  const gas = CONFIG.chain.currency.symbol;

  if (r.spotPrice && r.spotPrice.ok) {
    set('#sale-price-value', formatUnits(uint(r.spotPrice.value), 9));
    set('#sale-price-unit', 'gwei / ' + sym);
  } else {
    set('#sale-price-value', DASH);
    set('#sale-price-unit', '');
  }

  if (r.sold && r.sold.ok && r.inventory && r.inventory.ok) {
    const sold = uint(r.sold.value);
    const inv  = uint(r.inventory.value);
    // Проценты считаем в целых числах и делим один раз в конце: у BigInt нет
    // дробей, а Number(sold)/Number(inv) на таких величинах уже теряет точность.
    const ppm = inv > 0n ? Number((sold * 1000000n) / inv) / 10000 : 0;
    set('#sale-progress-pct', ppm.toFixed(4) + '%');
    setProgress(ppm);
    set('#sale-remaining', formatUnits(inv - sold, dec, 0) + ' ' + sym);
  } else {
    set('#sale-progress-pct', DASH);
    setProgress(null);
    set('#sale-remaining', DASH);
  }

  set('#sale-reserve', r.reserve && r.reserve.ok
    ? formatUnits(uint(r.reserve.value), 18, 9) + ' ' + gas
    : DASH);

  if (r.currentEpoch && r.currentEpoch.ok) {
    const n = uint(r.currentEpoch.value);
    set('#sale-epoch', n > 26n ? t('sale.epochDone') : t('sale.epochOf', { n }));
  } else {
    set('#sale-epoch', DASH);
  }

  setLiveDot(ch.stale || ch.failed > 0 ? 'down' : 'live');
}

/* ── кошелёк ───────────────────────────────────────────────────────────── */

function renderBuyMsg() {
  const el = $('#buy-message');
  if (!el) return;
  const m = view.msg;
  el.textContent = '';
  el.className = 'buy-message' + (m && m.kind ? ' is-' + m.kind : '');
  if (!m) return;

  if (m.hash) {
    el.textContent = t(m.sell ? 'sell.sent' : 'buy.sent');
    el.appendChild(linkEl(m.hash, ex.tx(m.hash)));
    return;
  }
  el.textContent = m.key ? t(m.key, m.params) : (m.text || '');
}

/** Сообщение по ключу словаря — переживает переключение языка. */
function buyMsg(key, params = null, kind = '') {
  view.msg = key ? { key, params, kind } : null;
  renderBuyMsg();
}
/** Сообщение готовым текстом (причина от узла/кошелька) — не переводится. */
function buyMsgText(text, kind = '') {
  view.msg = text ? { text, kind } : null;
  renderBuyMsg();
}

/* ─────────────────────────────────────────────────────────────────────────
 *  ВЫБОР КОШЕЛЬКА — EIP-6963 (Multi Injected Provider Discovery).
 *
 *  Почему не просто window.ethereum. Этот объект один, а расширений в браузере
 *  может стоять несколько: они дерутся за него при внедрении, и выигрывает то,
 *  которое отработало последним. Пользователь жмёт «подключить», а окно
 *  открывает не тот кошелёк, который он имел в виду. Хуже того, кошельки
 *  научились выставлять чужие флаги (isMetaMask ставит себе далеко не только
 *  MetaMask), так что и опознать победителя по объекту нельзя.
 *
 *  EIP-6963 переворачивает схему: страница бросает событие
 *  eip6963:requestProvider, а каждое расширение отвечает своим
 *  eip6963:announceProvider с парой {info, provider}. Мы собираем все ответы и
 *  даём выбрать явно. Слушатель ставится ДО запроса — расширение, успевшее
 *  объявиться раньше нас, иначе потеряется.
 * ───────────────────────────────────────────────────────────────────────── */

const LS_WALLET = 'maclrn.wallet';

const wallet = {
  found: new Map(),   // rdns → { info, provider, legacy }
  active: null,       // выбранная запись
  busy: false
};

const boundProviders = new WeakSet();   // чтобы не навесить обработчики дважды
let autoTried = false;

/* Иконка приходит из расширения — это чужой ввод, а не наш файл. EIP-6963
   требует именно data-URI; всё остальное (http, blob:, javascript:) отклоняем.
   Внешний URL здесь — это ещё и утечка: узел на том конце узнал бы, что
   пользователь открыл эту страницу. */
const SAFE_ICON = /^data:image\/(png|jpeg|jpg|gif|webp|svg\+xml);/i;

function activeProvider() { return wallet.active ? wallet.active.provider : null; }

function announceHandler(event) {
  const d = event && event.detail;
  if (!d || !d.provider || !d.info) return;
  const rdns = typeof d.info.rdns === 'string' ? d.info.rdns : '';
  if (!rdns || wallet.found.has(rdns)) return;
  wallet.found.set(rdns, { info: d.info, provider: d.provider, legacy: false });
  onWalletsChanged();
}

function discoverWallets() {
  window.addEventListener('eip6963:announceProvider', announceHandler);
  window.dispatchEvent(new Event('eip6963:requestProvider'));
}

/* Флаги, которыми кошельки метили window.ethereum до EIP-6963. Это эвристика,
   а не стандарт: Rabby стоит перед MetaMask потому, что сам выставляет
   isMetaMask ради совместимости. Такие записи помечаются в списке как legacy —
   догадку не стоит выдавать за факт. */
const LEGACY_FLAGS = [
  ['isRabby', 'Rabby'],
  ['isMetaMask', 'MetaMask'],
  ['isCoinbaseWallet', 'Coinbase Wallet'],
  ['isBraveWallet', 'Brave Wallet'],
  ['isTrust', 'Trust Wallet'],
  ['isOkxWallet', 'OKX Wallet'],
  ['isPhantom', 'Phantom']
];

function legacyName(p) {
  for (let i = 0; i < LEGACY_FLAGS.length; i++) {
    if (p && p[LEGACY_FLAGS[i][0]]) return LEGACY_FLAGS[i][1];
  }
  return null;
}

/** Запасной путь через window.ethereum — только если никто не объявился. */
function legacyEntries() {
  const eth = typeof window !== 'undefined' ? window.ethereum : null;
  if (!eth) return [];
  const list = Array.isArray(eth.providers) && eth.providers.length ? eth.providers : [eth];
  return list.map((p, i) => ({
    info: { uuid: 'legacy-' + i, rdns: 'legacy:' + i, name: legacyName(p) || t('wm.legacyName'), icon: '' },
    provider: p,
    legacy: true
  }));
}

function walletChoices() {
  if (wallet.found.size > 0) return Array.from(wallet.found.values());
  return legacyEntries();
}

function hasWallet() { return walletChoices().length > 0; }

/* ── модалка выбора ────────────────────────────────────────────────────── */

/** Строка состояния внутри окна выбора: kind='note' — обычная, иначе ошибка. */
function wmError(text, kind) {
  const el = $('#wm-error');
  if (!el) return;
  el.textContent = text || '';
  el.className = 'wm-error' + (kind === 'note' ? ' is-note' : '');
}

function walletButton(entry, last) {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'wm-item';

  if (typeof entry.info.icon === 'string' && SAFE_ICON.test(entry.info.icon)) {
    const img = document.createElement('img');
    img.className = 'wm-icon';
    img.src = entry.info.icon;
    img.alt = '';
    b.appendChild(img);
  } else {
    const box = document.createElement('span');
    box.className = 'wm-icon wm-icon-fallback';
    box.textContent = String(entry.info.name || '?').trim().charAt(0).toUpperCase();
    b.appendChild(box);
  }

  const text = document.createElement('span');
  text.className = 'wm-text';
  const name = document.createElement('span');
  name.className = 'wm-name';
  // textContent, а не innerHTML: имя приходит из расширения, это не наш текст.
  name.textContent = entry.info.name || entry.info.rdns;
  const rdns = document.createElement('span');
  rdns.className = 'wm-rdns';
  rdns.textContent = entry.legacy ? t('wm.legacyRdns') : entry.info.rdns;
  text.append(name, rdns);
  b.appendChild(text);

  if (entry.legacy || (last && last === entry.info.rdns)) {
    const tag = document.createElement('span');
    tag.className = 'wm-tag' + (entry.legacy ? '' : ' is-last');
    tag.textContent = entry.legacy ? t('wm.tag.legacy') : t('wm.tag.last');
    b.appendChild(tag);
  }

  b.addEventListener('click', () => connectWith(entry));
  return b;
}

function renderWalletList() {
  const list = $('#wm-list');
  const empty = $('#wm-empty');
  if (!list) return;

  const choices = walletChoices();
  const last = lsGet(LS_WALLET);

  list.textContent = '';
  choices.forEach((entry) => list.appendChild(walletButton(entry, last)));
  if (empty) empty.hidden = choices.length > 0;
}

function openWalletModal() {
  const dlg = $('#wallet-modal');
  if (!dlg) return;
  wmError('');
  renderWalletList();
  // showModal даёт фокус-ловушку, закрытие по Esc и инертный фон бесплатно.
  if (typeof dlg.showModal === 'function') { if (!dlg.open) dlg.showModal(); }
  else dlg.setAttribute('open', '');
}

function closeWalletModal() {
  const dlg = $('#wallet-modal');
  if (!dlg) return;
  if (typeof dlg.close === 'function' && dlg.open) dlg.close();
  else dlg.removeAttribute('open');
}

/* ── подключение ───────────────────────────────────────────────────────── */

async function connectWith(entry) {
  if (wallet.busy) return;
  wallet.busy = true;
  $$('.wm-item').forEach((b) => { b.disabled = true; });
  wmError('');

  const label = entry.info.name || entry.info.rdns;
  wmError(t('wm.connecting', { name: label }), 'note');
  buyMsg('wm.connecting', { name: label });

  try {
    const accounts = await entry.provider.request({ method: 'eth_requestAccounts' });
    const account = accounts && accounts[0] ? accounts[0] : null;
    if (!account) throw new Error(t('wallet.noAddress'));

    wallet.active = entry;
    state.account = account;
    bindProviderEvents(entry.provider);

    await ensureChain(entry.provider);

    // Запоминаем только устойчивый идентификатор из стандарта. Индекс legacy
    // ничего не значит между перезагрузками, поэтому его не сохраняем.
    if (!entry.legacy) lsSet(LS_WALLET, entry.info.rdns);

    wmError('');
    closeWalletModal();
    await showWallet();
    buyMsg(null);
  } catch (e) {
    wallet.active = null;
    state.account = null;
    view.wallet = null;
    renderWallet();
    renderConnectButtons();
    wmError(walletError(e));
    buyMsgText(walletError(e), 'error');
  } finally {
    wallet.busy = false;
    $$('.wm-item').forEach((b) => { b.disabled = false; });
  }
}

function connect() {
  if (!hasWallet()) {
    $('#no-wallet').hidden = false;
    buyMsg('wallet.notFound', null, 'error');
    return;
  }
  openWalletModal();
}

/** Локальный сброс. Кошелёк «отключить» снаружи нельзя — только забыть у себя. */
function disconnectWallet() {
  wallet.active = null;
  state.account = null;
  state.quote = null;
  view.wallet = null;
  view.quote = null;
  lsSet(LS_WALLET, '');
  $('#do-buy').disabled = true;
  renderQuote();
  renderWallet();
  renderConnectButtons();
  buyMsg('wallet.forgotten');
}

function bindProviderEvents(p) {
  if (!p || typeof p.on !== 'function' || boundProviders.has(p)) return;
  boundProviders.add(p);
  p.on('accountsChanged', (accs) => {
    if (activeProvider() !== p) return;                 // события чужого провайдера игнорируем
    state.account = accs && accs[0] ? accs[0] : null;
    if (!state.account) { disconnectWallet(); return; } // отключили сайт в кошельке
    showWallet();
  });
  p.on('chainChanged', () => { if (activeProvider() === p) showWallet(); });
}

/** Тихое восстановление сессии: eth_accounts не открывает окно кошелька. */
async function maybeAutoReconnect() {
  if (autoTried || state.account) return;
  const last = lsGet(LS_WALLET);
  if (!last) return;
  const entry = wallet.found.get(last);
  if (!entry) return;               // мог не успеть объявиться — попробуем на следующем announce
  autoTried = true;
  try {
    const accounts = await entry.provider.request({ method: 'eth_accounts' });
    if (!accounts || !accounts[0]) return;
    wallet.active = entry;
    state.account = accounts[0];
    bindProviderEvents(entry.provider);
    
    // Automatically switch to correct network on reconnect
    try {
      await ensureChain(entry.provider);
    } catch (e) {
      // If user rejects, we still show the wallet but they must switch later
    }
    
    await showWallet();
  } catch (_) { /* тихо: кнопка подключения на месте */ }
}

function onWalletsChanged() {
  const dlg = $('#wallet-modal');
  if (dlg && dlg.open) renderWalletList();
  if (hasWallet()) {
    const nw = $('#no-wallet');
    if (nw) nw.hidden = true;
    [$('#connect'), $('#connect-header')].forEach((b) => { if (b) b.disabled = false; });
    if (view.wallet && view.wallet.key === 'wallet.noExt') { view.wallet = null; renderWallet(); }
  }
  maybeAutoReconnect();
}

/* ── сеть ──────────────────────────────────────────────────────────────── */

async function ensureChain(provider) {
  const p = provider || activeProvider();
  if (!p) throw new Error(t('buy.noWallet'));

  const current = await p.request({ method: 'eth_chainId' });
  if (parseInt(current, 16) === CONFIG.chain.id) return;

  try {
    await p.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: CONFIG.chain.idHex }]
    });
  } catch (e) {
    const code = e && (e.code ?? (e.data && e.data.originalError && e.data.originalError.code));
    if (code !== 4902) throw e;
    // Сети нет в кошельке — предлагаем добавить. Параметры видны пользователю
    // в окне кошелька, и там же он их подтверждает.
    await p.request({
      method: 'wallet_addEthereumChain',
      params: [{
        chainId: CONFIG.chain.idHex,
        chainName: CONFIG.chain.name,
        nativeCurrency: {
          name: CONFIG.chain.currency.name,
          symbol: CONFIG.chain.currency.symbol,
          decimals: CONFIG.chain.currency.decimals
        },
        // Кошельку отдаём только основной узел. Резервные из rpcs годятся
        // странице (она умеет их пропускать), но кошелёк выберет любой из
        // списка и на первом же eth_call получит -32601 — тогда сломается
        // не страница, а кошелёк пользователя.
        rpcUrls: [rpcList()[0]],
        blockExplorerUrls: [CONFIG.chain.explorer]
      }]
    });
  }

  const after = await p.request({ method: 'eth_chainId' });
  if (parseInt(after, 16) !== CONFIG.chain.id) {
    throw new Error(t('wallet.wrongChain', { chain: CONFIG.chain.id }));
  }
}

/* ── отрисовка состояния кошелька ──────────────────────────────────────── */

function renderWallet() {
  const el = $('#wallet-state');
  const av = $('#wallet-avatar');
  if (!el) return;
  const w = view.wallet;

  if (av) {
    if (w && w.icon) { av.src = w.icon; av.hidden = false; }
    else { av.removeAttribute('src'); av.hidden = true; }
  }

  if (!w || !w.account) { el.textContent = t((w && w.key) || 'wallet.none'); return; }

  let s = w.name
    ? t('wallet.named', { name: w.name, addr: shortAddr(w.account), chain: w.chainId })
    : t('wallet.connected', { addr: shortAddr(w.account), chain: w.chainId });
  if (w.bought !== null && w.bought !== undefined) {
    s += t('wallet.buyback', { amount: formatUnits(w.bought, CONFIG.token.decimals, 6), sym: CONFIG.token.symbol });
  }
  el.textContent = s;
}

/** Кнопки «подключить» в шапке и в панели показывают адрес, когда он есть. */
function renderConnectButtons() {
  const connected = !!(view.wallet && view.wallet.account);
  const dc = $('#disconnect');
  if (dc) dc.hidden = !connected;
  const label = connected ? shortAddr(view.wallet.account) : t('buy.connect');
  [$('#connect'), $('#connect-header')].forEach((b) => { if (b) b.textContent = label; });
}

async function showWallet() {
  if (!state.account) { view.wallet = null; renderWallet(); renderConnectButtons(); return; }

  const p = activeProvider();
  let chainId = null;
  if (p) {
    try { chainId = parseInt(await p.request({ method: 'eth_chainId' }), 16); } catch (_) { /* не критично */ }
  }

  let bought = null;
  if (isSet(CONFIG.contracts.curve)) {
    try {
      bought = uint(await ethCall(CONFIG.contracts.curve, SEL.boughtOf + argAddr(state.account)));
    } catch (_) { /* не критично для покупки */ }
  }

  const info = wallet.active ? wallet.active.info : null;
  view.wallet = {
    account: state.account,
    name: info ? (info.name || info.rdns) : null,
    icon: info && typeof info.icon === 'string' && SAFE_ICON.test(info.icon) ? info.icon : null,
    chainId: Number.isFinite(chainId) ? chainId : CONFIG.chain.id,
    bought
  };
  renderWallet();
  renderConnectButtons();
  refreshSellLimit();
}

function walletError(e) {
  if (!e) return t('wallet.unknown');
  const code = e.code ?? (e.data && e.data.originalError && e.data.originalError.code);
  if (code === 4001) return t('wallet.rejected');
  if (code === -32002) return t('wallet.pending');
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
  if (ERRORS[sel]) return t(ERRORS[sel]);
  if (sel === '0x08c379a0') {
    try { return t('wallet.reverted', { reason: decodeString('0x' + raw.slice(10)) }); } catch (_) { /* ignore */ }
  }
  return '';
}

/* ── котировка и покупка ───────────────────────────────────────────────── */

function readInputs() {
  const valueWei = parseUnits($('#in-amount').value, CONFIG.chain.currency.decimals);
  if (valueWei <= 0n) throw new Error(t('input.positive'));

  const slipBps = parseUnits($('#in-slippage').value || '0', 2); // 1.25% → 125 bps
  if (slipBps >= 10000n) throw new Error(t('input.slippage'));

  const minutes = Number(String($('#in-deadline').value).trim());
  if (!Number.isFinite(minutes) || minutes <= 0 || minutes > 1440) throw new Error(t('input.deadline'));

  return { valueWei, slipBps, minutes };
}

/** Перерисовка последней котировки — вызывается и при смене языка. */
function renderQuote() {
  const out = $('#quote-out');
  const q = view.quote;
  if (!out) return;
  if (!q) { out.hidden = true; out.textContent = ''; return; }

  const gas = CONFIG.chain.currency.symbol;
  const sym = CONFIG.token.symbol;
  const dec = CONFIG.token.decimals;

  const rows = [
    [t('quote.row.out'), `${formatUnits(q.tokensOut, dec, 8)} ${sym}`],
    [t('quote.row.min'), `${formatUnits(q.minTokensOut, dec, 8)} ${sym}`],
    [t('quote.row.fee'), `${formatUnits(q.fee, 18, 9)} ${gas}`],
    [t('quote.row.net'), `${formatUnits(q.netIn, 18, 9)} ${gas}`],
    [t('quote.row.avg'), t('quote.avg', { price: formatUnits(q.effective, 9), sym })]
  ];
  if (q.maxIn !== null) rows.push([t('quote.row.max'), t('quote.max', { amount: formatUnits(q.maxIn, 18, 9), gas })]);

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
  if (q.overInventory) {
    warnings.push(t('quote.warn.inventory', { amount: formatUnits(q.maxIn, 18, 9), gas }));
  }
  if (q.antiSnipeHit) {
    warnings.push(t('quote.warn.antiSnipe', { amount: formatUnits(q.antiMax, dec, 0), sym }));
  }
  if (warnings.length) {
    const p = document.createElement('p');
    p.className = 'footnote';
    p.textContent = warnings.join(' ');
    out.appendChild(p);
  }

  $('#calldata-preview').textContent =
    `to:    ${q.curve}\n` +
    `value: ${q.valueWei} wei (${formatUnits(q.valueWei, 18, 18)} ${gas})\n` +
    `data:  ${SEL.buy}\n` +
    `       ${argUint(q.minTokensOut)}   // minTokensOut\n` +
    `       ${argUint(q.deadline)}   ${t('quote.deadlineNote')}`;
}

/**
 * «Максимум» — это не баланс кошелька, а maxEthIn(): точная верхняя граница,
 * которую позволяет остаток инвентаря. Переплата сверх неё не возвращается
 * сдачей, а ревертит, поэтому величину берём с цепочки, а не считаем на глаз.
 */
async function fillMaxAmount() {
  const C = CONFIG.contracts.curve;
  if (!isSet(C)) { buyMsg('quote.noCurve', null, 'error'); return; }
  try {
    const v = uint(await ethCall(C, SEL.maxEthIn));
    $('#in-amount').value = formatUnits(v, CONFIG.chain.currency.decimals).replace(/\s/g, '');
    buyMsg(null);
  } catch (e) {
    buyMsg('buy.quick.maxFailed', { reason: e.message || String(e) }, 'error');
  }
}

async function quote(silent = false) {
  const C = CONFIG.contracts.curve;
  if (!isSet(C)) { buyMsg('quote.noCurve', null, 'error'); return null; }

  let inp;
  try { inp = readInputs(); } catch (e) { buyMsgText(e.message, 'error'); return null; }

  if (!silent) buyMsg('quote.working');

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
    if (minTokensOut <= 0n) throw new Error(t('quote.tooSmall'));

    const effective = tokensOut > 0n ? (netIn * 10n ** 18n) / tokensOut : 0n; // wei за 1 целый токен

    // Лимит первого часа читается с цепочки, а не берётся из текста страницы:
    // окно могло уже закрыться, и тогда предупреждать не о чем.
    let antiSnipeHit = false;
    let antiMax = 0n;
    if (aux.antiEnd.ok && aux.antiMax.ok) {
      const antiEnd = uint(aux.antiEnd.value);
      antiMax = uint(aux.antiMax.value);
      const now = BigInt(Math.floor(Date.now() / 1000));
      antiSnipeHit = now < antiEnd && tokensOut > antiMax;
    }

    view.quote = {
      curve: C,
      valueWei: inp.valueWei,
      minutes: inp.minutes,
      deadline: BigInt(Math.floor(Date.now() / 1000) + inp.minutes * 60),
      tokensOut, fee, netIn, minTokensOut, effective, maxIn,
      overInventory: maxIn !== null && inp.valueWei > maxIn,
      antiSnipeHit, antiMax
    };
    renderQuote();

    state.quote = { valueWei: inp.valueWei, minTokensOut, tokensOut, minutes: inp.minutes };
    $('#do-buy').disabled = false;

    if (!silent) buyMsg('quote.ok');
    return state.quote;
  } catch (e) {
    state.quote = null;
    $('#do-buy').disabled = true;
    const reason = decodeRevert(e);
    if (reason) buyMsgText(reason, 'error');
    else buyMsg('quote.failed', { reason: e.message || String(e) }, 'error');
    return null;
  }
}

async function doBuy() {
  const C = CONFIG.contracts.curve;
  if (!isSet(C)) { buyMsg('buy.noCurve', null, 'error'); return; }
  if (!hasWallet()) { $('#no-wallet').hidden = false; buyMsg('buy.noWallet', null, 'error'); return; }

  try {
    // Кошелёк ещё не выбран — открываем окно выбора и на этом останавливаемся.
    // Подписывать нечего, пока неизвестно, чем подписывать.
    if (!state.account) { connect(); return; }
    await ensureChain();

    // Котировка пересчитывается прямо перед отправкой: между «Рассчитать» и
    // «Купить» могли пройти чужие сделки, а minTokensOut обязан отражать
    // актуальную цену, иначе защита от проскальзывания бессмысленна.
    const q = await quote(true);
    if (!q) return;

    const deadline = BigInt(Math.floor(Date.now() / 1000) + q.minutes * 60);
    const data = SEL.buy + argUint(q.minTokensOut) + argUint(deadline);

    buyMsg('buy.confirmTx');

    const hash = await activeProvider().request({
      method: 'eth_sendTransaction',
      params: [{
        from: state.account,
        to: C,
        value: toHexQty(q.valueWei),
        data: '0x' + data.replace(/^0x/, '')
      }]
    });

    view.msg = { hash, kind: 'ok' };
    renderBuyMsg();

    setTimeout(() => { refresh(); showWallet(); loadTrades(true).then(() => loadActivity(true)); }, 8000);
  } catch (e) {
    buyMsgText(walletError(e), 'error');
  }
}

/* ─────────────────────────────────────────────────────────────────────────
 *  ГРАФИК.
 *
 *  Источник данных ровно один — события Bought и Sold самой кривой, снятые
 *  через eth_getLogs. Ни бэкенда, ни индексатора, ни котировок со стороны:
 *  свеча существует только там, где на цепочке была сделка. Если сделок нет,
 *  здесь пусто, и это честный ответ, а не повод дорисовать «историю».
 *
 *  Цена сделки считается так же, как её видит контракт: сумма в ETH без
 *  комиссии, делённая на количество токенов. Это средняя цена исполнения —
 *  та же величина, что в карточке spotPrice.
 * ───────────────────────────────────────────────────────────────────────── */

const chart = {
  // Источник истины — длина интервала в секундах; tfKey нужен только чтобы
  // подсветить кнопку пресета (у произвольного интервала кнопки нет).
  tfSec: TIMEFRAMES[CONFIG.chart.defaultTf] || 3600,
  tfKey: CONFIG.chart.defaultTf,
  mode: 'candles',
  trades: null,        // [{ts, priceWei, price, ethWei, tokens, kind, block, tx}]
  scanned: null,       // { from, to } — какой диапазон блоков реально прочитан
  loading: false,
  errorText: null,
  shape: null,         // { startWei, finalWei, inv, sold, spotWei } для режима кривой

  candles: null,       // серия, построенная для текущего интервала
  candlesTf: null,

  /* Окно просмотра — дробный диапазон индексов свечей [i0, i0+span).
     За края выходить можно намеренно: на биржах справа всегда есть воздух,
     а слева видно, что история кончилась. null — «ещё не считали». */
  i0: null,
  span: null,

  priceZoom: 1,        // множитель вертикального масштаба поверх автоподбора
  cross: null,         // {x, y} в координатах viewBox
  drag: null,          // {kind, x, y, i0, span, priceZoom, step}
  geom: null,          // геометрия последней отрисовки — нужна обработчикам
  bound: false
};

/* Пределы, за которые зум не пускаем: иначе одним движением колеса можно
   улететь в состояние, из которого не видно ни одной свечи. */
const VIEW = {
  minSpan: 8,
  maxSpan: 20000,
  maxSeries: 20000,    // потолок длины серии: ~5.5 часа на 1s, две недели на 1m
  minPriceZoom: 0.05,
  maxPriceZoom: 60,
  // Ниже этой ширины свечи пустые интервалы не рисуем: они всё равно
  // сливаются в сплошную полосу, а перерисовка тормозит.
  denseStepPx: 1.2,
  // Реальная сделка не должна становиться волоском и теряться среди заливки.
  minRealBodyPx: 2
};

const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

const SVG_NS = 'http://www.w3.org/2000/svg';

function svgEl(tag, attrs) {
  const el = document.createElementNS(SVG_NS, tag);
  if (attrs) Object.keys(attrs).forEach((k) => el.setAttribute(k, String(attrs[k])));
  return el;
}

/* ── чтение сделок с цепочки ───────────────────────────────────────────── */

async function loadTrades(force = false) {
  const C = CONFIG.contracts.curve;
  if (!isSet(C)) { chart.errorText = t('chart.noCurve'); renderChart(); return; }
  if (chart.loading) return;
  if (chart.trades && !force) return;

  chart.loading = true;
  chart.errorText = null;
  renderChart();

  try {
    const latest = Number(BigInt(await rpc('eth_blockNumber')));
    const from = CONFIG.chart.curveDeployBlock;
    const logs = await getLogsChunked(C, [[EVENTS.bought, EVENTS.sold]], from, latest);

    chart.trades = await decodeTrades(logs);
    chart.scanned = { from, to: latest };
    chart.candles = null;          // серия пересоберётся из новых сделок
    chart.candlesTf = null;
  } catch (e) {
    chart.trades = null;
    chart.errorText = t('chart.failed', { reason: (e && e.message) || String(e) });
  } finally {
    chart.loading = false;
    renderChart();
  }
}

/**
 * eth_getLogs по диапазону блоков кусками: публичные узлы почти всегда
 * ограничивают ширину окна, и запрос «от развёртывания до latest» одним
 * куском у части из них просто не пройдёт.
 */
async function getLogsChunked(address, topics, fromBlock, toBlock) {
  const step = CONFIG.chart.logChunk;
  const out = [];
  for (let start = fromBlock; start <= toBlock; start += step) {
    const end = Math.min(start + step - 1, toBlock);
    const part = await rpc('eth_getLogs', [{
      address,
      fromBlock: '0x' + start.toString(16),
      toBlock: '0x' + end.toString(16),
      topics
    }]);
    if (Array.isArray(part)) out.push.apply(out, part);
  }
  return out;
}

/* Времени в логах нет — оно только в заголовке блока. Кэш общий на страницу:
   график и журнал операций смотрят на одни и те же блоки, и перечитывать их
   по второму разу незачем. */
const blockTimeCache = new Map();

async function fetchBlockTimes(numbers) {
  const missing = numbers.filter((n) => !blockTimeCache.has(n));
  if (missing.length) {
    const tasks = {};
    missing.forEach((n) => { tasks[String(n)] = rpc('eth_getBlockByNumber', ['0x' + n.toString(16), false]); });
    const got = await settle(tasks);
    missing.forEach((n) => {
      const r = got[String(n)];
      blockTimeCache.set(n, r && r.ok && r.value && r.value.timestamp ? Number(BigInt(r.value.timestamp)) : null);
    });
  }
  return blockTimeCache;
}

async function decodeTrades(logs) {
  const blockNums = new Set();
  const rows = [];

  logs.forEach((log) => {
    const w = words(log.data);
    if (w.length < 4 || !log.topics || !log.topics[0]) return;
    const isBuy = log.topics[0].toLowerCase() === EVENTS.bought;

    // Bought: ethIn, fee, tokensOut, newSold  →  в резерв ушло ethIn − fee
    // Sold:   tokensIn, fee, ethOut, newSold  →  до вычета комиссии ethOut + fee
    const ethWei = isBuy ? w[0] - w[1] : w[2] + w[1];
    const tokens = isBuy ? w[2] : w[0];
    if (tokens <= 0n || ethWei <= 0n) return;

    const block = Number(BigInt(log.blockNumber));
    blockNums.add(block);

    const priceWei = (ethWei * 10n ** 18n) / tokens;   // wei за один целый токен
    rows.push({
      kind: isBuy ? 'buy' : 'sell',
      block,
      tx: log.transactionHash,
      priceWei,
      price: Number(priceWei),
      ethWei,
      tokens
    });
  });

  // Блоков со сделками на порядки меньше, чем блоков в сети, поэтому это
  // единицы запросов, а не тысячи.
  const times = await fetchBlockTimes(Array.from(blockNums));

  return rows
    .map((r) => { r.ts = times.get(r.block); return r; })
    .filter((r) => r.ts !== null && Number.isFinite(r.ts))
    .sort((a, b) => a.ts - b.ts || a.block - b.block);
}

/* ── свечи ─────────────────────────────────────────────────────────────── */

/**
 * Сделки → OHLCV по интервалам. Промежутки без сделок заполняются плоскими
 * свечами: без этого ось времени врала бы — две сделки с разницей в сутки
 * встали бы вплотную, как соседние минуты.
 *
 * Строится вся серия целиком, а не «последние N»: окно просмотра теперь
 * двигается пользователем, и ему должно быть куда двигаться.
 */
function buildCandles(trades, tfSec) {
  if (!trades || !trades.length) return [];
  const bucketOf = (ts) => Math.floor(ts / tfSec) * tfSec;

  const map = new Map();
  trades.forEach((tr) => {
    const b = bucketOf(tr.ts);
    let c = map.get(b);
    if (!c) { c = { t: b, o: tr.price, h: tr.price, l: tr.price, c: tr.price, v: 0, n: 0 }; map.set(b, c); }
    if (tr.price > c.h) c.h = tr.price;
    if (tr.price < c.l) c.l = tr.price;
    c.c = tr.price;
    c.v += Number(tr.ethWei) / 1e18;
    c.n += 1;
  });

  const first = bucketOf(trades[0].ts);
  const last = bucketOf(trades[trades.length - 1].ts);
  // 5-минутный интервал за год — это больше ста тысяч свечей, из которых
  // непустых единицы. Рисовать их незачем, поэтому хвост обрезаем.
  const start = Math.max(first, last - (VIEW.maxSeries - 1) * tfSec);

  let carry = null;
  Array.from(map.keys()).sort((a, b) => a - b).forEach((b) => { if (b < start) carry = map.get(b).c; });

  const out = [];
  for (let b = start; b <= last; b += tfSec) {
    const c = map.get(b);
    if (c) { out.push(c); carry = c.c; }
    else if (carry !== null) out.push({ t: b, o: carry, h: carry, l: carry, c: carry, v: 0, n: 0, empty: true });
  }
  // Секундный интервал на длинной истории упирается в потолок серии. Молча
  // показать «часть» и назвать это всей историей нельзя — помечаем.
  out.truncated = start > first;
  out.from = start;
  // Индексы свечей со сделками. На секундном интервале их единицы среди
  // тысяч пустых, и отрисовка ходит только по ним.
  out.real = [];
  out.forEach((c, i) => { if (!c.empty) out.real.push(i); });
  return out;
}

/** Серия для текущего интервала, с кэшем: пересчёт только при смене tf. */
function chartSeries() {
  if (!chart.trades || !chart.trades.length) return [];
  if (chart.candles && chart.candlesTf === chart.tfSec) return chart.candles;
  chart.candles = buildCandles(chart.trades, chart.tfSec);
  chart.candlesTf = chart.tfSec;
  return chart.candles;
}

function resetView() {
  chart.i0 = null;
  chart.span = null;
  chart.priceZoom = 1;
}

/**
 * Стартовое окно строится по данным, а не по фиксированному числу свечей.
 *
 * Раньше здесь было «последние 70 свечей» — на пятиминутках и выше это
 * совпадало со всей историей, а на секундах окно уезжало в пустоту: пять
 * сделок за 83 минуты на интервале 1s разнесены на тысячи свечей друг от
 * друга, и в кадр попадала одна. Теперь рамка охватывает реальные сделки.
 */
function ensureView(n, series, plotW) {
  if (Number.isFinite(chart.span) && Number.isFinite(chart.i0)) { clampView(n); return; }

  let first = -1;
  let last = -1;
  for (let i = 0; i < n; i++) {
    if (series[i].empty) continue;
    if (first < 0) first = i;
    last = i;
  }
  if (first < 0) { first = 0; last = Math.max(0, n - 1); }

  const dataSpan = Math.max(1, last - first + 1);
  // Порог низкий намеренно: пустые интервалы при таком масштабе не рисуются
  // вовсе, поэтому широкая рамка ничего не стоит, зато все сделки в кадре.
  const maxUseful = Math.max(VIEW.minSpan, plotW / 0.04);
  const span = clamp(dataSpan * 1.22 + 4, VIEW.minSpan, Math.min(VIEW.maxSpan, maxUseful));

  chart.span = span;
  chart.i0 = span >= dataSpan
    ? (first + last + 1) / 2 - span / 2      // всё влезло — центрируем
    : last + 1 - span * 0.94;                // не влезло — прижимаем к свежему
  clampView(n);
}

/** Уехать совсем в пустоту нельзя: часть серии всегда остаётся на экране. */
function clampView(n) {
  chart.span = clamp(chart.span, VIEW.minSpan, VIEW.maxSpan);
  const lo = -chart.span * 0.9;
  const hi = Math.max(lo, n - chart.span * 0.1);
  chart.i0 = clamp(chart.i0, lo, hi);
}

/** Шаг сетки из «круглых» чисел: 1, 2, 5 × 10^k. */
function niceStep(range, targetTicks) {
  if (!(range > 0)) return 1;
  const raw = range / Math.max(1, targetTicks);
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const norm = raw / mag;
  const mult = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 5 ? 5 : 10;
  return mult * mag;
}

const GWEI = 1e9;
const fmtGwei = (wei) => (wei / GWEI).toFixed(6).replace(/0+$/, '').replace(/\.$/, '');
/** Цена в gwei с фиксированной точностью — чтобы соседние деления шкалы различались. */
const fmtGweiAt = (wei, decimals) => (wei / GWEI).toFixed(clamp(decimals, 0, 9));

function intlTime(ts, opts) {
  const d = new Date(ts * 1000);
  try { return new Intl.DateTimeFormat(LOCALE[LANG], opts).format(d); }
  catch (_) { return d.toISOString().slice(5, 16).replace('T', ' '); }
}

const fmtClockShort = (ts) => intlTime(ts, { hour: '2-digit', minute: '2-digit' });
const fmtDateShort  = (ts) => intlTime(ts, { day: '2-digit', month: '2-digit' });
const fmtFullTime   = (ts) => intlTime(ts, { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });

/** Подпись деления оси времени: дату дописываем только когда день сменился. */
function fmtTickTime(ts, tfSec, withDate) {
  if (tfSec >= 86400) return fmtDateShort(ts);
  return withDate ? fmtDateShort(ts) + ' ' + fmtClockShort(ts) : fmtClockShort(ts);
}

/* ── отрисовка ─────────────────────────────────────────────────────────── */

function chartMessage(text) {
  const box = $('#chart-empty');
  const svg = $('#chart-svg');
  if (!box) return;
  if (!text) { box.hidden = true; return; }
  box.hidden = false;
  box.textContent = text;
  if (svg) svg.textContent = '';
}

/** Легенда O/H/L/C над полем — то, что в терминалах читают вместо тултипа. */
function setLegend(c, tfSec, decimals) {
  const el = $('#chart-legend');
  if (!el) return;
  if (!c) { el.hidden = true; el.textContent = ''; return; }

  el.hidden = false;
  el.textContent = '';
  const dir = c.c > c.o ? 'lg-up' : c.c < c.o ? 'lg-down' : '';

  const put = (key, value, cls) => {
    const span = document.createElement('span');
    if (cls) span.className = cls;
    if (key) { const b = document.createElement('b'); b.textContent = key; span.appendChild(b); span.appendChild(document.createTextNode(' ')); }
    span.appendChild(document.createTextNode(value));
    el.appendChild(span);
  };

  put('', fmtFullTime(c.t));
  put('O', fmtGweiAt(c.o, decimals), dir);
  put('H', fmtGweiAt(c.h, decimals), dir);
  put('L', fmtGweiAt(c.l, decimals), dir);
  put('C', fmtGweiAt(c.c, decimals), dir);
  put(t('chart.vol'), (c.v ? c.v.toFixed(6) : '0') + ' ' + CONFIG.chain.currency.symbol);
}

function renderChart() {
  const svg = $('#chart-svg');
  if (!svg) return;
  bindChartPointer();

  $$('.seg-btn[data-tf]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.tf === chart.tfKey ? 'true' : 'false'));
  $$('.seg-btn[data-mode]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.mode === chart.mode ? 'true' : 'false'));

  // Переключатель интервала имеет смысл только для свечей.
  const tfGroup = $('.seg-btn[data-tf]') ? $('.seg-btn[data-tf]').parentNode : null;
  if (tfGroup) tfGroup.style.display = chart.mode === 'candles' ? '' : 'none';

  const hint = $('#chart-hint');
  const hideChrome = () => { setLegend(null); if (hint) hint.hidden = true; };

  svg.textContent = '';
  const w = Math.max(320, Math.round(svg.clientWidth || svg.parentNode.clientWidth || 720));
  const h = Math.max(220, Math.round(svg.clientHeight || 380));
  svg.setAttribute('viewBox', `0 0 ${w} ${h}`);

  if (chart.mode === 'curve') { hideChrome(); chart.geom = null; renderCurveMode(svg, w, h); return; }

  if (chart.loading)   { chartMessage(t('chart.loading')); setChartStatus(''); hideChrome(); return; }
  if (chart.errorText) { chartMessage(chart.errorText);    setChartStatus(''); hideChrome(); return; }

  const all = chartSeries();
  if (!all.length) { chartMessage(t('chart.empty')); setChartStatus(''); hideChrome(); chart.geom = null; return; }

  chartMessage(null);
  if (hint) hint.hidden = false;
  drawCandles(svg, w, h, all);

  setChartStatus(t('chart.status', {
    trades: chart.trades.length,
    candles: all.length,
    tf: timeframeLabel(chart.tfSec),
    block: chart.scanned ? groupDigits(String(chart.scanned.from)) : '?'
  }) + (all.truncated ? ' · ' + t('chart.truncated', { from: fmtFullTime(all.from) }) : ''));
}

/**
 * Отрисовка свечей в текущем окне просмотра.
 *
 * Поле делится на две панели: цена сверху, объём снизу, у каждой своя шкала.
 * Справа — ценовая ось, снизу — временная; обе являются зонами захвата мыши,
 * поэтому масштаб по каждой оси тянется отдельно, как в торговых терминалах.
 */
function drawCandles(svg, w, h, all) {
  const n = all.length;

  const tfSec = chart.tfSec;
  const padL = 8;
  const padR = 68;                 // ценовая шкала справа
  const padT = 14;
  const padB = 26;                 // временная шкала снизу
  const plotW = Math.max(40, w - padL - padR);

  // Рамка зависит от ширины поля, поэтому считается после геометрии.
  ensureView(n, all, plotW);
  const totalH = Math.max(80, h - padT - padB);
  const volH = Math.round(totalH * 0.2);
  const gapH = 12;
  const priceH = totalH - volH - gapH;
  const priceTop = padT;
  const priceBot = padT + priceH;
  const volTop = priceBot + gapH;
  const volBot = volTop + volH;

  const step = plotW / chart.span;
  const xOf = (i) => padL + (i - chart.i0 + 0.5) * step;
  const iOf = (x) => chart.i0 + (x - padL) / step - 0.5;

  const iA = Math.max(0, Math.floor(chart.i0) - 1);
  const iB = Math.min(n, Math.ceil(chart.i0 + chart.span) + 1);

  /* Диапазон цен — по видимым свечам, а не по всей серии: иначе при
     приближении график остался бы плоской линией у края экрана. */
  let lo = Infinity;
  let hi = -Infinity;
  let volMax = 0;
  for (let i = iA; i < iB; i++) {
    const c = all[i];
    if (c.l < lo) lo = c.l;
    if (c.h > hi) hi = c.h;
    if (c.v > volMax) volMax = c.v;
  }
  if (!(lo < hi)) {
    const mid0 = Number.isFinite(lo) ? lo : (n ? all[n - 1].c : GWEI);
    const pad0 = Math.max(mid0 * 0.002, 1);
    lo = mid0 - pad0;
    hi = mid0 + pad0;
  }
  const mid = (lo + hi) / 2;
  const half = (((hi - lo) / 2) * 1.14) / chart.priceZoom;
  lo = mid - half;
  hi = mid + half;

  const yOf = (p) => priceBot - ((p - lo) / (hi - lo)) * priceH;
  const pOf = (y) => lo + ((priceBot - y) / priceH) * (hi - lo);

  const stepP = niceStep(hi - lo, 6);
  const decimals = clamp(Math.ceil(-Math.log10(stepP / GWEI)), 0, 9);

  chart.geom = { padL, padR, padT, padB, plotW, priceTop, priceBot, volTop, volBot, step, n, decimals, xOf, iOf, yOf, pOf };

  /* — сетка и ценовая шкала — */
  for (let p = Math.ceil(lo / stepP) * stepP; p <= hi; p += stepP) {
    const y = yOf(p);
    if (y < priceTop - 0.5 || y > priceBot + 0.5) continue;
    svg.appendChild(svgEl('line', { class: 'ch-grid', x1: padL, y1: y, x2: padL + plotW, y2: y }));
    const label = svgEl('text', { class: 'ch-axis', x: padL + plotW + 6, y: y + 3 });
    label.textContent = fmtGweiAt(p, decimals);
    svg.appendChild(label);
  }
  svg.appendChild(svgEl('line', { class: 'ch-sep', x1: padL, y1: volTop - gapH / 2, x2: padL + plotW, y2: volTop - gapH / 2 }));

  /* — подписи времени: шаг подбираем по пикселям, а не по индексам, иначе
       при узком графике метки наезжают друг на друга — */
  // Серия непрерывна по построению — в ней есть каждый интервал от первого
  // до последнего. Значит время любого слота, включая пустые поля слева и
  // справа от данных, считается точно, и ось подписана по всей ширине, а не
  // только там, где случились сделки.
  const timeAt = (i) => all[0].t + Math.round(i) * tfSec;

  const everyN = Math.max(1, Math.ceil(96 / step));
  let prevDay = null;
  for (let i = Math.ceil(chart.i0 / everyN) * everyN; i < chart.i0 + chart.span; i += everyN) {
    const x = xOf(i);
    const ts = timeAt(i);
    const day = Math.floor(ts / 86400);
    const text = fmtTickTime(ts, tfSec, prevDay === null || day !== prevDay);
    // Ширину оцениваем по числу знаков: подпись, не влезающую в поле,
    // обрезал бы край карточки, и получалось бы «08 12:00» вместо даты.
    const halfW = (text.length * 5.6) / 2 + 2;
    if (x - halfW < padL || x + halfW > padL + plotW) continue;
    prevDay = day;
    const el = svgEl('text', { class: 'ch-axis', x, y: volBot + 16, 'text-anchor': 'middle' });
    el.textContent = text;
    svg.appendChild(el);
  }
  const unit = svgEl('text', { class: 'ch-hint', x: padL + plotW + 6, y: volBot + 16 });
  unit.textContent = 'gwei';
  svg.appendChild(unit);

  /* — свечи и объём — */
  const bodyW = clamp(step * 0.7, 1, 26);
  const dense = step < VIEW.denseStepPx;
  const realW = Math.max(bodyW, VIEW.minRealBodyPx);
  let realInView = 0;

  const drawSlot = (i) => {
    const c = all[i];
    const cx = xOf(i);
    if (cx < padL - step || cx > padL + plotW + step) return;

    if (c.v > 0 && volMax > 0) {
      const bh = Math.max(1, (c.v / volMax) * volH);
      const dirV = c.c > c.o ? ' ch-up-v' : c.c < c.o ? ' ch-down-v' : '';
      svg.appendChild(svgEl('rect', {
        class: 'ch-vol' + dirV, x: cx - realW / 2, y: volBot - bh, width: realW, height: bh
      }));
    }

    // Интервал без сделок — не свеча, а перенос предыдущего закрытия.
    // Рисуем дожи-чертой, чтобы её нельзя было принять за торговлю.
    if (c.empty) {
      const y = yOf(c.c);
      if (y >= priceTop && y <= priceBot) {
        svg.appendChild(svgEl('line', {
          class: 'ch-wick ch-flat', x1: cx - bodyW / 2, y1: y, x2: cx + bodyW / 2, y2: y, opacity: 0.45
        }));
      }
      return;
    }

    realInView++;
    const cls = c.c > c.o ? 'ch-up' : c.c < c.o ? 'ch-down' : 'ch-flat';
    svg.appendChild(svgEl('line', { class: `ch-wick ${cls}`, x1: cx, y1: yOf(c.h), x2: cx, y2: yOf(c.l) }));
    const yTop = yOf(Math.max(c.o, c.c));
    const bodyH = Math.max(1, Math.abs(yOf(c.o) - yOf(c.c)));
    // Сделку рисуем шириной не меньше пары пикселей: на секундном интервале
    // свеча иначе становится волоском и теряется среди пустых.
    svg.appendChild(svgEl('rect', { class: cls, x: cx - realW / 2, y: yTop, width: realW, height: bodyH }));
  };

  if (dense) {
    // Пустые интервалы при таком масштабе всё равно сливаются в полосу, а их
    // тут тысячи. Идём только по сделкам — стоимость кадра перестаёт зависеть
    // от того, насколько далеко отдалён график.
    const real = all.real || [];
    for (let k = 0; k < real.length; k++) {
      const i = real[k];
      if (i >= iA && i < iB) drawSlot(i);
    }
  } else {
    for (let i = iA; i < iB; i++) drawSlot(i);
  }

  // Попасть окном в пустой промежуток легко — тогда прямо говорим об этом,
  // а не оставляем пустое поле без объяснений.
  if (realInView === 0) {
    let realTotal = 0;
    for (let i = 0; i < n; i++) if (!all[i].empty) realTotal++;
    const note = svgEl('text', {
      class: 'ch-hint', x: padL + plotW / 2, y: priceTop + (priceBot - priceTop) / 2, 'text-anchor': 'middle'
    });
    note.textContent = t('chart.noneInView', { n: realTotal });
    svg.appendChild(note);
  }

  /* — линия последней цены — */
  const lastC = all[n - 1];
  const yLast = yOf(lastC.c);
  if (yLast >= priceTop && yLast <= priceBot) {
    svg.appendChild(svgEl('line', { class: 'ch-last', x1: padL, y1: yLast, x2: padL + plotW, y2: yLast }));
    axisTag(svg, padL + plotW + 2, yLast, fmtGweiAt(lastC.c, decimals), 'ch-last-tag');
  }

  /* — перекрестие — */
  let legendCandle = lastC;
  const cr = chart.cross;
  if (cr && cr.x >= padL && cr.x <= padL + plotW && cr.y >= priceTop && cr.y <= volBot) {
    const idx = Math.round(iOf(cr.x));
    const cx = xOf(idx);
    svg.appendChild(svgEl('line', { class: 'ch-cross', x1: cx, y1: priceTop, x2: cx, y2: volBot }));
    if (cr.y <= priceBot) {
      svg.appendChild(svgEl('line', { class: 'ch-cross', x1: padL, y1: cr.y, x2: padL + plotW, y2: cr.y }));
      axisTag(svg, padL + plotW + 2, cr.y, fmtGweiAt(pOf(cr.y), decimals), 'ch-tag');
    }
    // Время показываем и над пустым полем: слот там есть, просто без сделок.
    axisTag(svg, cx, volBot + 11, fmtFullTime(timeAt(idx)), 'ch-tag', true, w);
    if (idx >= 0 && idx < n) legendCandle = all[idx];
  }
  setLegend(legendCandle, tfSec, decimals);
  updateLastPrice(all, iA, iB, decimals);

  /* — зоны захвата осей: добавляются последними, чтобы быть сверху и
       задавать курсор именно там, где начинается перетаскивание — */
  svg.appendChild(svgEl('rect', {
    class: 'ch-zone ch-zone-price', x: padL + plotW, y: priceTop, width: padR, height: volBot - priceTop
  }));
  svg.appendChild(svgEl('rect', {
    class: 'ch-zone ch-zone-time', x: padL, y: volBot, width: plotW, height: Math.max(1, h - volBot)
  }));
}

/**
 * Плашка на шкале: тёмный прямоугольник с бумажным текстом поверх.
 * limitW — ширина холста: у края плашка прижимается, а не уезжает за него.
 */
function axisTag(svg, x, y, text, cls, centered, limitW) {
  const chW = 5.6;
  const padX = 5;
  const boxW = text.length * chW + padX * 2;
  const boxH = 15;
  let bx = centered ? x - boxW / 2 : x;
  if (limitW) bx = clamp(bx, 0, Math.max(0, limitW - boxW));
  svg.appendChild(svgEl('rect', { class: cls || 'ch-tag', x: bx, y: y - boxH / 2, width: boxW, height: boxH, rx: 2 }));
  const el = svgEl('text', { class: 'ch-tag-text', x: bx + boxW / 2, y: y + 3.5, 'text-anchor': 'middle' });
  el.textContent = text;
  svg.appendChild(el);
}

/* ── управление мышью и касанием ───────────────────────────────────────── *
 *
 *  Обработчики висят на самом <svg>, а не на его детях: содержимое
 *  перерисовывается целиком на каждый кадр, и слушатели на элементах
 *  пришлось бы вешать заново по сто раз в секунду.
 *
 *  Какая ось тянется, определяется по координате, а не по цели события, —
 *  так перетаскивание не срывается, когда курсор ушёл за край зоны.
 */
function bindChartPointer() {
  if (chart.bound) return;
  const svg = $('#chart-svg');
  if (!svg) return;
  chart.bound = true;

  const pointAt = (e) => {
    const r = svg.getBoundingClientRect();
    const vb = svg.viewBox && svg.viewBox.baseVal;
    const sx = vb && vb.width && r.width ? vb.width / r.width : 1;
    const sy = vb && vb.height && r.height ? vb.height / r.height : 1;
    return { x: (e.clientX - r.left) * sx, y: (e.clientY - r.top) * sy };
  };

  const zoneAt = (p) => {
    const g = chart.geom;
    if (!g) return 'pan';
    if (p.x > g.padL + g.plotW) return 'price';
    if (p.y > g.volBot) return 'time';
    return 'pan';
  };

  let raf = null;
  const schedule = () => {
    if (raf) return;
    raf = requestAnimationFrame(() => { raf = null; renderChart(); });
  };

  svg.addEventListener('wheel', (e) => {
    if (chart.mode !== 'candles' || !chart.geom) return;
    e.preventDefault();
    const g = chart.geom;
    const p = pointAt(e);
    // Индекс под курсором обязан остаться на месте — иначе приближение
    // «уводит» график и им невозможно пользоваться.
    const anchor = chart.i0 + (p.x - g.padL) / g.step;
    chart.span = clamp(chart.span * (e.deltaY > 0 ? 1.15 : 1 / 1.15), VIEW.minSpan, VIEW.maxSpan);
    chart.i0 = anchor - (p.x - g.padL) / (g.plotW / chart.span);
    clampView(g.n);
    schedule();
  }, { passive: false });

  svg.addEventListener('pointerdown', (e) => {
    if (chart.mode !== 'candles' || !chart.geom) return;
    const p = pointAt(e);
    chart.drag = {
      kind: zoneAt(p),
      x: p.x, y: p.y,
      i0: chart.i0, span: chart.span, priceZoom: chart.priceZoom,
      step: chart.geom.step, plotW: chart.geom.plotW
    };
    try { svg.setPointerCapture(e.pointerId); } catch (_) { /* старый браузер */ }
  });

  svg.addEventListener('pointermove', (e) => {
    if (chart.mode !== 'candles') return;
    const p = pointAt(e);
    const d = chart.drag;
    if (d) {
      if (d.kind === 'pan') {
        chart.i0 = d.i0 - (p.x - d.x) / d.step;
      } else if (d.kind === 'time') {
        chart.span = clamp(d.span * (1 + ((d.x - p.x) / d.plotW) * 1.8), VIEW.minSpan, VIEW.maxSpan);
      } else {
        // Вверх — растянуть цену, вниз — сжать. Экспонента, чтобы ход ручки
        // ощущался одинаково на любом текущем масштабе.
        chart.priceZoom = clamp(d.priceZoom * Math.exp((d.y - p.y) / 180), VIEW.minPriceZoom, VIEW.maxPriceZoom);
      }
      if (chart.geom) clampView(chart.geom.n);
      chart.cross = null;
    } else {
      chart.cross = p;
    }
    schedule();
  });

  const endDrag = (e) => {
    if (!chart.drag) return;
    chart.drag = null;
    try { svg.releasePointerCapture(e.pointerId); } catch (_) { /* уже отпущен */ }
    schedule();
  };
  svg.addEventListener('pointerup', endDrag);
  svg.addEventListener('pointercancel', endDrag);
  svg.addEventListener('pointerleave', () => {
    if (chart.drag) return;
    chart.cross = null;
    schedule();
  });

  svg.addEventListener('dblclick', () => {
    if (chart.mode !== 'candles') return;
    resetView();
    renderChart();
  });
}

async function loadCurveShape() {
  if (chart.shape) return;
  const C = CONFIG.contracts.curve;
  const ch = view.chain;
  if (!isSet(C) || !ch || ch.kind !== 'data' || !ch.r.inventory || !ch.r.inventory.ok) return;

  const inv = uint(ch.r.inventory.value);
  const [p0raw, pFinRaw] = await Promise.all([
    ethCall(C, SEL.priceAt + argUint(0)),
    ethCall(C, SEL.priceAt + argUint(inv))
  ]);

  const p0 = uint(p0raw);
  const pFin = uint(pFinRaw);

  // priceAt() отдаёт «сырую» цену, spotPrice() — цену целого токена в wei.
  // Множитель между ними выводим из самой цепочки, а не вписываем константой.
  const sold = ch.r.sold && ch.r.sold.ok ? uint(ch.r.sold.value) : 0n;
  const spot = ch.r.spotPrice && ch.r.spotPrice.ok ? uint(ch.r.spotPrice.value) : 0n;
  const rawNow = p0 + ((pFin - p0) * sold) / inv;
  const div = spot > 0n ? rawNow / spot : 0n;
  if (div <= 0n) return;

  chart.shape = {
    startWei: Number(p0 / div),
    finalWei: Number(pFin / div),
    inv: Number(inv) / 1e18,
    sold: Number(sold) / 1e18,
    spotWei: Number(spot)
  };
}

function renderCurveMode(svg, w, h) {
  const s = chart.shape;
  if (!s) {
    chartMessage(t('chart.curveWait'));
    setChartStatus('');
    loadCurveShape().then(() => { if (chart.mode === 'curve') renderChart(); }).catch(() => {});
    return;
  }
  chartMessage(null);

  const padL = 8;
  const padR = 62;
  const padT = 12;
  const padB = 30;
  const plotW = w - padL - padR;
  const plotH = h - padT - padB;

  const lo = s.startWei - (s.finalWei - s.startWei) * 0.08;
  const hi = s.finalWei + (s.finalWei - s.startWei) * 0.08;
  const yOf = (p) => padT + plotH - ((p - lo) / (hi - lo)) * plotH;
  const xOf = (frac) => padL + frac * plotW;

  for (let i = 0; i <= 5; i++) {
    const p = lo + ((hi - lo) * i) / 5;
    const y = yOf(p);
    svg.appendChild(svgEl('line', {class: 'ch-grid', x1: padL, y1: y, x2: padL + plotW, y2: y}));
    const label = svgEl('text', {class: 'ch-axis', x: padL + plotW + 6, y: y + 3});
    label.textContent = fmtGwei(p);
    svg.appendChild(label);
  }

  // Цена линейна по объёму, поэтому «кривая» — отрезок. Это и есть тезис:
  // никаких экспонент, только трапеция.
  svg.appendChild(svgEl('path', {
    class: 'ch-area',
    d: `M ${xOf(0)} ${yOf(s.startWei)} L ${xOf(1)} ${yOf(s.finalWei)} L ${xOf(1)} ${padT + plotH} L ${xOf(0)} ${padT + plotH} Z`
  }));
  svg.appendChild(svgEl('line', {
    class: 'ch-curve', x1: xOf(0), y1: yOf(s.startWei), x2: xOf(1), y2: yOf(s.finalWei)
  }));

  const frac = s.inv > 0 ? s.sold / s.inv : 0;
  const mx = xOf(frac);
  const my = yOf(s.spotWei);
  svg.appendChild(svgEl('line', {class: 'ch-grid', x1: mx, y1: padT, x2: mx, y2: padT + plotH}));
  svg.appendChild(svgEl('circle', {class: 'ch-marker', cx: mx, cy: my, r: 4}));

  const lbl = svgEl('text', {
    class: 'ch-hint',
    x: Math.min(mx + 8, padL + plotW - 4),
    y: Math.max(my - 10, padT + 10)
  });
  lbl.textContent = `${(frac * 100).toFixed(4)}% · ${fmtGwei(s.spotWei)} gwei`;
  svg.appendChild(lbl);

  [[0, 'start'], [1, 'end']].forEach(([f, anchor]) => {
    const el = svgEl('text', {class: 'ch-axis', x: xOf(f) + (f === 0 ? 2 : -2), y: h - padB + 16, 'text-anchor': anchor});
    el.textContent = f === 0 ? '0' : groupDigits(String(Math.round(s.inv)));
    svg.appendChild(el);
  });
  const cap = svgEl('text', {class: 'ch-hint', x: xOf(0.5), y: h - padB + 16, 'text-anchor': 'middle'});
  cap.textContent = t('chart.axisSold');
  svg.appendChild(cap);

  setChartStatus(t('chart.curveNote'));
  const last = $('#chart-last');
  const chg = $('#chart-change');
  if (last) last.textContent = fmtGwei(s.spotWei) + ' gwei';
  if (chg) { chg.textContent = ''; chg.className = 'chg'; }
}

function setChartStatus(text) {
  const el = $('#chart-status');
  if (el) el.textContent = text || '';
}

/** Заголовок: последняя цена и изменение за то окно, которое видно сейчас. */
function updateLastPrice(all, iA, iB, decimals) {
  const last = $('#chart-last');
  const chg = $('#chart-change');
  if (!last || !all.length) return;

  const cur = all[all.length - 1];
  last.textContent = fmtGweiAt(cur.c, Math.max(decimals, 4)) + ' gwei';

  const base = all[Math.max(0, Math.min(iA, all.length - 1))].o;
  if (!(base > 0) || iB <= iA) { chg.textContent = ''; chg.className = 'chg'; return; }
  const pct = ((cur.c - base) / base) * 100;
  chg.textContent = (pct >= 0 ? '+' : '') + pct.toFixed(2) + '%';
  chg.className = 'chg' + (pct > 0 ? ' is-up' : pct < 0 ? ' is-down' : '');
}

/* ─────────────────────────────────────────────────────────────────────────
 *  СВОДКА РЫНКА: цена, капитализация, FDV, ликвидность, объём.
 *
 *  Все величины считаются из данных цепочки. Единственное, чего на цепочке
 *  нет, — курс газового токена к доллару; он приходит от стороннего сервиса
 *  и может не прийти вовсе. Тогда цифры остаются в ETH: доллары здесь
 *  удобство, а не источник истины.
 *
 *  Про «ликвидность». У кривой нет пула, и сравнивать её с DEX-парой нельзя.
 *  Ближайшая честная величина — резерв: это ETH, которым обеспечен обратный
 *  выкуп. Он покрывает все непогашенные права выкупа и ничего сверх них.
 * ───────────────────────────────────────────────────────────────────────── */

const fiat = { usd: null, at: null, failed: false };

async function loadEthUsd(force = false) {
  const cfg = CONFIG.price;
  if (!cfg || !cfg.url) return null;
  if (!force && fiat.usd && fiat.at && Date.now() - fiat.at < cfg.ttlMs) return fiat.usd;

  try {
    const ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timer = ctrl ? setTimeout(() => ctrl.abort(), CONFIG.ui.rpcTimeoutMs) : null;
    let res;
    try {
      res = await fetch(cfg.url, {
        // Ни кук, ни кэша: сервису не за что зацепиться, кроме самого запроса.
        credentials: 'omit',
        cache: 'no-store',
        signal: ctrl ? ctrl.signal : undefined
      });
    } finally {
      if (timer) clearTimeout(timer);
    }
    if (!res.ok) throw new Error('HTTP ' + res.status);

    let value = await res.json();
    cfg.path.forEach((key) => { value = value == null ? null : value[key]; });
    const num = Number(value);
    if (!Number.isFinite(num) || num <= 0) throw new Error('bad price');

    fiat.usd = num;
    fiat.at = Date.now();
    fiat.failed = false;
  } catch (_) {
    // Курс — необязательная роскошь. Не пришёл — показываем ETH и молчим.
    fiat.failed = true;
  }
  renderMarket();
  return fiat.usd;
}

/** Доллары: от долей цента до тысяч одной функцией. */
function fmtUsd(value) {
  if (!Number.isFinite(value)) return null;
  if (value === 0) return '$0';
  const abs = Math.abs(value);
  if (abs >= 1000) return '$' + groupDigits(Math.round(value).toString());
  if (abs >= 1) return '$' + value.toFixed(2);
  if (abs >= 0.01) return '$' + value.toFixed(4);
  // Мельче цента круглые знаки бессмысленны — держим значащие цифры.
  return '$' + value.toPrecision(4).replace(/0+$/, '').replace(/\.$/, '');
}

const weiToEth = (wei) => Number(wei) / 1e18;

/**
 * Сводка из уже прочитанных данных. Возвращает null, пока читать нечего, —
 * плитки тогда просто не рисуются, а не показывают нули.
 */
function marketStats() {
  const ch = view.chain;
  if (!ch || ch.kind !== 'data') return null;
  const r = ch.r;
  const ok = (k) => !!(r[k] && r[k].ok);
  if (!ok('spotPrice') || !ok('totalSupply')) return null;

  const ONE = 10n ** 18n;
  const spot = uint(r.spotPrice.value);        // wei за один целый токен
  const total = uint(r.totalSupply.value);     // базовые единицы

  // Считаем обращение только если прочитаны ВСЕ вычитаемые балансы: иначе
  // капитализация окажется завышенной, а понять это по цифре нельзя.
  const balKeys = ['balDead', 'balEmission', 'balCurve', 'balVesting'];
  const haveBalances = balKeys.every(ok);
  let locked = 0n;
  balKeys.forEach((k) => { if (ok(k)) locked += uint(r[k].value); });
  const circulating = haveBalances ? (total > locked ? total - locked : 0n) : null;

  let vol24 = 0n;
  let volAll = 0n;
  const since = Math.floor(Date.now() / 1000) - 86400;
  (chart.trades || []).forEach((tr) => {
    volAll += tr.ethWei;
    if (tr.ts >= since) vol24 += tr.ethWei;
  });

  return {
    spotWei: spot,
    priceEth: weiToEth(spot),
    total,
    circulating,
    fdvEth: weiToEth((total * spot) / ONE),
    mcapEth: circulating === null ? null : weiToEth((circulating * spot) / ONE),
    reserveEth: ok('reserve') ? weiToEth(uint(r.reserve.value)) : null,
    vol24Eth: weiToEth(vol24),
    volAllEth: weiToEth(volAll),
    tradesKnown: !!chart.trades
  };
}

function mstat(labelKey, usdValue, ethValue, naKey, subOverride) {
  const box = document.createElement('div');
  box.className = 'mstat';

  const k = document.createElement('span');
  k.className = 'k';
  k.textContent = t(labelKey);
  box.appendChild(k);

  const v = document.createElement('span');
  v.className = 'v';
  const s = document.createElement('span');
  s.className = 's';

  if (ethValue === null || ethValue === undefined) {
    v.textContent = '—';
    v.classList.add('is-na');
    if (naKey) s.textContent = t(naKey);
  } else {
    const gas = CONFIG.chain.currency.symbol;
    // Цена одного токена в ETH — это 2e-9, и в таком виде она нечитаема.
    // Для неё подпись приходит готовой, в gwei, как и везде на странице.
    const eth = subOverride
      || (ethValue < 0.000001 && ethValue > 0 ? ethValue.toPrecision(3) : ethValue.toFixed(6).replace(/0+$/, '').replace(/\.$/, '')) + ' ' + gas;
    const usd = usdValue === null ? null : fmtUsd(usdValue);
    // Доллары наверх, если они есть; иначе главной строкой становится ETH.
    v.textContent = usd || eth;
    s.textContent = usd ? eth : '';
  }

  box.append(v, s);
  return box;
}

function renderMarket() {
  const box = $('#market-stats');
  const note = $('#market-note');
  if (!box) return;

  const m = marketStats();
  box.textContent = '';
  if (!m) { if (note) note.textContent = ''; return; }

  const usd = fiat.usd;
  const inUsd = (eth) => (usd && eth !== null && eth !== undefined ? eth * usd : null);

  box.appendChild(mstat('market.price', inUsd(m.priceEth), m.priceEth, null,
    fmtGwei(Number(m.spotWei)) + ' gwei'));
  box.appendChild(mstat('market.mcap', inUsd(m.mcapEth), m.mcapEth, 'market.mcap.na'));
  box.appendChild(mstat('market.fdv', inUsd(m.fdvEth), m.fdvEth));
  box.appendChild(mstat('market.liquidity', inUsd(m.reserveEth), m.reserveEth));
  box.appendChild(mstat('market.vol24', inUsd(m.vol24Eth), m.tradesKnown ? m.vol24Eth : null, 'market.vol.na'));
  box.appendChild(mstat('market.volAll', inUsd(m.volAllEth), m.tradesKnown ? m.volAllEth : null, 'market.vol.na'));

  if (note) {
    const parts = [t('market.note')];
    if (!CONFIG.price || !CONFIG.price.url) parts.push(t('market.usd.off'));
    else if (fiat.failed && !usd) parts.push(t('market.usd.failed', { gas: CONFIG.chain.currency.symbol }));
    else if (usd) parts.push(t('market.usd.src', { src: CONFIG.price.source, rate: fmtUsd(usd), gas: CONFIG.chain.currency.symbol }));
    note.textContent = parts.join(' ');
  }
}

/* ─────────────────────────────────────────────────────────────────────────
 *  ЖУРНАЛ ОПЕРАЦИЙ.
 *
 *  Основа — полный лог Transfer токена, а не события кривой. Так в таблицу
 *  попадает всё движение MACLRN: genesis, сожжение, стейкинг, любые переводы
 *  между кошельками, а не только торговля.
 *
 *  Сделка кривой порождает сразу два события: своё (Bought/Sold) и Transfer.
 *  Строку рисуем одну — из Transfer, — а цену и сумму в ETH подставляем из
 *  события кривой той же транзакции. Иначе одна покупка выглядела бы в
 *  журнале как две разные операции.
 * ───────────────────────────────────────────────────────────────────────── */

const ACT_PAGE = 25;

const activity = {
  rows: null,
  loading: false,
  errorText: null,
  filter: 'all',
  limit: ACT_PAGE
};

async function loadActivity(force = false) {
  const T = CONFIG.contracts.token;
  if (!isSet(T)) { activity.errorText = t('act.noToken'); renderActivity(); return; }
  if (activity.loading) return;
  if (activity.rows && !force) return;

  activity.loading = true;
  activity.errorText = null;
  renderActivity();

  try {
    const latest = Number(BigInt(await rpc('eth_blockNumber')));
    const logs = await getLogsChunked(T, [EVENTS.transfer], CONFIG.chart.tokenDeployBlock, latest);
    activity.rows = await decodeTransfers(logs);
  } catch (e) {
    activity.rows = null;
    activity.errorText = t('act.failed', { reason: (e && e.message) || String(e) });
  } finally {
    activity.loading = false;
    renderActivity();
  }
}

async function decodeTransfers(logs) {
  const curve = isSet(CONFIG.contracts.curve) ? CONFIG.contracts.curve.toLowerCase() : '';
  const blockNums = new Set();
  const rows = [];

  logs.forEach((log) => {
    if (!log.topics || log.topics.length < 3) return;
    // Индексированный адрес лежит в топике, дополненный слева нулями до
    // 32 байт: сам адрес — последние 20.
    const from = ('0x' + log.topics[1].slice(26)).toLowerCase();
    const to = ('0x' + log.topics[2].slice(26)).toLowerCase();
    const block = Number(BigInt(log.blockNumber));
    blockNums.add(block);

    rows.push({
      block,
      tx: log.transactionHash,
      logIndex: log.logIndex ? Number(BigInt(log.logIndex)) : 0,
      from,
      to,
      value: uint(log.data),
      fromCurve: !!curve && from === curve,
      toCurve: !!curve && to === curve
    });
  });

  const times = await fetchBlockTimes(Array.from(blockNums));

  return rows
    .map((r) => { r.ts = times.get(r.block); return r; })
    .sort((a, b) => (b.ts || 0) - (a.ts || 0) || b.block - a.block || b.logIndex - a.logIndex);
}

/**
 * Тип операции. Покупкой и продажей считается только тот перевод, у которого
 * в той же транзакции есть событие кривой.
 *
 * По одному лишь адресу судить нельзя: инвентарь в 1 000 000 000 токенов
 * уехал на кривую обычным переводом при раскладке genesis, никакой продажи
 * там не было, — а по признаку «получатель равен кривой» это выглядело бы
 * как крупнейшая продажа в истории токена.
 */
function transferKind(r, trade) {
  if (r.from === ZERO_ADDR) return 'mint';
  if (r.to === DEAD_ADDR || r.to === ZERO_ADDR) return 'burn';
  if (trade && r.fromCurve) return 'buy';
  if (trade && r.toCurve) return 'sell';
  return 'transfer';
}

/** Известные адреса подписываем именем: читать проще, чем сверять хвосты. */
function knownAddress(addr) {
  const a = String(addr || '').toLowerCase();
  if (a === ZERO_ADDR) return t('act.who.zero');
  if (a === DEAD_ADDR) return t('act.who.burn');
  const c = CONFIG.contracts;
  if (isSet(c.curve) && a === c.curve.toLowerCase()) return t('grid.curve');
  if (isSet(c.emission) && a === c.emission.toLowerCase()) return t('grid.emission');
  if (isSet(c.vesting) && a === c.vesting.toLowerCase()) return t('grid.vesting');
  if (isSet(c.token) && a === c.token.toLowerCase()) return t('grid.token');
  return null;
}

function fmtAgo(ts) {
  if (!ts) return '—';
  const s = Math.max(0, Math.floor(Date.now() / 1000) - ts);
  if (s < 60) return t('ago.s', { n: s });
  if (s < 3600) return t('ago.m', { n: Math.floor(s / 60) });
  if (s < 86400) return t('ago.h', { n: Math.floor(s / 3600) });
  return t('ago.d', { n: Math.floor(s / 86400) });
}

function actCell(text, cls) {
  const td = document.createElement('td');
  if (cls) td.className = cls;
  td.textContent = text;
  return td;
}

function actAddressCell(addr) {
  const td = document.createElement('td');
  const box = document.createElement('span');
  box.className = 'act-who';
  const label = knownAddress(addr);
  if (label) {
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = label;
    box.appendChild(name);
  }
  const link = linkEl(shortAddr(addr), ex.address(addr));
  link.className = 'addr';
  box.appendChild(link);
  td.appendChild(box);
  return td;
}

function activityRow(r, trade, kind) {
  const tr = document.createElement('tr');
  const dec = CONFIG.token.decimals;
  const gas = CONFIG.chain.currency.symbol;

  const time = actCell(fmtAgo(r.ts));
  if (r.ts) time.title = fmtFullTime(r.ts) + ' · ' + t('act.block', { n: groupDigits(String(r.block)) });
  tr.appendChild(time);

  const typeTd = document.createElement('td');
  const badge = document.createElement('span');
  badge.className = 'act-badge is-' + kind;
  badge.textContent = t('act.kind.' + kind);
  typeTd.appendChild(badge);
  tr.appendChild(typeTd);

  tr.appendChild(actCell(formatUnits(r.value, dec, 6) + ' ' + CONFIG.token.symbol, 'col-num'));

  // Цена и сумма в ETH есть только у сделок кривой: у обычного перевода
  // цены не существует, и придумывать её нечем.
  tr.appendChild(trade
    ? actCell(formatUnits(trade.ethWei, 18, 9) + ' ' + gas, 'col-num')
    : actCell('—', 'col-num muted'));
  tr.appendChild(trade
    ? actCell(formatUnits(trade.priceWei, 9) + ' gwei', 'col-num')
    : actCell('—', 'col-num muted'));

  tr.appendChild(actAddressCell(r.from));
  tr.appendChild(actAddressCell(r.to));

  const txTd = document.createElement('td');
  if (r.tx) {
    const a = linkEl(r.tx.slice(0, 8) + '…', ex.tx(r.tx));
    a.title = r.tx;
    txTd.appendChild(a);
  } else {
    txTd.textContent = '—';
  }
  tr.appendChild(txTd);

  return tr;
}

function setActStatus(text) {
  const el = $('#act-status');
  if (el) el.textContent = text || '';
}

function renderActivityLinks() {
  const box = $('#act-links');
  if (!box) return;
  box.textContent = '';
  if (isSet(CONFIG.contracts.token)) box.appendChild(linkEl(t('act.link.all'), ex.token(CONFIG.contracts.token)));
  if (isSet(CONFIG.contracts.curve)) box.appendChild(linkEl(t('act.link.curve'), ex.address(CONFIG.contracts.curve)));
}

function renderActivity() {
  const body = $('#act-rows');
  if (!body) return;

  $$('.seg-btn[data-act]').forEach((b) => b.setAttribute('aria-pressed', b.dataset.act === activity.filter ? 'true' : 'false'));
  renderActivityLinks();

  const empty = $('#act-empty');
  const more = $('#act-more');
  const setEmpty = (text) => { if (empty) { empty.hidden = !text; empty.textContent = text || ''; } };

  body.textContent = '';

  if (activity.loading || (!activity.rows && !activity.errorText)) {
    setEmpty(t('act.loading')); setActStatus(''); if (more) more.hidden = true; return;
  }
  if (activity.errorText) {
    setEmpty(activity.errorText); setActStatus(''); if (more) more.hidden = true; return;
  }

  // Сопоставление с событиями кривой строим на каждую отрисовку: сделки
  // могли догрузиться позже журнала, и порядок загрузки не должен влиять
  // ни на тип операции, ни на цену в строке.
  const byTx = new Map();
  (chart.trades || []).forEach((tr) => { if (tr.tx) byTx.set(String(tr.tx).toLowerCase(), tr); });

  const enriched = activity.rows.map((r) => {
    const trade = byTx.get(String(r.tx || '').toLowerCase()) || null;
    const kind = transferKind(r, trade);
    return { r, kind, trade: kind === 'buy' || kind === 'sell' ? trade : null };
  });

  const rows = enriched.filter((e) => {
    const isTrade = e.kind === 'buy' || e.kind === 'sell';
    return activity.filter === 'trade' ? isTrade : activity.filter === 'transfer' ? !isTrade : true;
  });

  if (!rows.length) { setEmpty(t('act.empty')); setActStatus(''); if (more) more.hidden = true; return; }
  setEmpty(null);

  const shown = rows.slice(0, activity.limit);
  shown.forEach((e) => body.appendChild(activityRow(e.r, e.trade, e.kind)));

  setActStatus(t('act.status', { shown: shown.length, total: rows.length }));
  if (more) {
    const rest = rows.length - shown.length;
    more.hidden = rest <= 0;
    more.textContent = t('act.more', { n: Math.min(rest, ACT_PAGE) });
  }
}

/* ─────────────────────────────────────────────────────────────────────────
 *  ПРОДАЖА.
 *
 *  Две транзакции: разрешение ровно на продаваемое количество и сама
 *  продажа. Неограниченный approve не запрашивается никогда — если сделка
 *  сорвётся, у контракта не останется права тратить остаток баланса.
 *
 *  Потолок продажи — не баланс токенов, а boughtOf(): кривая выкупает только
 *  то, что этот же адрес у неё купил.
 * ───────────────────────────────────────────────────────────────────────── */

function setPane(which) {
  const isSell = which === 'sell';
  const bp = $('#pane-buy');
  const sp = $('#pane-sell');
  if (bp) bp.hidden = isSell;
  if (sp) sp.hidden = !isSell;
  $$('.trade-tab').forEach((b) => b.setAttribute('aria-selected', b.dataset.pane === which ? 'true' : 'false'));
  buyMsg(null);
}

/** Сколько этот адрес реально может продать кривой: min(boughtOf, balanceOf). */
async function readSellLimit() {
  const C = CONFIG.contracts.curve;
  const T = CONFIG.contracts.token;
  if (!state.account || !isSet(C) || !isSet(T)) return null;
  const r = await settle({
    bought: ethCall(C, SEL.boughtOf + argAddr(state.account)),
    balance: ethCall(T, SEL.balanceOf + argAddr(state.account))
  });
  if (!r.bought.ok || !r.balance.ok) return null;
  const bought = uint(r.bought.value);
  const balance = uint(r.balance.value);
  return { bought, balance, max: bought < balance ? bought : balance };
}

async function refreshSellLimit() {
  const el = $('#sell-limit');
  if (!el) return;
  if (!state.account) { view.sellLimit = null; el.textContent = t('sell.limit.none'); return; }
  const lim = await readSellLimit();
  view.sellLimit = lim;
  renderSellLimit();
}

function renderSellLimit() {
  const el = $('#sell-limit');
  if (!el) return;
  if (!state.account) { el.textContent = t('sell.limit.none'); return; }
  const lim = view.sellLimit;
  if (!lim) { el.textContent = t('sell.limit.none'); return; }
  const dec = CONFIG.token.decimals;
  const sym = CONFIG.token.symbol;
  if (lim.bought === 0n) { el.textContent = t('sell.limit.zero'); return; }
  el.textContent = t('sell.limit', {
    amount: formatUnits(lim.max, dec, 6),
    bal: formatUnits(lim.balance, dec, 6),
    sym
  });
}

function readSellInputs() {
  const amount = parseUnits($('#sell-amount').value, CONFIG.token.decimals);
  if (amount <= 0n) throw new Error(t('input.positive'));
  const slipBps = parseUnits($('#sell-slippage').value || '0', 2);
  if (slipBps >= 10000n) throw new Error(t('input.slippage'));
  const minutes = Number(String($('#sell-deadline').value).trim());
  if (!Number.isFinite(minutes) || minutes <= 0 || minutes > 1440) throw new Error(t('input.deadline'));
  return { amount, slipBps, minutes };
}

function renderSellQuote() {
  const out = $('#sell-quote-out');
  const q = view.sellQuote;
  if (!out) return;
  if (!q) { out.hidden = true; out.textContent = ''; return; }

  const gas = CONFIG.chain.currency.symbol;
  const sym = CONFIG.token.symbol;
  const rows = [
    [t('sell.row.out'), `${formatUnits(q.ethOut, 18, 9)} ${gas}`],
    [t('sell.row.min'), `${formatUnits(q.minEthOut, 18, 9)} ${gas}`],
    [t('sell.row.fee'), `${formatUnits(q.fee, 18, 9)} ${gas}`],
    [t('sell.row.avg'), t('quote.avg', { price: formatUnits(q.effective, 9), sym })]
  ];

  out.hidden = false;
  out.textContent = '';
  const dl = document.createElement('dl');
  rows.forEach(([k, v]) => {
    const dt = document.createElement('dt'); dt.textContent = k;
    const dd = document.createElement('dd'); dd.textContent = v;
    dl.append(dt, dd);
  });
  out.appendChild(dl);

  if (q.warn) {
    const p = document.createElement('p');
    p.className = 'footnote';
    p.textContent = q.warn;
    out.appendChild(p);
  }
}

async function sellQuote(silent = false) {
  const C = CONFIG.contracts.curve;
  if (!isSet(C)) { buyMsg('quote.noCurve', null, 'error'); return null; }

  let inp;
  try { inp = readSellInputs(); } catch (e) { buyMsgText(e.message, 'error'); return null; }
  if (!silent) buyMsg('quote.working');

  try {
    const raw = await ethCall(C, SEL.previewSell + argUint(inp.amount));
    const [ethOut, fee] = words(raw);
    if (ethOut <= 0n) throw new Error(t('quote.tooSmall'));

    const minEthOut = (ethOut * (10000n - inp.slipBps)) / 10000n;
    const gross = ethOut + fee;
    const effective = (gross * 10n ** 18n) / inp.amount;

    // Потолок читаем заново: между открытием вкладки и расчётом адрес мог
    // и докупить, и уже что-то продать.
    const lim = await readSellLimit();
    view.sellLimit = lim;
    renderSellLimit();

    let warn = null;
    if (lim) {
      const sym = CONFIG.token.symbol;
      if (inp.amount > lim.balance) warn = t('sell.overBalance');
      else if (inp.amount > lim.bought) warn = t('sell.overLimit', { amount: formatUnits(lim.bought, CONFIG.token.decimals, 6), sym });
    }

    view.sellQuote = { amount: inp.amount, ethOut, fee, minEthOut, effective, minutes: inp.minutes, warn };
    renderSellQuote();

    state.sellQuote = { amount: inp.amount, minEthOut, minutes: inp.minutes };
    $('#do-sell').disabled = false;
    if (!silent) buyMsg('quote.ok');
    return state.sellQuote;
  } catch (e) {
    state.sellQuote = null;
    $('#do-sell').disabled = true;
    const reason = decodeRevert(e);
    if (reason) buyMsgText(reason, 'error');
    else buyMsg('quote.failed', { reason: (e && e.message) || String(e) }, 'error');
    return null;
  }
}

/** Ждём, пока разрешение окажется в блоке: без него sell() гарантированно упадёт. */
async function waitReceipt(hash, timeoutMs = 150000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const r = await rpc('eth_getTransactionReceipt', [hash]);
      if (r && r.blockNumber) return r;
    } catch (_) { /* узел ещё не видит транзакцию — это норма */ }
    await new Promise((res) => setTimeout(res, 3000));
  }
  return null;
}

async function doSell() {
  const C = CONFIG.contracts.curve;
  const T = CONFIG.contracts.token;
  if (!isSet(C) || !isSet(T)) { buyMsg('buy.noCurve', null, 'error'); return; }
  if (!hasWallet()) { $('#no-wallet').hidden = false; buyMsg('buy.noWallet', null, 'error'); return; }

  try {
    if (!state.account) { connect(); return; }
    await ensureChain();

    const q = await sellQuote(true);
    if (!q) return;

    const dec = CONFIG.token.decimals;
    const sym = CONFIG.token.symbol;

    // 1. Разрешение ровно на продаваемое количество — и только если текущего
    //    не хватает. Лишняя транзакция никому не нужна.
    const allowanceRaw = await ethCall(T, SEL.allowance + argAddr(state.account) + argAddr(C));
    if (uint(allowanceRaw) < q.amount) {
      buyMsg('sell.approving', { amount: formatUnits(q.amount, dec, 6), sym });
      const approveHash = await activeProvider().request({
        method: 'eth_sendTransaction',
        params: [{
          from: state.account,
          to: T,
          data: SEL.approve + argAddr(C) + argUint(q.amount)
        }]
      });
      buyMsg('sell.approveWait');
      const receipt = await waitReceipt(approveHash);
      if (!receipt) { buyMsg('sell.approveFailed', null, 'error'); return; }
    }

    // 2. Сама продажа. Дедлайн считаем здесь, а не в котировке: между
    //    расчётом и подтверждением разрешения могли пройти минуты.
    const deadline = BigInt(Math.floor(Date.now() / 1000) + q.minutes * 60);
    buyMsg('sell.confirmTx');

    const hash = await activeProvider().request({
      method: 'eth_sendTransaction',
      params: [{
        from: state.account,
        to: C,
        data: SEL.sell + argUint(q.amount) + argUint(q.minEthOut) + argUint(deadline)
      }]
    });

    view.msg = { hash, kind: 'ok', sell: true };
    renderBuyMsg();

    setTimeout(() => { refresh(); showWallet(); refreshSellLimit(); loadTrades(true).then(() => loadActivity(true)); }, 8000);
  } catch (e) {
    buyMsgText(walletError(e), 'error');
  }
}

function fillSellPct(pct) {
  const lim = view.sellLimit;
  if (!lim || lim.max <= 0n) { buyMsg('sell.limit.zero', null, 'error'); return; }
  const amount = (lim.max * BigInt(pct)) / 100n;
  $('#sell-amount').value = formatUnits(amount, CONFIG.token.decimals).replace(/\s/g, '');
}

/* ── копирование адреса ────────────────────────────────────────────────── */

async function copyFrom(btn) {
  const target = document.getElementById(btn.dataset.copyTarget);
  if (!target) return;
  const text = target.textContent.trim().split(/\s+/)[0];
  if (!/^0x[0-9a-fA-F]{40}$/.test(text)) return;   // копируем только адрес, а не «адрес не задан»
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
  // Кнопок с копированием несколько, и подписи у них разные — возвращаем ту,
  // что была, а не одну общую.
  if (!btn.dataset.label) btn.dataset.label = btn.textContent;
  btn.textContent = t('buy.addr.copied');
  setTimeout(() => { btn.textContent = btn.dataset.label; }, 1500);
}

/* ── применение языка ──────────────────────────────────────────────────── */

/** Проставляет переводы во всю статическую разметку. */
function applyI18n() {
  document.documentElement.lang = LANG;
  document.title = t('meta.title');
  const md = $('meta[name="description"]');
  if (md) md.setAttribute('content', t('meta.description'));

  $$('[data-i18n]').forEach((el) => { el.textContent = t(el.getAttribute('data-i18n')); });
  // Значения приходят только из словаря выше — это статический файл,
  // не сеть и не пользовательский ввод.
  $$('[data-i18n-html]').forEach((el) => { el.innerHTML = t(el.getAttribute('data-i18n-html')); });
  $$('[data-i18n-aria]').forEach((el) => { el.setAttribute('aria-label', t(el.getAttribute('data-i18n-aria'))); });
  $$('[data-i18n-title]').forEach((el) => { el.title = t(el.getAttribute('data-i18n-title')); });

  $$('.lang-btn').forEach((b) => {
    const on = b.dataset.lang === LANG;
    b.setAttribute('aria-pressed', on ? 'true' : 'false');
    b.setAttribute('aria-label', t('lang.' + b.dataset.lang + '.aria'));
  });
}

/**
 * Смена языка без перезагрузки. Сеть не трогаем: всё, что уже прочитано,
 * лежит в view и просто рисуется заново.
 */
function setLang(lang) {
  if (lang !== 'ru' && lang !== 'en') return;
  LANG = lang;
  lsSet(LS_LANG, lang);

  applyI18n();

  // Динамические куски — из сохранённых сырых данных, без единого запроса.
  renderChainBanner();
  renderAddresses();
  renderContracts();
  renderVerifyCommands();
  renderLinkGrid();
  renderChain();
  renderSale();
  renderMarket();
  renderStatus();
  renderQuote();
  renderSellQuote();
  renderSellLimit();
  renderChart();
  renderActivity();
  renderBuyMsg();
  renderWallet();
  // После applyI18n кнопки подключения снова подписаны «Connect wallet» —
  // если кошелёк подключён, возвращаем на них адрес.
  renderConnectButtons();
  if ($('#wallet-modal') && $('#wallet-modal').open) renderWalletList();
}

/* ── инициализация ─────────────────────────────────────────────────────── */

function init() {
  LANG = detectLang();

  $('#in-slippage').value = CONFIG.ui.defaultSlippagePct;
  $('#in-deadline').value = CONFIG.ui.defaultDeadlineMin;

  applyI18n();

  renderChainBanner();
  renderAddresses();
  renderContracts();
  renderVerifyCommands();
  renderLinkGrid();
  renderSale();
  setStatus('status.loading');
  renderWallet();
  renderConnectButtons();

  $('#refresh').addEventListener('click', () => refresh());
  $('#quote').addEventListener('click', () => quote());
  $('#do-buy').addEventListener('click', () => doBuy());
  $('#connect').addEventListener('click', () => connect());
  $('#connect-header').addEventListener('click', () => connect());
  $('#disconnect').addEventListener('click', () => disconnectWallet());
  $('#wm-close').addEventListener('click', () => closeWalletModal());
  $('#amount-max').addEventListener('click', () => { fillMaxAmount(); $('#in-amount').dispatchEvent(new Event('input')); });
  $$('.chip[data-amount]').forEach((b) => {
    b.addEventListener('click', () => { $('#in-amount').value = b.dataset.amount; $('#in-amount').dispatchEvent(new Event('input')); });
  });

  /* — вкладки, продажа, график — */
  $$('.trade-tab').forEach((b) => b.addEventListener('click', () => setPane(b.dataset.pane)));
  $('#sell-quote').addEventListener('click', () => sellQuote());
  $('#do-sell').addEventListener('click', () => doSell());
  $$('.chip[data-sell-pct]').forEach((b) => {
    b.addEventListener('click', () => { fillSellPct(Number(b.dataset.sellPct)); $('#sell-amount').dispatchEvent(new Event('input')); });
  });

  // Смена интервала меняет и длину серии, поэтому окно просмотра из старого
  // масштаба переносить некуда — сбрасываем в авто.
  const customTf = $('#tf-custom');
  const applyTf = (sec, key) => {
    chart.tfSec = sec;
    chart.tfKey = key || null;
    resetView();
    renderChart();
  };

  $$('.seg-btn[data-tf]').forEach((b) => b.addEventListener('click', () => {
    if (customTf) { customTf.value = ''; customTf.className = 'tf-custom'; }
    applyTf(TIMEFRAMES[b.dataset.tf], b.dataset.tf);
  }));

  if (customTf) {
    const applyCustom = () => {
      const raw = customTf.value.trim();
      if (!raw) { customTf.className = 'tf-custom'; return; }
      const sec = parseTimeframe(raw);
      // Непонятный ввод подсвечиваем и НЕ применяем: молча подставить своё
      // значение хуже, чем показать, что строка не разобрана.
      if (!sec) { customTf.className = 'tf-custom is-bad'; return; }
      customTf.className = 'tf-custom is-active';
      applyTf(sec, null);
    };
    customTf.addEventListener('change', applyCustom);
    customTf.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); applyCustom(); } });
  }
  $$('.seg-btn[data-mode]').forEach((b) => b.addEventListener('click', () => { chart.mode = b.dataset.mode; renderChart(); }));
  // Журнал перечитываем вместе со сделками: цена в его строках берётся из
  // событий кривой, и рассинхрон двух источников был бы заметен.
  $('#chart-reload').addEventListener('click', () => loadTrades(true).then(() => { renderMarket(); renderActivity(); }));
  $('#act-reload').addEventListener('click', () => loadTrades(true).then(() => { renderMarket(); return loadActivity(true); }));
  $$('.seg-btn[data-act]').forEach((b) => b.addEventListener('click', () => {
    activity.filter = b.dataset.act;
    activity.limit = ACT_PAGE;
    renderActivity();
  }));
  $('#act-more').addEventListener('click', () => { activity.limit += ACT_PAGE; renderActivity(); });

  // Ширину графика знает только лейаут, поэтому перерисовываем на ресайзе.
  // Дребезг гасим таймером: тянуть окно мышью — это сотни событий подряд.
  let resizeTimer = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => renderChart(), 150);
  });
  $$('.lang-btn').forEach((b) => b.addEventListener('click', () => setLang(b.dataset.lang)));

  // Копирование — делегированием: кнопок несколько, и часть из них рисуется
  // скриптом уже после init.
  document.addEventListener('click', (e) => {
    const btn = e.target && e.target.closest ? e.target.closest('[data-copy-target]') : null;
    if (btn) copyFrom(btn);
  });

  // Клик мимо окна закрывает его: <dialog> вместе с ::backdrop занимает весь
  // экран, поэтому попадание «в подложку» — это событие на самом диалоге.
  const dlg = $('#wallet-modal');
  if (dlg) dlg.addEventListener('click', (e) => { if (e.target === dlg) closeWalletModal(); });

  discoverWallets();

  // Ответы на eip6963:requestProvider обычно приходят синхронно, но гарантий
  // стандарт не даёт. Поэтому вердикт «кошелька нет» откладываем: если
  // расширение объявится позже, onWalletsChanged() вернёт кнопки на место.
  setTimeout(() => {
    if (hasWallet()) { maybeAutoReconnect(); return; }
    $('#no-wallet').hidden = false;
    [$('#connect'), $('#connect-header')].forEach((b) => { if (b) b.disabled = true; });
    view.wallet = { key: 'wallet.noExt' };
    renderWallet();
  }, 400);

  refresh();
  renderChart();
  renderActivity();
  renderMarket();
  loadEthUsd();
  // Сначала сделки, потом журнал: в журнале цена берётся из событий кривой.
  loadTrades().then(() => { renderMarket(); return loadActivity(); });

  if (CONFIG.ui.autoRefreshMs > 0) {
    setInterval(() => {
      if (document.visibilityState !== 'visible') return;
      refresh();
      loadEthUsd();
    }, CONFIG.ui.autoRefreshMs);
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}

// --- PREMIUM UPGRADES APPLIED HERE ---

// 1. Theme Toggler
(function() {
  const toggle = document.getElementById('theme-toggle');
  const root = document.documentElement;
  const saved = localStorage.getItem('theme') || 'light';
  root.setAttribute('data-theme', saved);
  
  if (toggle) {
    toggle.addEventListener('click', () => {
      const current = root.getAttribute('data-theme');
      const next = current === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      localStorage.setItem('theme', next);
    });
  }
})();

// 2. Fade In Microanimations
(function() {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.05 });

  document.querySelectorAll('section.wrap, .sale-card, .metric, .address-block').forEach(el => {
    el.classList.add('fade-in');
    observer.observe(el);
  });
})();

// 3. Toasts for Buy/Sell Messages
let _lastToastMsg = '';
const _originalRenderBuyMsg = renderBuyMsg;
renderBuyMsg = function() {
  _originalRenderBuyMsg();
  const el = document.getElementById('buy-message');
  if (el && el.textContent) {
    const html = el.innerHTML;
    if (html !== _lastToastMsg) {
      showToast(html, el.className.includes('err') ? 'error' : 'success');
      _lastToastMsg = html;
    }
    el.style.display = 'none'; // Hide the static one
  } else {
    _lastToastMsg = '';
  }
};

function showToast(html, type) {
  const container = document.getElementById('toast-container');
  if (!container) return;
  const toast = document.createElement('div');
  toast.className = 'toast ' + (type === 'error' ? 'is-error' : 'is-success');
  toast.innerHTML = html;
  container.appendChild(toast);
  requestAnimationFrame(() => toast.classList.add('is-visible'));
  setTimeout(() => {
    toast.classList.remove('is-visible');
    setTimeout(() => toast.remove(), 300);
  }, 5000);
}

// 4. Chart Reset Zoom Button
(function() {
  const resetBtn = document.getElementById('chart-reset-zoom');
  if (resetBtn) {
    resetBtn.addEventListener('click', () => {
      if (typeof resetView === 'function' && typeof renderChart === 'function') {
        resetView();
        renderChart();
      }
    });
    // Optional: show button only when zoomed? 
    // It's hidden by default in HTML. The user didn't ask for dynamic visibility, but let's make it always visible if chart mode is candles.
    resetBtn.hidden = false;
  }
})();


const _originalRenderChart = renderChart;
renderChart = function() {
  _originalRenderChart();
  const resetBtn = document.getElementById('chart-reset-zoom');
  if (resetBtn) {
    resetBtn.style.display = chart.mode === 'candles' ? '' : 'none';
  }
};

// Header scroll state
window.addEventListener('scroll', () => {
  const header = document.querySelector('.site-header');
  if (header) {
    if (window.scrollY > 20) {
      header.classList.add('is-scrolled');
    } else {
      header.classList.remove('is-scrolled');
    }
  }
}, { passive: true });


;(function() {
  const btn = document.getElementById('chart-resize');
  const card = document.querySelector('.chart-card');
  if (!btn || !card) return;
  const modes = ['', 'chart-compact', 'chart-expanded'];
  const labels = ['Expand', 'Compact', 'Normal'];
  let idx = 0;
  btn.addEventListener('click', () => {
    card.classList.remove(...modes.filter(Boolean));
    idx = (idx + 1) % modes.length;
    if (modes[idx]) card.classList.add(modes[idx]);
    btn.textContent = labels[idx];
    // trigger chart re-render after CSS transition completes
    setTimeout(() => {
      const svg = document.getElementById('chart-svg');
      if (svg) svg.dispatchEvent(new Event('resize'));
      window.dispatchEvent(new Event('resize'));
      if (typeof renderChart === 'function') renderChart();
    }, 320);
  });
})();
;(function() {
  function setupSettingsToggle(toggleId, panelId, slippageInputId, displayId) {
    const toggle = document.getElementById(toggleId);
    const panel = document.getElementById(panelId);
    const slipInput = document.getElementById(slippageInputId);
    const display = document.getElementById(displayId);
    if (!toggle || !panel) return;
    toggle.addEventListener('click', () => {
      const isHidden = panel.hidden;
      panel.hidden = !isHidden;
      toggle.setAttribute('aria-expanded', String(isHidden));
    });
    if (slipInput && display) {
      slipInput.addEventListener('input', () => {
        display.textContent = (slipInput.value || '1') + '%';
      });
    }
  }
  setupSettingsToggle('buy-settings-toggle', 'buy-settings', 'in-slippage', 'slippage-display');
  setupSettingsToggle('sell-settings-toggle', 'sell-settings', 'sell-slippage', 'sell-slippage-display');
})();


;(function() {
  // Auto-quote: когда пользователь вводит сумму, автоматически вызываем Get quote с debounce
  let buyTimer = null;
  let sellTimer = null;
  
  const buyInput = document.getElementById('in-amount');
  const quoteBtn = document.getElementById('quote');
  const sellInput = document.getElementById('sell-amount');
  const sellQuoteBtn = document.getElementById('sell-quote');
  
  if (buyInput && quoteBtn) {
    buyInput.addEventListener('input', () => {
      clearTimeout(buyTimer);
      const val = buyInput.value.trim();
      if (!val || isNaN(parseFloat(val)) || parseFloat(val) <= 0) return;
      buyTimer = setTimeout(() => { quoteBtn.click(); }, 600);
    });
  }
  
  if (sellInput && sellQuoteBtn) {
    sellInput.addEventListener('input', () => {
      clearTimeout(sellTimer);
      const val = sellInput.value.trim();
      if (!val || isNaN(parseFloat(val)) || parseFloat(val) <= 0) return;
      sellTimer = setTimeout(() => { sellQuoteBtn.click(); }, 600);
    });
  }
})();

