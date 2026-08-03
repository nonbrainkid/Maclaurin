# Maclaurin Series ($MACLRN) — RELEASE CHECKLIST

Единый документ «от готового кода до запуска». Идти строго сверху вниз.
Каждый пункт — что сделать, **критерий «сделано»** и **что делать, если пошло не так**.

> **Про имя.** Проект называется **Maclaurin Series**, тикер **MACLRN**.
> Ряд Маклорена — это ряд Тейлора, разложенный в нуле; наш ряд
> `e = Σ 1/n! = 1/0! + 1/1! + 1/2! + …` именно такой.
> Переименование доведено до кода: контракты называются `Maclaurin*`,
> в конструкторе токена стоит `ERC20("Maclaurin Series", "MACLRN")`
> (`src/MaclaurinToken.sol:65`). `name` и `symbol` зашиты в конструктор и после
> деплоя не меняются никогда — поэтому на цепочке они появятся ровно такими.

Легенда:

| Пометка | Смысл |
|---|---|
| 🔴 | Необратимо или блокирует деплой |
| 🟡 | Подставить свои значения |
| ⛔ | Блокер: пока не закрыт, деплой в мейннет не начинается |

Все команды — PowerShell (Windows). В Windows PowerShell 5.1 **нет `&&` и `||`**,
поэтому команды даны по одной на строку.

---

## 0. Фактическое состояние репозитория

Сверено с кодом 2026-08-03 (`forge test`, `forge build --sizes`, `grep` по `src/`).
Единственный источник правды здесь — код; если документ и код расходятся, прав код.

| Что | Как есть на самом деле |
|---|---|
| Контракты | Четыре: `MaclaurinToken`, `MaclaurinEmission`, `MaclaurinCurve`, `MaclaurinVesting`. Все неизменяемые, без владельца, без прокси, без паузы |
| Имя и тикер в коде | `ERC20("Maclaurin Series", "MACLRN")`, `src/MaclaurinToken.sol:65`. Переименование доведено до кода целиком — `Taylor` в `src/`, `test/`, `script/` не встречается |
| Тесты | **229 passed, 0 failed, 1 skipped** (`test_Run_OnFork` без `DEPLOY_FORK_RPC_URL`). Плюс 17 символьных проверок `check_*` в `test/halmos/Formal.t.sol` — их `forge test` не подхватывает |
| Slither | 0 находок, конфиг `slither.config.json`, `fail_on: low` |
| `forge fmt --check` | чисто |
| Сеть | **Robinhood Chain**: 4663 (mainnet) / 46630 (testnet). Верификация через **Blockscout**, ключ API не нужен. Base/Basescan из проекта ушли |
| Раскладка genesis | **Решена и захардкожена** в `script/Distribute.s.sol` (доли — `constant` в байткоде скрипта, таблица — `PHASE4-SPEC.md` §7 и §7.1 ниже). На адресе создателя после раскладки — ноль |
| Пул Uniswap | **Из критического пути выведен.** Ликвидность даёт бондинг-кривая; доли под LP в раскладке genesis нет. `script/Pool.s.sol` остаётся как необязательный шаг после запуска |
| Тестнет | Пройден **на старой версии, до переименования и до фикса кривой**. Адреса из `LAUNCH-PLAN.md` этап 2 — история; нужен передеплой (§3.4) |
| Кривая — не биржа | В `MaclaurinCurve` есть `boughtOf`: продать в кривую можно ровно то, что этот адрес у неё купил. Это код, а не обещание (`src/MaclaurinCurve.sol`, `sell()`) |

Разбивка 229 тестов по файлам — для §2.2:

| Файл | Тестов |
|---|---|
| `test/MaclaurinCurve.t.sol` | 57 (43 + 14 инвариантов) |
| `test/MaclaurinEmission.t.sol` | 45 |
| `test/MaclaurinRadius.t.sol` | 33 |
| `test/Distribute.t.sol` | 22 |
| `test/MaclaurinVesting.t.sol` | 19 |
| `test/MaclaurinToken.t.sol` | 13 |
| `test/AuditProbe.t.sol` | 11 |
| `test/MaclaurinInvariants.t.sol` | 10 |
| `test/CurveProbe.t.sol` | 7 |
| `test/Phase2Probe.t.sol` | 7 |
| `test/Deploy.t.sol` | 5 (+1 skip) |

**Что из фазы 4 действительно готово:** `src/MaclaurinCurve.sol`, `src/MaclaurinVesting.sol`,
`script/Distribute.s.sol`, тесты к ним, пробы `test/CurveProbe.t.sol`, символьные
проверки `test/halmos/Formal.t.sol`, конфиг `halmos.toml`.

**Чего нет — это и есть содержание §1 и §2:**

| Пробел | Где закрывается |
|---|---|
| Скрипта, который разворачивает кривую и казну одним прогоном с раскладкой | §1.2 |
| Ни одного коммита в репозитории (`git log` → «does not have any commits yet») — тегировать нечего | §1.4 |
| Независимого аудита фазы 4 (`MaclaurinCurve`, `MaclaurinVesting`, `Distribute.s.sol`) | §2.5 |
| Записи о фактическом прогоне halmos: доказательства написаны, но не прогнаны до конца | §2.4 |
| Тестнет-прогона фазы 4 — кривая и казна в живой сети не разворачивались ни разу | §3.4 |
| `DEPLOY-RUNBOOK.md` описывает только эмиссию, токен и пул; про кривую, казну и `Distribute.s.sol` в нём нет ни строки | отдельная задача, деплой не блокирует |
| У `rh_testnet` в `foundry.toml` URL с хвостом `/rpc`, в `.env.example` — без него | §4.1 |

---

## 1. ⛔ Блокеры. Пока не закрыты — дальше не идти

### 1.1 Имя на цепочке и имя в материалах совпадают

✅ **Код:** переименование доведено до конца. `src/MaclaurinToken.sol:65` —
`ERC20("Maclaurin Series", "MACLRN")`, строки `Taylor` в `src/`, `test/`, `script/`
не осталось. Проверяется одной командой:

```powershell
Select-String -Pattern "Taylor" -Path src\*.sol,test\*.sol,script\*.sol   # ничего
```

⛔ **Что ещё открыто:** хендл в X. `@TaylorSeriesRHC` (`LAUNCH-PLAN.md` этап 7) занимали
под старое имя, и с `name()` он больше не совпадает. Сверка «хендл ↔ эксплорер» —
базовая проверка доверия, поэтому хендл, совпадающий с `Maclaurin Series`, занимается
**до** анонса и после анонса не меняется.

