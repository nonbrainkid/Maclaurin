# $MACLRN — DEPLOY RUNBOOK

Пошаговая инструкция для Windows / PowerShell. Покрывает этапы 2–6 из `LAUNCH-PLAN.md`:
тестнет, деплой в мейннет, верификация, пул ликвидности, смета, мониторинг.

> ## Сеть запуска: Robinhood Chain
>
> Решение владельца от 2026-08-01. Раньше в этом документе была Base — **код контрактов
> не поменялся ни на строку**, Robinhood Chain полностью EVM-совместима и Foundry работает
> без правок. Поменялись только параметры сети: RPC, chain ID, эксплорер, кран и —
> существеннее всего — **верификация идёт через Blockscout, а не через Etherscan API**
> (§5). Ключ Etherscan/Basescan больше не нужен вообще.
>
> | | Mainnet | Testnet |
> |---|---|---|
> | Chain ID | **4663** | **46630** |
> | RPC | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` |
> | Эксплорер | https://robinhoodchain.blockscout.com | https://explorer.testnet.chain.robinhood.com |
> | Газ | ETH | ETH |
>
> Оба RPC проверены живыми 2026-08-01: `cast chain-id` возвращает `4663` и `46630`,
> клиент — `nitro/v3.11.3` (Arbitrum Nitro). Это L2 на Arbitrum, данные публикуются
> в Ethereum блобами. Деплой permissionless — разрешения ни у кого просить не надо.

**Все цифры газа и цен в этом документе — замеренные, а не оценочные.**
Дата замеров: **2026-08-01**, Robinhood Chain mainnet, блок `24848143`. Как перепроверить — в §9.

**Статус ABI: финальный.** Фаза 2 (Radius of Convergence) реализована, `forge build`
зелёный, 124 теста проходят, Slither — 0 находок. Все сигнатуры в этом документе сняты
с собранного артефакта командой
`forge inspect src/MaclaurinEmission.sol:MaclaurinEmission methodIdentifiers`
и **прогнаны целиком на локальном anvil** (деплой + полный цикл
stake/earned/claim/unstake/exit/poke/sweep) — см. §4.1. Черновиков в документе больше нет.

---

## Как читать этот документ

| Пометка | Что означает |
|---|---|
| 🟢 | Проверено реальным исполнением или замерами — можно выполнять как написано |
| 🟡 | Синтаксис верный, но подставь свои значения |
| 🔴 | **Необратимо или блокирует деплой** — читать особенно внимательно |

Порядок разделов = порядок выполнения. Не прыгать: §4 (тестнет) обязателен до §6 (мейннет),
потому что контракты неизменяемы и ошибка в мейннете стоит всего бюджета.

> **Про PowerShell.** В Windows PowerShell 5.1 **нет операторов `&&` и `||`** — они дают
> ошибку парсера. Все команды ниже даны по одной на строку. Переменные задаются как
> `$env:NAME = "value"` (для окружения процесса) или `$NAME = "value"` (обычная переменная
> PowerShell). Это разные вещи: `forge`/`cast` видят только первое.

---

## 1. Предварительные требования

```powershell
forge --version
cast --version
```

Ожидается Foundry ≥ 1.7.1 (на нём всё проверялось). Проект собирается фиксированным
компилятором `0.8.24` и `evm_version = shanghai` — это записано в `foundry.toml` и менять
нельзя: байткод должен быть воспроизводим, иначе верификация не сойдётся.

```powershell
forge build --sizes
forge test
```

Оба должны быть зелёными **до** любых денежных операций. Эталон на 2026-08-01:

| Что | Значение |
|---|---|
| `forge test` | 124 теста, все зелёные |
| Slither | 0 находок |
| Независимый аудит фазы 2 | завершён, находок выше Info нет |
| `MaclaurinEmission` runtime | 6 988 байт (лимит 24 576) |
| `MaclaurinToken` runtime | 2 479 байт |

Со стороны безопасности контракт готов к тестнету. Дальше — только получить тестовый
ETH из крана (§3) и выполнить команды.

### Что тебе понадобится завести заранее

| Что | Где | Зачем |
|---|---|---|
| Кошелёк для деплоя | новый, пустой | Ключ этого кошелька уходит в keystore |
| Кошелёк `GENESIS_RECIPIENT` | **другой** | Держит 2 000 000 000 MACLRN |
| Кошелёк `REMAINDER_VAULT` | **третий** | Казна остаточного члена, immutable навсегда |

> **API-ключа эксплорера больше не нужно.** Robinhood Chain индексируется Blockscout, а он
> принимает верификацию без ключа. Строку `BASESCAN_API_KEY` из старых инструкций можно
> просто забыть: она относилась к Etherscan API V2 и к Base. Если у тебя уже заведён ключ
> etherscan.io — он здесь ни на что не влияет и не мешает.

### Прописать сети в `foundry.toml`

Чтобы вместо длинных URL писать `--rpc-url rh_testnet`, добавь в `foundry.toml`:

```toml
[rpc_endpoints]
rh          = "${RH_RPC_URL}"
rh_testnet  = "${RH_TESTNET_RPC_URL}"
```

Секция `[etherscan]` для Robinhood Chain не нужна — верификатор задаётся флагами
`--verifier blockscout --verifier-url …` прямо в команде (§5).

> Правка `foundry.toml` — за пределами этого документа: файл держит зафиксированные
> `solc = 0.8.24` и `evm_version = shanghai`, и трогать в нём что-либо, кроме
> `[rpc_endpoints]`, нельзя — байткод обязан оставаться воспроизводимым, иначе
> верификация не сойдётся. Пока алиасы не прописаны, во всех командах ниже вместо
> `--rpc-url rh_testnet` пиши полный URL.

---

## 2. Безопасная работа с приватным ключом

**Приватный ключ не должен попадать ни в `.env`, ни в историю PowerShell, ни в аргументы
командной строки.**

Почему это не паранойя. `.env` читает всё, что запускается в проекте, — любой скрипт,
любая зависимость, любое расширение редактора. История PowerShell пишется в
`%APPDATA%\Microsoft\Windows\PowerShell\PSReadline\ConsoleHost_history.txt` открытым
текстом и живёт там годами. Ключ, засветившийся в аргументе `--private-key`, оказывается
и в истории, и в списке процессов, откуда его видит любой процесс пользователя.
Кошелёк с этим ключом придётся считать скомпрометированным навсегда — отозвать приватный
ключ нельзя.

### 2.1 Импорт ключа в зашифрованный keystore 🟢

> ⚠️ **Если keystore заводился до переименования проекта**, он лежит под старым
> именем `taylor-deployer` (и `taylor-second` для второго кошелька). Ключи внутри
> те же — сменилось только имя файла. Достаточно переименовать файл в
> `~/.foundry/keystores/`, `cast wallet list` подхватит новое имя. Пароль и адрес
> не меняются, переимпорт не нужен.

```powershell
cast wallet import maclaurin-deployer --interactive
```

Команда спросит две вещи, обе ввод скрытый:
1. `Enter private key:` — приватный ключ кошелька деплоера;
2. `Enter password:` — пароль, которым он будет зашифрован.

Результат — файл `~/.foundry/keystores/maclaurin-deployer` (на Windows это
`C:\Users\<user>\.foundry\keystores\maclaurin-deployer`), зашифрованный этим паролем.
Дальше ключ нигде в открытом виде не появляется: каждая транзакция спрашивает пароль.

Проверить, что импортировалось то, что нужно:

```powershell
cast wallet list
cast wallet address --account maclaurin-deployer
```

Вторая команда спросит пароль и напечатает адрес. Сверь его с тем, что показывает твой
кошелёк. **Если адрес не совпал — не продолжай**, ты импортировал не тот ключ.

Сохрани адрес в переменную, он нужен дальше:

```powershell
$DEPLOYER = "0xТвойАдресДеплоера"
```

### 2.2 Как этим пользоваться

Во всех командах ниже вместо ключа передаётся `--account maclaurin-deployer`:

```powershell
forge script ... --account maclaurin-deployer --sender $DEPLOYER
cast send ... --account maclaurin-deployer
```

`--sender` нужен именно для `forge script`: скрипт сначала прогоняется в симуляции, и без
явного отправителя симуляция пойдёт от дефолтного адреса, а не от твоего. Расхождение
между симуляцией и реальной транзакцией — это как раз тот класс ошибок, который в
мейннете обходится дорого.

### 2.3 Что кладём в `.env`

`.env` в git не попадает (см. `.gitignore`), но **приватного ключа там всё равно нет**.
Скопируй `.env.example` в `.env` и заполни:

```powershell
Copy-Item .env.example .env
```

```ini
GENESIS_RECIPIENT=0x...
REMAINDER_VAULT=0x...
EMISSION_START_DELAY=300
RH_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com
RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com
```

Ключа эксплорера в этом списке нет намеренно — Blockscout его не требует (§5).

`forge` подхватывает `.env` из корня проекта сам — `source .env` (которого в PowerShell
и нет) не требуется.

---

## 3. Тестовый ETH для Robinhood Chain testnet 🟡

Нужно совсем немного. Весь тестнет-прогон — деплой плюс полтора десятка транзакций
стейкинга — при газе тестнета 0.01 gwei стоит **меньше 0.0001 ETH**. Токены для стейкинга
берутся из GENESIS, а не покупаются. **0.01 ETH хватает с запасом в сто раз.**

Краны проверены запросом 2026-08-01, порядок — по убыванию доверия к источнику:

| Кран | URL | Статус | Примечание |
|---|---|---|---|
| Chainlink | https://faucets.chain.link/robinhood-testnet | `200` | Chainlink Labs, начинать отсюда |
| Официальный Robinhood Chain | https://faucet.testnet.chain.robinhood.com | `429` | Рейт-лимит на запрос; из браузера может открыться |
| faucet.trade | https://faucet.trade/robinhood-testnet-eth-faucet | `200` | Неизвестный агрегатор, только как запасной |
| ZalalenA | https://faucet.zalalena.com/robinhood | `200` | То же самое |

**Запасной путь — официальный бридж Arbitrum с Sepolia.** Robinhood Chain построена
на Arbitrum Orbit, поэтому мост работает штатно:

```
https://portal.arbitrum.io/bridge?sourceChain=sepolia&destinationChain=robinhood-chain-testnet
```

Этот путь надёжнее любого крана этой сети: sepolia-ETH раздают десятки кранов, и
зависимости от лимитов одного хоста не возникает. Портал возвращает `403` на `curl` —
это защита от скриптов, в браузере открывается нормально.

> ⚠️ **Безопасность — краны это стандартная приманка для фишинга.** Человек приходит
> туда с разблокированным кошельком и в ожидании, что ему сейчас дадут денег.
>
> Легитимный кран запрашивает **только адрес кошелька**. Закрывать вкладку немедленно,
> если сайт:
> - просит приватный ключ или seed-фразу — законной причины не существует в принципе;
> - просит подписать транзакцию или выдать `approve` — настоящий кран сам шлёт ETH тебе,
>   подпись ему не нужна;
> - предлагает «разблокировать» выдачу переводом реального ETH.
>
> **Использовать отдельный кошелёк под тестнет** — не тот, с которого пойдёт мейннет-деплой.
> Стоит ноль, а закрывает весь класс рисков от неизвестных кранов из таблицы выше.

> 🟡 **Что не проверено.** Конкретные лимиты выдачи, требования к аккаунту и наличие
> анти-сибил проверки — выяснится при первом заходе. Официальный кран вернул `429`,
> поэтому объём выдачи установить не удалось.

Просить тестовый ETH нужно **на адрес деплоера** (`$DEPLOYER`). Проверить приход:

```powershell
cast balance $DEPLOYER --rpc-url https://rpc.testnet.chain.robinhood.com --ether
```

Публичный RPC живой (проверено 2026-08-01), ключ и регистрация ему не нужны:

```powershell
cast chain-id --rpc-url https://rpc.testnet.chain.robinhood.com    # 46630
cast chain-id --rpc-url https://rpc.mainnet.chain.robinhood.com    # 4663
```

> **Публичные RPC рейт-лимитированы.** Для ручного прогона по этому документу их хватает
> с большим запасом. Если упрёшься в лимит — у сети есть бесплатные ключи Alchemy
> (`https://robinhood-testnet.g.alchemy.com/v2/<key>`), а также QuickNode, dRPC,
> Blockdaemon и Validation Cloud.

---

## 4. Деплой в Robinhood Chain testnet (стоимость ≈ $0)

Это генеральная репетиция. Всё, что здесь сломается, в мейннете стоило бы денег и было бы
неисправимо.

### 4.1 Репетиция на локальном anvil — до всякой сети 🟢

Anvil — локальная EVM-нода из комплекта Foundry. Она бесплатна, не требует тестового ETH,
и, в отличие от тестнета, **умеет перематывать время**. Для контракта, у которого вся
механика висит на семидневных эпохах и локах, это единственный способ проверить полный
цикл не за 49 дней, а за пять минут.

Всё, что описано ниже в §7, было прогнано именно так: деплой отработал, инварианты сошлись,
цикл `stake → earned → claim → unstake → exit → poke → sweep` прошёл целиком.

**Терминал 1 — нода:**

```powershell
anvil --port 8545 --block-time 1
```

