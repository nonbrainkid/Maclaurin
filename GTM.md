# Maclaurin Series ($MACLRN) — материалы для публикации

Что здесь: тред для X, короткое описание проекта на английском (профиль, token info
на Blockscout), заготовки ответов на вопросы, которые зададут, и жёсткий список того,
чего писать нельзя.

**Публикуемые тексты — на английском** (аудитория запуска и token info в эксплорере
англоязычные). Всё, что вокруг них по-русски, — инструкции, не для публикации.

> **Про имя.** Ряд Маклорена — это ряд Тейлора, разложенный в нуле. Наш ряд
> `e = Σ 1/n! = 1/0! + 1/1! + 1/2! + …` именно такой. Эту формулировку стоит держать
> наготове: её спросят те, кто помнит школьный курс, и это хороший повод объяснить
> математику, а не отмахнуться.

> ⚠️ **Ничего не публиковать, пока не закрыт `RELEASE-CHECKLIST.md` §6** (все контракты
> верифицированы) **и §7.2** (`name()` = `Maclaurin Series`, `symbol()` = `MACLRN`).
> Ссылки в треде должны вести на готовые страницы, а имя в материалах — совпадать
> с именем на цепочке буква в букву.

---

## 1. Тред для X (10 постов)

Правила, по которым он написан, — чтобы правки их не сломали:

- пост 1 — **факт, интересный сам по себе**, без анонса и без тикера;
- каждый пост несёт одно проверяемое число или одно проверяемое утверждение;
- ни одного обещания доходности, ни одной ракеты, ни одного «to the moon»;
- риски названы прямо, в самом треде, а не мелким шрифтом на сайте;
- ссылки подставить **после** верификации контрактов.

---