- **Сделано:** `cast call $TOKEN "name()(string)"` вернул `Maclaurin Series`,
  `symbol()` → `MACLRN`; хендл в X и заголовок лендинга совпадают с ними буква в букву;
  судьба старого хендла решена (удалить, перенаправить или молча оставить — но не
  использовать в материалах).
- **Если не так:** деплой откладывается. Любая правка `name`/`symbol` — **изменение
  кода**, значит после неё заново §2 целиком, включая аудит диффа.

### 1.2 Один прогон: деплой кривой + раздача genesis 🔴

**Требование.** Развёртывание `MaclaurinCurve` и перевод в неё инвентаря обязаны
пройти **одним прогоном скрипта**, без ручной паузы между ними.

**Почему.** `MaclaurinCurve` ставит часы в конструкторе:

```solidity
startTime    = block.timestamp;                        // src/MaclaurinCurve.sol:314
antiSnipeEnd = block.timestamp + ANTI_SNIPE_WINDOW;    // ANTI_SNIPE_WINDOW = 1 hours
```

Окно анти-снайпа (лимит `ANTI_SNIPE_MAX = 10 000 000` токенов на адрес, §7.4)
отсчитывается **от деплоя**, а не от первой продажи. Если между деплоем кривой и
переводом инвентаря пройдёт больше часа, к моменту, когда торговать станет чем,
окно уже истечёт — и смягчение не сработает вообще: первый же адрес сможет выкупить
любую долю инвентаря одной транзакцией.

**Чего сейчас нет.** `script/Distribute.s.sol` принимает адреса кривой и казны из
окружения (`MACLAURIN_CURVE`, `MACLAURIN_VESTING`) — то есть предполагает, что они **уже
развёрнуты**. Скрипта, который их разворачивает, в `script/` нет (там только
`Deploy.s.sol`, `Distribute.s.sol` и необязательный `Pool.s.sol`).

**Что сделать:** написать `script/Launch.s.sol`, который одним прогоном:

1. читает адрес уже развёрнутой эмиссии, берёт `emission.startTime()`;
2. разворачивает `MaclaurinVesting(token, beneficiary, startTime + 175 days)`;
3. разворачивает `MaclaurinCurve(token, feeRecipient)` — **последним из деплоев**;
4. сразу за этим вызывает `Distribute.distribute(token, sender, recipients, expectedUnlockTime)`
   с адресами из памяти, а **первым** переводом ставит долю кривой;
5. подписывается **одним** кошельком — тем, на котором лежит genesis
   (`Distribute.distribute` делает `vm.startBroadcast(sender)`, где `sender` = `GENESIS_RECIPIENT`;
   второй ключ в том же прогоне означал бы `--private-keys` россыпью — лишний риск).

- **Сделано:** прогон на форке мейннета отправляет 8 транзакций (2 деплоя + 6 переводов),
  между первой и последней проходит **меньше часа**; в логе — `sender balance is zero,
  all post-checks hold`; на скрипт есть тест в `test/`, покрывающий порядок и адреса.
- **Если не так** (прогон встал посередине, часть переводов ушла, часть нет): не
  досылать переводы руками «как получится». Сначала §11.2 — оценить, истекло ли окно,
  и решить: доложить остаток тем же скриптом (`verify()` покажет, чего не хватает) или
  развернуть кривую заново и перевести инвентарь в новую (старая останется пустой и
  безвредной — продавать ей нечего).

> «Один прогон» ≠ «одна транзакция». Foundry шлёт транзакции по одной внутри одного
> broadcast; это нормально. Считать надо не транзакции, а **время от деплоя кривой до
> перевода инвентаря**: оно обязано быть меньше часа. Средний блок Robinhood Chain —
> около 101 с (`DEPLOY-RUNBOOK.md` §11), восемь транзакций это ~15 минут. Запас есть,
> но он не бесконечный: не запускать прогон, если сеть тормозит.

### 1.3 Адреса и параметры, которые после деплоя не переигрываются 🔴

Заполнить и перепроверить глазами **до** любой транзакции. Все — immutable.

| Что | Куда идёт | Чем плоха ошибка |
|---|---|---|
| `GENESIS_RECIPIENT` | конструктор `MaclaurinEmission` | На него минтятся 2 000 000 000 токенов; он же подписывает прогон §1.2. Ошибка = передеплой всего |
| `REMAINDER_VAULT` | конструктор `MaclaurinEmission` + хвостовая доля genesis | Казна остаточного члена навсегда |
| `feeRecipient` кривой | конструктор `MaclaurinCurve` | Получатель 1% комиссии навсегда, функции смены нет |
| `beneficiary` казны | конструктор `MaclaurinVesting` | Единственный получатель 500 000 000 токенов навсегда |
| `MARKETING_WALLET`, `RESERVE_WALLET` | `Distribute.s.sol` | Обычные кошельки, но 125M и 62.5M токенов |
| `EMISSION_START_DELAY` | `Deploy.s.sol` | Мейннет — `86400`. Минимум 300 (`MIN_START_DELAY`) |
| `EXPECTED_UNLOCK_TIME` | `Distribute.s.sol` | Для мейннета **задать обязательно**: `emission.startTime() + 15 120 000` (175 дней). Не задана — сверка молча пропускается |

- **Сделано:** каждый адрес открыт в эксплорере, у каждого проверено, что ты
  контролируешь ключ (тестовый перевод на копейку туда-обратно — до мейннета, в тестнете
  или на форке); ни один адрес не повторяется дважды.
- **Если не так:** `Distribute.s.sol` отобьёт нули и дубликаты (`_checkRecipients`),
  но опечатку в валидном чужом адресе не поймает никто. 1.5 миллиарда токенов на
  чужом кошельке не отзываются.

### 1.4 Код под контролем версий

- **Сделано:** `git add` + `git commit` всего репозитория (кроме `.env`, `out/`, `cache/`,
  `broadcast/` — они уже в `.gitignore`), `git tag maclrn-mainnet-v1` на том коммите,
  который идёт в мейннет, `git log --oneline -1` печатает его.
- **Если не так:** воспроизвести байткод для верификации потом будет нечем, а на вопрос
  «какой код развёрнут» не окажется ответа. Без коммита мейннета нет.

### 1.5 Мусор из репозитория убран

✅ Проверено 2026-08-03: в `test/` только одиннадцать рабочих файлов и `test/halmos/`,
временных файлов вида `test/ZZTmpNum.t.sol` нет, `forge test` зелёный.

- **Сделано:** то же самое ещё раз, непосредственно перед тегом §1.4 — файл мог
  появиться после этой проверки.
