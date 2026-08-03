// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

/**
 * @title Phase2Probe
 * @notice Независимые пробы на обход лока, написанные при ревью фазы 2.
 *
 * @dev Тесты фазы 2 писал тот же агент, что и механику. Пробы ниже идут
 *      не от кода, а от вопроса «как отсюда украсть»: буст 2.718x должен
 *      доставаться только тому, кто реально отсидел заявленный радиус.
 */
contract Phase2Probe is Test {
    MaclaurinEmission emission;
    MaclaurinToken token;

    address genesis = makeAddr("genesis");
    address vault = makeAddr("vault");

    uint256 constant SERIES = 718_281_828_459_045_235_360_287_457;

    function setUp() public {
        vm.warp(1_000_000);
        emission = new MaclaurinEmission(genesis, vault, block.timestamp);
        token = emission.token();
    }

    function _stake(address who, uint256 amt, uint256 r) internal {
        vm.prank(genesis);
        token.transfer(who, amt);
        vm.startPrank(who);
        token.approve(address(emission), amt);
        emission.stake(amt, r);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
        1. ПРЯМОЙ ОБХОД ЛОКА
    //////////////////////////////////////////////////////////////*/

    /// @notice Максимальный буст нельзя вывести, не отсидев лок.
    function test_probe_CannotClaimBeforeUnlock() public {
        address a = makeAddr("a");
        _stake(a, 1000e18, 7);

        // Проходим весь лок по неделе и на каждом шаге пробуем забрать.
        for (uint256 i = 0; i < 7; ++i) {
            vm.warp(block.timestamp + 7 days - 1);
            assertGt(emission.earned(a), 0, unicode"награда копится");
            vm.prank(a);
            vm.expectRevert();
            emission.claim();
            vm.warp(block.timestamp + 1);
        }

        // Лок отсижен — только теперь забирать можно.
        vm.prank(a);
        emission.claim();
        assertGt(token.balanceOf(a), 0, unicode"после лока награда доступна");
    }

    /// @notice poke на себе не открывает лок досрочно.
    /// @dev Ключевая проверка: poke сбрасывает вес истёкшей позиции, и если бы
    ///      он работал на активном локе, это был бы бесплатный выход из него.
    function test_probe_PokeCannotUnlockEarly() public {
        address a = makeAddr("a");
        _stake(a, 1000e18, 7);
        vm.warp(block.timestamp + 14 days);

        vm.prank(a);
        vm.expectRevert();
        emission.poke(a);

        // И посторонний тоже не может.
        vm.prank(makeAddr("outsider"));
        vm.expectRevert();
        emission.poke(a);

        vm.prank(a);
        vm.expectRevert();
        emission.claim();
    }

    /*//////////////////////////////////////////////////////////////
        2. ОБХОД ЧЕРЕЗ ВЫХОД И ПОВТОРНЫЙ ВХОД
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Полный досрочный выход удаляет позицию — не открывает ли это
     *         claim для награды, набранной с бустом?
     *
     * @dev Механика: unstake() полностью стирает radius и unlockTime, иначе
     *      вышедший навсегда остался бы с закрытым claim. Проверяю, что
     *      сгорание награды происходит РАНЬШЕ этого стирания, иначе получился
     *      бы бесплатный обход: вышел досрочно, лок обнулился, забрал буст.
     */
    function test_probe_ExitThenClaim_CannotRecoverForfeitedReward() public {
        address a = makeAddr("a");
        _stake(a, 1000e18, 7);

        vm.warp(block.timestamp + 21 days);
        uint256 accrued = emission.earned(a);
        assertGt(accrued, 0, unicode"награда с бустом набрана");

        vm.prank(a);
        emission.unstake(1000e18);

        assertEq(token.balanceOf(a), 1000e18, unicode"тело вернулось целиком");
        assertEq(emission.earned(a), 0, unicode"награда сгорела");

        vm.prank(a);
        vm.expectRevert();
        emission.claim();

        assertEq(
            emission.totalClaimed(), 0, unicode"из контракта не ушло ни wei награды"
        );
    }

    /// @notice Частичный досрочный выход тоже сжигает награду целиком.
    /// @dev Иначе дробление: вывести почти всё тело, оставить пыль досиживать
    ///      лок и сохранить награду, набранную полным телом.
    function test_probe_PartialExit_ForfeitsEverything() public {
        address a = makeAddr("a");
        _stake(a, 1000e18, 7);

        vm.warp(block.timestamp + 21 days);
        assertGt(emission.earned(a), 0);

        vm.prank(a);
        emission.unstake(999e18); // оставляем 1 токен досиживать

        assertEq(emission.earned(a), 0, unicode"дробление не сохраняет награду");
    }

    /*//////////////////////////////////////////////////////////////
        3. ЭКОНОМИЧЕСКАЯ ПРОВЕРКА БУСТА
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Буст достаётся строго пропорционально множителю и только тому,
     *         кто отсидел лок.
     *
     * @dev Два стейкера с одинаковым телом: R=1 (1.0x) и R=7 (2.718x).
     *      Оба сидят до конца эмиссии. Отношение наград обязано совпасть
     *      с отношением множителей.
     */
    function test_probe_BoostIsProportionalToMultiplier() public {
        address low = makeAddr("low");
        address high = makeAddr("high");
        _stake(low, 1000e18, 1);
        _stake(high, 1000e18, 7);

        vm.warp(emission.emissionEnd() + 1);

        uint256 rLow = emission.earned(low);
        uint256 rHigh = emission.earned(high);

        // multiplier(7) / multiplier(1) = 2.718055... / 1.0
        uint256 ratio = (rHigh * 1e18) / rLow;
        assertApproxEqRel(ratio, emission.multiplier(7), 1e12, unicode"буст = множителю");

        // Оба реально забирают — лок давно истёк.
        vm.prank(low);
        emission.claim();
        vm.prank(high);
        emission.claim();
        assertGt(token.balanceOf(high), token.balanceOf(low));
    }

    /*//////////////////////////////////////////////////////////////
        4. СГОРЕВШАЯ НАГРАДА И ДВОЙНОЙ УЧЁТ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Сгоревшая награда доходит до казны ровно один раз и не создаёт
     *         перевыпуска сверх суммы ряда.
     *
     * @dev Самый опасный класс ошибки при сжигании: награда уже была учтена
     *      в аккумуляторе как распределённая, и если её же добавить в
     *      unallocated без изъятия у пользователя, суммарные обязательства
     *      превысят то, что контракт держит.
     */
    function test_probe_ForfeitedRewardNoDoubleCount() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _stake(a, 1000e18, 7);
        _stake(b, 1000e18, 7);

        vm.warp(block.timestamp + 21 days);
        vm.prank(a);
        emission.unstake(1000e18); // a сжигает свою награду

        vm.warp(emission.emissionEnd() + 1);

        uint256 obligations =
            emission.earned(a) + emission.earned(b) + emission.pendingUnallocated() + emission.totalStaked();
        assertGe(
            token.balanceOf(address(emission)), obligations, unicode"неплатёжеспособность"
        );

        vm.prank(b);
        emission.exit();
        emission.sweepToRemainderVault();

        uint256 distributed = emission.totalClaimed() + emission.totalSwept();
        assertLe(distributed, SERIES, unicode"роздано больше суммы ряда");
        assertGt(token.balanceOf(vault), 0, unicode"сгоревшее дошло до казны");
    }

    /*//////////////////////////////////////////////////////////////
        5. ЛОВУШКА ПРОДЛЕНИЯ ЛОКА
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Документирует поведение, которое легко принять за баг:
     *         добавление в позицию продлевает лок на УЖЕ заработанную награду.
     *
     * @dev Пользователь честно отсидел R=1, награда разблокирована. Он
     *      докидывает 1 wei с R=7 — и его старая награда снова заперта,
     *      теперь на 49 дней. Потерь нет, но это неочевидно, и в UI об этом
     *      надо предупреждать явно. Проверяю, что деньги при этом целы.
     */
    function test_probe_TopUpRelocksEarnedReward() public {
        address a = makeAddr("a");
        _stake(a, 1000e18, 1);

        vm.warp(block.timestamp + 7 days + 1);
        uint256 beforeTopUp = emission.earned(a);
        assertGt(beforeTopUp, 0);

        vm.prank(a);
        emission.claim(); // сначала убедимся, что забрать МОЖНО
        uint256 claimed = token.balanceOf(a);
        assertEq(claimed, beforeTopUp);

        // Теперь докидываем с максимальным радиусом.
        _stake(a, 1e18, 7);
        vm.warp(block.timestamp + 7 days);

        assertGt(emission.earned(a), 0, unicode"новая награда копится");
        vm.prank(a);
        vm.expectRevert();
        emission.claim(); // и она заперта на новый лок

        // Тело при этом доступно всегда.
        vm.prank(a);
        emission.unstake(1e18);
        assertEq(token.balanceOf(a), claimed + 1e18, unicode"тело возвращается всегда");
    }
}