**Терминал 2 — деплой.** Anvil выдаёт 10 разблокированных аккаунтов с 10 000 ETH; их адреса
печатаются при старте. Приватные ключи здесь не нужны вообще: `--unlocked` заставляет
подписывать транзакции саму ноду.

```powershell
$RPC      = "http://127.0.0.1:8545"
$DEPLOYER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"   # anvil account #0
$env:GENESIS_RECIPIENT     = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"   # account #1
$env:REMAINDER_VAULT       = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"   # account #2
$env:EMISSION_START_DELAY  = "300"

forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --sender $DEPLOYER --unlocked --broadcast
```

Ожидаемый хвост вывода (замерено):

```
  all post-deploy invariants hold
  total supply (wei): 2718281828459045235360287471
ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
```

Адреса при чистой ноде детерминированы (nonce 0 деплоера):

```
MaclaurinEmission: 0x5FbDB2315678afecb367f032d93F642f64180aa3
MaclaurinToken:    0xa16E02E87b7454126E5E10d957A927A7F5B5d2be
```

Перемотка времени (нужна для §7.4 и §7.5) — два RPC-вызова:

```powershell
cast rpc evm_increaseTime 604800 --rpc-url $RPC   # +7 дней
cast rpc evm_mine --rpc-url $RPC                  # применить

# или прыжок в конкретный момент
cast rpc evm_setNextBlockTimestamp 1786233143 --rpc-url $RPC
cast rpc evm_mine --rpc-url $RPC
```

> **Не запускай anvil с `--chain-id 46630`.** Foundry разложит брод­каст-логи в
> `broadcast/Deploy.s.sol/46630/`, то есть туда же, куда потом лягут логи настоящего
> тестнет-деплоя, и адреса перемешаются. Дефолтный `31337` уже прописан в `.gitignore`
> именно для этого.

Когда нагулялся:

```powershell
taskkill /F /IM anvil.exe
```

### 4.2 Сухой прогон против тестнета (без транзакций) 🟢

```powershell
$TRPC = "https://rpc.testnet.chain.robinhood.com"
forge script script/Deploy.s.sol:Deploy --rpc-url $TRPC --sender $DEPLOYER
```

Без `--broadcast` ничего не отправляется. Проверено 2026-08-01 — скрипт отрабатывает
против живого тестнета и печатает:

```
  chain id:           46630
  all post-deploy invariants hold
  total supply (wei): 2718281828459045235360287471

Chain 46630
Estimated gas price: 0.020000001 gwei
Estimated total gas used for script: 3000255
Estimated amount required: 0.000060005103000255 ETH
```

**Шестьдесят микроэфиров** — вот вся стоимость тестнет-деплоя. `chain id` обязан быть
`46630`, адреса genesis/vault — твои.

### 4.3 Реальный деплой 🟡

Автоверификация на Blockscout прямо из `forge script` в этой сети ненадёжна (§5), поэтому
деплой и верификация разведены на два шага. Сначала просто деплой:

```powershell
forge script script/Deploy.s.sol:Deploy --rpc-url $TRPC --account maclaurin-deployer --sender $DEPLOYER --broadcast
```

Запиши из вывода два адреса:

```powershell
$EMISSION = "0x..."   # MaclaurinEmission
$TOKEN    = "0x..."   # MaclaurinToken
```

Их же всегда можно достать из брод­каст-лога:

```powershell
Get-Content broadcast/Deploy.s.sol/46630/run-latest.json | ConvertFrom-Json | Select-Object -ExpandProperty transactions | Select-Object contractName, contractAddress
```

Адрес токена надёжнее спросить у самого контракта — он не зависит от того, что записалось
в лог:

```powershell
$TOKEN = (cast call $EMISSION "token()(address)" --rpc-url $TRPC)
```

Посмотреть контракт в эксплорере:

```powershell
Start-Process "https://explorer.testnet.chain.robinhood.com/address/$EMISSION"
```

### 4.4 Пошаговый чеклист тестнета

Порядок именно такой. Пункты 1–5 занимают минуты, пункт 6 требует подождать неделю
реального времени (как обойти — §7.4).

- [ ] **1. Подготовка.** `cast wallet import` (§2.1), `.env` заполнен (§2.3), тестовый ETH
      получен из крана (§3), `cast balance` показывает ненулевой баланс.
- [ ] **2. Репетиция на anvil** (§4.1) — прошла целиком, включая §7.
- [ ] **3. Сухой прогон** (§4.2) — `chain id 46630`, `all post-deploy invariants hold`.
- [ ] **4. Деплой** (§4.3). Записаны `$EMISSION` и `$TOKEN`.
- [ ] **5. Верификация ОБОИХ контрактов** на https://explorer.testnet.chain.robinhood.com
      (§5). Оба — вручную, через Blockscout. Критерий: на обеих страницах эксплорера
      вкладка Contract показывает исходник, а не байткод.
- [ ] **6. Read-only проверки** (§7.2) — сапплай, распределение, таблица ряда,
      `epochAmount(27) == 0`, таблица множителей.
- [ ] **7. Полный цикл стейкинга** (§7.3) — `stake → positions → earned → claim →
      unstake → exit`.
- [ ] **8. Проверка лока** (§7.4) — `claim()` до `unlockTime` ревертит `StillLocked`,
      после — проходит. **Это главная проверка всей фазы 2.**
- [ ] **9. Досрочный выход** (§7.5) — тело вернулось целиком, награда ушла в казну.
- [ ] **10. `poke`** (§7.6) — на активном локе ревертит, на истёкшем понижает вес до 1x.
- [ ] **11. `sweepToRemainderVault`** (§7.7) — незанятая награда дошла до `remainderVault`.
- [ ] ~~12. Пул на Uniswap~~ — **в тестнете невозможно, см. §8.0.** Uniswap на Robinhood
      Chain testnet не развёрнут. Пул репетируется на форке мейннета.

**Критерий готовности: весь цикл отработал, ничего не зареверило неожиданно, а всё, что
должно было зареверить, зареверило с правильной ошибкой.**

> **Что тестнет НЕ покроет.** Пункт 12 вычеркнут не по недосмотру: по адресам Uniswap
> в тестнете Robinhood Chain **нет кода вообще** — ни фабрики, ни `NonfungiblePositionManager`,
> ни WETH (проверено `cast code` 2026-08-01, §8.0). Единственный контракт Uniswap-стека,
> который там есть, — `Permit2`, и то потому, что он разворачивается детерминированно
> на любой сети. Поэтому весь §8 репетируется **на локальном форке мейннета**, а не
> в тестнете.

---

## 5. Верификация через Blockscout

**Верифицировать нужно ДВА контракта, и оба — вручную.** Robinhood Chain индексируется
Blockscout, а не Etherscan-совместимым эксплорером, поэтому:

- **API-ключ не нужен.** Ни `--etherscan-api-key`, ни `BASESCAN_API_KEY`, ни аккаунт.
- Верификатор задаётся флагами `--verifier blockscout --verifier-url <api>`.
- `--verify` внутри `forge script` для этой связки ненадёжен, поэтому в §4.3 деплой
  идёт без него, а верификация — отдельным шагом.

Адреса API верификатора (оба проверены живыми 2026-08-01, отвечают `HTTP 200`):

| Сеть | `--verifier-url` | Chain ID |
|---|---|---|
| Testnet | `https://explorer.testnet.chain.robinhood.com/api/` | 46630 |
| Mainnet | `https://robinhoodchain.blockscout.com/api/` | 4663 |