- **Если не так:** временный тест уедет в тег и в публичный репозиторий; вопрос «что это»
  задаст первый же читатель.

---

## 2. Что должно быть зелёным до деплоя

Всё в этом разделе прогоняется **на том самом коммите**, который идёт в мейннет.
Не «на прошлой неделе», не «до переименования».

### 2.1 Формат и сборка

```powershell
forge fmt --check
forge build --sizes
```

Замер 2026-08-03 (лимит EIP-170 — 24 576 B runtime):

| Контракт | Runtime | Initcode | Запас до лимита |
|---|---:|---:|---:|
| `MaclaurinEmission` | 6 988 B | 11 322 B | 17 588 B |
| `MaclaurinCurve` | 5 643 B | 6 022 B | 18 933 B |
| `MaclaurinToken` | 2 479 B | 3 676 B | 22 097 B |
| `MaclaurinVesting` | 1 223 B | 1 555 B | 23 353 B |

- **Сделано:** `fmt --check` молчит; сборка зелёная; размеры совпали с таблицей выше
  (расхождение = развёрнут будет не тот код, который аудировали).
- **Если не так:** `forge fmt` без `--check` чинит формат; превышение лимита EIP-170
  чинится только правкой кода → назад в §2.5 (аудит изменённого).

### 2.2 Тесты

```powershell
forge test
forge test --match-path test/MaclaurinCurve.t.sol
forge test --match-path test/CurveProbe.t.sol
forge test --match-path test/Distribute.t.sol
forge test --match-path test/MaclaurinInvariants.t.sol
```

Эталон 2026-08-03: **229 passed, 0 failed, 1 skipped** (разбивка по файлам — §0).

- **Сделано:** `0 failed`, и число passed **не меньше** 229. Пропуск допустим ровно
  один — `test_Run_OnFork` без `DEPLOY_FORK_RPC_URL`. Уменьшилось число тестов —
  разобраться почему, прежде чем идти дальше: тест мог быть удалён вместе с
  проверяемым им свойством.
- **Если не так:** ни одного «оно и раньше падало». Красный тест = деплоя нет.

### 2.3 Slither

```powershell
slither .
```

- **Сделано:** 0 находок. Конфиг — `slither.config.json`, `fail_on: low`.
  Обоснование каждого исключения — в `README.md`, раздел «Slither».
- **Если не так:** каждая новая находка либо чинится, либо получает письменное
  обоснование в README **до** деплоя. Молча добавлять детектор в
  `detectors_to_exclude` запрещено.
- **Помнить:** Slither собирает проект без `script/**`, то есть `Deploy.s.sol`,
  `Distribute.s.sol` и будущий `Launch.s.sol` статикой **не покрыты**. Их закрывают
  только тесты и репетиции (§4).

### 2.4 Символьные проверки (halmos)

CI их не гоняет (`.github/workflows/test.yml` — только fmt/build/test/slither),
значит запускать руками.

```powershell
halmos --match-path test/halmos/Formal.t.sol
```

**Состояние: доказательства написаны, полный прогон не закончен.** В
`test/halmos/Formal.t.sol` 17 функций `check_*` (теоремы A–E4), конфиг в `halmos.toml`
разобран построчно, но записи о завершённом прогоне нет ни в одном документе. Считать
это невыполненным пунктом, а не выполненным по умолчанию. Что именно доказывается и
где проходит граница честности — `README.md`, раздел «Machine-checked proofs».

- **Сделано:** все 17 `check_*` прошли; в выводе **нет** предупреждения о достигнутой
  границе разворачивания циклов (`loop = 26` в `halmos.toml` подобран так, чтобы обе
  петли `MaclaurinEmission` разворачивались целиком); вывод сохранён в материалы запуска —
  «прогнали и всё сошлось» без лога равнозначно «не прогоняли».
- **Известное ограничение, не считать его провалом:** двоичный поиск
  `MaclaurinCurve._tokensFor` (~90 итераций) из области доказательства **исключён явно**;
  в теореме E2 он заменён своим постусловием. Его закрывают обычные тесты и фаззинг,
  и об этом честно написано и в `halmos.toml`, и в самом `Formal.t.sol`.
- **Если не так:** контрпример от halmos — это находка уровня Critical, пока не доказано
  обратное. Разбирать до деплоя. Если прогон не сходится по времени или падает по
  инструменту — так и написать в материалах: «доказательства не прогнаны», а не
  ссылаться на наличие файла.

### 2.5 Аудиты

| Что | Состояние | Где записано |
|---|---|---|
| Фаза 1 (`MaclaurinToken`, `MaclaurinEmission`) | ✅ Critical/High/Medium — 0; единственный Low исправлен (`MIN_START_DELAY = 300`) | `LAUNCH-PLAN.md` этап 1 |
| Фаза 2 (веса, локи, `poke`) | ✅ Critical/High/Medium/Low — 0 | `PHASE3-PLAN.md` §3.1 |
| **Фаза 4 (`MaclaurinCurve`, `MaclaurinVesting`, `Distribute.s.sol`)** | ⛔ **записи о независимом аудите нет** | — |
| **`script/Launch.s.sol` (§1.2)** | ⛔ ещё не написан | — |
| Переименование `Taylor*` → `Maclaurin*` | ⛔ дифф аудитом не проходил | — |

> Переименование трогает конструктор токена, а значит и байткод всех четырёх
> контрактов. Формально это правка кода после аудита (§9.1), и закрывается она тем же
> проходом по фазе 4 — отдельного аудита переименования не нужно, но и «мы же только
> строчку поменяли» здесь не работает.

- **Сделано:** независимый проход по фазе 4 (субагент `smart-contract-auditor`,
  только чтение `src/` и `script/`), Critical/High/Medium — ноль, каждое Info
  с письменным обоснованием; отчёт приложен к материалам запуска.
- **Если не так:** Medium и выше — чинить и аудировать заново. Аудит «почти прошёл»
  не бывает: контракты неизменяемы.

---

## 3. Репетиции. Всё, что можно сломать бесплатно, ломается здесь

### 3.1 Локальный anvil — связка эмиссии

`DEPLOY-RUNBOOK.md` §4.1, командами оттуда. Anvil умеет перематывать время, поэтому
здесь проверяется то, чего не проверить в живой сети: успешный `claim()` после лока,
`poke()` на истёкшей позиции.

- **Сделано:** в выводе `all post-deploy invariants hold` и
  `total supply (wei): 2718281828459045235360287471`; цикл
  `stake → earned → claim → unstake → exit → poke → sweep` прошёл целиком.

### 3.2 Локальный anvil — кривая, казна, раскладка

