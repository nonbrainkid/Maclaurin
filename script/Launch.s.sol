// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MaclaurinCurve} from "../src/MaclaurinCurve.sol";
import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinVesting} from "../src/MaclaurinVesting.sol";
import {Distribute} from "./Distribute.s.sol";

/**
 * @title  Launch
 * @notice Запуск фазы 4 ОДНИМ прогоном: развернуть казну, развернуть кривую,
 *         разложить genesis по таблице §7 и проверить результат на цепочке.
 *
 * @dev    ЗАЧЕМ ОДИН ПРОГОН, А НЕ ТРИ КОМАНДЫ ПОДРЯД. Это не удобство, а
 *         единственный способ, которым смягчение §4.5 вообще работает.
 *
 *         Окно анти-снайпа кривой стартует в её КОНСТРУКТОРЕ:
 *         `startTime = block.timestamp` (src/MaclaurinCurve.sol). Продавать
 *         кривой при этом нечего — инвентарь приходит обычным `transfer` из
 *         genesis, то есть ОТДЕЛЬНОЙ транзакцией. Значит окно тикает с момента
 *         развёртывания, а торги начинаются с момента прихода миллиарда
 *         токенов, и всё, что между этими двумя точками, вычитается из защиты.
 *         Если человек развернул кривую вечером, а раскладку запустил утром,
 *         ANTI_SNIPE_WINDOW истечёт до первой сделки и лимит в 1% инвентаря на
 *         адрес не сработает ни разу: первый же бот выкупит существенную долю
 *         по минимальной цене. Чинить будет нечего — контракт неизменяем.
 *
 *         Здесь оба шага идут внутри одного `forge script`, без пауз и без
 *         ручного копирования адресов между командами. Пост-проверка
 *         `_verify` явно требует, чтобы к концу прогона окно ещё было открыто
 *         (см. «РАДИ ЧЕГО ВСЁ ЗАТЕВАЛОСЬ» ниже), и падает, если нет.
 *
 *         ЧТО ЭТОТ СКРИПТ НЕ ДЕЛАЕТ. Он не разворачивает ни токен, ни
 *         `MaclaurinEmission` — их разворачивает `Deploy.s.sol`, и раньше.
 *         Причина в том, что эмиссия должна стартовать до продаж, а её
 *         тайминг с окном анти-снайпа никак не связан: у неё нет ничего, что
 *         протухало бы за час. Адреса приходят сюда через окружение
 *         (`MACLAURIN_TOKEN`, необязательный `MACLAURIN_EMISSION`).
 *
 *         ЛОГИКА РАЗДАЧИ НЕ ДУБЛИРУЕТСЯ. Все шесть переводов, предусловия и
 *         постусловия §7 живут в `Distribute.s.sol` и вызываются отсюда как
 *         есть — через публичную `distribute(token, sender, to, expected)`.
 *         Копия таблицы долей в двух файлах означала бы, что однажды они
 *         разойдутся, и разойдутся молча. Здесь долям Distribute верят, но
 *         сверяют их с независимо записанными литералами (`_checkConfig`) —
 *         тот же приём двойной записи, что и в самом Distribute.
 *
 *         КТО ПОДПИСЫВАЕТ. Весь прогон идёт от ОДНОГО адреса — того самого
 *         `GENESIS_RECIPIENT`, на котором лежат 2 000 000 000 MACLRN. Он же
 *         разворачивает казну и кривую. Двух подписантов в одном `forge
 *         script` пришлось бы заводить флагами, а любая ошибка в них означает
 *         половину выполненного запуска: контракты развёрнуты, инвентарь не
 *         пришёл, окно тикает. Один ключ на один прогон — меньше поводов
 *         остановиться на середине. Практическое следствие: на
 *         `GENESIS_RECIPIENT` должен быть газ.
 *
 *         ПОЧЕМУ ПРОВЕРКИ ДО BROADCAST ИМЕЮТ СМЫСЛ. `forge script` сначала
 *         прогоняет `run()` в симуляции целиком и отправляет транзакции
 *         только если она прошла до конца. Упавший `require` — хоть на входе,
 *         хоть в самом конце — означает, что не будет отправлено НИЧЕГО.
 *         Порядок проверок здесь всё равно выстроен «сначала дешёвое и
 *         очевидное»: сообщение об ошибке должно называть причину, а не
 *         последствие.
 */