> **Косая черта на конце обязательна.** Blockscout отдаёт `404` на URL без неё, а Foundry
> в этом случае печатает невнятную ошибку про endpoint, а не про URL. Это ровно та форма,
> которая приведена в официальном туториале Robinhood Chain
> (https://docs.robinhood.com/chain/deploy-smart-contracts).

### 5.1 Суть проблемы

`script/Deploy.s.sol` разворачивает **только** `MaclaurinEmission`. Токен создаётся внутри
конструктора эмиссии:

```
EOA --tx--> CREATE MaclaurinEmission
                  └── constructor --CREATE--> MaclaurinToken
```

У `MaclaurinEmission` есть транзакция создания, и в её calldata лежат аргументы конструктора —
верификатор их оттуда достаёт сам. У `MaclaurinToken` **транзакции создания не существует**:
его init-код и аргументы собрались в памяти родительского конструктора и в calldata никогда
не попадали.

Практические следствия:

1. Автоверификация через `--verify` в `forge script` для токена обычно молча не срабатывает
   или падает — верификатор не знает, чем был вызван конструктор.
2. Флаг `--guess-constructor-args` здесь **не поможет** принципиально: он читает calldata
   транзакции создания, а её нет.
3. Аргументы надо закодировать вручную и передать явно.

Если этого не сделать, токен останется неверифицированным. Для проекта, весь нарратив
которого построен на «посмотрите в код, там нет функции mint», это обнуляет тезис:
проверять нечего.

> 🟡 **Отдельная тонкость Blockscout.** `forge verify-contract --help` про флаг
> `--constructor-args` пишет буквально «Only for Etherscan». То есть нет гарантии, что
> Foundry прокинет аргументы в Blockscout-провайдер так же, как в Etherscan. Проверить это
> без реального деплоя невозможно, поэтому в §5.3 дан порядок из трёх попыток: сначала без
> аргументов (Blockscout, в отличие от Etherscan, индексирует internal transactions и часто
> достаёт аргументы сам), затем с `--constructor-args`, затем через веб-форму эксплорера,
> где поле для аргументов есть гарантированно. Хотя бы один из трёх сработает — верификация
> бесплатна и повторяется сколько угодно раз.

### 5.2 Собираем аргументы конструктора 🟢

Конструктор токена (`src/MaclaurinToken.sol:65`):

```solidity
constructor(address genesisRecipient, address emissionContract)
```

`emissionContract` — это адрес самого контракта эмиссии. Получаем всё из цепочки, а не из
памяти:

```powershell
$EMISSION = "0x..."
$TOKEN   = (cast call $EMISSION "token()(address)" --rpc-url $TRPC)
$GENESIS = $env:GENESIS_RECIPIENT
```

Кодируем:

```powershell
$TOKEN_ARGS = cast abi-encode "constructor(address,address)" $GENESIS $EMISSION
$TOKEN_ARGS
```

Вывод — 130 символов (`0x` + 128 hex). Пример реального вывода (адреса из anvil-прогона):

```
0x00000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c80000000000000000000000005fbdb2315678afecb367f032d93f642f64180aa3
```

Самопроверка перед отправкой (декодируем обратно и сверяем глазами):

```powershell
cast abi-decode --input "f(address,address)" $TOKEN_ARGS
```

Должно напечатать ровно твои `GENESIS_RECIPIENT` и `EMISSION`, **в этом порядке**.
Перепутанные местами адреса дадут корректно закодированные, но неверные аргументы, и
верификация свалится с невнятной ошибкой несовпадения байткода.

Проверить длину, не считая символы глазами:

```powershell
$TOKEN_ARGS.Length      # 130
```

### 5.3 Команда верификации токена 🟡

Сначала задай сеть одной парой переменных — дальше все команды одинаковы для тестнета
и мейннета:

```powershell
# Testnet
$CHAIN = "46630"
$VURL  = "https://explorer.testnet.chain.robinhood.com/api/"
$RPCV  = "https://rpc.testnet.chain.robinhood.com"

# Mainnet
# $CHAIN = "4663"
# $VURL  = "https://robinhoodchain.blockscout.com/api/"
# $RPCV  = "https://rpc.mainnet.chain.robinhood.com"
```

**Попытка 1 — без аргументов конструктора.** Blockscout индексирует internal transactions,
поэтому у него, в отличие от Etherscan, есть шанс достать init-код токена самостоятельно:

```powershell
forge verify-contract $TOKEN src/MaclaurinToken.sol:MaclaurinToken --chain $CHAIN --rpc-url $RPCV --compiler-version 0.8.24 --num-of-optimizations 1000000 --verifier blockscout --verifier-url $VURL --watch
```

**Попытка 2 — с явными аргументами** (если первая сказала, что байткод не сошёлся):

```powershell
forge verify-contract $TOKEN src/MaclaurinToken.sol:MaclaurinToken --chain $CHAIN --rpc-url $RPCV --constructor-args $TOKEN_ARGS --compiler-version 0.8.24 --num-of-optimizations 1000000 --verifier blockscout --verifier-url $VURL --watch
```

**Попытка 3 — веб-форма эксплорера.** Самый надёжный путь, потому что поле для аргументов
конструктора там есть точно. Foundry подготовит для неё готовый JSON:

```powershell
New-Item -ItemType Directory -Force .ignore | Out-Null
forge verify-contract $TOKEN src/MaclaurinToken.sol:MaclaurinToken --chain $CHAIN --show-standard-json-input > .ignore/token-standard-input.json

Start-Process "https://explorer.testnet.chain.robinhood.com/address/$TOKEN/contract-verification"
```

В форме выбрать **Solidity (Standard JSON Input)**, приложить файл, компилятор `0.8.24`,
а в поле constructor arguments вставить `$TOKEN_ARGS` **без префикса `0x`**. Если в форме
есть галочка «попытаться получить аргументы конструктора автоматически» — сначала попробуй
с ней.

`--watch` заставляет команду дождаться результата, а не просто поставить задачу в очередь.
Ждать обычно 10–60 секунд.

### 5.4 Верификация `MaclaurinEmission` 🟡

С эмиссией проще: у неё есть настоящая транзакция создания, и её аргументы лежат в calldata.
Начни с автоматического извлечения:

```powershell
forge verify-contract $EMISSION src/MaclaurinEmission.sol:MaclaurinEmission --chain $CHAIN --rpc-url $RPCV --guess-constructor-args --compiler-version 0.8.24 --num-of-optimizations 1000000 --verifier blockscout --verifier-url $VURL --watch
```

Если не вышло — собери аргументы руками. Конструктор эмиссии принимает три аргумента,
третий — `startTime`, который вычислялся в момент деплоя. **Не восстанавливай его по памяти
или по формуле** — прочитай из контракта:

```powershell
$START = (cast call $EMISSION "startTime()(uint256)" --rpc-url $RPCV).Split(" ")[0]
$START
```

> `.Split(" ")[0]` нужен потому, что `cast call` печатает крупные числа с человекочитаемым
> хвостом вида `1785628340 [1.785e9]`. В аргументы кодировщика должно уйти только число.
> Это касается **всех** мест, где вывод `cast call` подставляется в другую команду.

```powershell
$EMISSION_ARGS = cast abi-encode "constructor(address,address,uint256)" $GENESIS $env:REMAINDER_VAULT $START
cast abi-decode --input "f(address,address,uint256)" $EMISSION_ARGS
```

Декодирование должно напечатать три строки: genesis, vault, startTime — **в этом порядке**.

```powershell
forge verify-contract $EMISSION src/MaclaurinEmission.sol:MaclaurinEmission --chain $CHAIN --rpc-url $RPCV --constructor-args $EMISSION_ARGS --compiler-version 0.8.24 --num-of-optimizations 1000000 --verifier blockscout --verifier-url $VURL --watch
```

### 5.4.1 Как убедиться, что верифицированы ОБА 🟡

Проверять надо не по выводу команды, а по эксплореру — команда может отчитаться об успешно
поставленной задаче, а задача потом отвалиться.

```powershell
# Testnet
Start-Process "https://explorer.testnet.chain.robinhood.com/address/$EMISSION?tab=contract"
Start-Process "https://explorer.testnet.chain.robinhood.com/address/$TOKEN?tab=contract"

# Mainnet
# Start-Process "https://robinhoodchain.blockscout.com/address/$EMISSION?tab=contract"
# Start-Process "https://robinhoodchain.blockscout.com/address/$TOKEN?tab=contract"
```

На обеих страницах должен быть виден Solidity-исходник и зелёная галочка `Verified`,
а не hex-байткод.

Программная проверка, без браузера — Blockscout отдаёт статус в JSON:

```powershell
(Invoke-RestMethod "https://explorer.testnet.chain.robinhood.com/api/v2/smart-contracts/$TOKEN").is_verified
(Invoke-RestMethod "https://explorer.testnet.chain.robinhood.com/api/v2/smart-contracts/$EMISSION").is_verified
```

Обе строки обязаны напечатать `True`.

### 5.5 Запасной верификатор — Sourcify 🟡

Верификация бесплатна и её можно повторять сколько угодно, поэтому запасной путь есть
всегда. Sourcify не требует ни ключа, ни привязки к конкретному эксплореру, а Blockscout
умеет подтягивать из него результат:

```powershell
forge verify-contract $TOKEN src/MaclaurinToken.sol:MaclaurinToken --chain $CHAIN --rpc-url $RPCV --verifier sourcify --watch
```

> 🟡 Поддерживает ли Sourcify chain ID 4663 и 46630 — не проверено. Если нет, остаётся
> путь через веб-форму Blockscout (§5.3, попытка 3), который от внешних сервисов
> не зависит вообще.

### 5.6 Частые причины провала верификации

| Симптом | Причина | Что делать |
|---|---|---|
| `Bytecode does not match` | не совпал компилятор / оптимизатор / EVM-версия | сверить с `foundry.toml`: `0.8.24`, `optimizer_runs = 1000000`, `evm_version = shanghai` |
| `Bytecode does not match` при верных настройках | перепутан порядок аргументов конструктора | §5.2, `cast abi-decode` |
| Ошибка про endpoint / `404` | забыта косая черта на конце `--verifier-url` | URL обязан оканчиваться на `/api/` |
| Попытка передать `--etherscan-api-key` | здесь Blockscout, ключ не нужен и может мешать | убрать флаг, оставить `--verifier blockscout` |
| `Unable to locate ContractCode` | контракт ещё не проиндексирован | подождать 1–2 минуты после деплоя |
| Токен не верифицируется никакой командой | у него нет транзакции создания (§5.1) | веб-форма эксплорера (§5.3, попытка 3) |

---

## 6. Деплой в мейннет Robinhood Chain

```powershell
$MRPC = "https://rpc.mainnet.chain.robinhood.com"
```

### 6.1 Перед тем как нажать 🔴 БЛОКИРУЮЩЕЕ

- [ ] Приняты решения из `LAUNCH-PLAN.md` §0.1 (распределение GENESIS) и §0.4 (адреса).
      `GENESIS_RECIPIENT` и `REMAINDER_VAULT` **immutable навсегда**.
- [ ] `EMISSION_START_DELAY` покрывает время на создание пула. Для мейннета 86400 (сутки) —
      этого хватает с большим запасом: весь §8 выполняется за минуты. **Не путать с
      тестнетом**, где имеет смысл 300 (§7.4).
- [x] Фаза 2 (`PHASE2-SPEC.md`) доделана. ✅ 2026-08-01: 124 теста зелёные, Slither 0 находок,
      независимый аудит фазы 2 завершён — находок выше Info нет.
- [ ] `forge test` зелёный, Slither чистый, CI зелёный **на том коммите, который идёт
      в мейннет** (а не на том, который аудировали месяц назад).
- [ ] **Тестнет-прогон §4.4 пройден целиком**, включая §7.4 (лок держит `claim()`)
      и §7.5 (досрочный выход возвращает тело). Это не формальность: обе проверки
      закрывают дыру, ради которой делалась фаза 2.
- [ ] Сделан `git tag` того коммита, который идёт в мейннет.
- [ ] **Пул отрепетирован на форке мейннета** (§8.0) — в тестнете этот шаг невозможен.
- [ ] ETH заведён **сразу в сети Robinhood Chain**, а не сбриджен из Ethereum
      (бридж из мейннета стоит $5–20 и съест весь бюджет). Как именно ETH попадает в эту
      сеть — через приложение Robinhood или мост, описанный в
      https://docs.robinhood.com/chain/ — решается до деплоя, а не в процессе.

Проверить баланс:

```powershell
cast balance $DEPLOYER --rpc-url $MRPC --ether
```

### 6.2 Сухой прогон на мейннете 🟢

```powershell
forge script script/Deploy.s.sol:Deploy --rpc-url $MRPC --sender $DEPLOYER
```

`chain id` в выводе обязан быть **4663**. Симуляция бесплатна — прогони её столько раз,
сколько нужно, чтобы перестать сомневаться.

### 6.3 Деплой 🟡

```powershell
forge script script/Deploy.s.sol:Deploy --rpc-url $MRPC --account maclaurin-deployer --sender $DEPLOYER --broadcast
```

Сразу после:

```powershell
$EMISSION = "0x..."
$TOKEN = (cast call $EMISSION "token()(address)" --rpc-url $MRPC)
```

- [ ] Верифицировать `MaclaurinEmission` (§5.4) и `MaclaurinToken` (§5.3) — оба вручную
- [ ] Убедиться, что верифицированы **оба** контракта (§5.4.1)
- [ ] Записать оба адреса в `README.md`
- [ ] Прогнать read-only проверки §7.2 уже на мейннете — они бесплатны

> 🟡 **Про чекеры honeypot.** Token Sniffer и Honeypot.is Robinhood Chain (chain ID 4663)
> пока не поддерживают — сеть новая. Заменить их нечем, поэтому проверка «токен не
> honeypot» делается вручную: реальные свопы в обе стороны через Uniswap (§8.5, шаг 5).
> Это, вообще говоря, честнее любого автоматического чекера.

> **Про `renounceOwnership()`.** В смете `MACLAURIN-TOKEN-SPEC.md` эта строка есть, но в коде
> `Ownable` не используется — ни в токене, ни в эмиссии. Отказываться не от чего,
> транзакция не нужна, $0.05 из сметы освобождаются. Это не упущение, а изначальное
> проектное решение (§6.2 спеки): владельца просто нет в байткоде.

---

## 7. Чеклист ручной проверки после деплоя

Все сигнатуры ниже сняты с собранного артефакта и прогнаны на anvil (§4.1). Если захочешь
пересверить сам — вот источник истины, а не этот документ:

```powershell
forge inspect src/MaclaurinEmission.sol:MaclaurinEmission methodIdentifiers
forge inspect src/MaclaurinToken.sol:MaclaurinToken methodIdentifiers
```

Ещё удобнее — сгенерировать готовый Solidity-интерфейс:

```powershell
New-Item -ItemType Directory -Force .ignore | Out-Null
forge inspect src/MaclaurinEmission.sol:MaclaurinEmission abi > .ignore/emission.abi.json
cast interface .ignore/emission.abi.json
```

(`.ignore/` уже прописан в `.gitignore` — временные файлы оттуда в репозиторий не уедут.)

Чтобы не повторять адрес сети в каждой команде, задай:

```powershell
$RPC = "https://rpc.testnet.chain.robinhood.com"     # или https://rpc.mainnet.chain.robinhood.com
```

> Флаг `--account maclaurin-deployer` ниже пишется полностью в каждой команде намеренно.
> Сложить его в переменную и подставлять через сплэттинг (`@ACC`) в PowerShell 5.1 для
> внешних программ работает не всегда — в части случаев `@ACC` уезжает в `cast` буквальной
> строкой, транзакция подписывается не тем ключом или не подписывается вовсе. Лишние 26
> символов дешевле отладки такой ошибки.

### 7.0 Правило работы: сначала `cast call`, потом `cast send` 🟢

Если сигнатура не совпадёт с реальной, транзакция **не** упадёт понятной ошибкой: она уйдёт
по несуществующему селектору и зареверит без объяснений, потратив газ. Поэтому каждую
транзакцию сначала прогоняй бесплатно:

```powershell
cast call $EMISSION "<сигнатура>" <аргументы> --from $DEPLOYER --rpc-url $RPC
```

`cast call` исполняет ровно ту же логику EVM, но ничего не пишет и не стоит газа. Пустой
вывод `0x` означает «прошло бы»; реверт увидишь здесь, а не после списания.

**Как читать реверт.** `cast call` печатает голый селектор ошибки, потому что не знает ABI
контракта:

```
execution reverted: custom error 0x16b82bbe: 000000000000000000000000000000000000000000000000000000006a77c136
```

Расшифровывается одной командой:

```powershell
cast decode-error --sig "StillLocked(uint256)" 0x16b82bbe000000000000000000000000000000000000000000000000000000006a77c136
# 1786233142 [1.786e9]
```

Полная таблица селекторов `MaclaurinEmission` (проверено `cast sig`):

| Селектор | Ошибка | Когда возникает |
|---|---|---|
| `0x1f2a2005` | `ZeroAmount()` | `stake(0, R)` или `unstake(0)` |
| `0x45be0a26` | `InsufficientStake(uint256,uint256)` | `unstake` больше, чем в позиции |
| `0x969bf728` | `NothingToClaim()` | `claim()` при нулевой награде |
| `0x351261fc` | `NothingToSweep()` | `sweepToRemainderVault()` при `unallocated == 0` |
| `0x26e687eb` | `StartTimeInPast()` | конструктор: `startTime` в прошлом |
| `0xd92e233d` | `ZeroAddress()` | конструктор: `remainderVault == 0` |
| `0x8b8f35ce` | `InvalidRadius(uint256)` | радиус вне `1..7` |
| `0xbe92293a` | `RadiusCannotDecrease(uint256,uint256)` | дозаход с радиусом меньше текущего |
| **`0x16b82bbe`** | **`StillLocked(uint256)`** | **`claim()` или `poke()` до `unlockTime`** |
| `0xabf0f034` | `NoPosition()` | `poke()` по адресу без стейка |
| `0x25b064c0` | `AlreadyAtBaseline()` | `poke()` по позиции, которая уже 1.0x |

> Приятная деталь: `cast send` расшифровывает ошибку сам (`… : StillLocked(1786233142)`),
> потому что видит артефакты проекта. И, что важнее, при провале на этапе `eth_estimateGas`
> транзакция **вообще не отправляется** — газ не тратится. То есть даже ошибочный `cast send`
> из корня проекта бесплатен. Но полагаться на это не надо: `cast call` надёжнее.

### 7.1 Шпаргалка по ABI `MaclaurinEmission` 🟢

Полный список того, что понадобится ниже. Слева — то, что пишется в кавычках в `cast`.

**Транзакции:**

| Сигнатура | Что делает |
|---|---|
| `stake(uint256,uint256)` | `(amount, radius)`. Радиус 1..7, лок = `radius × 7 дней` |
| `unstake(uint256)` | `(amount)`. Доступно **всегда**, тело возвращается целиком |
| `claim()` | Забрать награду. Ревертит `StillLocked` до `unlockTime` |
| `exit()` | `unstake(всё)` + `claim()`, если после сжигания что-то осталось |
| `poke(address)` | Permissionless сброс истёкшего множителя до 1.0x |
| `sweepToRemainderVault()` | Permissionless отправка `unallocated` в казну |

**View по пользователю:**

| Сигнатура | Возвращает |
|---|---|
| `positions(address)(uint256,uint256,uint256,uint256)` | `staked, radius, unlockTime, weight` |
| `stakedOf(address)(uint256)` | принципал |
| `weightOf(address)(uint256)` | вес = `staked × multiplier(radius) / 1e18` |
| `unlockTimeOf(address)(uint256)` | момент, после которого открыт `claim()` |
| `isLocked(address)(bool)` | `true`, пока `claim()` закрыт |
| `isPokeable(address)(bool)` | `true`, если лок истёк, а множитель ещё > 1.0x |
| `earned(address)(uint256)` | начислено (не значит «доступно» — см. `isLocked`) |
| `rewards(address)(uint256)` | зафиксированная часть награды |
| `userRewardPerTokenPaid(address)(uint256)` | служебное, для отладки аккумулятора |

**View глобальные:**

| Сигнатура | Возвращает |
|---|---|
| `multiplier(uint256)(uint256)` | множитель радиуса, 1e18 = 1.0x. Ревертит вне 1..7 |
| `lockDuration(uint256)(uint256)` | длительность лока радиуса в секундах |
| `totalStaked()(uint256)` / `totalWeight()(uint256)` | суммы принципалов и весов |
| `rewardPerToken()(uint256)` / `rewardPerTokenStored()(uint256)` | аккумулятор |
| `pendingUnallocated()(uint256)` / `unallocated()(uint256)` | награда без стейкеров |
| `totalClaimed()(uint256)` / `totalSwept()(uint256)` | счётчики выплат |
| `currentEpoch()(uint256)` / `epochEndsAt(uint256)(uint256)` | эпохи |
| `emissionFinished()(bool)` / `emissionEnd()(uint256)` | конец эмиссии |
| `epochAmount(uint256)(uint256)` / `totalEmittable()(uint256)` | таблица ряда |
| `MAX_RADIUS()(uint256)` / `E_FIXED()(uint256)` | 7 и `floor(e×1e18)` |
| `EPOCH_DURATION()` / `FIRST_EPOCH()` / `LAST_EPOCH()` / `EMISSION_DURATION()` | константы |

> **Чего в ABI НЕТ и не будет:** `setRadius`, `extendLock`, `emergencyWithdraw`, `pause`,
> `owner`, `setRemainderVault`. Ни одной функции, меняющей параметры, в контракте не
> существует — это проверяется тем же `methodIdentifiers`, а не обещанием.

### 7.2 Read-only проверки (бесплатно, ничего не тратят) 🟢

Выводы в комментариях — фактические, снятые с anvil-прогона.

```powershell
# --- Токен: неизменяемость сапплая ---
cast call $TOKEN "name()(string)" --rpc-url $RPC
cast call $TOKEN "symbol()(string)" --rpc-url $RPC
cast call $TOKEN "decimals()(uint8)" --rpc-url $RPC
cast call $TOKEN "totalSupply()(uint256)" --rpc-url $RPC          # 2718281828459045235360287471
cast call $TOKEN "TOTAL_SUPPLY()(uint256)" --rpc-url $RPC
cast call $TOKEN "GENESIS()(uint256)" --rpc-url $RPC              # 2000000000000000000000000000
cast call $TOKEN "EMISSION_POOL()(uint256)" --rpc-url $RPC        #  718281828459045235360287471

# --- Распределение ---
cast call $TOKEN "balanceOf(address)(uint256)" $GENESIS --rpc-url $RPC     # == GENESIS
cast call $TOKEN "balanceOf(address)(uint256)" $EMISSION --rpc-url $RPC    # == EMISSION_POOL

# --- Эмиссия: связи и тайминг ---
cast call $EMISSION "token()(address)" --rpc-url $RPC             # == $TOKEN
cast call $EMISSION "remainderVault()(address)" --rpc-url $RPC
cast call $EMISSION "startTime()(uint256)" --rpc-url $RPC
cast call $EMISSION "emissionEnd()(uint256)" --rpc-url $RPC
cast call $EMISSION "EPOCH_DURATION()(uint256)" --rpc-url $RPC    # 604800
cast call $EMISSION "FIRST_EPOCH()(uint256)" --rpc-url $RPC       # 2
cast call $EMISSION "LAST_EPOCH()(uint256)" --rpc-url $RPC        # 26
cast call $EMISSION "currentEpoch()(uint256)" --rpc-url $RPC

# --- Ряд Маклорена: главный нарративный инвариант ---
cast call $EMISSION "epochAmount(uint256)(uint256)" 2 --rpc-url $RPC   # 500000000000000000000000000
cast call $EMISSION "epochAmount(uint256)(uint256)" 26 --rpc-url $RPC  # 2
cast call $EMISSION "epochAmount(uint256)(uint256)" 27 --rpc-url $RPC  # 0  <- эмиссия кончилась сама
cast call $EMISSION "totalEmittable()(uint256)" --rpc-url $RPC         # 718281828459045235360287457
```

**Главная проверка нарратива — последние три строки.** `epochAmount(27) == 0` означает, что
эмиссия заканчивается свойством целочисленной арифметики, а не решением мультисига.
А `EMISSION_POOL - totalEmittable == 14` — те самые 14 wei остаточного члена Лагранжа.
Посчитать разницу:

```powershell
cast call $TOKEN "EMISSION_POOL()(uint256)" --rpc-url $RPC
cast call $EMISSION "totalEmittable()(uint256)" --rpc-url $RPC
# 718281828459045235360287471 - 718281828459045235360287457 = 14
```

**Таблица множителей — второй нарративный инвариант.** Прирост между соседними радиусами
равен ровно членам того же ряда `1/n!`, а потолок `e` недостижим ни при каком `R`:

```powershell
1..7 | ForEach-Object {
  $m = (cast call $EMISSION "multiplier(uint256)(uint256)" $_ --rpc-url $RPC).Split(" ")[0]
  $l = (cast call $EMISSION "lockDuration(uint256)(uint256)" $_ --rpc-url $RPC).Split(" ")[0]
  "R={0}  mult={1}  lock={2}s ({3} д)" -f $_, $m, $l, ($l / 86400)
}
cast call $EMISSION "E_FIXED()(uint256)" --rpc-url $RPC     # 2718281828459045235
cast call $EMISSION "MAX_RADIUS()(uint256)" --rpc-url $RPC   # 7
```

Ожидаемый вывод (сверено с `PHASE2-SPEC.md` §1):

| R | `multiplier(R)` | Лок |
|---|---|---|
| 1 | `1000000000000000000` | 604 800 с = 7 д |
| 2 | `2000000000000000000` | 1 209 600 с = 14 д |
| 3 | `2500000000000000000` | 1 814 400 с = 21 д |
| 4 | `2666666666666666666` | 2 419 200 с = 28 д |
| 5 | `2708333333333333333` | 3 024 000 с = 35 д |
| 6 | `2716666666666666666` | 3 628 800 с = 42 д |
| 7 | `2718055555555555555` | 4 233 600 с = 49 д |
| — | `E_FIXED = 2718281828459045235` | **недостижим** |

`multiplier(7) < E_FIXED` — предел ряда записан в контракт, но выдать его нельзя.
Радиус вне диапазона ревертит, а не возвращает тихий ноль:

```powershell
cast call $EMISSION "multiplier(uint256)(uint256)" 8 --rpc-url $RPC
# custom error 0x8b8f35ce -> InvalidRadius(8)
cast call $EMISSION "multiplier(uint256)(uint256)" 0 --rpc-url $RPC
# custom error 0x8b8f35ce -> InvalidRadius(0)
```

Проверить, что функции `mint` физически нет в байткоде:

```powershell
forge inspect src/MaclaurinToken.sol:MaclaurinToken methodIdentifiers
```

Фактический список селекторов токена — ровно 12 штук, ни одной лишней:

```
EMISSION_POOL()  GENESIS()  TOTAL_SUPPLY()
allowance(address,address)  approve(address,uint256)  balanceOf(address)
decimals()  name()  symbol()  totalSupply()
transfer(address,uint256)  transferFrom(address,address,uint256)
```

Ни `mint`, ни `burn`, ни `owner`, ни `transferOwnership`, ни `pause`. Это и есть тот самый
пруф — не обещание, а отсутствие функции.

### 7.3 Полный цикл стейкинга 🟢

Прогнано целиком на anvil; все выводы ниже — фактические. MACLRN для стейка берётся у
`GENESIS_RECIPIENT`: у деплоера токенов нет вообще (§1). Если стейкать хочешь деплоером —
сначала переведи ему сколько-нибудь с genesis-кошелька.

```powershell
$AMOUNT = "1000000000000000000000"   # 1000 MACLRN = 1000 × 1e18
$RADIUS = "1"                        # начинаем с R=1: лок 7 дней, множитель 1.0x
$ME     = $DEPLOYER                  # адрес, которым стейкаешь
```

**Шаг 1. Апрув.** Аллованс выдаётся ровно на сумму стейка, а не `type(uint256).max`:

```powershell
cast send $TOKEN "approve(address,uint256)" $EMISSION $AMOUNT --rpc-url $RPC --account maclaurin-deployer
cast call $TOKEN "allowance(address,address)(uint256)" $ME $EMISSION --rpc-url $RPC
```

**Шаг 2. Стейк.** Сначала бесплатная проверка, потом отправка:

```powershell
cast call $EMISSION "stake(uint256,uint256)" $AMOUNT $RADIUS --from $ME --rpc-url $RPC   # ожидается 0x
cast send $EMISSION "stake(uint256,uint256)" $AMOUNT $RADIUS --rpc-url $RPC --account maclaurin-deployer
```

**Шаг 3. Позиция.** `positions()` — публичный маппинг на структуру
`Position{staked, radius, unlockTime, weight}`, и раскладывать её надо именно четырьмя
`uint256`:

```powershell
cast call $EMISSION "positions(address)(uint256,uint256,uint256,uint256)" $ME --rpc-url $RPC
```

Фактический вывод при `stake(1000e18, 1)` — четыре строки:

```
1000000000000000000000 [1e21]      <- staked
1                                  <- radius
1786233142 [1.786e9]               <- unlockTime = момент стейка + 604800
1000000000000000000000 [1e21]      <- weight = staked × 1.0
```

Те же поля по одному, если так удобнее:

```powershell
cast call $EMISSION "stakedOf(address)(uint256)"     $ME --rpc-url $RPC
cast call $EMISSION "weightOf(address)(uint256)"     $ME --rpc-url $RPC
cast call $EMISSION "unlockTimeOf(address)(uint256)" $ME --rpc-url $RPC
cast call $EMISSION "isLocked(address)(bool)"        $ME --rpc-url $RPC   # true
cast call $EMISSION "isPokeable(address)(bool)"      $ME --rpc-url $RPC   # false (R=1)
cast call $EMISSION "totalStaked()(uint256)" --rpc-url $RPC
cast call $EMISSION "totalWeight()(uint256)" --rpc-url $RPC
```

Человекочитаемо посмотреть, когда истекает лок:

```powershell
$U = [int]((cast call $EMISSION "unlockTimeOf(address)(uint256)" $ME --rpc-url $RPC).Split(" ")[0])
[DateTimeOffset]::FromUnixTimeSeconds($U).UtcDateTime
```

> **Ключевой инвариант фазы 2:** `weight == staked × multiplier(radius) / 1e18`.
> При `R=1` вес равен телу. При `R=7` тот же стейк даёт вес
> `1000e18 × 2718055555555555555 / 1e18 = 2718055555555555555000` — проверено на anvil,
> сходится до последнего wei. При `R=3` и теле 600e18 вес `1500000000000000000000`.
> Если `weightOf` расходится с этой формулой — останавливайся, это блокирующая находка.

**Шаг 4. Награда капает.** Награда начисляется только после `startTime` и только
пропорционально **весу**:

```powershell
cast call $EMISSION "earned(address)(uint256)" $ME --rpc-url $RPC
cast call $EMISSION "rewardPerToken()(uint256)" --rpc-url $RPC
cast call $EMISSION "currentEpoch()(uint256)" --rpc-url $RPC
```

Порядок величины: эпоха 2 раздаёт `5e26` wei за 7 дней. Единственный стейкер за час
набирает `5e26 / 168 ≈ 2.98e24`; на anvil фактически вышло
`2987764550264550264550264`. Если `earned` держится в нуле — почти наверняка ещё не
наступил `startTime` (`cast call $EMISSION "startTime()(uint256)"` и сравни с
`cast block latest -f timestamp`).

**Шаг 5. Частичный вывод.** Тело не блокируется локом никогда:

```powershell
cast send $EMISSION "unstake(uint256)" 500000000000000000000 --rpc-url $RPC --account maclaurin-deployer
cast call $EMISSION "positions(address)(uint256,uint256,uint256,uint256)" $ME --rpc-url $RPC
```

Вес пересчитывается на остаток, `radius` и `unlockTime` сохраняются.

**Шаг 6. Выход целиком.** `exit()` = `unstake(всё)` + `claim()`, если после этого осталась
награда:

```powershell
cast send $EMISSION "exit()" --rpc-url $RPC --account maclaurin-deployer
cast call $EMISSION "positions(address)(uint256,uint256,uint256,uint256)" $ME --rpc-url $RPC
# 0 0 0 0 — позиция удалена целиком, следующий стейк выбирает любой радиус
cast call $EMISSION "earned(address)(uint256)" $ME --rpc-url $RPC   # 0
```

Замеренный расход газа (чистая EVM, anvil):

| Операция | Газ |
|---|---:|
| `approve` | ~46 000 |
| `stake` | ~150 000 |
| `unstake` (частичный) | 89 007 |
| `claim` | 125 165 |
| `exit` (после лока) | 105 037 |
| `poke` | 85 955 |
| `sweepToRemainderVault` | 93 746 |

При газе Robinhood Chain 0.02 gwei весь этот цикл стоит меньше цента.

**Дозаход в существующую позицию** — два правила, оба проверены:

```powershell
# радиус НЕЛЬЗЯ понизить
cast call $EMISSION "stake(uint256,uint256)" 1 1 --from $ME --rpc-url $RPC
# при активной позиции с R=3 -> custom error 0xbe92293a = RadiusCannotDecrease(3, 1)

# лок пересчитывается ОТ ТЕКУЩЕГО момента, а не продлевается от старого
cast send $EMISSION "stake(uint256,uint256)" 100000000000000000000 3 --rpc-url $RPC --account maclaurin-deployer
cast call $EMISSION "unlockTimeOf(address)(uint256)" $ME --rpc-url $RPC   # вырос
```

Второе правило и есть защита от «докинуть пыль за день до разлока и получить полный
множитель на новую сумму за сутки обязательства».

### 7.4 ГЛАВНАЯ ПРОВЕРКА: лок действительно держит `claim()` 🟢

Это то, ради чего переделывалась вся фаза 2 (`PHASE2-SPEC.md` §3). Если `claim()` работает
до `unlockTime`, атакующий каждую эпоху выводит награду с множителем 2.718x, а потом
уходит досрочно — штрафовать уже нечего, потому что награда давно на его кошельке.
**Провал этой проверки отменяет деплой в мейннет.**

#### Сценарий (R=1, минимальный лок — 7 дней)

```powershell
$AMOUNT = "1000000000000000000000"

# 1. Стейк с R=1
cast send $TOKEN    "approve(address,uint256)" $EMISSION $AMOUNT --rpc-url $RPC --account maclaurin-deployer
cast send $EMISSION "stake(uint256,uint256)" $AMOUNT 1 --rpc-url $RPC --account maclaurin-deployer

# 2. Убедиться, что лок стоит
cast call $EMISSION "isLocked(address)(bool)" $ME --rpc-url $RPC          # true
cast call $EMISSION "unlockTimeOf(address)(uint256)" $ME --rpc-url $RPC

# 3. Подождать, чтобы награда начала капать (минут пять хватит), и убедиться, что она есть
cast call $EMISSION "earned(address)(uint256)" $ME --rpc-url $RPC         # > 0

# 4. ПОПЫТКА КЛЕЙМА ДО РАЗЛОКА — ОБЯЗАНА ЗАРЕВЕРТИТЬ
cast call $EMISSION "claim()" --from $ME --rpc-url $RPC
```

Ожидаемый вывод шага 4 (фактический, с anvil):

```
execution reverted: custom error 0x16b82bbe: 000000000000000000000000000000000000000000000000000000006a77c136
```

Расшифровать и сверить, что число совпадает с `unlockTimeOf`:

```powershell
cast decode-error --sig "StillLocked(uint256)" 0x16b82bbe000000000000000000000000000000000000000000000000000000006a77c136
# 1786233142 [1.786e9]
```

- [ ] селектор именно `0x16b82bbe` (`StillLocked`), а не какой-то другой;
- [ ] аргумент ошибки равен `unlockTimeOf($ME)`;
- [ ] `earned($ME) > 0` — то есть блокируется **непустая** награда, а не «нечего клеймить»
      (иначе можно случайно принять `NothingToClaim` `0x969bf728` за успешную проверку).

**Если шаг 4 вернул `0x` — это блокирующая находка. Мейннет отменяется.**

#### Вторая половина: после разлока `claim()` проходит

```powershell
# ждём истечения unlockTime
cast call $EMISSION "isLocked(address)(bool)" $ME --rpc-url $RPC          # должно стать false
cast call $EMISSION "claim()" --from $ME --rpc-url $RPC                   # 0x — прошло бы
cast send $EMISSION "claim()" --rpc-url $RPC --account maclaurin-deployer
```

Проверить, что токены дошли:

```powershell
cast call $TOKEN    "balanceOf(address)(uint256)" $ME --rpc-url $RPC
cast call $EMISSION "totalClaimed()(uint256)" --rpc-url $RPC
cast call $EMISSION "earned(address)(uint256)" $ME --rpc-url $RPC          # 0 после клейма
```

#### Как не ждать 7 дней 🟢

**Укоротить лок нельзя.** `EPOCH_DURATION = 7 days` — `constant` в байткоде,
`lockDuration(R) = R × 604800`, минимум `R = 1`. Ни переменной окружения, ни параметра
деплоя, который это меняет, не существует, и это правильно: тестировать надо тот же
контракт, который поедет в мейннет. `EMISSION_START_DELAY` сдвигает только **старт
эмиссии**, к локу отношения не имеет.

Отсюда три честных варианта:

| Вариант | Время | Что покрывает |
|---|---|---|
| **Форк тестнета Robinhood Chain на anvil** | минуты | всё, включая клейм после разлока — **рекомендуется** |
| Локальный anvil (§4.1) | минуты | всё, но на локально задеплоенном контракте |
| Реальный тестнет | 7 дней | всё, но с настоящим ожиданием |

**Форк — лучший вариант, потому что это ровно тот контракт, который ты только что
задеплоил в тестнет, со всем его состоянием.** Транзакции уходят в локальную копию,
реальная сеть не трогается, тестовый ETH не тратится:

```powershell
# Терминал 1
anvil --fork-url https://rpc.testnet.chain.robinhood.com

# Терминал 2 — тот же $EMISSION и $TOKEN, но RPC локальный
$RPC = "http://127.0.0.1:8545"

# перемотать на 7 дней и 1 секунду вперёд
cast rpc evm_increaseTime 604801 --rpc-url $RPC
cast rpc evm_mine --rpc-url $RPC

cast call $EMISSION "isLocked(address)(bool)" $ME --rpc-url $RPC   # false
cast call $EMISSION "claim()" --from $ME --rpc-url $RPC            # 0x
```

Чтобы подписывать транзакции на форке своим адресом без ключа — попроси anvil
представиться им:

```powershell
cast rpc anvil_impersonateAccount $ME --rpc-url $RPC
cast rpc anvil_setBalance $ME 0xDE0B6B3A7640000 --rpc-url $RPC     # 1 ETH на газ
cast send $EMISSION "claim()" --rpc-url $RPC --unlocked --from $ME
```

На **реальном тестнете** обязательная часть — шаг 4 (реверт), она занимает минуту и стоит
ноль. Вторая половина (клейм после разлока) на реальной сети проверяется через неделю: это
не блокирует продолжение работы, но галочку в §4.4 нужно поставить до мейннета.

> **Побочный, но полезный факт про тестнет.** Для тестнета имеет смысл ставить
> `EMISSION_START_DELAY=300` (минимум, который допускает `Deploy.s.sol`), а не 86400:
> иначе эмиссия начнётся только через сутки и `earned` будет честным нулём весь первый
> день. В мейннете 86400 нужен, чтобы успеть собрать пул до начала эмиссии.

### 7.5 Досрочный выход: тело целиком, награда в казну 🟢

Вторая половина той же механики. Проверяется **отдельным адресом**, чтобы не портить
позицию из §7.4.

```powershell
$U2 = "0x..."     # второй кошелёк
$A  = "1000000000000000000000"

# 1. Застейкать с максимальным множителем
cast send $TOKEN    "approve(address,uint256)" $EMISSION $A --rpc-url $RPC --account maclaurin-second
cast send $EMISSION "stake(uint256,uint256)" $A 7 --rpc-url $RPC --account maclaurin-second

# 2. Вес обязан быть телом × 2.718055…
cast call $EMISSION "weightOf(address)(uint256)" $U2 --rpc-url $RPC
# 2718055555555555555000 при теле 1000e18

# 3. Дать награде накопиться, затем зафиксировать три числа ДО выхода
cast call $TOKEN    "balanceOf(address)(uint256)" $U2 --rpc-url $RPC
cast call $EMISSION "earned(address)(uint256)"    $U2 --rpc-url $RPC
cast call $EMISSION "unallocated()(uint256)" --rpc-url $RPC

# 4. Досрочный выход — лок ещё активен
cast call $EMISSION "isLocked(address)(bool)" $U2 --rpc-url $RPC          # true
cast send $EMISSION "exit()" --rpc-url $RPC --account maclaurin-second

# 5. Сверить результат
cast call $TOKEN    "balanceOf(address)(uint256)" $U2 --rpc-url $RPC
cast call $EMISSION "positions(address)(uint256,uint256,uint256,uint256)" $U2 --rpc-url $RPC
cast call $EMISSION "unallocated()(uint256)" --rpc-url $RPC
```

Что обязано получиться (проверено на anvil):

- [ ] **тело вернулось ровно целиком, до последнего wei**: баланс вырос на `1000e18`,
      ни на wei меньше. Лок не удерживает принципал ни при каких условиях;
- [ ] **награда сгорела**: `earned($U2)` стал `0`, на кошелёк она не пришла;
- [ ] **сгоревшее не исчезло, а уехало в казну**: `unallocated()` вырос примерно на ту
      сумму, которая была в `earned` до выхода (на anvil: `1.65e21 → 5.22e25`);
- [ ] позиция удалена: `positions()` вернул `0 0 0 0`.

> `exit()` при активном локе **не** ревертит `StillLocked`. Внутри он сначала зовёт
> `unstake`, который сжигает награду, и `claim` после этого просто не вызывается — клеймить
> уже нечего. То есть выйти из лока одной транзакцией можно всегда, ценой награды и только
> её.

Если хочется отделить сжигание от вывода — то же самое, но через `unstake`. Сгорает вся
награда даже при частичном выходе, это сознательное решение (иначе можно было бы выйти
телом на 99.99% и досидеть лок пылинкой, сохранив награду, набранную полным телом):

```powershell
cast send $EMISSION "unstake(uint256)" 1 --rpc-url $RPC --account maclaurin-second   # 1 wei
cast call $EMISSION "earned(address)(uint256)" $U2 --rpc-url $RPC                 # 0
```

Отследить событие сжигания (индексатор отличает его от «никто не стейкал»):

```powershell
cast logs --from-block <блок деплоя> --address $EMISSION "RewardForfeited(address,uint256)" --rpc-url $RPC
```

### 7.6 `poke` — permissionless сброс истёкшего множителя 🟢

`poke` нужен потому, что после `unlockTime` пользователь уже ничем не рискует, а вес его
позиции всё ещё умножен на 2.718. Кипера в системе нет, поэтому пересчёт вынесен наружу и
открыт кому угодно.

```powershell
# 1. На АКТИВНОМ локе обязан зареверить
cast call $EMISSION "poke(address)" $U2 --from $ME --rpc-url $RPC
# custom error 0x16b82bbe -> StillLocked(unlockTime)   <- тот же селектор, что у claim()

# 2. После истечения лока позиция становится «pokeable»
cast call $EMISSION "isPokeable(address)(bool)" $U2 --rpc-url $RPC        # true

# 3. Позвать может ЛЮБОЙ адрес, не только владелец позиции
cast send $EMISSION "poke(address)" $U2 --rpc-url $RPC --account maclaurin-deployer

# 4. Результат: радиус и вес сброшены до 1.0x, totalWeight уменьшился
cast call $EMISSION "positions(address)(uint256,uint256,uint256,uint256)" $U2 --rpc-url $RPC
cast call $EMISSION "totalWeight()(uint256)" --rpc-url $RPC
cast call $EMISSION "isPokeable(address)(bool)" $U2 --rpc-url $RPC        # false
```

Фактический прогон (позиция 1000e18 с R=2, лок истёк):

```
до poke:   1000000000000000000000  2  1787702011  2000000000000000000000   totalWeight 3e21
после:     1000000000000000000000  1  1787702011  1000000000000000000000   totalWeight 2e21
```

Обрати внимание: `unlockTime` **не** обнуляется, сбрасываются только `radius` и `weight`.
Это правильно — инвариант `weight == staked × multiplier(radius) / 1e18` продолжает
держаться, а пользователь освобождается от обязанности стейкать с прежним `R`.

Граничные случаи, оба проверены:

```powershell
cast call $EMISSION "poke(address)" 0x000000000000000000000000000000000000dEaD --from $ME --rpc-url $RPC
# 0xabf0f034 -> NoPosition()

cast call $EMISSION "poke(address)" $ME --from $ME --rpc-url $RPC
# 0x25b064c0 -> AlreadyAtBaseline(), если позиция уже 1.0x
```

> `poke` — не админское полномочие: адрес не выбирается (условие проверяется на цепочке),
> сумма не выбирается, новый вес однозначен. Проверить это можно ровно так, как выше:
> вызвать с чужого адреса и убедиться, что сработало, и вызвать на активном локе и
> убедиться, что нет.

### 7.7 `sweepToRemainderVault` — незанятая награда доходит до казны 🟢

Награда эпох, в которые не было ни одного стейкера, плюс всё сгоревшее при досрочных
выходах, копится в `unallocated` и уходит на `remainderVault`. Функция permissionless:
получатель immutable, сумма ограничена счётчиком — выбирать нечего.

```powershell
$VAULT = (cast call $EMISSION "remainderVault()(address)" --rpc-url $RPC)

cast call $EMISSION "pendingUnallocated()(uint256)" --rpc-url $RPC   # включая незафиксированное
cast call $EMISSION "unallocated()(uint256)" --rpc-url $RPC          # только зафиксированное
cast call $TOKEN    "balanceOf(address)(uint256)" $VAULT --rpc-url $RPC

cast send $EMISSION "sweepToRemainderVault()" --rpc-url $RPC --account maclaurin-deployer

cast call $TOKEN    "balanceOf(address)(uint256)" $VAULT --rpc-url $RPC
cast call $EMISSION "totalSwept()(uint256)" --rpc-url $RPC
cast call $EMISSION "unallocated()(uint256)" --rpc-url $RPC          # 0
```

- [ ] баланс `remainderVault` вырос ровно на `pendingUnallocated`, который был до вызова;
- [ ] `totalSwept()` равен этой же сумме;
- [ ] `unallocated()` обнулился.

Повторный вызов на пустом счётчике обязан зареверить:

```powershell
cast call $EMISSION "sweepToRemainderVault()" --from $ME --rpc-url $RPC
# 0x351261fc -> NothingToSweep()
```

**Как получить непустой `unallocated` на тестнете.** Два независимых источника, любой
подойдёт:

1. **Пустая эпоха.** Если после деплоя никто не стейкал какое-то время, награда за этот
   промежуток целиком уходит в `unallocated` — достаточно подождать десять минут после
   `startTime` и не стейкать.
2. **Досрочный выход** из §7.5 — сгоревшая награда попадает туда же.

### 7.8 Инварианты, которые должны держаться всегда 🟢

| Инвариант | Как проверить |
|---|---|
| `totalSupply()` неизменен | `cast call $TOKEN "totalSupply()(uint256)"` — всегда `2718281828459045235360287471` |
| Контракт эмиссии платёжеспособен | `balanceOf($EMISSION) >= totalStaked()` |
| Принципал возвращается целиком | после `exit()` баланс пользователя вырос ровно на сумму стейка + награда |
| Эмиссия завершается | `epochAmount(27) == 0` |
| Вес соответствует радиусу | `weightOf(u) == stakedOf(u) × multiplier(radius) / 1e18` для каждой позиции |
| Вес не меньше тела | `totalWeight() >= totalStaked()`, множитель всегда ≥ 1.0x |
| Пустой стейк = пустой вес | `totalWeight() == 0` тогда и только тогда, когда `totalStaked() == 0` |
| Потолок `e` недостижим | `multiplier(7) < E_FIXED()` |
| Лок не держит тело | `unstake` проходит при `isLocked(u) == true` |
| Лок держит награду | `claim()` ревертит `StillLocked`, пока `isLocked(u) == true` |

Быстрая проверка платёжеспособности и весов одной командой:

```powershell
$bal = [decimal]((cast call $TOKEN "balanceOf(address)(uint256)" $EMISSION --rpc-url $RPC).Split(" ")[0])
$stk = [decimal]((cast call $EMISSION "totalStaked()(uint256)" --rpc-url $RPC).Split(" ")[0])
$wgt = [decimal]((cast call $EMISSION "totalWeight()(uint256)" --rpc-url $RPC).Split(" ")[0])
"balance >= staked : {0}" -f ($bal -ge $stk)
"weight  >= staked : {0}" -f ($wgt -ge $stk)
```

Обе строки обязаны напечатать `True`. Если хоть одна `False` — останавливайся немедленно,
это блокирующая находка.

---

## 8. Пул ликвидности на Uniswap V3

### 8.0 🔴 В ТЕСТНЕТЕ ЭТОТ РАЗДЕЛ ВЫПОЛНИТЬ НЕЛЬЗЯ

**Uniswap на Robinhood Chain testnet не развёрнут.** Это не предположение — проверено
`cast code` по всем адресам из официального списка Uniswap 2026-08-01:

```powershell
$T = "https://rpc.testnet.chain.robinhood.com"
cast code 0x1f7d7550b1b028f7571e69a784071f0205fd2efa --rpc-url $T   # 0x  (фабрика)
cast code 0x73991a25c818bf1f1128deaab1492d45638de0d3 --rpc-url $T   # 0x  (NPM)
cast code 0xcaf681a66d020601342297493863e78c959e5cb2 --rpc-url $T   # 0x  (SwapRouter02)
cast code 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 --rpc-url $T   # 0x  (WETH)
```

Все четыре возвращают пустой `0x`. Единственный контракт Uniswap-стека, который в тестнете
есть, — `Permit2` по адресу `0x000000000022D473030F116dDEE9F6B43aC78BA3`, и то лишь потому,
что он разворачивается детерминированно на любой EVM-сети.

**WETH в тестнете тоже нет.** А без WETH пара MACLRN/WETH не собирается в принципе.

**Что с этим делать.** Репетировать §8 на **локальном форке мейннета** — там весь стек
на месте, транзакции уходят в локальную копию, реальных денег не тратится:

```powershell
anvil --fork-url https://rpc.mainnet.chain.robinhood.com
```

Дальше все команды §8.5 — с `--rpc-url http://127.0.0.1:8545` вместо `rh`. MACLRN на форке
можно взять двумя способами: задеплоить связку в тот же форк ещё раз (`forge script … --unlocked`)
или, если контракт уже в мейннете, представиться genesis-кошельком через
`cast rpc anvil_impersonateAccount`.

Практический вывод для чеклиста: **пункт «пул» в §4.4 вычеркнут, а в §6.1 добавлен пункт
«пул отрепетирован на форке мейннета».** Порядок остаётся прежним — просто репетиция
переезжает с тестнета на форк.

### 8.1 Адреса 🟢

Сверено с официальным списком Uniswap для Robinhood Chain
(https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments)
**и перепроверено on-chain 2026-08-01**: у всех контрактов есть код, а
`NonfungiblePositionManager.factory()`, `SwapRouter02.factory()` и `QuoterV2.factory()`
указывают на одну и ту же фабрику.

**Robinhood Chain mainnet (chainid 4663):**

| Контракт | Адрес |
|---|---|
| UniswapV3Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| NonfungiblePositionManager | `0x73991a25c818bf1f1128deaab1492d45638de0d3` |
| SwapRouter02 | `0xcaf681a66d020601342297493863e78c959e5cb2` |
| UniversalRouter | `0x8876789976decbfcbbbe364623c63652db8c0904` |
| QuoterV2 | `0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7` |
| TickLens | `0x7dfd4f31be6814d2906bde155c3e1b146eac1468` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| **WETH** | **`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`** |

**Robinhood Chain testnet (chainid 46630):** ничего из перечисленного, кроме `Permit2`.
См. §8.0.

> 🔴 **Адрес WETH изменился по сравнению со старой версией этого документа.** На Base
> WETH был предеплоем OP Stack по `0x4200…0006`. Robinhood Chain — это **Arbitrum**, там
> такого предеплоя нет, и WETH живёт по обычному адресу
> `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`. Проверено: `name()` и `symbol()` возвращают
> `WETH`, `decimals()` = 18, `totalSupply()` ≈ 25 520 WETH.
> `NonfungiblePositionManager.WETH9()` возвращает ровно этот адрес.
> **Захардкоженный `0x4200…0006` в любом скрипте — это гарантированная потеря средств.**

Перепроверить самому перед использованием (адреса иногда переезжают, а ошибка здесь стоит
всей ликвидности):

```powershell
$M = "https://rpc.mainnet.chain.robinhood.com"
cast call 0x73991a25c818bf1f1128deaab1492d45638de0d3 "factory()(address)" --rpc-url $M
cast call 0x73991a25c818bf1f1128deaab1492d45638de0d3 "WETH9()(address)" --rpc-url $M
```

Первая обязана вернуть `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`, вторая —
`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`.
`script/Pool.s.sol` делает эту сверку сам и падает, если по адресу нет кода.

**Uniswap на этой сети живой, а не декоративный.** Проверено существующим пулом: пара
`RIBBIT/WETH` в тире 1% по адресу `0x31c6CbB6Dd23579711a7cf3aEC61846622442cd8` держит
~0.99 WETH активной ликвидности. То есть в мейннете есть и код, и торговля, и тир 1% —
именно тот, который нужен нам (§8.2).

### 8.2 Выбор fee tier

Фабрика Robinhood Chain поддерживает четыре тира (проверено `feeAmountTickSpacing`
on-chain 2026-08-01):

| Fee | Значение параметра | Tick spacing | Для чего |
|---|---|---|---|
| 0.01% | `100` | 1 | стейблкоин ↔ стейблкоин |
| 0.05% | `500` | 10 | коррелированные активы (ETH/wstETH) |
| 0.30% | `3000` | 60 | «обычные» токены |
| **1.00%** | **`10000`** | **200** | **экзотика, высокая волатильность** |

**Берём 1% (`10000`).** Причина не в жадности до комиссий. При $13 ликвидности любая
сделка двигает цену на десятки процентов, то есть арбитражник и так снимает с пула
несопоставимо больше комиссии. 1% — это тир, в котором такие токены и живут: там их ищут
агрегаторы, и там не создаётся ложного впечатления ликвидного рынка. Шаг тиков 200 при
этом ещё и удобен — границы диапазона грубые, промахнуться сложнее.

### 8.3 Расчёт стартовой цены

В Uniswap V3 стартовая цена задаётся числом `sqrtPriceX96`:

```
sqrtPriceX96 = sqrt(amount1 / amount0) × 2^96
```

где `token0`/`token1` — та же пара, отсортированная **по возрастанию адреса**. Какой из
токенов окажется `token0`, заранее неизвестно: адрес MACLRN получается из `CREATE` и
зависит от нонса деплоера. `script/Pool.s.sol` обрабатывает оба порядка.

**Цена — это просто пропорция, в которой ты вносишь ликвидность.** Ты её не «угадываешь»,
ты её назначаешь. И назначаешь ровно двумя числами: сколько MACLRN и сколько ETH кладёшь.

При $13 = **0.0070 ETH** (курс $1859.95) выбор количества MACLRN задаёт оценку проекта:

| MACLRN в пул | Цена за токен | FDV (сапплай `e`×10⁹) |
|---|---|---|
| 20 000 000 | $6.51 × 10⁻⁷ | ~$1 770 |
| 50 000 000 | $2.60 × 10⁻⁷ | ~$708 |
| 100 000 000 | $1.30 × 10⁻⁷ | ~$354 |
| **200 000 000** (10% genesis) | **$6.51 × 10⁻⁸** | **~$177** |
| 500 000 000 | $2.60 × 10⁻⁸ | ~$71 |

Честно: при $13 реальной ликвидности FDV — величина декоративная, её двигает сделка на $3.
Смысл выбора не в «оценке», а в том, чтобы цена одного токена не выглядела абсурдно
(ни `$0.000000000001`, ни `$5` при пустом пуле). 200M (10% genesis) — разумная середина,
и она же оставляет 90% genesis на распределение из `LAUNCH-PLAN.md` §0.1.

Посчитать, ничего не отправляя:

```powershell
$env:MACLAURIN_TOKEN  = $TOKEN
$env:MACLAURIN_AMOUNT = "200000000000000000000000000"   # 200 000 000 × 1e18
$env:ETH_AMOUNT    = "7000000000000000"              # 0.0070 ETH
$env:POOL_FEE      = "10000"

forge script script/Pool.s.sol:PoolQuote --rpc-url rh
```

Скрипт напечатает `sqrtPriceX96`, границы тиков и состояние пула. Транзакций не шлёт.

### 8.4 Выбор диапазона: почему full range 🟢

Здесь замеры, а не рассуждения. Пул 1%, 200M MACLRN + 0.0070 ETH,
покупка на **$3** (0.0016 ETH):

| Диапазон | Цена от/до | Концентрация | Сдвиг цены от покупки на $3 |
|---|---|---|---|
| **full range** | 0 … ∞ | ×1.00 | **+50.4%** |
| ±14000 тиков | 0.25× … 4.06× | ×1.97 | +24.3% |
| ±7000 тиков | 0.50× … 2.01× | ×3.32 | +14.1% |
| ±3000 тиков | 0.74× … 1.35× | — | +6.7% |
| ±1400 тиков | 0.87× … 1.15× | — | +3.4% |
| ±600 тиков | 0.94× … 1.06× | — | +1.7% |
| ±200 тиков | 0.98× … 1.02× | — | +0.8% |

Соблазн очевиден: узкий диапазон даёт на порядок меньшее проскальзывание при тех же $13.

**Но берём всё равно full range, и вот почему.**

Позиция сжигается (`LAUNCH-PLAN.md` §6). Сожжённая позиция — это позиция, которую
**невозможно подвинуть никогда**. У узкого диапазона есть граница, и когда цена её
пересекает:

- ликвидность перестаёт быть активной — торговать становится **физически нечем**;
- вся позиция превращается в один актив (вышли вверх — остался только ETH, вниз — только MACLRN);
- комиссии перестают капать;
- исправить нельзя: NFT у `0x…dEaD`.

Насколько это близко: при ±200 тиках покупка на $3 съедает 20% половины диапазона.
**Порядка $7 покупок — и токен упирается в потолок +2%, выше которого его нельзя купить
ни за какие деньги.** Это не гипотетический сценарий, это два свопа.

Теперь добавь к этому, что эпоха 2 выпускает 500 000 000 токенов — **18.4% всего сапплая**
за одну неделю. Цена гарантированно поедет, и поедет далеко за любой разумный узкий
диапазон.

Компромисс ±14000 (0.25×…4×) выглядит привлекательно — вдвое меньше проскальзывание при
широком коридоре, — но покупает эту вдвое всего лишь ×1.97 концентрации ценой того, что
за пределами 4× пул мёртв навсегда. Плохая сделка.

**Итог: `full range` (тики −887200 … 887200 при шаге 200) — дефолт в `script/Pool.s.sol`.**
Проскальзывание в 50% на $3 — это честная характеристика пула на $13, а не дефект
настройки. Прятать её узким диапазоном означает менять видимую цифру на реальный риск
необратимо убить торговлю.

> Если когда-нибудь появится бюджет на нормальную ликвидность — правильный ответ не
> «сузить диапазон», а **не сжигать вторую позицию**: сжечь базовую full-range (это и есть
> пруф), а поверх держать управляемую концентрированную. Для первого запуска на $13 второй
> позиции просто не из чего делать.

### 8.5 Создание пула и внесение ликвидности 🟡

Скрипт `script/Pool.s.sol` разбит на отдельные шаги намеренно: между ними нужно смотреть
на результат, а не узнавать об ошибке после того, как деньги потрачены.

```powershell
# Общие переменные
$env:MACLAURIN_TOKEN  = $TOKEN
$env:MACLAURIN_AMOUNT = "200000000000000000000000000"
$env:ETH_AMOUNT    = "7000000000000000"
$env:POOL_FEE      = "10000"
```

**Шаг 1 — расчёт, без транзакций:**

```powershell
forge script script/Pool.s.sol:PoolQuote --rpc-url rh
```

**Шаг 2 — создать и инициализировать пул** (самая дорогая транзакция всего запуска:
здесь разворачивается контракт пула, ~4.65M газа; токены не тратятся):

```powershell
forge script script/Pool.s.sol:CreatePool --rpc-url rh --account maclaurin-deployer --sender $DEPLOYER --broadcast
```

**Шаг 3 — внести ликвидность.** Скрипт сам обернёт нужное количество ETH в WETH, выдаст
апрувы ровно на нужные суммы (не `type(uint256).max`) и заминтит позицию full range:

```powershell
forge script script/Pool.s.sol:AddLiquidity --rpc-url rh --account maclaurin-deployer --sender $DEPLOYER --broadcast
```

Из вывода запиши `LP tokenId` — **без него нельзя ни собрать комиссии, ни сжечь позицию**:

```powershell
$env:LP_TOKEN_ID = "12345"
```

> MACLRN должен лежать на кошельке **деплоера**. Если genesis ушёл на другой адрес (а он
> должен — см. §1), сначала переведи туда нужное количество:
> ```powershell
> cast send $TOKEN "transfer(address,uint256)" $DEPLOYER $env:MACLAURIN_AMOUNT --rpc-url rh --account genesis-wallet
> ```
> либо запускай `AddLiquidity` от имени genesis-кошелька, импортировав его тем же
> `cast wallet import`.

**Шаг 4 — проверить состояние:**

```powershell
forge script script/Pool.s.sol:PoolStatus --rpc-url rh
```

**Шаг 5 — свопы в обе стороны реальными деньгами.** Это последняя проверка перед сжиганием
позиции: пока NFT у тебя, ещё можно всё откатить. Купить на ~$1, продать обратно.
Убедиться, что:

- [ ] своп проходит в обе стороны;
- [ ] полученное количество примерно совпадает с котировкой;
- [ ] токен **не** ведёт себя как honeypot (продажа не ревертит).

Через веб-интерфейс https://app.uniswap.org (выбрать сеть Robinhood Chain, вставить адрес
токена) — так проще и нагляднее, чем собирать calldata роутера руками.