Тот же anvil, но прогоняется §1.2 целиком: `Launch.s.sol` на свежей ноде.

- **Сделано:** `sender balance is zero, all post-checks hold`; балансы получателей
  совпали с таблицей §7.1 до последнего wei; `curve.token()` равен адресу токена;
  `vesting.unlockTime()` равен `emission.startTime() + 15 120 000`.
- **Если не так:** любой упавший `require` в `Distribute` — это **успех** репетиции.
  Читать текст ошибки, чинить окружение, повторять.

### 3.3 Форк мейннета — генеральная репетиция

```powershell
anvil --fork-url https://rpc.mainnet.chain.robinhood.com
```

Здесь и только здесь проверяется поведение с реальными деньгами без реальных денег.

- [ ] `Deploy.s.sol` → `Launch.s.sol` подряд, как в мейннете;
- [ ] покупка на маленькую сумму: `previewBuy` → `buy` → сверить фактический `tokensOut`
      с превью;
- [ ] продажа обратно **тем же адресом**: `approve` → `sell` → пришло меньше, чем
      уплачено (комиссия 1% с обеих сторон плюс округление в пользу протокола);
- [ ] продажа **чужим** адресом, у которого есть токены, но он ничего не покупал у
      кривой → `ExceedsPurchased`;
- [ ] попытка купить больше `ANTI_SNIPE_MAX` в первый час → `AntiSnipeLimit`;
- [ ] `withdrawFees()` доставляет комиссию на `feeRecipient`, `reserve` при этом
      не меняется;
- [ ] `release()` казны до срока → `StillLocked`.
- **Сделано:** все семь пунктов отработали как описано.
- **Если не так:** это блокирующая находка. Мейннет отменяется до разбора.

### 3.4 Тестнет Robinhood Chain (46630) — передеплой всей связки

Эмиссия в тестнете уже проходилась (`LAUNCH-PLAN.md` этап 2, контракты
`0x842f0f32…` / `0x7D4E9AAA…`), но тот прогон **не засчитывается**:

- он сделан **до переименования** — в байткоде по тем адресам зашиты `"Taylor Series"`
  и `"TAYLOR"`, и поменять их нельзя, контракты неизменяемы;
- он сделан **до фикса кривой** (`boughtOf`), а кривой и казны там не было вообще.

Значит тестнет проходится **заново, целиком**: `Deploy.s.sol` → `Launch.s.sol` →
ручной цикл. Старые адреса — история этапа, ссылаться на них в материалах нельзя.

- [ ] `Deploy.s.sol` в тестнете заново, под `MaclaurinToken`/`MaclaurinEmission`;
- [ ] `Launch.s.sol` в тестнете, `EMISSION_START_DELAY=300`;
- [ ] верификация всех новых контрактов на тестнет-Blockscout (§6) — репетиция
      команд перед мейннетом;
- [ ] реальная покупка и продажа обратно тестовым ETH;
- [ ] `verify()` раскладки:
      `forge script script/Distribute.s.sol --sig "verify()" --rpc-url rh_testnet`.
- **Сделано:** всё прошло, ничего не зареверило неожиданно, а всё, что должно было
  зареверить, зареверило **с правильной ошибкой**.
- **Если не так:** чинить и повторять. Тестнет стоит ноль, мейннет — весь бюджет.

---

## 4. Подготовка к мейннету

### 4.1 Сеть и алиасы

```powershell
cast chain-id --rpc-url https://rpc.mainnet.chain.robinhood.com    # 4663
cast chain-id --rpc-url rh                                          # 4663
cast chain-id --rpc-url rh_testnet                                  # 46630
```

- **Сделано:** все три вернули ожидаемое.
- **Если не так:** у `rh_testnet` в `foundry.toml` URL с хвостом `/rpc`, а в
  `.env.example` — без него. Расхождение известное: писать полный URL руками, пока
  не проверено, какая форма живая. `foundry.toml` при этом **не трогать ни в чём,
  кроме `[rpc_endpoints]`**: `solc = 0.8.24`, `evm_version = shanghai`,
  `optimizer_runs = 1000000` обязаны остаться, иначе не сойдётся верификация.

### 4.2 Ключи

```powershell
cast wallet import maclrn-deployer --interactive
cast wallet import maclrn-genesis  --interactive
cast wallet address --account maclrn-deployer
cast wallet address --account maclrn-genesis
```

- **Сделано:** оба адреса совпали с тем, что показывает кошелёк; приватный ключ
  нигде не появлялся в открытом виде — ни в `.env`, ни в аргументах команд,
  ни в истории PowerShell.
- **Если не так:** кошелёк, чей ключ засветился в аргументе или в `.env`, считается
  скомпрометированным навсегда. Завести новый, не «быть аккуратнее».

### 4.3 Деньги

- **Сделано:** ETH заведён **сразу в сети Robinhood Chain** (не бридж из Ethereum —
  бридж съест бюджет); на деплоере — сумма газа плюс запас минимум `0.0005 ETH`;
  на genesis-кошельке — ETH на 8 транзакций прогона §1.2.
- Смета по замерам (`DEPLOY-RUNBOOK.md` §9): деплой эмиссии — 2 327 373 газа
  (~$0.09 при 0.02 gwei). Деплой кривой и казны плюс шесть переводов — того же
  порядка. Пул на Uniswap в критический путь запуска **не входит**.
- **Если не так:** `cast gas-price --rpc-url rh` перед прогоном; при аномальной цене
  газа — просто подождать, спешить некуда.

### 4.4 Сухой прогон (бесплатно, повторяемо)

```powershell
forge script script/Deploy.s.sol:Deploy --rpc-url rh --sender $DEPLOYER
```

- **Сделано:** `chain id: 4663`, `all post-deploy invariants hold`, адреса genesis
  и vault — твои, `Estimated amount required` укладывается в баланс.
- **Если не так:** `StartTimeInPast` → поднять `EMISSION_START_DELAY` до 86400.

---

## 5. Мейннет-деплой

### 5.1 Шаг 1 — эмиссия и токен 🔴

```powershell
$MRPC = "https://rpc.mainnet.chain.robinhood.com"
forge script script/Deploy.s.sol:Deploy --rpc-url $MRPC --account maclrn-deployer --sender $DEPLOYER --broadcast
```

Сразу записать:

```powershell
$EMISSION = "0x..."
$TOKEN = (cast call $EMISSION "token()(address)" --rpc-url $MRPC)
```

- **Сделано:** в выводе `all post-deploy invariants hold`; `$TOKEN` получен **из
  контракта**, а не из лога; блок деплоя записан (пригодится для `cast logs`).