contract Launch is Script {
    /*//////////////////////////////////////////////////////////////
                            ОЖИДАЕМЫЕ ИТОГИ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Сколько токенов обязано лежать в кривой после запуска.
     *         1/2 genesis, §7.
     *
     * @dev Записано здесь ещё раз, хотя ровно то же число есть в
     *      `Distribute.CURVE_SHARE` и в `MaclaurinCurve.INVENTORY`. Это не
     *      копипаста, а сверка трёх независимых источников: доля из скрипта
     *      раздачи, константа из контракта кривой и литерал спеки. Кривая
     *      считает свой инвентарь равным `INVENTORY` и на этом строит все
     *      расчёты цены; если фактический баланс окажется меньше, последние
     *      покупки отревертят на переводе токена, а если больше — разница
     *      застрянет в контракте навсегда, потому что функции спасения
     *      токенов в нём нет по замыслу.
     */
    uint256 public constant CURVE_INVENTORY = 1_000_000_000e18;

    /// @notice Сколько токенов обязано лежать в казне после запуска. 1/4, §7.
    uint256 public constant VESTING_TREASURY = 500_000_000e18;

    /*//////////////////////////////////////////////////////////////
                              КОНФИГУРАЦИЯ
    //////////////////////////////////////////////////////////////*/

    /**
     * @param token               Уже развёрнутый $MACLRN (`MACLAURIN_TOKEN`).
     * @param sender              `GENESIS_RECIPIENT`: держит genesis, подписывает прогон.
     * @param beneficiary         `VESTING_BENEFICIARY`: кому откроется казна.
     * @param unlockTime          `VESTING_UNLOCK_TIME`: когда откроется, unix-время.
     * @param feeRecipient        `FEE_RECIPIENT`: кому идёт 1% комиссии кривой.
     * @param marketing           `MARKETING_WALLET`, доля 1/16.
     * @param reserve             `RESERVE_WALLET`, доля 1/32.
     * @param remainder           `REMAINDER_VAULT`, хвост ряда.
     * @param expectedUnlockTime  `EXPECTED_UNLOCK_TIME`, 0 — «не сверять».
     * @param emission            `MACLAURIN_EMISSION`, address(0) — «не сверять».
     */
    struct Config {
        IERC20 token;
        address sender;
        address beneficiary;
        uint256 unlockTime;
        address feeRecipient;
        address marketing;
        address reserve;
        address remainder;
        uint256 expectedUnlockTime;
        address emission;
    }

    /*//////////////////////////////////////////////////////////////
                                  ЗАПУСК
    //////////////////////////////////////////////////////////////*/

    /// @notice Читает окружение и выполняет запуск.
    function run() external returns (MaclaurinCurve curve, MaclaurinVesting vesting) {
        return launch(_envConfig());
    }

    /**
     * @notice Тот же запуск, но с явной конфигурацией — без чтения окружения.
     *
     * @dev Публичная и параметризованная по той же причине, что и
     *      `Distribute.distribute`: тесты обязаны проверять ровно тот код,
     *      который поедет в сеть, а не его копию. Окружение читает только
     *      `run()` — переменные окружения у процесса общие, и параллельные
     *      тесты дрались бы за них.
     */
    function launch(Config memory cfg) public returns (MaclaurinCurve curve, MaclaurinVesting vesting) {
        // Раздача — чужой код, вызываемый как есть. Экземпляр создаётся ДО
        // broadcast, поэтому в сеть он не уезжает: `forge script` отправляет
        // только то, что попало между start/stopBroadcast.
        Distribute distributor = new Distribute();

        _checkConfig(cfg, distributor);

        console2.log("chain id:           ", block.chainid);
        console2.log("token:              ", address(cfg.token));
        console2.log("sender (genesis):   ", cfg.sender);
        console2.log("vesting beneficiary:", cfg.beneficiary);
        console2.log("vesting unlockTime: ", cfg.unlockTime);
        console2.log("curve fee recipient:", cfg.feeRecipient);
        console2.log("");

        // Казна первой, кривая второй — порядок §9 спеки. Между ними нет
        // ничего, что могло бы затянуться: обе транзакции уходят подряд.
        vm.startBroadcast(cfg.sender);
        vesting = new MaclaurinVesting(cfg.token, cfg.beneficiary, cfg.unlockTime);
        curve = new MaclaurinCurve(cfg.token, cfg.feeRecipient);
        vm.stopBroadcast();

        console2.log("MaclaurinVesting:   ", address(vesting));
        console2.log("MaclaurinCurve:     ", address(curve));
        console2.log("anti-snipe ends at: ", curve.antiSnipeEnd());
        console2.log("");

        // Раскладка genesis: шесть переводов и все проверки §7 — из
        // Distribute.s.sol, ни одной строки логики здесь не повторяется.
        distributor.distribute(
            cfg.token,
            cfg.sender,
            Distribute.Recipients({
                curve: address(curve),
                vesting: address(vesting),
                marketing: cfg.marketing,
                reserve: cfg.reserve,
                remainder: cfg.remainder
            }),
            cfg.expectedUnlockTime
        );

        _verify(cfg, curve, vesting);
    }

    /*//////////////////////////////////////////////////////////////
                          ПРОВЕРКИ ДО РАЗВЁРТЫВАНИЯ
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Всё, что можно узнать до первой транзакции. Каждая проверка названа
     *      именем переменной окружения: человек, читающий упавший прогон,
     *      должен понять, какую строку в `.env` чинить, не открывая код.
     */
    function _checkConfig(Config memory cfg, Distribute distributor) internal view {
        require(address(cfg.token) != address(0), "MACLAURIN_TOKEN is zero");
        require(address(cfg.token).code.length > 0, "MACLAURIN_TOKEN is not a contract");
        require(cfg.sender != address(0), "GENESIS_RECIPIENT is zero");
        require(cfg.beneficiary != address(0), "VESTING_BENEFICIARY is zero");
        require(cfg.feeRecipient != address(0), "FEE_RECIPIENT is zero");
        require(cfg.marketing != address(0), "MARKETING_WALLET is zero");
        require(cfg.reserve != address(0), "RESERVE_WALLET is zero");
        require(cfg.remainder != address(0), "REMAINDER_VAULT is zero");

        // Доли: литерал спеки против константы Distribute. Разойтись они могут
        // только правкой, и тогда прогон встанет здесь, а не на середине.
        require(CURVE_INVENTORY == 1e27, "CURVE_INVENTORY != 1e27");
        require(VESTING_TREASURY == 5e26, "VESTING_TREASURY != 5e26");
        require(distributor.CURVE_SHARE() == CURVE_INVENTORY, "curve share != CURVE_INVENTORY");
        require(distributor.VESTING_SHARE() == VESTING_TREASURY, "vesting share != VESTING_TREASURY");
        // Третий источник — константа самой кривой, `INVENTORY`. Сверяется не
        // здесь, а в `_verify`: до развёртывания геттера ещё нет, а читать
        // константу через тип контракта Solidity не даёт.

        // Конструктор казны отревертил бы `UnlockTimeInPast`, но голый селектор
        // custom error в выводе скрипта не объясняет, какую строку править.
        require(cfg.unlockTime > block.timestamp, "VESTING_UNLOCK_TIME is not in the future");

        if (cfg.expectedUnlockTime == 0) {
            console2.log("EXPECTED_UNLOCK_TIME is not set: unlock date is NOT pinned, check it by hand");
        } else {
            require(cfg.unlockTime == cfg.expectedUnlockTime, "VESTING_UNLOCK_TIME != EXPECTED_UNLOCK_TIME");
        }

        _checkEmission(cfg);

        // Предусловие раздачи, поднятое сюда: упасть лучше до того, как
        // развёрнуты два неизменяемых контракта. Distribute проверит то же
        // самое ещё раз — здесь оно стоит ради внятного сообщения.
        require(
            cfg.token.balanceOf(cfg.sender) == distributor.GENESIS(), "sender does not hold exactly GENESIS"
        );
    }

    /**
     * @notice Сверка даты разблокировки с уже развёрнутой эмиссией.
     *
     * @dev По §6 казна открывается ровно в конце эмиссии — `startTime + 175
     *      дней`, то есть `emissionEnd()`. Это единственный источник даты,
     *      который нельзя набрать с опечаткой: он читается с цепочки, а не из
     *      `.env`. Поэтому если `MACLAURIN_EMISSION` задан, дата обязана
     *      совпасть с ним точно.
     *
     *      Переменная необязательная: скрипт должен оставаться запускаемым и
     *      тогда, когда эмиссии в этой сети нет вовсе (например, репетиция на
     *      чистом anvil). Не задана — сверка пропускается, но об этом
     *      печатается строка, чтобы отсутствие проверки было видно, а не
     *      подразумевалось.
     */
    function _checkEmission(Config memory cfg) internal view {
        if (cfg.emission == address(0)) {
            console2.log("MACLAURIN_EMISSION is not set: unlock date is not cross-checked on-chain");
            return;
        }

        require(cfg.emission.code.length > 0, "MACLAURIN_EMISSION is not a contract");

        MaclaurinEmission e = MaclaurinEmission(cfg.emission);
        require(address(e.token()) == address(cfg.token), "emission holds a different token");
        require(cfg.unlockTime == e.emissionEnd(), "VESTING_UNLOCK_TIME != emission.emissionEnd()");

        console2.log("emission:           ", cfg.emission);
        console2.log("emission ends at:   ", e.emissionEnd());
    }

    /*//////////////////////////////////////////////////////////////
                           ПРОВЕРКИ ПОСЛЕ ЗАПУСКА
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Постусловия сверх тех, что уже отработали в `Distribute._verify`
     *      (каждая доля на месте, на отправителе ноль). Здесь проверяется то,
     *      что относится к двум только что развёрнутым контрактам, — и то,
     *      ради чего весь скрипт существует.
     */
    function _verify(Config memory cfg, MaclaurinCurve curve, MaclaurinVesting vesting) internal view {
        uint256 curveBalance = cfg.token.balanceOf(address(curve));
        require(curveBalance == CURVE_INVENTORY, "curve inventory != 1e27");
        require(curveBalance == curve.INVENTORY(), "curve inventory != curve.INVENTORY()");
        require(cfg.token.balanceOf(address(vesting)) == VESTING_TREASURY, "vesting treasury != 5e26");

        // Оба контракта обслуживают ТОТ ЖЕ токен. Инвентарь, отправленный
        // кривой от чужого актива, не продастся никогда; казна, развёрнутая на
        // чужой актив, не откроется никогда — `release()` переведёт пустоту.
        require(address(curve.token()) == address(cfg.token), "curve serves a different token");
        require(address(vesting.token()) == address(cfg.token), "vesting serves a different token");

        require(vesting.beneficiary() == cfg.beneficiary, "vesting beneficiary mismatch");
        require(curve.feeRecipient() == cfg.feeRecipient, "curve feeRecipient mismatch");

        uint256 unlock = vesting.unlockTime();
        require(unlock > block.timestamp, "vesting is already unlocked");
        if (cfg.expectedUnlockTime != 0) {
            require(unlock == cfg.expectedUnlockTime, "unlockTime != EXPECTED_UNLOCK_TIME");
        }

        // Кривая обязана быть девственно чистой: до этой секунды продавать ей
        // было нечего, и любое ненулевое состояние означает, что по адресу
        // стоит не та кривая, которую только что развернули.
        require(curve.sold() == 0, "curve has already sold something");
        require(curve.reserve() == 0, "curve reserve is not empty");
        require(curve.feesAccrued() == 0, "curve fees are not empty");

        // РАДИ ЧЕГО ВСЁ ЗАТЕВАЛОСЬ. Инвентарь пришёл, пока окно анти-снайпа
        // ещё открыто, — значит лимит §4.5 будет действовать с первой сделки,
        // а не окажется просроченным к моменту, когда торговать стало чем.
        // Первое условие — прямое: кривая развёрнута этим же прогоном.
        // Второе — то же самое в терминах, которые видит покупатель.
        uint256 elapsed = block.timestamp - curve.startTime();
        require(elapsed < curve.ANTI_SNIPE_WINDOW(), "anti-snipe window closed before inventory arrived");
        require(curve.antiSnipeEnd() > block.timestamp, "anti-snipe window is already over");

        // Дублирует постусловие Distribute намеренно: если бы `_verify` там
        // однажды опустел, ноль на личном адресе создателя — то единственное,
        // что §7 обещает держателю, — проверялся бы здесь.
        require(cfg.token.balanceOf(cfg.sender) == 0, "sender not drained");

        console2.log("");
        console2.log("curve inventory:    ", curveBalance / 1e18);
        console2.log("vesting treasury:   ", cfg.token.balanceOf(address(vesting)) / 1e18);
        console2.log("sender balance:     ", cfg.token.balanceOf(cfg.sender));
        console2.log("curve spot price:   ", curve.spotPrice());
        console2.log("curve total raise:  ", curve.TOTAL_RAISE());
        console2.log("anti-snipe left, s: ", curve.antiSnipeEnd() - block.timestamp);
        console2.log("anti-snipe cap:     ", curve.ANTI_SNIPE_MAX() / 1e18);
        console2.log("");
        console2.log("all post-launch invariants hold");
        console2.log("write these two lines into .env:");
        console2.log("  MACLAURIN_CURVE=  ", address(curve));
        console2.log("  MACLAURIN_VESTING=", address(vesting));
    }

    /*//////////////////////////////////////////////////////////////
                                ОКРУЖЕНИЕ
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev `MACLAURIN_CURVE` и `MACLAURIN_VESTING` здесь НЕ читаются — это
     *      выходы скрипта, а не входы. Их печатает `_verify`, и уже оттуда они
     *      попадают в `.env` для `Distribute.verify()` и для эксплорера.
     *
     *      `REMAINDER_VAULT` — тот же адрес, что в `Deploy.s.sol`: и остаток
     *      эмиссии, и хвост геометрического ряда — это одно и то же по смыслу
     *      (то, что не досталось никому по правилам), и одна казна на оба
     *      источника честнее двух похожих названий.
     */
    function _envConfig() internal view returns (Config memory) {
        return Config({
            token: IERC20(vm.envAddress("MACLAURIN_TOKEN")),
            sender: vm.envAddress("GENESIS_RECIPIENT"),
            beneficiary: vm.envAddress("VESTING_BENEFICIARY"),
            unlockTime: vm.envUint("VESTING_UNLOCK_TIME"),
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            marketing: vm.envAddress("MARKETING_WALLET"),
            reserve: vm.envAddress("RESERVE_WALLET"),
            remainder: vm.envAddress("REMAINDER_VAULT"),
            expectedUnlockTime: vm.envOr("EXPECTED_UNLOCK_TIME", uint256(0)),
            emission: vm.envOr("MACLAURIN_EMISSION", address(0))
        });
    }
}