> 🟡 Поддерживает ли официальный веб-интерфейс Uniswap сеть Robinhood Chain в списке —
> не проверено. Если её там нет, свопы делаются напрямую через `SwapRouter02`
> (`0xCaf681a66D020601342297493863E78C959E5cb2`) или `UniversalRouter`
> (`0x8876789976decbfcbbbe364623c63652db8c0904`) вызовом `cast send`. Проверка
> «продажа не ревертит» от интерфейса не зависит и обязательна в любом случае:
> **это единственный доступный honeypot-тест**, автоматических чекеров для chain ID 4663
> пока нет.

### 8.6 Сжигание LP-позиции 🔴 НЕОБРАТИМО

Варианты и почему выбран именно этот:

| Вариант | Стоимость | Оценка |
|---|---|---|
| **Сжечь NFT (`→ 0x…dEaD`)** | **~63 200 газа (~$0.001)** | **выбран** |
| Локер (UNCX, Team Finance) | десятки долларов | вне бюджета $15 |
| Оставить у себя | $0 | нет пруфа, красный флаг у любого чекера |

Что теряется вместе с позицией: право вывести ликвидность (`decreaseLiquidity`), право
собрать накопленные комиссии (`collect`) и право сдвинуть диапазон. Ликвидность остаётся
в пуле навсегда — **это и есть пруф, что рагпула не будет**.