- **Если не так:** транзакция зареверила — деньги почти не потрачены, читать ошибку
  по таблице `DEPLOY-RUNBOOK.md` §7.0 и повторять. Развернулось с неверным
  `GENESIS_RECIPIENT`/`REMAINDER_VAULT` — только передеплой, адреса immutable.

> Здесь пауза допустима: у эмиссии нет часов, которые начинают тикать в конструкторе,
> кроме `startTime = деплой + EMISSION_START_DELAY` (сутки запаса). У кривой — есть,
> поэтому шаг 2 разрывать нельзя.

### 5.2 Шаг 2 — казна, кривая, раскладка genesis: ОДНИМ ПРОГОНОМ 🔴

```powershell
$env:MACLAURIN_TOKEN         = $TOKEN
$env:GENESIS_RECIPIENT    = "0x..."     # тот же, что в шаге 1
$env:MARKETING_WALLET     = "0x..."
$env:RESERVE_WALLET       = "0x..."
$env:REMAINDER_VAULT      = "0x..."     # тот же, что в шаге 1
$env:EXPECTED_UNLOCK_TIME = "..."       # emission.startTime() + 15120000

forge script script/Launch.s.sol:Launch --rpc-url $MRPC --account maclrn-genesis --sender $GENESIS --broadcast
```

`EXPECTED_UNLOCK_TIME` считается заранее, до прогона:

```powershell
$START = [int64]((cast call $EMISSION "startTime()(uint256)" --rpc-url $MRPC).Split(" ")[0])
$START + 15120000
[DateTimeOffset]::FromUnixTimeSeconds($START + 15120000).UtcDateTime
```

- **Сделано:** в логе — адреса развёрнутых `MaclaurinVesting` и `MaclaurinCurve`,
  `unlockTime matches EXPECTED_UNLOCK_TIME`, шесть переводов и финальное
  `sender balance is zero, all post-checks hold`. От транзакции деплоя кривой до
  транзакции перевода инвентаря — **меньше часа** (сверить по таймстампам блоков).
- **Если не так — три разных случая:**
  1. **Упало в симуляции, ничего не отправлено** (самый частый и самый безобидный).
     Читать текст `require`: `sender balance != GENESIS`, `vesting unlockTime !=
     EXPECTED_UNLOCK_TIME`, `curve is not a contract`, `duplicate address among
     recipients`. Чинить окружение, повторять — цена ноль.
  2. **Прогон встал посередине.** Не досылать переводы руками наугад. Запустить
     `forge script script/Distribute.s.sol --sig "verify()" --rpc-url rh` — он скажет,
     какая доля не сошлась, и досылать ровно её.
  3. **Между деплоем кривой и переводом инвентаря прошло больше часа.** Окно
     анти-снайпа потеряно. Решение принимается сознательно: либо принять (и **не
     писать в материалах, что защита от снайпинга работает**), либо развернуть кривую
     заново и перевести инвентарь в новую. Старая кривая без инвентаря безвредна —
     продавать ей нечего.

### 5.3 Что после этого шага верно навсегда

- на личном адресе создателя — **ноль токенов**;
- 250 000 000 токенов уничтожены в `0x…dEaD`;
- 500 000 000 заперты в `MaclaurinVesting` до `startTime + 175 дней`, и функции
  досрочного вывода не существует ни для кого;
- 1 000 000 000 лежат в кривой и достаются только покупкой за ETH;
- у создателя нет ни одной функции, изымающей резерв кривой.

---

## 6. Верификация на Blockscout (ключ не нужен)

Верифицировать **четыре** контракта: `MaclaurinToken`, `MaclaurinEmission`, `MaclaurinCurve`,
`MaclaurinVesting`. Etherscan здесь ни при чём — у сети его нет.

```powershell
$CHAIN = "4663"
$VURL  = "https://robinhoodchain.blockscout.com/api/"      # косая черта на конце ОБЯЗАТЕЛЬНА
$RPCV  = "https://rpc.mainnet.chain.robinhood.com"
```

### 6.1 Три простых контракта

У `MaclaurinEmission`, `MaclaurinCurve` и `MaclaurinVesting` есть настоящие транзакции создания,
поэтому аргументы конструктора достаются из calldata:

```powershell
forge verify-contract $EMISSION src/MaclaurinEmission.sol:MaclaurinEmission --chain $CHAIN --rpc-url $RPCV --guess-constructor-args --compiler-version 0.8.24 --num-of-optimizations 1000000 --verifier blockscout --verifier-url $VURL --watch
forge verify-contract $CURVE    src/MaclaurinCurve.sol:MaclaurinCurve       --chain $CHAIN --rpc-url $RPCV --guess-constructor-args --compiler-version 0.8.24 --num-of-optimizations 1000000 --verifier blockscout --verifier-url $VURL --watch
forge verify-contract $VESTING  src/MaclaurinVesting.sol:MaclaurinVesting   --chain $CHAIN --rpc-url $RPCV --guess-constructor-args --compiler-version 0.8.24 --num-of-optimizations 1000000 --verifier blockscout --verifier-url $VURL --watch
```

Если `--guess-constructor-args` не сработал — собрать руками:

```powershell
$EMISSION_ARGS = cast abi-encode "constructor(address,address,uint256)" $GENESIS $env:REMAINDER_VAULT $START
$CURVE_ARGS    = cast abi-encode "constructor(address,address)" $TOKEN $FEE_RECIPIENT
$VESTING_ARGS  = cast abi-encode "constructor(address,address,uint256)" $TOKEN $BENEFICIARY $UNLOCK
cast abi-decode --input "f(address,address,uint256)" $EMISSION_ARGS      # сверить глазами порядок
```

и передать через `--constructor-args`.

### 6.2 Токен — отдельный случай 🔴

`MaclaurinToken` рождается **внутри конструктора** `MaclaurinEmission`, транзакции создания
у него нет, поэтому `--guess-constructor-args` здесь бесполезен принципиально.
Порядок из трёх попыток (в тестнете сработала первая же с `--constructor-args`,
вопреки пометке «Only for Etherscan» в справке forge):

