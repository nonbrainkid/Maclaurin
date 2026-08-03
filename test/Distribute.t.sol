// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Distribute} from "../script/Distribute.s.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";
import {MaclaurinVesting} from "../src/MaclaurinVesting.sol";

/**
 * @title  DistributeTest
 * @notice Прогон боевого скрипта раскладки genesis целиком, вместе со всеми
 *         его require.
 *
 * @dev Зачем это отдельный тест — та же причина, что у DeployTest: скрипт
 *      исполняется ровно один раз и необратимо, а ошибка в нём стоит доли
 *      безвозвратно. Пока `distribute()` никто не вызывал, его проверки не
 *      исполнялись ни разу, то есть страховка сама была непроверенной.
 *
 *      Тесты вызывают `distribute(...)` напрямую, а не `run()`. Это тот же
 *      самый код — `run()` только читает окружение и передаёт его сюда, — но
 *      не требует писать переменные окружения из каждого теста: окружение у
 *      процесса общее, и параллельные тесты дрались бы за него. Чтение
 *      окружения проверяется отдельно, в test_Run_UsesEnvironmentAddresses.
 */
contract DistributeTest is Test {
    Distribute internal script;
    MaclaurinToken internal token;
    MaclaurinVesting internal vestingContract;

    /// @dev Метки те же, что в DeployTest, и это намеренно: makeAddr
    ///      детерминирован, поэтому GENESIS_RECIPIENT и REMAINDER_VAULT
    ///      в общем окружении процесса получают одно и то же значение,
    ///      кто бы из наборов ни записал их первым.
    address internal sender = makeAddr("genesisRecipient");
    address internal remainder = makeAddr("remainderVault");

    address internal curve;
    address internal marketing = makeAddr("marketingWallet");
    address internal reserve = makeAddr("reserveWallet");
    address internal treasuryBeneficiary = makeAddr("treasuryBeneficiary");

    address internal constant EMISSION = address(0xE41551);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Числа из §7 спеки, продублированные литералами намеренно: тест, который
    // читает долю из проверяемого скрипта, не проверяет ничего.
    uint256 internal constant SPEC_GENESIS = 2000000000000000000000000000;
    uint256 internal constant SPEC_CURVE = 1000000000000000000000000000;
    uint256 internal constant SPEC_VESTING = 500000000000000000000000000;
    uint256 internal constant SPEC_BURN = 250000000000000000000000000;
    uint256 internal constant SPEC_MARKETING = 125000000000000000000000000;
    uint256 internal constant SPEC_RESERVE = 62500000000000000000000000;
    uint256 internal constant SPEC_REMAINDER = 62500000000000000000000000;

    function setUp() public {
        vm.warp(1_700_000_000);

        script = new Distribute();
        token = new MaclaurinToken(sender, EMISSION);
        vestingContract =
            new MaclaurinVesting(IERC20(address(token)), treasuryBeneficiary, block.timestamp + 175 days);

        // Заглушка вместо MaclaurinCurve: контракт кривой пишет параллельная
        // задача, и импортировать её сюда значило бы ломать этот набор при
        // каждой правке того файла. Скрипту от инвентаря нужно ровно одно —
        // контракт, обслуживающий тот же токен, и заглушка это даёт.
        curve = address(new TokenHolderStub(address(token)));

        vm.setEnv("MACLAURIN_TOKEN", vm.toString(address(token)));
        vm.setEnv("GENESIS_RECIPIENT", vm.toString(sender));
        vm.setEnv("MACLAURIN_CURVE", vm.toString(curve));
        vm.setEnv("MACLAURIN_VESTING", vm.toString(address(vestingContract)));
        vm.setEnv("MARKETING_WALLET", vm.toString(marketing));
        vm.setEnv("RESERVE_WALLET", vm.toString(reserve));
        vm.setEnv("REMAINDER_VAULT", vm.toString(remainder));
    }

    /// @dev Ноль вместо EXPECTED_UNLOCK_TIME означает «дату не сверять».
    ///      Сама сверка проверяется отдельно — test_Distribute_UnlockTime*.
    function _distribute(Distribute.Recipients memory to) internal {
        script.distribute(IERC20(address(token)), sender, to, 0);
    }

    function _recipients() internal view returns (Distribute.Recipients memory) {
        return Distribute.Recipients({
            curve: curve,
            vesting: address(vestingContract),
            marketing: marketing,
            reserve: reserve,
            remainder: remainder
        });
    }

    /*//////////////////////////////////////////////////////////////
                         АРИФМЕТИКА ДОЛЕЙ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Сумма долей — ровно 2 000 000 000 токенов, то есть 2e27 wei.
     * @dev Ровно, а не «примерно»: остаток в один wei означал бы, что на
     *      личном адресе создателя после раскладки что-то осталось, а именно
     *      это утверждение §7 и продаёт держателю.
     */
    function test_Shares_SumToExactlyGenesis() public view {
        uint256 sum = script.CURVE_SHARE() + script.VESTING_SHARE() + script.BURN_SHARE()
            + script.MARKETING_SHARE() + script.RESERVE_SHARE() + script.REMAINDER_SHARE();

        assertEq(sum, 2e27, unicode"сумма долей = 2e27 wei");
        assertEq(sum, SPEC_GENESIS);
        assertEq(script.GENESIS(), SPEC_GENESIS);
        assertEq(sum, token.GENESIS(), unicode"совпадает с GENESIS токена");
    }

    /// @notice Каждая доля совпадает с таблицей §7 до последнего wei.
    function test_Shares_MatchSpecTable() public view {
        assertEq(script.CURVE_SHARE(), SPEC_CURVE, unicode"1/2 — инвентарь кривой");
        assertEq(script.VESTING_SHARE(), SPEC_VESTING, unicode"1/4 — казна");
        assertEq(script.BURN_SHARE(), SPEC_BURN, unicode"1/8 — сжечь");
        assertEq(script.MARKETING_SHARE(), SPEC_MARKETING, unicode"1/16 — маркетинг");
        assertEq(script.RESERVE_SHARE(), SPEC_RESERVE, unicode"1/32 — резерв");
        assertEq(script.REMAINDER_SHARE(), SPEC_REMAINDER, unicode"хвост");
    }

    /// @notice Ряд геометрический с шагом 1/2, а хвост равен последнему
    ///         выписанному члену — это свойство ряда, а не подгонка остатка.
    function test_Shares_FormGeometricSeries() public view {
        assertEq(script.CURVE_SHARE(), script.GENESIS() / 2);
        assertEq(script.VESTING_SHARE(), script.CURVE_SHARE() / 2);
        assertEq(script.BURN_SHARE(), script.VESTING_SHARE() / 2);
        assertEq(script.MARKETING_SHARE(), script.BURN_SHARE() / 2);
        assertEq(script.RESERVE_SHARE(), script.MARKETING_SHARE() / 2);
        assertEq(
            script.REMAINDER_SHARE(),
            script.RESERVE_SHARE(),
            unicode"хвост = последний член"
        );
    }

    /// @notice Адрес сжигания — константа скрипта, а не переменная окружения.
    /// @dev Настраиваемый «адрес сжигания» — известный способ оставить себе
    ///      9.2% сапплая, не меняя ни строчки в документации.
    function test_BurnAddress_IsCanonicalDeadAndNotConfigurable() public view {
        assertEq(script.BURN_ADDRESS(), DEAD);
    }

    /*//////////////////////////////////////////////////////////////
                          ОСНОВНОЙ ПРОГОН
    //////////////////////////////////////////////////////////////*/

    function test_Distribute_DeliversEveryShare() public {
        _distribute(_recipients());

        assertEq(token.balanceOf(curve), SPEC_CURVE, unicode"инвентарь кривой");
        assertEq(token.balanceOf(address(vestingContract)), SPEC_VESTING, unicode"казна");
        assertEq(token.balanceOf(DEAD), SPEC_BURN, unicode"сожжено");
        assertEq(token.balanceOf(marketing), SPEC_MARKETING, unicode"маркетинг");
        assertEq(token.balanceOf(reserve), SPEC_RESERVE, unicode"резерв");
        assertEq(token.balanceOf(remainder), SPEC_REMAINDER, unicode"остаточный член");
    }

    /// @notice Главный итог раскладки: на адресе создателя — ноль.
    function test_Distribute_DrainsSenderToZero() public {
        assertEq(token.balanceOf(sender), SPEC_GENESIS, unicode"до раскладки — весь genesis");

        _distribute(_recipients());

        assertEq(token.balanceOf(sender), 0, unicode"после раскладки — ноль");
    }

    /// @notice Ничего не потерялось и ничего не появилось: сумма выданного
    ///         равна genesis, общий сапплай не изменился.
    function test_Distribute_ConservesSupply() public {
        uint256 supplyBefore = token.totalSupply();
        _distribute(_recipients());

        uint256 handedOut = token.balanceOf(curve) + token.balanceOf(address(vestingContract))
            + token.balanceOf(DEAD) + token.balanceOf(marketing) + token.balanceOf(reserve)
            + token.balanceOf(remainder);

        assertEq(handedOut, SPEC_GENESIS, unicode"роздано ровно genesis");
        assertEq(token.totalSupply(), supplyBefore, unicode"сапплай не изменился");
        assertEq(
            token.balanceOf(EMISSION), token.EMISSION_POOL(), unicode"пул эмиссии не тронут"
        );
    }

    /*//////////////////////////////////////////////////////////////
                       ПРЕДУСЛОВИЯ: ЧТО НЕ ПРОЙДЁТ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Раскладка не начнётся, если на отправителе не ровно genesis.
     * @dev Меньше — значит кошелёк не тот или раскладка уже частично прошла.
     *      Больше — значит адрес используется ещё для чего-то, и постусловие
     *      «на отправителе ноль» стало бы ложным обещанием.
     */
    function test_Distribute_RevertsIfSenderBalanceIsNotExactlyGenesis() public {
        vm.prank(sender);
        token.transfer(marketing, 1);

        vm.expectRevert(bytes("sender balance != GENESIS"));
        _distribute(_recipients());

        vm.prank(EMISSION);
        token.transfer(sender, 2);

        vm.expectRevert(bytes("sender balance != GENESIS"));
        _distribute(_recipients());
    }

    /// @notice Незаполненная строка в .env превращается в address(0) —
    ///         скрипт падает до первого перевода, а не на середине раскладки.
    function test_Distribute_RevertsOnZeroRecipient() public {
        Distribute.Recipients memory to = _recipients();
        to.marketing = address(0);

        vm.expectRevert(bytes("zero address among recipients"));
        _distribute(to);

        assertEq(
            token.balanceOf(sender), SPEC_GENESIS, unicode"ни один перевод не прошёл"
        );
    }

    /// @notice Один и тот же адрес в двух долях — обычная опечатка копипастой.
    function test_Distribute_RevertsOnDuplicateRecipient() public {
        Distribute.Recipients memory to = _recipients();
        to.reserve = to.marketing;

        vm.expectRevert(bytes("duplicate address among recipients"));
        _distribute(to);
    }

    /// @notice Доля, направленная обратно отправителю, тоже ловится: иначе
    ///         постусловие «на отправителе ноль» перестало бы выполняться.
    function test_Distribute_RevertsIfRecipientIsSender() public {
        Distribute.Recipients memory to = _recipients();
        to.reserve = sender;

        vm.expectRevert(bytes("duplicate address among recipients"));
        _distribute(to);
    }

    /// @notice Доля, направленная в адрес сжигания вторым потоком, ловится там же.
    function test_Distribute_RevertsIfRecipientIsBurnAddress() public {
        Distribute.Recipients memory to = _recipients();
        to.marketing = DEAD;

        vm.expectRevert(bytes("duplicate address among recipients"));
        _distribute(to);
    }

    /**
     * @notice Инвентарь и казна обязаны быть контрактами.
     * @dev Опечатка в адресе кривой или вестинга отправила бы 1.5 миллиарда
     *      токенов на кошелёк, который никто не контролирует. Отозвать перевод
     *      нельзя, поэтому проверка стоит до broadcast.
     */
    function test_Distribute_RevertsIfCurveOrVestingIsNotAContract() public {
        Distribute.Recipients memory to = _recipients();
        to.curve = makeAddr("eoaByMistake");

        vm.expectRevert(bytes("curve is not a contract"));
        _distribute(to);

        to = _recipients();
        to.vesting = makeAddr("anotherEoaByMistake");

        vm.expectRevert(bytes("vesting is not a contract"));
        _distribute(to);
    }

    /*//////////////////////////////////////////////////////////////
                     ВЕСТИНГ И КРИВАЯ ДО BROADCAST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Казна, развёрнутая на другой токен, ловится до перевода.
     * @dev Иначе 500 миллионов $MACLRN легли бы в контракт, чей `release()`
     *      переводит совсем другой актив: достать их не смогла бы ни одна
     *      функция — ни раньше срока, ни позже.
     */
    function test_Distribute_RevertsIfVestingHoldsAnotherToken() public {
        MaclaurinToken other = new MaclaurinToken(address(0xBEEF), address(0xCAFE));
        MaclaurinVesting wrong =
            new MaclaurinVesting(IERC20(address(other)), treasuryBeneficiary, block.timestamp + 175 days);

        Distribute.Recipients memory to = _recipients();
        to.vesting = address(wrong);

        vm.expectRevert(bytes("vesting holds a different token"));
        _distribute(to);

        assertEq(
            token.balanceOf(sender), SPEC_GENESIS, unicode"ни один перевод не прошёл"
        );
    }

    /// @notice Уже открытая казна — это не казна, а кошелёк: 18.4% сапплая
    ///         можно было бы забрать в том же блоке.
    function test_Distribute_RevertsIfVestingIsAlreadyUnlocked() public {
        MaclaurinVesting soon =
            new MaclaurinVesting(IERC20(address(token)), treasuryBeneficiary, block.timestamp + 1);
        vm.warp(block.timestamp + 2);

        Distribute.Recipients memory to = _recipients();
        to.vesting = address(soon);

        vm.expectRevert(bytes("vesting is already unlocked"));
        _distribute(to);
    }

    /**
     * @notice EXPECTED_UNLOCK_TIME сверяется точным равенством.
     * @dev Проверка «дата в будущем» ловит только грубую ошибку. Дату,
     *      промахнувшуюся на год, не ловит ничто, кроме сверки с заранее
     *      посчитанным значением — а исправить её после перевода нельзя.
     */
    function test_Distribute_UnlockTimeIsCheckedAgainstExpectedValue() public {
        uint256 actual = vestingContract.unlockTime();

        vm.expectRevert(bytes("vesting unlockTime != EXPECTED_UNLOCK_TIME"));
        script.distribute(IERC20(address(token)), sender, _recipients(), actual + 1);

        assertEq(
            token.balanceOf(sender), SPEC_GENESIS, unicode"ни один перевод не прошёл"
        );

        script.distribute(IERC20(address(token)), sender, _recipients(), actual);
        assertEq(token.balanceOf(address(vestingContract)), SPEC_VESTING);
    }

    /// @notice Ноль означает «не сверять»: раскладка проходит, а фактическая
    ///         дата печатается в лог, чтобы человек увидел её перед отправкой.
    function test_Distribute_UnlockTimeCheckIsSkippedWhenExpectedIsZero() public {
        script.distribute(IERC20(address(token)), sender, _recipients(), 0);
        assertEq(token.balanceOf(address(vestingContract)), SPEC_VESTING);
    }

    /**
     * @notice Кривая обязана обслуживать тот же токен.
     * @dev Инвентарь, отправленный кривой от другого актива, не продастся
     *      никогда: она отдаёт покупателю свой токен, а миллиард $MACLRN
     *      останется в ней навсегда.
     */
    function test_Distribute_RevertsIfCurveHoldsAnotherToken() public {
        Distribute.Recipients memory to = _recipients();
        to.curve = address(new TokenHolderStub(makeAddr("someOtherToken")));

        vm.expectRevert(bytes("curve holds a different token"));
        _distribute(to);
    }

    /// @notice Контракт без геттера `token()` — это не кривая, а что-то другое.
    /// @dev Отсутствие геттера считается ошибкой, а не поводом пропустить
    ///      проверку: у настоящей кривой он есть всегда.
    function test_Distribute_RevertsIfCurveHasNoTokenGetter() public {
        address notACurve = makeAddr("notACurve");
        vm.etch(notACurve, hex"60006000fd");

        Distribute.Recipients memory to = _recipients();
        to.curve = notACurve;

        vm.expectRevert(bytes("curve does not expose token()"));
        _distribute(to);
    }

    /*//////////////////////////////////////////////////////////////
                        ОКРУЖЕНИЕ И ПОСТ-ПРОВЕРКА
    //////////////////////////////////////////////////////////////*/

    /// @notice Адреса берутся из окружения, а не зашиты в скрипт.
    function test_Run_UsesEnvironmentAddresses() public {
        script.run();

        assertEq(token.balanceOf(curve), SPEC_CURVE);
        assertEq(token.balanceOf(address(vestingContract)), SPEC_VESTING);
        assertEq(token.balanceOf(marketing), SPEC_MARKETING);
        assertEq(token.balanceOf(reserve), SPEC_RESERVE);
        assertEq(token.balanceOf(remainder), SPEC_REMAINDER);
        assertEq(token.balanceOf(sender), 0);
    }

    /// @notice `verify()` — та же проверка, но по живому состоянию цепочки:
    ///         до раскладки падает, после проходит.
    function test_Verify_FailsBeforeAndPassesAfterDistribution() public {
        vm.expectRevert(bytes("curve share mismatch"));
        script.verify();

        script.run();
        script.verify();
    }

    /*//////////////////////////////////////////////////////////////
                        СВЯЗКА С ВЕСТИНГОМ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Доля казны после раскладки лежит под замком, а не «у команды».
     * @dev Это и есть смысл §7: 18.4% сапплая физически не могут двинуться
     *      до конца эмиссии, потому что функции досрочного вывода не
     *      существует, а не потому, что так обещано.
     */
    function test_Distribute_VestedShareIsLockedUntilUnlockTime() public {
        _distribute(_recipients());

        uint256 unlock = vestingContract.unlockTime();
        vm.expectRevert(abi.encodeWithSelector(MaclaurinVesting.StillLocked.selector, unlock));
        vestingContract.release();

        vm.warp(unlock);
        vestingContract.release();

        assertEq(token.balanceOf(treasuryBeneficiary), SPEC_VESTING);
        assertEq(token.balanceOf(address(vestingContract)), 0);
    }
}

/**
 * @notice Заглушка держателя токена — стоит вместо MaclaurinCurve.
 * @dev Настоящая кривая сюда не импортируется намеренно: её пишет параллельная
 *      задача, и жёсткая зависимость ломала бы этот набор при каждой правке
 *      того файла. Скрипт спрашивает у инвентаря ровно одно — `token()`, —
 *      и заглушка отвечает на тот же вопрос тем же ABI.
 */
contract TokenHolderStub {
    address public immutable token;

    constructor(address token_) {
        token = token_;
    }
}