> **Сжигать на `0x…dEaD`, а не на `address(0)`.** ERC-721 от OpenZeppelin реверит перевод
> на нулевой адрес, туда позицию просто не отправить.

> **Комиссии.** После сжигания они недоступны навсегда. Если позиция успела поторговать
> (а после §8.5 успела) — либо собери их до сжигания, либо осознанно оставь: при таких
> оборотах речь о центах.

```powershell
$env:LP_TOKEN_ID = "12345"
$env:BURN_CONFIRM = "BURN"
forge script script/Pool.s.sol:BurnLp --rpc-url rh --account maclaurin-deployer --sender $DEPLOYER --broadcast
```

Скрипт не даст выстрелить в ногу: требует `BURN_CONFIRM=BURN`, проверяет, что позиция
действительно по паре с MACLRN, что в ней есть ликвидность, и что диапазон — full range
(отключается через `LP_EXPECT_FULL_RANGE=false`).

Пруф после сжигания:

```powershell
cast call 0x73991a25c818bf1f1128deaab1492d45638de0d3 "ownerOf(uint256)(address)" $env:LP_TOKEN_ID --rpc-url rh
```

Должно вернуть `0x000000000000000000000000000000000000dEaD`. Ссылку на эту транзакцию на
https://robinhoodchain.blockscout.com — в README и во все материалы запуска.