```powershell
$TOKEN_ARGS = cast abi-encode "constructor(address,address)" $GENESIS $EMISSION
$TOKEN_ARGS.Length     # 130
cast abi-decode --input "f(address,address)" $TOKEN_ARGS    # ровно genesis, затем emission

# попытка 1 — без аргументов
forge verify-contract $TOKEN src/MaclaurinToken.sol:MaclaurinToken --chain $CHAIN --rpc-url $RPCV --compiler-version 0.8.24 --num-of-optimizations 1000000 --verifier blockscout --verifier-url $VURL --watch

# попытка 2 — с аргументами
forge verify-contract $TOKEN src/MaclaurinToken.sol:MaclaurinToken --chain $CHAIN --rpc-url $RPCV --constructor-args $TOKEN_ARGS --compiler-version 0.8.24 --num-of-optimizations 1000000 --verifier blockscout --verifier-url $VURL --watch

# попытка 3 — веб-форма эксплорера (поле для аргументов там есть гарантированно)
New-Item -ItemType Directory -Force .ignore | Out-Null
forge verify-contract $TOKEN src/MaclaurinToken.sol:MaclaurinToken --chain $CHAIN --show-standard-json-input > .ignore/token-standard-input.json
Start-Process "https://robinhoodchain.blockscout.com/address/$TOKEN/contract-verification"
```

В форме: **Solidity (Standard JSON Input)**, компилятор `0.8.24`, EVM version
**shanghai**, аргументы конструктора — `$TOKEN_ARGS` **без префикса `0x`**.

### 6.3 Критерий «сделано»

```powershell
(Invoke-RestMethod "https://robinhoodchain.blockscout.com/api/v2/smart-contracts/$TOKEN").is_verified
(Invoke-RestMethod "https://robinhoodchain.blockscout.com/api/v2/smart-contracts/$EMISSION").is_verified
(Invoke-RestMethod "https://robinhoodchain.blockscout.com/api/v2/smart-contracts/$CURVE").is_verified
(Invoke-RestMethod "https://robinhoodchain.blockscout.com/api/v2/smart-contracts/$VESTING").is_verified
```

- **Сделано:** четыре `True`, и на каждой странице эксплорера во вкладке Contract виден
  исходник, а не hex.
- **Если не так:** таблица причин — `DEPLOY-RUNBOOK.md` §5.6. Чаще всего: забытая косая
  черта в `--verifier-url`, несовпадение `evm_version`/`optimizer_runs` с `foundry.toml`,
  контракт ещё не проиндексирован (подождать пару минут). Верификация бесплатна и
  повторяется сколько угодно раз. Запасной путь — `--verifier sourcify`.

**Пока не верифицированы все четыре — адреса не публикуются нигде.**

---

## 7. Пост-деплойные проверки на цепочке

Всё ниже — `cast call`, то есть бесплатно и без транзакций. Задать один раз:

```powershell
$RPC   = "https://rpc.mainnet.chain.robinhood.com"
$DEAD  = "0x000000000000000000000000000000000000dEaD"
```

### 7.1 Раскладка genesis — таблица из `PHASE4-SPEC.md` §7

```powershell
cast call $TOKEN "balanceOf(address)(uint256)" $GENESIS   --rpc-url $RPC
cast call $TOKEN "balanceOf(address)(uint256)" $CURVE     --rpc-url $RPC
cast call $TOKEN "balanceOf(address)(uint256)" $VESTING   --rpc-url $RPC
cast call $TOKEN "balanceOf(address)(uint256)" $DEAD      --rpc-url $RPC
cast call $TOKEN "balanceOf(address)(uint256)" $MARKETING --rpc-url $RPC
cast call $TOKEN "balanceOf(address)(uint256)" $RESERVE   --rpc-url $RPC
cast call $TOKEN "balanceOf(address)(uint256)" $VAULT     --rpc-url $RPC
cast call $TOKEN "balanceOf(address)(uint256)" $EMISSION  --rpc-url $RPC
```

| Адрес | Ожидаемое значение (wei) | Токенов | Доля сапплая |
|---|---:|---:|---:|
| **`GENESIS_RECIPIENT`** | **`0`** | **0** | **0%** |
| `MaclaurinCurve` (инвентарь, 1/2) | `1000000000000000000000000000` | 1 000 000 000 | 36.79% |
| `MaclaurinVesting` (казна, 1/4) | `500000000000000000000000000` | 500 000 000 | 18.39% |
| `0x…dEaD` (сожжено, 1/8) | `250000000000000000000000000` | 250 000 000 | 9.20% |
| `MARKETING_WALLET` (1/16) | `125000000000000000000000000` | 125 000 000 | 4.60% |
| `RESERVE_WALLET` (1/32) | `62500000000000000000000000` | 62 500 000 | 2.30% |
| `REMAINDER_VAULT` (хвост) | `62500000000000000000000000` | 62 500 000 | 2.30% |
| `MaclaurinEmission` (пул эмиссии) | `718281828459045235360287471` | 718 281 828.459… | 26.42% |

- **Сделано:** совпало **всё**, и в первую очередь первая строка — ноль на личном адресе
  создателя. Сумма шести долей раскладки = ровно `2e27`.
- **Если не так:** `forge script script/Distribute.s.sol --sig "verify()" --rpc-url rh`
  покажет, какая именно доля не сошлась. Досылать ровно недостающее, с того же кошелька,
  и повторять `verify()` до полного схождения.

### 7.2 Токен

```powershell
cast call $TOKEN "name()(string)" --rpc-url $RPC              # Maclaurin Series
cast call $TOKEN "symbol()(string)" --rpc-url $RPC            # MACLRN
cast call $TOKEN "decimals()(uint8)" --rpc-url $RPC           # 18
cast call $TOKEN "totalSupply()(uint256)" --rpc-url $RPC      # 2718281828459045235360287471
cast call $TOKEN "GENESIS()(uint256)" --rpc-url $RPC          # 2000000000000000000000000000
cast call $TOKEN "EMISSION_POOL()(uint256)" --rpc-url $RPC    #  718281828459045235360287471
```

Отсутствие привилегий — не по обещанию, а поиском селекторов в **развёрнутом** байткоде:

```powershell
$code = cast code $TOKEN --rpc-url $RPC
$code -match "40c10f19"    # mint(address,uint256)      -> False
$code -match "8da5cb5b"    # owner()                    -> False
$code -match "f2fde38b"    # transferOwnership(address) -> False
```

- **Сделано:** три `False`; `forge inspect src/MaclaurinToken.sol:MaclaurinToken methodIdentifiers`
  печатает ровно 12 селекторов (`EMISSION_POOL`, `GENESIS`, `TOTAL_SUPPLY`, `allowance`,
  `approve`, `balanceOf`, `decimals`, `name`, `symbol`, `totalSupply`, `transfer`,
  `transferFrom`) и ничего сверх.
- **Если не так:** любое `True` означает, что развёрнут не тот код. Останавливаться,
  ничего не публиковать.

### 7.3 Эмиссия — главный нарративный инвариант