**1/**

```
e = 1 + 1/1! + 1/2! + 1/3! + ...

Scale it by 10^27 and compute in integers. At n = 27 the term isn't small — it's 0.
10^27 / 27! is zero in integer arithmetic.

The series stops itself.
```

*Опора: `epochAmount(27) == 0` на цепочке. Пост не продаёт ничего — он про арифметику.*

---

**2/**

```
That's a Maclaurin series — a Taylor series expanded at zero. Σ 1/n! is the one for e.

Maclaurin Series (MACLRN) is an ERC-20 built on exactly that.

Total supply = floor(e × 10^27) = 2,718,281,828.459045235360287471 tokens.
Set in the constructor, never again.
```

*Здесь и только здесь вводится тикер. Число можно проверить: `totalSupply()`.*

---

**3/**

```
The first two terms, 1/0! + 1/1! = 2, exist from block zero: 2,000,000,000 tokens.

The tail — Σ 1/n! for n ≥ 2, or 718,281,828.459… tokens — sits in the emission
contract and is paid out one term per week. Epoch n pays exactly 10^27/n! wei.
```

---

**4/**

```
So emission ends by arithmetic, not by decision.

Epoch 26 pays 2 wei. Epoch 27 would pay 10^27/27! = 0.
25 epochs × 7 days = 175 days, and it's over.

Nobody votes on this. Integer division does.
```

---

**5/**

```
Round 25 terms down and they don't add back up to the pool: 14 wei are left over
forever. The Lagrange remainder, sitting in a contract.

Useful side effect: paying out more than the pool holds isn't forbidden by a check,
it's impossible by arithmetic.
```

*Опора: `EMISSION_POOL − totalEmittable == 14`.*

---

**6/**

```
Staking uses the same series. Pick a radius R = 1..7 (a lock of R weeks); the reward
multiplier is the partial sum up to R:

1.0 → 2.0 → 2.5 → 2.666… → 2.708… → 2.716… → 2.718055…

The ceiling is e itself. A partial sum never reaches its own limit.
```

*Опора: `multiplier(7) = 2718055555555555555 < E_FIXED = 2718281828459045235`.
Формулировать как механику, не как доходность.*

---

**7/**

```
Tokens are sold by a bonding curve: linear price, exact integer trapezoid area,
no fixed-point exponential anyone has to take on faith.

Coefficients are chosen so the price from the first coin to the last rises by
exactly ×e. The full inventory costs 1 + e ETH.
```

*Опора: `P_FINAL × 1e18 / P0 == E_FIXED`, `TOTAL_RAISE == 3718281828459045235`.*

---

**8/**

```
The token has 12 functions. mint is not one of them.

No owner, no pause, no blacklist, no upgrade proxy either. That's not a promise —
those selectors are absent from the deployed bytecode, and the source is verified.

Search for 40c10f19 in the code. It isn't there.
```

*`0x40c10f19` — селектор `mint(address,uint256)`. Проверяется в одну команду, и это
сильнее любого «мы обещаем».*

---

**9/**

```
The curve buys back — but only from the addresses that bought from it, and only up
to what they bought.

Its ETH belongs to its buyers. Tokens nobody paid it for can't drain it.
No pause, no cooldown, no allowlist on selling.
```

---

**10/**

```
Honest scale: the whole inventory would raise ~3.7 ETH. An experiment in putting a
convergent series on-chain — it can go to zero, no yield promised, not financial
advice.

Deployed on Robinhood Chain. Not affiliated with Robinhood.

Code: <ссылка>
```

*Последняя строка про сеть — обязательная. Она снимает вопрос «вы связаны с компанией?»
до того, как его зададут, и делает это фактом, а не оправданием.*

---

### Проверка перед публикацией

- [ ] каждый пост ≤ 280 символов (посты выше в это укладываются; после правок — пересчитать);
- [ ] все числа сверены с §7 `RELEASE-CHECKLIST.md`, а не взяты из этого файла на веру;
- [ ] ссылки открываются и ведут на верифицированные контракты;
- [ ] в треде нет ни одного имени реального человека и ни одного логотипа компании.

---

## 2. Короткое описание (профиль X, token info на Blockscout)

**Версия для token info (3 предложения):**

```
Maclaurin Series (MACLRN) is an ERC-20 whose entire monetary schedule is the series
for e: total supply is floor(e × 10^27), and each weekly epoch emits exactly 10^27/n!
wei, so emission ends at n = 27 by integer arithmetic rather than by decision. The
contracts are immutable and ownerless — no mint, no pause, no proxy, no upgrade path —
and every number above can be checked against the verified source on-chain. An
experimental project: liquidity is small, the price is volatile, and nothing here is
investment advice.
```

**Версия для профиля X (одна строка, если лимит био жмёт):**

```
An ERC-20 whose supply is e and whose emission is Σ 1/n!. Immutable, no mint,
no owner. Experimental — not investment advice.
```

---

## 3. Ответы на вопросы, которые зададут

Общее правило: отвечать **фактом и ссылкой на эксплорер**, а не убеждением.
«Проверьте сами» здесь работает буквально — все утверждения проекта проверяются
одной командой.

### «Это скам?»

```
Fair question — here's what you can check yourself instead of trusting me.

1. mint() does not exist. The token has 12 functions and that isn't one of them.
   No owner, no pause, no blacklist, no proxy. Verified source is on the explorer.
2. The creator's personal address holds zero tokens. Everything was distributed at
   launch: inventory to the curve, treasury to a time-lock, 250M burned to 0x…dEaD.
3. The treasury contract has no early-withdrawal function for anyone, including me.
4. Selling back to the curve has no pause, no cooldown and no allowlist.
5. Four independent audits. The last one found a real hole in the curve — anyone
   holding tokens could have drained the buyers' ETH reserve. It's fixed, the fix
   was audited separately, and the whole thing is written up in the repo.

What I can't give you: a guarantee that the price goes anywhere. Nobody can, and
anyone who does is lying.
```

### «Почему так мало ликвидности?»

```
Because there is no venture money behind this and I'd rather say so.

The curve doesn't need pre-funded liquidity: the ETH that backs buybacks comes from
buyers themselves, and it stays in the contract. Selling the entire inventory would
raise about 3.7 ETH in total — that's the real scale of this thing.

Practical consequence, stated plainly: small trades move the price a lot. Size
accordingly, or don't participate.
```

### «Зачем локи в стейкинге?»

```
Because the reward multiplier is a partial sum of the series, and a multiplier you
can take without committing anything isn't a multiplier — it's a leak.

So: claim() is closed until your unlock time. unstake() is open always and returns
your principal in full, to the last wei — the lock never holds your deposit hostage.
Leaving early burns the accrued reward and sends it to the remainder vault.

Lock length is R weeks for radius R, R = 1..7. You pick it when you stake.
```

### «Почему нельзя продать награды стейкинга обратно в кривую?»

Самый важный из ответов: без него механика выглядит как ограничение продажи,
то есть как признак honeypot. Объяснять надо через защиту покупателя — и добивать
ссылкой на код, потому что здесь это не обещание, а публичный счётчик:
`boughtOf(address)` в `MaclaurinCurve` виден в эксплорере, и `sell()` ревертит
`ExceedsPurchased`, если попросить больше. Механика проверяется тем же способом,
что и всё остальное в проекте, — одной командой.

```
Because the curve is a primary sale with a money-back guarantee, not an exchange.
Its ETH reserve was put there by buyers, and it exists to give it back to them.

If any token could be sold into it, holders of tokens that cost nothing — staking
rewards, genesis shares — would drain the reserve, and actual buyers would find it
empty when they went to exit. That is not hypothetical arithmetic: rewards and
genesis shares together are comparable in size to the entire curve inventory.

So the right to sell back is per-address and equals exactly what that address bought
from the curve — no less and no more. It's a public counter, not a policy: call
boughtOf(yourAddress) on the verified contract and you'll see your own exit right.
Ask for more and sell() reverts with ExceedsPurchased.

Everything else trades on the secondary market, where the counterparty is another
trader, not other buyers' deposits.
```

*Опора: `mapping(address => uint256) public boughtOf` в `src/MaclaurinCurve.sol`;
растёт только в `buy()` на того, чей ETH лёг в резерв, и гасится в `sell()`.
Инвариант `Σ boughtOf == sold` закреплён тестом `invariant_PurchaseRightsSumToSold`,
а сама атака (посторонний забирает резерв покупателя) — пробой
`test_probe_OutsiderCannotStealBuyerReserve`.*

> **Если разговор пойдёт вглубь — это сильный аргумент, а не слабое место.** Первая
> редакция кривой действительно была уязвима именно так, дыру нашёл независимый аудит,
> она воспроизведена тестом (покупатель внёс 1 ETH, посторонний забрал 0.9801 ETH,
> покупатель не смог выйти вообще), закрыта `boughtOf`, а фикс проаудирован отдельным
> проходом. Рассказывать об этом можно и нужно: «мы нашли и починили» проверяется по
> коду, а «у нас всё изначально было идеально» — нет. Разбор целиком — в README,
> раздел «Что нашёл аудит фазы 4». **Формулировать без бравады и без деталей эксплойта
> сверх тех, что уже опубликованы в репозитории.**

> Если спросят «а если я купил у другого держателя?» — отвечать прямо: право выкупа
> живёт на адресе покупателя, а не на токенах, и обычным `transfer` не переносится.
> Иначе учёт пришлось бы вести в самом токене, то есть менять уже развёрнутый
> неизменяемый контракт.

---

## 4. Чего писать нельзя — ни в треде, ни в ответах, ни на лендинге

| Нельзя | Почему |
|---|---|
| «доходность», «APY», «×N к вложениям», ракеты, «to the moon» | Обещание финансового результата. Множитель стейкинга описывать только как механику распределения, никогда как доход |
| Имя, фото, цитата или должность реального человека так, что подразумевается его причастность или одобрение | Прямой запрет из `MACLAURIN-TOKEN-SPEC.md` §9, `PHASE4-SPEC.md` §10 и `README.md` («Правовое»). Проект **не аффилирован** с Robinhood и её руководством |
| Логотипы, шрифты, фирменные цвета чужих компаний | То же самое, только визуально |
| «Мы на цепочке компании X» с намёком на партнёрство | Указание сети деплоя — факт. Претензия на связь — нет. Формулировка: «deployed on Robinhood Chain», без прилагательных |
| «Аудировано, значит безопасно» | Аудит — рассуждение о коде, а не страховка. Писать: «прошёл четыре независимых аудита; последний нашёл критическую дыру, она закрыта и фикс проаудирован отдельно», со ссылками на отчёты. Не писать «находок не было» — они были, и это как раз довод в пользу процесса |
| «Риска нет», «застраховано», «гарантированный возврат» | Кривая гарантирует выкуп **купленного у неё** по формуле, а не сохранность денег. Разница существенная, и её надо проговаривать |
| Прятать масштаб ликвидности | ~3.7 ETH за весь инвентарь — говорить прямо. Умолчание об этом читается как обман, когда цифру найдут сами |
| Публиковать адреса до верификации | `RELEASE-CHECKLIST.md` §9 |

**Обязательный дисклеймер** (лендинг, закреплённый пост, token info — везде, где есть
место):

```
Experimental project. Liquidity is small and the price is volatile; you can lose
everything you put in. Contracts are immutable and cannot be fixed after deployment.
Not affiliated with any company. Nothing here is investment or financial advice.
```

---

## 5. Числа, которые понадобятся под рукой

Все проверяются командами из `RELEASE-CHECKLIST.md` §7 — брать оттуда, а не отсюда.

| Величина | Значение |
|---|---|
| Общий сапплай | `2 718 281 828.459045235360287471` = floor(e × 10²⁷) |
| GENESIS (1/0! + 1/1!) | 2 000 000 000 токенов, 73.576% |
| Пул эмиссии (Σ 1/n!, n ≥ 2) | 718 281 828.459… токенов, 26.424% |
| Эпоха | 7 дней; эпохи 2…26; всего 175 дней |
| Эпоха 2 / 26 / 27 | 500 000 000 токенов / 2 wei / **0** |
| Остаточный член | 14 wei, навсегда в контракте эмиссии |
| Множители стейкинга R=1..7 | 1.0 … 2.718055…, потолок e = 2.718281828459045235 недостижим |
| Инвентарь кривой | 1 000 000 000 токенов, 36.79% сапплая |
| Стартовая цена / конечная | 2 gwei → 5.436563656… gwei за токен, рост ровно ×e |
| Весь инвентарь стоит | `3 718 281 828 459 045 235` wei = (1 + e) ETH ≈ 3.72 ETH |
| Комиссия кривой | 1%, в ETH, обе стороны. Из резерва не берётся никогда |
| Право выкупа | именное: `boughtOf(адрес)` — сколько этот адрес купил у кривой и ещё не вернул. Продать больше → `ExceedsPurchased` |
| Окно анти-снайпа | 1 час от деплоя кривой, ≤ 10 000 000 токенов на адрес (≈ 0.0202 ETH) |
| Сожжено | 250 000 000 токенов (9.20%) в `0x…dEaD` |
| Казна под замком | 500 000 000 (18.39%) до конца эмиссии, досрочно не выдаётся никому |
| На личном адресе создателя | **0** |

> **Про анти-снайп говорить честно.** Это **смягчение, а не защита**: лимит считается
> по адресу и обходится несколькими кошельками. Он даёт обычным покупателям несколько
> блоков форы, и подавать его надо ровно так — иначе первая же ветка «а я обошёл»
> превратится в обвинение во лжи. И если окно было потеряно при деплое
> (`RELEASE-CHECKLIST.md` §5.2, случай 3) — про анти-снайп не писать вообще.