---

## 9. Смета по фактическим цифрам

### 9.1 Исходные данные (замерено 2026-08-01, Robinhood Chain mainnet, блок 24848143) 🟢

```powershell
cast gas-price --rpc-url https://rpc.mainnet.chain.robinhood.com      # 20012000 wei = 0.020 gwei
cast base-fee  --rpc-url https://rpc.mainnet.chain.robinhood.com      # 20114000 wei = 0.020 gwei
```

Blockscout той же сети показывает свою оценку — `slow 0.03 / average 0.04 / fast 0.06 gwei`.
Расхождение нормальное: `cast gas-price` берёт текущий base fee, Blockscout закладывает
запас. В таблице ниже посчитаны обе точки плюс стресс-сценарий.

Курс ETH: **$1 859.95**, снят 2026-08-01 с он-чейн фида Chainlink ETH/USD
(`latestRoundData()`, 8 знаков, ответ `185994900000`).

> 🟡 Адрес фида Chainlink **на самой Robinhood Chain** установить не удалось — сеть новая,
> в публичном списке фидов её ещё нет. Приведённое значение снято с фида на другой сети
> в тот же день. ETH — один и тот же актив везде, так что для сметы это годится, но перед
> мейннетом курс стоит перепроверить любым способом: цена ETH за месяцы меняется сильнее,
> чем всё остальное в этой таблице.

