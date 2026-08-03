// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MaclaurinVesting} from "../src/MaclaurinVesting.sol";

/**
 * @dev Минимальный интерфейс держателя токена. Нужен, чтобы спросить у кривой,
 *      какой актив она обслуживает, не импортируя `MaclaurinCurve`: файл кривой
 *      пишется параллельно, и жёсткая зависимость означала бы, что этот скрипт
 *      перестаёт компилироваться каждый раз, когда там идёт правка. У геттера
 *      `token()` ABI один и тот же независимо от того, объявлен он как `IERC20`
 *      или как `address`, поэтому проверка от этого не слабеет.
 */
interface ITokenHolder {
    function token() external view returns (address);
}

/**
 * @title  Distribute
 * @notice Раскладка GENESIS (2 000 000 000 MACLRN) по адресам из §7 спеки —
 *         одной транзакцией, с проверками до и после.
 *
 * @dev    ЗАЧЕМ ЭТО СКРИПТ, А НЕ ШЕСТЬ ПЕРЕВОДОВ РУКАМИ. Пока весь genesis
 *         висит на одном кошельке, скриншот списка холдеров перечёркивает и
 *         отсутствие `mint`, и оба аудита: снаружи это выглядит ровно как
 *         преминт под рагпул. Шесть ручных переводов растянуты во времени и
 *         оставляют промежуточные состояния, в которых картина ещё хуже, а
 *         одна опечатка в адресе стоит доли безвозвратно.
 *
 *         ЧТО ЗДЕСЬ ЗАЩИЩАЕТ. Проверки до broadcast — это то, что реально
 *         спасает: `forge script` сначала прогоняет `run()` в симуляции и
 *         отправляет транзакции только если она прошла целиком. Упавший
 *         require — на входе или на выходе — означает, что не будет отправлено
 *         НИЧЕГО. Поэтому и предусловия, и постусловия имеют смысл, хотя
 *         исполняются они в симуляции.
 *
 *         Для проверки уже случившейся раскладки на живой цепочке есть
 *         отдельная `verify()`:
 *
 *           forge script script/Distribute.s.sol --sig "verify()" --rpc-url rh
 *
 *         ПРО ПРОВЕРКУ ПОЛУЧАТЕЛЕЙ-КОНТРАКТОВ. Казна и инвентарь — не просто
 *         адреса, а контракты с известным поведением, и скрипт раздачи — это
 *         последний момент, когда ошибку в них можно поймать. После перевода
 *         чинить нечего: и вестинг, и кривая неизменяемы. Поэтому у вестинга
 *         сверяются токен, бенефициар и дата разблокировки (_checkVesting),
 *         а у кривой — что она обслуживает тот же токен (_checkCurve).
 *
 *         ПРО MaclaurinCurve. Адрес инвентаря принимается как обычный адрес, тип
 *         контракта не импортируется — только минимальный интерфейс `token()`
 *         выше: скрипт не должен переставать компилироваться из-за правок в
 *         файле кривой, который пишется параллельно.
 */