```powershell
cast call $EMISSION "epochAmount(uint256)(uint256)" 2  --rpc-url $RPC   # 500000000000000000000000000
cast call $EMISSION "epochAmount(uint256)(uint256)" 26 --rpc-url $RPC   # 2
cast call $EMISSION "epochAmount(uint256)(uint256)" 27 --rpc-url $RPC   # 0   <- эмиссия кончается сама
cast call $EMISSION "totalEmittable()(uint256)" --rpc-url $RPC          # 718281828459045235360287457
cast call $EMISSION "EPOCH_DURATION()(uint256)" --rpc-url $RPC          # 604800
cast call $EMISSION "FIRST_EPOCH()(uint256)" --rpc-url $RPC             # 2
cast call $EMISSION "LAST_EPOCH()(uint256)" --rpc-url $RPC              # 26
cast call $EMISSION "E_FIXED()(uint256)" --rpc-url $RPC                 # 2718281828459045235
cast call $EMISSION "MAX_RADIUS()(uint256)" --rpc-url $RPC              # 7
cast call $EMISSION "multiplier(uint256)(uint256)" 7 --rpc-url $RPC     # 2718055555555555555 < E_FIXED
cast call $EMISSION "startTime()(uint256)" --rpc-url $RPC
cast call $EMISSION "remainderVault()(address)" --rpc-url $RPC          # == $VAULT
```

- **Сделано:** `EMISSION_POOL − totalEmittable == 14` (те самые 14 wei остаточного члена),
  `epochAmount(27) == 0`, `multiplier(7) < E_FIXED`, `remainderVault` — твой адрес.
- **Если не так:** расхождение здесь означает подмену кода; `Deploy.s.sol` эти же
  равенства проверяет в `_verify()` и упал бы. Останавливаться.

### 7.4 Кривая

```powershell
cast call $CURVE "token()(address)" --rpc-url $RPC                 # == $TOKEN
cast call $CURVE "feeRecipient()(address)" --rpc-url $RPC          # == твой адрес комиссии
cast call $CURVE "INVENTORY()(uint256)" --rpc-url $RPC             # 1000000000000000000000000000
cast call $CURVE "P0()(uint256)" --rpc-url $RPC                    # 200000000000000000
cast call $CURVE "P_FINAL()(uint256)" --rpc-url $RPC               # 543656365691809047
cast call $CURVE "SLOPE()(uint256)" --rpc-url $RPC                 # 343656365691809047
cast call $CURVE "E_FIXED()(uint256)" --rpc-url $RPC               # 2718281828459045235
cast call $CURVE "TOTAL_RAISE()(uint256)" --rpc-url $RPC           # 3718281828459045235  = (1+e) ETH
cast call $CURVE "FEE_BPS()(uint256)" --rpc-url $RPC               # 100  (1.00%)
cast call $CURVE "ANTI_SNIPE_WINDOW()(uint256)" --rpc-url $RPC     # 3600
cast call $CURVE "ANTI_SNIPE_MAX()(uint256)" --rpc-url $RPC        # 10000000000000000000000000
cast call $CURVE "antiSnipeEnd()(uint256)" --rpc-url $RPC          # startTime + 3600
cast call $CURVE "sold()(uint256)" --rpc-url $RPC                  # 0
cast call $CURVE "reserve()(uint256)" --rpc-url $RPC               # 0
cast call $CURVE "feesAccrued()(uint256)" --rpc-url $RPC           # 0
cast call $CURVE "remainingInventory()(uint256)" --rpc-url $RPC    # 1000000000000000000000000000
cast call $CURVE "spotPrice()(uint256)" --rpc-url $RPC             # 2000000000  (2 gwei за токен)
cast call $CURVE "priceAt(uint256)(uint256)" 0 --rpc-url $RPC                            # 200000000000000000
cast call $CURVE "priceAt(uint256)(uint256)" 1000000000000000000000000000 --rpc-url $RPC # 543656365691809047
cast call $CURVE "quoteBuyCost(uint256)(uint256)" 1000000000000000000000000000 --rpc-url $RPC  # 3718281828459045235
```

- **Сделано:** всё совпало. Главная проверка нарратива кривой —
  `P_FINAL × 1e18 / P0 = 543656365691809047 × 1e18 / 2e17 = 2718281828459045235 = E_FIXED`,
  то есть цена от первой монеты до последней растёт **ровно в `e` раз**, без округления.
  Второе: стоимость всего инвентаря = `TOTAL_RAISE` = `e + 1` ETH ровно.
- **Если не так:** любое расхождение констант = развёрнут не тот байткод. Стоп.

### 7.5 Казна

```powershell
cast call $VESTING "token()(address)" --rpc-url $RPC           # == $TOKEN
cast call $VESTING "beneficiary()(address)" --rpc-url $RPC     # == твой адрес
cast call $VESTING "unlockTime()(uint256)" --rpc-url $RPC      # == startTime эмиссии + 15120000
cast call $VESTING "release()" --from $BENEFICIARY --rpc-url $RPC
# ожидается: custom error 0x16b82bbe -> StillLocked(unlockTime)
cast decode-error --sig "StillLocked(uint256)" 0x16b82bbe<32 байта аргумента>
```

- **Сделано:** `release()` ревертит `StillLocked`, аргумент ошибки равен `unlockTime()`,
  а сам `unlockTime` совпадает с датой конца эмиссии.
- **Если не так:** `release()` прошёл бы — значит казна не заперта; это блокирующая
  находка, публикацию останавливать.

### 7.6 Живая проверка деньгами (маленькая, но обязательная)

Автоматических honeypot-чекеров для chain ID 4663 нет (Token Sniffer и Honeypot.is
сеть не поддерживают), поэтому «продать можно» проверяется руками. Это честнее любого
чекера.

```powershell
# 1. Сколько дадут за 0.0002 ETH
cast call $CURVE "previewBuy(uint256)(uint256,uint256,uint256)" 200000000000000 --rpc-url $RPC

# 2. Покупка. minTokensOut = превью минус 1%, deadline = сейчас + 600 c
cast send $CURVE "buy(uint256,uint256)" $MIN_OUT $DEADLINE --value 200000000000000 --rpc-url $RPC --account maclrn-buyer

# 3. Право выкупа появилось ровно у покупателя
cast call $CURVE "boughtOf(address)(uint256)" $BUYER --rpc-url $RPC     # == полученному количеству

# 4. Продажа обратно: сначала апрув ровно на сумму
cast send $TOKEN "approve(address,uint256)" $CURVE $AMOUNT --rpc-url $RPC --account maclrn-buyer
cast call  $CURVE "previewSell(uint256)(uint256,uint256)" $AMOUNT --rpc-url $RPC
cast send  $CURVE "sell(uint256,uint256,uint256)" $AMOUNT $MIN_ETH $DEADLINE --rpc-url $RPC --account maclrn-buyer

# 5. После: право выкупа обнулилось, резерв вернулся к нулю
cast call $CURVE "boughtOf(address)(uint256)" $BUYER --rpc-url $RPC     # 0
cast call $CURVE "reserve()(uint256)" --rpc-url $RPC                    # ~0
cast call $CURVE "sold()(uint256)" --rpc-url $RPC                       # 0
```