### 9.2 Газ по операциям 🟢

**Деплой** — фактический `eth_estimateGas` по реальному байткоду, снятый **напрямую
с Robinhood Chain mainnet** 2026-08-01 (`2 327 373`). Операции стейкинга — `gasUsed` из
чеков транзакций на anvil. Операции с пулом — замеры на форке через `vm.createSelectFork`
(это тот же код Uniswap V3, газ от сети почти не зависит).

| Операция | Газ | @0.02 gwei | @0.06 gwei | @0.5 gwei |
|---|---:|---:|---:|---:|
| Деплой `MaclaurinEmission` (+`MaclaurinToken` из конструктора) | **2 327 373** | **$0.087** | **$0.260** | **$2.164** |
| Обернуть ETH → WETH | 33 408 | $0.001 | $0.004 | $0.031 |
| `approve` MACLRN → NPM | 29 797 | $0.001 | $0.003 | $0.028 |
| `approve` WETH → NPM | 24 894 | $0.001 | $0.003 | $0.023 |
| **Создать пул** (1% tier) | **4 654 196** | **$0.173** | **$0.519** | **$4.328** |
| Заминтить LP-позицию (full range) | 520 137 | $0.019 | $0.058 | $0.484 |
| Сжечь LP-NFT → `0x…dEaD` | 63 208 | $0.002 | $0.007 | $0.059 |
| Тестовый своп WETH → MACLRN | 58 863 | $0.002 | $0.007 | $0.055 |
| Тестовый своп MACLRN → WETH | 55 969 | $0.002 | $0.006 | $0.052 |
| **ИТОГО** | **7 767 845** | **$0.29** | **$0.87** | **$7.22** |

> **Про L1-составляющую.** Robinhood Chain — это Arbitrum Nitro, а не OP Stack, поэтому
> отдельной «L1 fee» в чеке нет: стоимость публикации данных в Ethereum уже зашита в
> `gasUsed`. Видно это прямым сравнением: та же транзакция деплоя стоит **2 307 889** газа
> в чистой EVM (anvil) и **2 327 373** на Robinhood Chain. Разница — **19 484 газа**, то есть
> меньше процента, при 11.4 КБ calldata. Блобы и brotli-сжатие Nitro делают эту часть
> практически бесплатной. Функции `getL1Fee(bytes)` из OP Stack здесь **нет** — вызывать
> `0x420…000F` бессмысленно, такого предеплоя в этой сети не существует.

> **Деплой перемерен после фазы 2.** Было 1 887 955 (фаза 1, чистая EVM), стало
> **2 307 889** в чистой EVM и **2 327 373** на Robinhood Chain. Рост на ~420 тысяч (+22%) —
> это `poke`, таблица множителей, взвешенный аккумулятор и проверка лока. В деньгах при
> текущем газе это **+$0.016**.

Операции стейкинга (оплачивает их пользователь, не бюджет запуска):
`stake` ~150 000, `claim` 125 165, `unstake` 89 007, `exit` 105 037, `poke` 85 955,
`sweepToRemainderVault` 93 746. При 0.02 gwei каждая — доли цента.

**Тестнет ещё дешевле:** там `gas-price` = 0.01 gwei, и весь деплой обходится в
`0.000060 ETH` (§4.2) — то есть кран нужен ровно для того, чтобы на кошельке было хоть
что-то.

### 9.3 Итоговая смета при бюджете $15

| Статья | Прежняя оценка (`MACLAURIN-TOKEN-SPEC.md` §7) | По факту | Комментарий |
|---|---|---|---|
| Завести ETH в сеть Robinhood Chain | ~$1.00 | 🟡 не проверено | комиссия моста/площадки, не газ |
| Деплой токена | $0.10–0.50 | \$0.09 (общий) | токен и эмиссия — одна транзакция |
| Деплой эмиссии | $0.20–0.60 | ↑ | |
| `renounceOwnership()` | $0.05 | **$0** | `Ownable` не используется, отказываться не от чего |
| Верификация | $0 | $0 | Blockscout, ключ не нужен |
| Создание пула | ~$0.30 | $0.17 | самая тяжёлая транзакция запуска |
| Ликвидность + сжигание + свопы | — | $0.03 | |
| **Инфраструктура итого (газ)** | **~$2.00** | **$0.29** | при 0.02 gwei |
| **В пул остаётся** | ~$13.00 | **~$13.7** | минус комиссия за завод ETH в сеть |

**Запас относительно $15: примерно 50× по газовой части.** Даже если газ Robinhood Chain
подскочит в 25 раз относительно текущих 0.02 gwei (до 0.5 gwei), вся инфраструктура
уложится в $7.22, и в пул всё равно уйдёт больше $7.