contract Distribute is Script {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                  ДОЛИ
    //////////////////////////////////////////////////////////////*/

    /// @notice Первые два члена ряда, 1/0! + 1/1! = 2. Раскладывается целиком.
    uint256 public constant GENESIS = 2_000_000_000e18;

    /// @notice 1/2 — инвентарь бондинг-кривой, продаётся людям за ETH.
    uint256 public constant CURVE_SHARE = 1_000_000_000e18;

    /// @notice 1/4 — казна под вестингом, MaclaurinVesting.
    uint256 public constant VESTING_SHARE = 500_000_000e18;

    /// @notice 1/8 — сжигается безвозвратно.
    uint256 public constant BURN_SHARE = 250_000_000e18;

    /// @notice 1/16 — маркетинг и эйрдропы.
    uint256 public constant MARKETING_SHARE = 125_000_000e18;

    /// @notice 1/32 — резерв.
    uint256 public constant RESERVE_SHARE = 62_500_000e18;

    /// @notice Хвост геометрического ряда. Равен последнему выписанному члену —
    ///         это свойство ряда с шагом 1/2, а не подгонка под остаток.
    uint256 public constant REMAINDER_SHARE = 62_500_000e18;

    /**
     * @notice Адрес сжигания. Константа, а не переменная окружения, и это
     *         принципиально: подменяемый «адрес сжигания» в .env — известный
     *         способ оставить себе 9.2% сапплая, сохранив красивую строчку в
     *         документации. Здесь его нельзя настроить, только прочитать.
     *
     * @dev    Именно 0x…dEaD, а не address(0): OZ ERC20 v5 запрещает перевод
     *         на нулевой адрес (ERC20InvalidReceiver), а публичной `burn`
     *         у токена нет — сжигание возможно только отправкой в чёрную дыру.
     */
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /*//////////////////////////////////////////////////////////////
                              ПОЛУЧАТЕЛИ
    //////////////////////////////////////////////////////////////*/

    /// @dev Адрес сжигания в структуру не входит — он константа.
    struct Recipients {
        address curve;
        address vesting;
        address marketing;
        address reserve;
        address remainder;
    }

    /*//////////////////////////////////////////////////////////////
                                  ЗАПУСК
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Читает адреса из окружения и раскладывает genesis.
     *
     * @dev Отправитель — GENESIS_RECIPIENT из .env, тот же адрес, что получил
     *      genesis в Deploy.s.sol. `startBroadcast(sender)` с явным адресом,
     *      а не безымянный `startBroadcast()`: если подписывающий кошелёк
     *      окажется не тем, foundry скажет об этом до отправки, а не разложит
     *      пустой баланс постороннего адреса.
     */
    function run() external {
        IERC20 token = IERC20(vm.envAddress("MACLAURIN_TOKEN"));
        address sender = vm.envAddress("GENESIS_RECIPIENT");
        distribute(token, sender, _envRecipients(), _envExpectedUnlockTime());
    }

    /**
     * @notice Та же раскладка, но с явными аргументами — без чтения окружения.
     *
     * @param expectedUnlockTime  Ожидаемая дата разблокировки казны. Ноль —
     *                            «не сверять», см. _checkVesting.
     *
     * @dev Публичная и параметризованная, чтобы тесты проверяли ровно тот код,
     *      который поедет в сеть, а не его копию. Окружение читают только
     *      `run()` и `verify()`: переменные окружения у процесса общие, и
     *      параллельные тесты дрались бы за них.
     */
    function distribute(IERC20 token, address sender, Recipients memory to, uint256 expectedUnlockTime)
        public
    {
        _checkShares();
        _checkRecipients(sender, to);
        _checkVesting(token, to.vesting, expectedUnlockTime);
        _checkCurve(token, to.curve);

        // Предусловие: на отправителе лежит РОВНО genesis и ничего сверх.
        // Больше — значит адрес используется ещё для чего-то, и проверка
        // «после раздачи ноль» стала бы ложной; меньше — раскладка уже
        // частично произошла или кошелёк не тот.
        uint256 balance = token.balanceOf(sender);
        require(balance == GENESIS, "sender balance != GENESIS");

        console2.log("chain id:  ", block.chainid);
        console2.log("token:     ", address(token));
        console2.log("sender:    ", sender);

        vm.startBroadcast(sender);
        token.safeTransfer(to.curve, CURVE_SHARE);
        token.safeTransfer(to.vesting, VESTING_SHARE);
        token.safeTransfer(BURN_ADDRESS, BURN_SHARE);
        token.safeTransfer(to.marketing, MARKETING_SHARE);
        token.safeTransfer(to.reserve, RESERVE_SHARE);
        token.safeTransfer(to.remainder, REMAINDER_SHARE);
        vm.stopBroadcast();

        _verify(token, sender, to);
    }

    /**
     * @notice Проверка уже выполненной раскладки на живой цепочке.
     * @dev Ничего не отправляет. Запускается отдельно, после broadcast:
     *      `forge script script/Distribute.s.sol --sig "verify()" --rpc-url rh`.
     */
    function verify() external view {
        IERC20 token = IERC20(vm.envAddress("MACLAURIN_TOKEN"));
        address sender = vm.envAddress("GENESIS_RECIPIENT");
        Recipients memory to = _envRecipients();

        _verify(token, sender, to);
        // Связь «кривая обслуживает тот же токен» не зависит от времени и
        // проверяется здесь тоже. _checkVesting сюда не входит намеренно: он
        // требует, чтобы разблокировка была впереди, и после её наступления
        // честно ревертил бы на корректно выполненной раскладке.
        _checkCurve(token, to.curve);
    }

    /*//////////////////////////////////////////////////////////////
                                ПРОВЕРКИ
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Сумма долей обязана быть ровно 2e27 — проверяется арифметикой,
     *      а не глазами. Если кто-то поправит одну константу и забудет
     *      остальные, скрипт не доедет до первого перевода.
     */
    function _checkShares() internal pure {
        uint256 sum =
            CURVE_SHARE + VESTING_SHARE + BURN_SHARE + MARKETING_SHARE + RESERVE_SHARE + REMAINDER_SHARE;
        require(sum == GENESIS, "shares != GENESIS");
        // Та же величина в другой записи: если кто-то ошибётся в разрядах
        // при правке долей, две независимые формы записи разойдутся.
        require(GENESIS == 2e27, "GENESIS != 2e27");
    }

    /**
     * @dev Что проверяется и от чего это спасает:
     *
     *      1. Ненулевые адреса. Незаполненная строка в .env превращается в
     *         address(0); OZ ERC20 такой перевод отбил бы, но упасть лучше
     *         до того, как половина долей уже разъехалась.
     *      2. Попарная различность. Одинаковые адреса у двух долей — обычная
     *         опечатка копипастой; постусловия её поймают, но с невнятной
     *         диагностикой, а здесь она названа явно. Отправитель и адрес
     *         сжигания включены в тот же список: доля, ушедшая обратно
     *         отправителю, сломала бы условие «на отправителе ноль».
     *      3. Наличие кода у кривой и казны. Инвентарь и вестинг — контракты;
     *         адрес EOA на их месте означает опечатку, а 1.5 миллиарда
     *         токенов на чужом кошельке не отзываются. У маркетинга, резерва
     *         и остаточного члена кода может не быть — это обычные кошельки.
     */
    function _checkRecipients(address sender, Recipients memory to) internal view {
        address[7] memory all =
            [sender, to.curve, to.vesting, BURN_ADDRESS, to.marketing, to.reserve, to.remainder];

        for (uint256 i = 0; i < all.length; ++i) {
            require(all[i] != address(0), "zero address among recipients");
            for (uint256 j = i + 1; j < all.length; ++j) {
                require(all[i] != all[j], "duplicate address among recipients");
            }
        }

        require(to.curve.code.length > 0, "curve is not a contract");
        require(to.vesting.code.length > 0, "vesting is not a contract");
    }

    /**
     * @notice Казна — это действительно казна $MACLRN, и замок стоит на
     *         ожидаемую дату.
     *
     * @dev Здесь последний момент, когда ошибку в вестинге ещё можно поймать:
     *      после перевода 500 миллионов токенов чинить нечего, контракт
     *      неизменяем, а функции досрочного вывода в нём нет по замыслу.
     *
     *      Что ловится:
     *
     *      1. Другой токен. Вестинг развёрнут на посторонний ERC-20 — тогда
     *         присланный сюда $MACLRN не выдаст никогда никакая функция:
     *         `release()` переведёт баланс ТОГО токена, то есть пустоту, а
     *         наши 500 миллионов останутся в контракте навсегда.
     *      2. Нулевой бенефициар. Сам MaclaurinVesting такое не развернёт, но
     *         адрес мог указывать на другой, менее осторожный контракт с той
     *         же сигнатурой — проверка стоит один staticcall.
     *      3. Разблокировка не в будущем. Уже открытая казна — это не казна,
     *         а кошелёк: 18.4% сапплая можно забрать в том же блоке.
     *      4. Расхождение с EXPECTED_UNLOCK_TIME, если переменная задана.
     *         Пункт 3 ловит только грубую ошибку; дату, промахнувшуюся на
     *         год, не ловит ничто, кроме сверки с заранее посчитанным
     *         значением. Переменная не задана — сверка пропускается, но
     *         фактическая дата печатается, чтобы человек увидел её глазами
     *         до отправки.
     */
    function _checkVesting(IERC20 token, address vesting, uint256 expectedUnlockTime) internal view {
        MaclaurinVesting v = MaclaurinVesting(vesting);

        require(address(v.token()) == address(token), "vesting holds a different token");
        require(v.beneficiary() != address(0), "vesting beneficiary is zero");

        uint256 unlock = v.unlockTime();
        require(unlock > block.timestamp, "vesting is already unlocked");

        console2.log("vesting beneficiary:", v.beneficiary());
        console2.log("vesting unlockTime: ", unlock);

        if (expectedUnlockTime == 0) {
            console2.log("EXPECTED_UNLOCK_TIME is not set: date above is NOT pinned, check it by hand");
        } else {
            require(unlock == expectedUnlockTime, "vesting unlockTime != EXPECTED_UNLOCK_TIME");
            console2.log("unlockTime matches EXPECTED_UNLOCK_TIME");
        }
    }

    /**
     * @notice Кривая обслуживает тот же токен, что раздаётся.
     *
     * @dev Тип `MaclaurinCurve` не импортируется — только геттер `token()` через
     *      минимальный интерфейс (см. ITokenHolder над контрактом). Отсутствие
     *      геттера считается ошибкой, а не поводом пропустить проверку: у
     *      настоящей кривой он есть, и его отсутствие само по себе означает,
     *      что по адресу лежит не кривая.
     *
     *      Ловится ровно то же, что и у казны: инвентарь, отправленный кривой
     *      от другого токена, продаваться не будет никогда — она отдаёт
     *      покупателю свой актив, а миллиард $MACLRN останется в ней навсегда.
     */
    function _checkCurve(IERC20 token, address curve) internal view {
        try ITokenHolder(curve).token() returns (address curveToken) {
            require(curveToken == address(token), "curve holds a different token");
        } catch {
            revert("curve does not expose token()");
        }
    }

    /**
     * @dev Постусловия. Считаем не «примерно столько», а точные равенства:
     *      каждый получатель имеет ровно свою долю, а отправитель — ноль.
     *      Ноль на отправителе и есть главный итог раскладки: на личном
     *      адресе создателя не остаётся ничего (§7).
     */
    function _verify(IERC20 token, address sender, Recipients memory to) internal view {
        require(token.balanceOf(to.curve) == CURVE_SHARE, "curve share mismatch");
        require(token.balanceOf(to.vesting) == VESTING_SHARE, "vesting share mismatch");
        require(token.balanceOf(BURN_ADDRESS) == BURN_SHARE, "burn share mismatch");
        require(token.balanceOf(to.marketing) == MARKETING_SHARE, "marketing share mismatch");
        require(token.balanceOf(to.reserve) == RESERVE_SHARE, "reserve share mismatch");
        require(token.balanceOf(to.remainder) == REMAINDER_SHARE, "remainder share mismatch");
        require(token.balanceOf(sender) == 0, "sender not drained");

        console2.log("");
        console2.log("curve     ", to.curve, CURVE_SHARE / 1e18);
        console2.log("vesting   ", to.vesting, VESTING_SHARE / 1e18);
        console2.log("burned    ", BURN_ADDRESS, BURN_SHARE / 1e18);
        console2.log("marketing ", to.marketing, MARKETING_SHARE / 1e18);
        console2.log("reserve   ", to.reserve, RESERVE_SHARE / 1e18);
        console2.log("remainder ", to.remainder, REMAINDER_SHARE / 1e18);
        console2.log("");
        console2.log("sender balance is zero, all post-checks hold");
    }

    /*//////////////////////////////////////////////////////////////
                               ОКРУЖЕНИЕ
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev REMAINDER_VAULT здесь — НАМЕРЕННО тот же самый адрес, что получает
     *      остаточный член в Deploy.s.sol и MaclaurinEmission. Это не экономия на
     *      переменной, а совпадение по смыслу: в эмиссию туда уходят награда
     *      эпох, в которые никто не стейкал, и награда, сгоревшая при досрочном
     *      выходе из лока; здесь туда уходит хвост геометрического ряда. И то,
     *      и другое — остаточный член, то, что не досталось никому по правилам.
     *      Одна казна на оба источника проще и честнее, чем два адреса с
     *      похожими названиями, которые пришлось бы различать в объяснениях.
     */
    function _envRecipients() internal view returns (Recipients memory) {
        return Recipients({
            curve: vm.envAddress("MACLAURIN_CURVE"),
            vesting: vm.envAddress("MACLAURIN_VESTING"),
            marketing: vm.envAddress("MARKETING_WALLET"),
            reserve: vm.envAddress("RESERVE_WALLET"),
            remainder: vm.envAddress("REMAINDER_VAULT")
        });
    }

    /// @dev Ноль означает «переменная не задана, дату не сверять». Настоящий
    ///      unlockTime нулём быть не может: MaclaurinVesting ревертит на дате,
    ///      которая не в будущем, — поэтому ноль здесь однозначен.
    function _envExpectedUnlockTime() internal view returns (uint256) {
        return vm.envOr("EXPECTED_UNLOCK_TIME", uint256(0));
    }
}