- **Сделано:** покупка и продажа прошли; вернулось **меньше**, чем уплачено (1% комиссии
  с каждой стороны плюс округление в пользу протокола) — так и должно быть, круг
  «купил-продал» убыточен по построению; ссылки на обе транзакции сохранены — это
  публичный пруф «не honeypot».
- **Если не так:** `sell` зареверил → читать ошибку. `ExceedsPurchased` при продаже
  того, что куплено у кривой, — блокирующая находка. `SlippageSell` — просто занижен
  `minEthOut`, пересчитать по `previewSell`.

### 7.7 Итоговая сводка для публикации

Заполнить и держать под рукой — эти же данные идут в README, лендинг и token info:

| Что | Значение |
|---|---|
| `MaclaurinToken` (MACLRN) | `0x…` |
| `MaclaurinEmission` | `0x…` |
| `MaclaurinCurve` | `0x…` |
| `MaclaurinVesting` | `0x…` |
| Блок деплоя | |
| `startTime` эмиссии / конец эмиссии | |
| `unlockTime` казны | |
| Транзакция сжигания 250M в `0x…dEaD` | |
| Транзакции тестовой покупки и продажи | |

---

## 8. Публикация: что и в каком порядке

Порядок не косметический: каждый следующий шаг опирается на пруф из предыдущего.

1. **Ничего.** Пока §6 не закрыт (все четыре контракта верифицированы) — ни одного
   адреса наружу. Неверифицированный контракт = «поверьте на слово».
2. **README репозитория:** адреса всех четырёх контрактов со ссылками на Blockscout,
   раскладка genesis с суммами, ссылка на транзакцию сжигания, статус проверок
   (тесты/Slither/halmos/аудиты), явная оговорка про риски. README сейчас описывает
   фазы 1–2 и ссылается на Base — **переписать до публикации**.
3. **Token info на Blockscout:** логотип, короткое английское описание (готово в
   `GTM.md`), ссылки на сайт и X. Заявка подаётся с адреса-владельца или через форму
   эксплорера.
4. **Лендинг** (делается параллельной задачей): объяснение ряда, таблица эмиссии,
   таблица множителей, инструкция «как купить и как продать обратно», раздел «почему
   здесь нельзя напечатать токены» со ссылкой на верифицированный код.
5. **Тред в X** (`GTM.md`): публиковать **только после** пунктов 2–4, чтобы каждая
   ссылка из треда вела на готовую страницу, а не на 404.
6. **Ответы на вопросы:** заготовки в `GTM.md`. Отвечать фактами и ссылками на
   эксплорер, а не обещаниями.
7. **Мониторинг** (`DEPLOY-RUNBOOK.md` §10): первая неделя — эпоха 2, 500 000 000
   токенов, 18.4% сапплая. Смотреть ежедневно: `totalStaked`, `pendingUnallocated`,
   `sold`, `reserve`, платёжеспособность эмиссии.

- **Сделано:** каждая ссылка в треде открывается и ведёт туда, куда обещает; имя и
  тикер в материалах совпадают с `name()`/`symbol()` на цепочке.
- **Если не так:** пост с битой ссылкой удалять и публиковать заново — исправленный
  тред дешевле, чем репутация «ссылки не работают».

---

## 9. 🔴 Чего делать НЕЛЬЗЯ ни при какой спешке

Каждый пункт — не осторожность, а класс уже случавшихся у людей потерь.

1. **Не деплоить код, который не прошёл аудит после последней правки.**
   Переименование `Taylor*` → `Maclaurin*` — это правка кода, а не «косметика»:
   меняются строки конструктора, а с ними байткод. После любой правки — §2 целиком.
2. **Не пропускать тестнет и форк мейннета.** Контракты неизменяемы: ошибка,
   которая в тестнете стоит ноль, в мейннете стоит всего бюджета и всей репутации
   проекта. Особенно это касается фазы 4, которая в живой сети **ещё ни разу не
   разворачивалась**.
3. **Не публиковать адреса до верификации.** Неверифицированный контракт нельзя
   проверить, а первое впечатление одно.
4. **Не разносить деплой кривой и раздачу инвентаря** на два прогона, на «завтра
   доделаю», на ручные переводы. Час — это весь запас (§1.2).
5. **Не менять `foundry.toml`** (`solc`, `evm_version`, `optimizer_runs`) между
   аудитом и верификацией. Байткод обязан быть воспроизводим, иначе верификация не
   сойдётся, и починить это после деплоя нельзя.
6. **Не класть приватный ключ в `.env`, в аргумент `--private-key` или в историю
   оболочки.** Отозвать приватный ключ невозможно.
7. **Не трогать доли и `BURN_ADDRESS` в `Distribute.s.sol`** «на ходу». Адрес
   сжигания — константа в байткоде скрипта именно затем, чтобы его нельзя было
   подменить переменной окружения.
8. **Не запускать раскладку в мейннете без `EXPECTED_UNLOCK_TIME`.** Без неё
   промах даты казны на год не поймает ничто.
9. **Не оставлять genesis на одном кошельке «на пару дней».** Скриншот списка
   холдеров с 73% на одном адресе перечёркивает и отсутствие `mint`, и оба аудита.
10. **Не обещать доходность и не намекать на связь с реальными людьми и компаниями.**
    Указание сети деплоя — факт; претензия на аффилиацию — нет (`GTM.md`, блок
    «чего не писать»).
11. **Не делать необратимое уставшим.** Сжигание LP-позиции, если до неё дойдёт
    дело, и любой шаг с пометкой 🔴 — только на свежую голову и по написанному.

---

## 10. Финальная отметка

- [ ] §1 блокеры закрыты
- [ ] §2 всё зелёное на теговом коммите
- [ ] §3 репетиции пройдены (anvil, форк, тестнет)
- [ ] §4 кошельки и деньги готовы
- [ ] §5 мейннет-деплой, оба шага
- [ ] §6 четыре контракта верифицированы
- [ ] §7 все проверки на цепочке сошлись, включая ноль на адресе создателя
- [ ] §8 публикация в правильном порядке
- [ ] §9 перечитан перед каждым 🔴-шагом