Практический вывод: **основной риск бюджета — не газ, а стоимость завода ETH в сеть.**
Это единственная статья сметы, которую нельзя замерить командой, и единственная,
про которую в этом документе честно написано «не проверено».

### 9.4 Оговорки

- **Газ деплоя перемерен и после фазы 2, и после смены сети.** Итог: **2 327 373** —
  `eth_estimateGas` по реальному байткоду напрямую с Robinhood Chain mainnet. Перед
  деплоем всё равно сделай сухой прогон, он бесплатен и покажет актуальную цену газа:
  ```powershell
  forge script script/Deploy.s.sol:Deploy --rpc-url rh --sender $DEPLOYER
  ```
  В конце вывода Foundry печатает `Estimated gas price` и `Estimated total gas used`.
- 🟡 **Цифры по пулу перенесены с замеров на форке другой сети.** Код Uniswap V3 там
  побайтово тот же, и газ EVM от сети не зависит, но Arbitrum добавляет свою надбавку за
  публикацию данных (на деплое она составила меньше процента). Перемерить можно бесплатно
  на форке мейннета (§8.0) — и это стоит сделать до мейннета, потому что создание пула —
  самая дорогая транзакция всего запуска.
- Цена ETH и цена газа меняются:
  ```powershell
  cast gas-price --rpc-url https://rpc.mainnet.chain.robinhood.com
  ```
- Резерв: держи на кошельке деплоера **минимум 0.0005 ETH (~$0.93)** сверх суммы
  ликвидности. Это ~3× от полной стоимости всех транзакций при нынешнем газе и покрывает
  пересылку неудачной транзакции.

---

## 10. Мониторинг после запуска

Эмиссия идёт **175 дней**: эпохи 2…26, по 7 дней каждая (`25 × 7 = 175`).
Эпоха `n` начинается в `startTime + (n − 2) × 604800`.

### 10.1 Календарь эпох 🟢

```powershell
$START = [int]((cast call $EMISSION "startTime()(uint256)" --rpc-url rh).Split(" ")[0])
2..8 | ForEach-Object {
  $ts = $START + ($_ - 2) * 604800
  "{0,2}  {1}  {2}" -f $_, $ts, [DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime
}
```

Или прямо из контракта:

```powershell
cast call $EMISSION "epochEndsAt(uint256)(uint256)" 2 --rpc-url rh
cast call $EMISSION "currentEpoch()(uint256)" --rpc-url rh
cast call $EMISSION "emissionFinished()(bool)" --rpc-url rh
```

### 10.2 Что смотреть в первые дни

**День 0 (сразу после деплоя):**

- [ ] оба контракта верифицированы на https://robinhoodchain.blockscout.com (§5.4.1)
- [ ] `epochAmount(27) == 0` (§7.2)
- [ ] LP-NFT принадлежит `0x…dEaD` (§8.6)
- [ ] токен открывается на Uniswap, своп проходит в обе стороны (автоматических
      honeypot-чекеров для chain ID 4663 пока нет — §6.3)

**Первая неделя (эпоха 2) — самое важное окно.** Здесь распределяется
**500 000 000 токенов, 18.4% всего сапплая**. Риск из `LAUNCH-PLAN.md` §0.3: если за неделю
пришёл ровно один стейкер, он забирает всё — измерено пробой, адрес со стейком в **1 wei**
получает всю эпоху. Это корректная работа pro-rata, а не баг, но следить надо ежедневно:

```powershell
cast call $EMISSION "totalStaked()(uint256)" --rpc-url rh
cast call $EMISSION "rewardPerToken()(uint256)" --rpc-url rh
cast call $EMISSION "pendingUnallocated()(uint256)" --rpc-url rh
cast call $TOKEN "balanceOf(address)(uint256)" $EMISSION --rpc-url rh
```

Кто именно стейкает — по событиям. **Сигнатуры финальные**, сняты с собранного артефакта
(`forge inspect src/MaclaurinEmission.sol:MaclaurinEmission events`):

| Событие | topic0 |
|---|---|
| `Staked(address,uint256,uint256,uint256)` | `0xb4caaf29adda3eefee3ad552a8e85058589bf834c7466cae4ee58787f70589ed` |
| `Unstaked(address,uint256)` | `0x0f5bb82176feb1b5e747e28471aa92156a04d9f3ab9f45f28e2d704232b93f75` |
| `RewardClaimed(address,uint256)` | `0x106f923f993c2149d49b4255ff723acafa1f2d94393f561d3eda32ae348f7241` |
| `RewardForfeited(address,uint256)` | `0x13cc1c835292398b4f1062a0dbaed54c860ff73ce245d8e4db91b06169f77a27` |
| `Unallocated(uint256)` | `0x877e3995a8ee2a49bbb95a67d3ca17267d54398da227e209bee9f3e358b26f03` |
| `Poked(address,address)` | `0x0fe1185a801e8030a098dc8e5b82f5eebbff519f00d2b486b1a7520040c65565` |
| `SweptToRemainderVault(uint256)` | `0x9a6a7105b0533cbae4ddca781baf9cd03c30a4798bbe2aa512e6cb7da34e8a10` |

```powershell
cast logs --from-block <блок деплоя> --address $EMISSION "Staked(address,uint256,uint256,uint256)" --rpc-url rh
cast logs --from-block <блок деплоя> --address $EMISSION "RewardClaimed(address,uint256)" --rpc-url rh
cast logs --from-block <блок деплоя> --address $EMISSION "Poked(address,address)" --rpc-url rh
```

> **`Staked` теперь четырёхаргументный** — `(user, amount, radius, unlockTime)`. Старая
> сигнатура `Staked(address,uint256)` даёт другой topic0 и просто **не найдёт ни одного
> лога** — молча, без ошибки. Если внешний индексатор или дашборд писался под фазу 1, его
> надо переподписать.

`RewardForfeited` и `Unallocated` — два разных источника роста `unallocated`. Первый значит
«кто-то вышел досрочно», второй — «эпоха прошла без единого стейкера». Разделены намеренно,
чтобы это можно было отличить по логам, а не гадать.

**Ежедневно, первые две недели:**

| Что | Команда | Тревожный признак |
|---|---|---|
| Платёжеспособность | `balanceOf($EMISSION)` vs `totalStaked()` | баланс меньше принципала |
| Сапплай не поехал | `totalSupply()` | что угодно кроме `2718281828459045235360287471` |
| Эпоха идёт | `currentEpoch()` | застряла или прыгнула |
| Незаклеймленное копится | `pendingUnallocated()` | растёт быстро → никто не стейкает |
| Цена и ликвидность в пуле | `forge script script/Pool.s.sol:PoolStatus --rpc-url rh` | `active liquidity == 0` |
| LP всё ещё сожжён | `ownerOf($env:LP_TOKEN_ID)` | не `0x…dEaD` |

**Понедельно, до конца эмиссии (175 дней):**

- смена эпохи произошла вовремя (`currentEpoch()` +1 каждые 7 дней);
- `sweepToRemainderVault()` вызывается на эпохах, где никто не стейкал — награда не
  теряется, а уходит в казну остаточного члена;
- **истёкшие локи сбрасываются через `poke(address)`.** У других стейкеров есть прямой
  экономический стимул это делать (снижение чужого веса поднимает их собственную долю), но
  в первые недели, пока стейкеров мало, звать `poke` придётся самому — иначе завышенный вес
  истёкшей позиции размывает остальных. Найти кандидатов можно по событиям `Staked`:
  ```powershell
  cast call $EMISSION "isPokeable(address)(bool)" <адрес> --rpc-url rh
  cast send $EMISSION "poke(address)" <адрес> --rpc-url rh --account maclaurin-deployer
  ```
  `poke` стоит ~86 000 газа, то есть меньше цента, и вызвать её может кто угодно —
  разрешения владельца позиции не требуется, потому что условие проверяется на цепочке.

**Конец эмиссии (~день 175):**

```powershell
cast call $EMISSION "emissionFinished()(bool)" --rpc-url rh   # true
cast call $EMISSION "epochAmount(uint256)(uint256)" 27 --rpc-url rh   # 0
cast call $TOKEN "balanceOf(address)(uint256)" $EMISSION --rpc-url rh # остаток = невыплаченное + 14 wei
```

Те самые **14 wei** остаются в контракте навсегда — остаточный член Лагранжа. Это не
недоработка, а следствие округления каждого члена ряда вниз: сумма всех выплат строго
меньше баланса, и инвариант «нельзя выплатить больше, чем есть» держится арифметически,
без единой проверки в коде.

---

## 11. Если что-то пошло не так

| Ситуация | Что делать |
|---|---|
| `StartTimeInPast` при деплое | `EMISSION_START_DELAY` слишком мал; `Deploy.s.sol` держит минимум 300 с — увеличить до 86400 |
| Транзакция висит | проверить `cast tx <hash> --rpc-url rh`; при необходимости переслать с большим `--gas-price`. Средний блок мейннета — ~101 с, так что несколько минут ожидания это норма, а не залипание |
| Верификация не проходит | §5.6 |
| Пул создан с неверной ценой | пока в пуле нет ликвидности — цену можно поправить свопом на копейки; **после `AddLiquidity` — уже нет**, поэтому §8.3 считается до §8.5 |
| Заминтил позицию с неверным диапазоном | пока NFT **не сожжён** — `decreaseLiquidity` + `collect` + новый `mint`. После сжигания — ничего |
| Отправил не туда genesis | `GENESIS_RECIPIENT` immutable; передеплой — единственный вариант, и это ещё $0.02 |

**Ошибки, специфичные для стейкинга** (селекторы и расшифровка — §7.0):

| Ошибка | Почему возникает | Что делать |
|---|---|---|
| `StillLocked(unlockTime)` при `claim()` | лок ещё не истёк | это **правильное** поведение; ждать до `unlockTime` или выходить через `exit()`, теряя награду |
| `StillLocked` при `poke()` | позиция ещё в локе | ждать; `isPokeable()` подскажет, когда можно |
| `NothingToClaim()` | награда нулевая | `earned()` == 0: либо ещё не наступил `startTime`, либо награда уже сгорела при досрочном выходе |
| `RadiusCannotDecrease(cur, req)` | дозаход с меньшим радиусом | либо использовать радиус ≥ текущего, либо полностью выйти и застейкать заново, либо взять другой адрес |
| `InvalidRadius(r)` | радиус вне 1..7 | `MAX_RADIUS = 7`, ноль недопустим |
| `AlreadyAtBaseline()` | `poke()` по позиции с R=1 | ничего делать не надо, вес уже 1.0x |
| `NoPosition()` | `poke()` по адресу без стейка | опечатка в адресе |
| `NothingToSweep()` | `unallocated == 0` | нечего отправлять; `pendingUnallocated()` покажет, сколько накопится |
| `InsufficientStake(req, avail)` | `unstake` больше, чем в позиции | сверить со `stakedOf()` |
| Транзакция ушла и зареверила без внятной ошибки | вероятно, неверная сигнатура в кавычках | сверить с §7.1 и `forge inspect ... methodIdentifiers`; неизвестный селектор реверта не объясняет |
| `cast send` вернул `status 0` | транзакция прошла оценку газа, но упала при исполнении | перепроверить через `cast call` в текущем состоянии и повторить; состояние могло измениться между оценкой и включением в блок |

> **Единственная действительно необратимая точка — сжигание LP-позиции (§8.6).** Всё, что
> до неё, при бюджете в центах на транзакцию чинится передеплоем. Всё, что после, — не
> чинится ничем.

---

## Приложение: сводка переменных окружения

| Переменная | Кто использует | Пример |
|---|---|---|
| `GENESIS_RECIPIENT` | `Deploy.s.sol` | `0x…` |
| `REMAINDER_VAULT` | `Deploy.s.sol` | `0x…` |
| `EMISSION_START_DELAY` | `Deploy.s.sol` | `300` в тестнете, `86400` в мейннете |
| `UNISWAP_WETH` | `Pool.s.sol` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` (**не** `0x4200…0006`) |
| `RH_RPC_URL` / `RH_TESTNET_RPC_URL` | `foundry.toml` | `https://rpc.mainnet.chain.robinhood.com` |
| `MACLAURIN_TOKEN` | `Pool.s.sol` | адрес токена |
| `MACLAURIN_AMOUNT` | `Pool.s.sol` | `200000000000000000000000000` |
| `ETH_AMOUNT` | `Pool.s.sol` | `7000000000000000` |
| `POOL_FEE` | `Pool.s.sol` | `10000` |
| `TICK_LOWER` / `TICK_UPPER` | `Pool.s.sol` | по умолчанию full range |
| `LP_MIN_BPS` | `Pool.s.sol` | `0` (защита от сдвига цены между шагами) |
| `LP_TOKEN_ID` | `Pool.s.sol` | id LP-позиции |
| `BURN_CONFIRM` | `Pool.s.sol` | `BURN` — только для сжигания |
| `LP_EXPECT_FULL_RANGE` | `Pool.s.sol` | `true` |
| `UNISWAP_NPM` / `UNISWAP_FACTORY` | `Pool.s.sol` | переопределение адресов; по умолчанию берутся по `chainid` |
