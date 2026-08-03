// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";
import {MaclaurinVesting} from "../src/MaclaurinVesting.sol";

/**
 * @title  MaclaurinVestingTest
 * @notice Казна отдаёт всё и только после срока — и не отдаёт никак иначе.
 *
 * @dev Главные тесты здесь не про то, что release() работает (это одна строка),
 *      а про то, что альтернативных путей к деньгам не существует. Проверка
 *      «вызвал — отревертило» для этого не годится: она зелёная и в контракте,
 *      где нужная злоумышленнику функция есть, но требует другого аргумента.
 *      Поэтому отсутствие доказывается сканированием байткода — селекторов
 *      в диспетчере и опасных опкодов в теле.
 */
contract MaclaurinVestingTest is Test {
    MaclaurinToken internal token;
    MaclaurinVesting internal vesting;

    address internal constant GENESIS_RECIPIENT = address(0xA11CE);
    address internal constant EMISSION = address(0xE41551);

    address internal beneficiary = makeAddr("vestingBeneficiary");
    address internal stranger = makeAddr("stranger");

    /// @notice §6: разблокировка на конце цикла эмиссии, старт + 175 дней.
    uint256 internal constant LOCK_DURATION = 175 days;

    /// @notice Доля казны по §7 — 1/4 genesis.
    uint256 internal constant TREASURY = 500_000_000e18;

    uint256 internal unlockTime;

    function setUp() public {
        vm.warp(1_700_000_000);

        token = new MaclaurinToken(GENESIS_RECIPIENT, EMISSION);
        unlockTime = block.timestamp + LOCK_DURATION;
        vesting = new MaclaurinVesting(IERC20(address(token)), beneficiary, unlockTime);

        vm.prank(GENESIS_RECIPIENT);
        token.transfer(address(vesting), TREASURY);
    }

    /*//////////////////////////////////////////////////////////////
                              КОНСТРУКТОР
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(vesting.unlockTime(), unlockTime);
        assertEq(token.balanceOf(address(vesting)), TREASURY, unicode"казна пополнена");
    }

    function test_Constructor_ZeroToken_Reverts() public {
        vm.expectRevert(MaclaurinVesting.ZeroAddress.selector);
        new MaclaurinVesting(IERC20(address(0)), beneficiary, block.timestamp + 1);
    }

    function test_Constructor_ZeroBeneficiary_Reverts() public {
        vm.expectRevert(MaclaurinVesting.ZeroAddress.selector);
        new MaclaurinVesting(IERC20(address(token)), address(0), block.timestamp + 1);
    }

    /**
     * @notice Прошедшая или сегодняшняя дата разблокировки не принимается.
     * @dev Иначе достаточно опечатки в скрипте, чтобы «казна под замком»
     *      оказалась открытой с нулевого блока — и починить это было бы уже
     *      нечем: контракт неизменяем.
     */
    function test_Constructor_UnlockTimeNotInFuture_Reverts() public {
        vm.expectRevert(MaclaurinVesting.UnlockTimeInPast.selector);
        new MaclaurinVesting(IERC20(address(token)), beneficiary, block.timestamp);

        vm.expectRevert(MaclaurinVesting.UnlockTimeInPast.selector);
        new MaclaurinVesting(IERC20(address(token)), beneficiary, block.timestamp - 1);
    }

    /*//////////////////////////////////////////////////////////////
                             ДО РАЗБЛОКИРОВКИ
    //////////////////////////////////////////////////////////////*/

    function test_Release_BeforeUnlock_Reverts() public {
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinVesting.StillLocked.selector, unlockTime));
        vesting.release();

        assertEq(token.balanceOf(address(vesting)), TREASURY, unicode"казна не тронута");
        assertEq(token.balanceOf(beneficiary), 0);
    }

    /// @notice За секунду до срока — всё ещё замок.
    function test_Release_OneSecondBeforeUnlock_Reverts() public {
        vm.warp(unlockTime - 1);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinVesting.StillLocked.selector, unlockTime));
        vesting.release();
    }

    /// @notice Ни деплоер, ни бенефициар, ни посторонний не могут забрать раньше.
    function test_Release_NobodyCanReleaseEarly() public {
        address[3] memory callers = [address(this), beneficiary, stranger];

        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(MaclaurinVesting.StillLocked.selector, unlockTime));
            vesting.release();
        }

        assertEq(token.balanceOf(address(vesting)), TREASURY);
    }

    /// @notice Ни в какой момент до срока замок не открывается.
    function testFuzz_Release_LockedForEveryInstantBeforeUnlock(uint256 t) public {
        t = bound(t, 1, unlockTime - 1);
        vm.warp(t);

        vm.expectRevert(abi.encodeWithSelector(MaclaurinVesting.StillLocked.selector, unlockTime));
        vesting.release();
        assertEq(token.balanceOf(address(vesting)), TREASURY);
    }

    /*//////////////////////////////////////////////////////////////
                            ПОСЛЕ РАЗБЛОКИРОВКИ
    //////////////////////////////////////////////////////////////*/

    /// @notice Ровно в момент unlockTime замок уже открыт: проверка `<`, не `<=`.
    function test_Release_ExactlyAtUnlockTime_Works() public {
        vm.warp(unlockTime);
        vesting.release();

        assertEq(token.balanceOf(beneficiary), TREASURY);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_Release_TransfersEntireBalance() public {
        vm.warp(unlockTime + 1);

        vm.expectEmit(true, false, false, true, address(vesting));
        emit MaclaurinVesting.Released(beneficiary, TREASURY);

        vm.prank(beneficiary);
        vesting.release();

        assertEq(token.balanceOf(beneficiary), TREASURY, unicode"выдано целиком");
        assertEq(token.balanceOf(address(vesting)), 0, unicode"в казне ноль");
    }

    /**
     * @notice Посторонний может нажать кнопку, но получить ничего не может.
     * @dev Открытый вызов — осознанное решение: получатель зашит в immutable,
     *      поэтому чужой вызов способен только оплатить газ за бенефициара.
     *      Атака, которой здесь нет: «фронтран release() и забрал казну» —
     *      адрес назначения не зависит от msg.sender вообще.
     */
    function test_Release_ByStranger_GoesToBeneficiaryOnly() public {
        vm.warp(unlockTime);

        vm.prank(stranger);
        vesting.release();

        assertEq(token.balanceOf(beneficiary), TREASURY);
        assertEq(token.balanceOf(stranger), 0, unicode"постороннему ничего");
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_Release_Twice_RevertsOnEmptyTreasury() public {
        vm.warp(unlockTime);
        vesting.release();

        vm.expectRevert(MaclaurinVesting.NothingToRelease.selector);
        vesting.release();
    }

    /// @notice Токены, присланные после выдачи, тоже достаются бенефициару.
    /// @dev Расчёт от живого баланса безопасен именно потому, что получатель
    ///      один: чужой перевод сюда — подарок бенефициару, а не рычаг.
    function test_Release_LaterDepositsAreAlsoReleasable() public {
        vm.warp(unlockTime);
        vesting.release();

        vm.prank(GENESIS_RECIPIENT);
        token.transfer(address(vesting), 1234e18);

        vesting.release();
        assertEq(token.balanceOf(beneficiary), TREASURY + 1234e18);
    }

    function testFuzz_Release_GivesExactlyTheWholeBalance(uint256 extra) public {
        extra = bound(extra, 0, 1_000_000_000e18 - TREASURY);

        vm.prank(GENESIS_RECIPIENT);
        token.transfer(address(vesting), extra);

        vm.warp(unlockTime);
        vesting.release();

        assertEq(token.balanceOf(beneficiary), TREASURY + extra);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       ГЛАВНОЕ: ЧЕГО В КОНТРАКТЕ НЕТ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ни одной функции, дающей доступ к казне раньше срока или мимо
     *         бенефициара, в байткоде не существует.
     *
     * @dev Ищем селекторы в РАЗВЁРНУТОМ байткоде, а не проверяем «вызов
     *      реверит». Разница принципиальная: `emergencyWithdraw()` без
     *      аргументов ревертнёт и там, где она есть, — просто на проверке
     *      прав. Такой тест зелёный и бесполезный. Отсутствие селектора
     *      в диспетчере — это доказательство.
     *
     *      Атака, которую это предотвращает: самый частый «вестинг» на рынке
     *      имеет `emergencyWithdraw() onlyOwner` или `setBeneficiary()`.
     *      Формально не уязвимость — задокументированное полномочие, и казна
     *      разблокирована с первого дня. Единственная защита — чтобы такой
     *      функции физически не было.
     */
    function test_NoPrivilegedFunctionsInBytecode() public view {
        string[16] memory forbidden = [
            "emergencyWithdraw()",
            "withdraw()",
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "sweep(address)",
            "rescueTokens(address,uint256)",
            "recover(address,uint256)",
            "setBeneficiary(address)",
            "setUnlockTime(uint256)",
            "revoke()",
            "owner()",
            "renounceOwnership()",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "execute(address,uint256,bytes)"
        ];

        bytes memory code = address(vesting).code;
        assertGt(code.length, 0, "no code deployed");

        for (uint256 i = 0; i < forbidden.length; ++i) {
            bytes4 sel = bytes4(keccak256(bytes(forbidden[i])));
            assertFalse(_containsSelector(code, sel), forbidden[i]);
        }
    }

    /// @dev Контрольная проверка самого метода: селекторы существующих функций
    ///      обязаны находиться. Без этого тест выше мог бы «проходить» просто
    ///      потому, что поиск сломан.
    function test_SelectorScanner_IsSane() public view {
        bytes memory code = address(vesting).code;
        assertTrue(_containsSelector(code, bytes4(keccak256("release()"))));
        assertTrue(_containsSelector(code, bytes4(keccak256("beneficiary()"))));
        assertTrue(_containsSelector(code, bytes4(keccak256("unlockTime()"))));
    }

    /**
     * @notice В теле контракта нет опкодов, которыми казну можно увести мимо
     *         объявленной логики.
     *
     * @dev Селекторы закрывают публичный интерфейс, опкоды — всё остальное.
     *      DELEGATECALL означал бы, что чужой код исполняется в контексте
     *      казны и может распоряжаться её балансом; SELFDESTRUCT в старой
     *      семантике вычищал контракт вместе с ETH; CREATE/CREATE2 —
     *      возможность развернуть из казны что угодно. Ничего этого здесь нет,
     *      и это утверждение о байткоде, а не о намерениях.
     */
    function test_NoDangerousOpcodesInBytecode() public view {
        bytes memory code = address(vesting).code;

        assertFalse(_containsOpcode(code, 0xf4), "DELEGATECALL");
        assertFalse(_containsOpcode(code, 0xf2), "CALLCODE");
        assertFalse(_containsOpcode(code, 0xff), "SELFDESTRUCT");
        assertFalse(_containsOpcode(code, 0xf0), "CREATE");
        assertFalse(_containsOpcode(code, 0xf5), "CREATE2");
    }

    /// @dev Контроль сканера опкодов: CALL обязан находиться — им SafeERC20
    ///      переводит токен. Если бы не находился, тест выше не значил бы ничего.
    function test_OpcodeScanner_IsSane() public view {
        assertTrue(_containsOpcode(address(vesting).code, 0xf1), "CALL");
    }

    /*//////////////////////////////////////////////////////////////
                            КОНТРАКТ И ETH
    //////////////////////////////////////////////////////////////*/

    /// @notice Ни receive, ни fallback: ETH сюда не отправить обычной
    ///         транзакцией, и застрять ему негде.
    function test_DoesNotAcceptEther() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vesting).call{value: 1 ether}("");
        assertFalse(ok, unicode"ETH не принимается");

        (bool okData,) = address(vesting).call{value: 1 ether}(hex"12345678");
        assertFalse(okData, unicode"неизвестный селектор не принимается");
    }

    /*//////////////////////////////////////////////////////////////
                              ВСПОМОГАТЕЛЬНОЕ
    //////////////////////////////////////////////////////////////*/

    function _containsSelector(bytes memory code, bytes4 sel) private pure returns (bool) {
        if (code.length < 4) return false;
        for (uint256 i = 0; i <= code.length - 4; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3])
            {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Проход по опкодам с пропуском данных PUSH: иначе байт 0xf4 внутри
     *      константы был бы засчитан за DELEGATECALL, и тест ловил бы призраков.
     *      Хвост CBOR-метаданных solc отрезается — это не исполняемый код.
     */
    function _containsOpcode(bytes memory code, uint8 op) private pure returns (bool) {
        uint256 end = _executableLength(code);

        for (uint256 i = 0; i < end;) {
            uint8 b = uint8(code[i]);
            if (b == op) return true;
            // PUSH1..PUSH32 (0x60..0x7f) тянут за собой 1..32 байта данных.
            // PUSH0 (0x5f) данных не имеет и обрабатывается общим случаем.
            i += (b >= 0x60 && b <= 0x7f) ? uint256(b) - 0x5f + 1 : 1;
        }
        return false;
    }

    /// @dev Последние два байта рантайм-байткода solc — длина CBOR-метаданных.
    function _executableLength(bytes memory code) private pure returns (uint256) {
        if (code.length < 2) return code.length;
        uint256 metaLen = (uint256(uint8(code[code.length - 2])) << 8) | uint256(uint8(code[code.length - 1]));
        if (metaLen + 2 >= code.length) return code.length;
        return code.length - metaLen - 2;
    }
}
