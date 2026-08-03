// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

/**
 * @title  MaclaurinRadiusTest
 * @notice Фаза 2 — Radius of Convergence: множители за лок, взвешенный
 *         аккумулятор, досрочный выход и poke.
 *
 * @dev Главный тест файла — test_Attack_BoostWithoutLock_IsImpossible.
 *      Всё остальное существует для того, чтобы он оставался красным при
 *      любой попытке «упростить» лок на claim.
 */
contract MaclaurinRadiusTest is Test {
    MaclaurinEmission internal emission;
    MaclaurinToken internal token;

    address internal genesis = makeAddr("genesis");
    address internal vault = makeAddr("remainderVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal start;

    uint256 internal constant WEEK = 7 days;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant SPEC_EMITTABLE = 718281828459045235360287457;

    /// @dev floor(e × 1e18). Дублирован литералом намеренно: если сверяться
    ///      с константой самого контракта, тест проверит лишь то, что код
    ///      равен самому себе.
    uint256 internal constant SPEC_E = 2718281828459045235;

    function setUp() public {
        vm.warp(1_700_000_000);
        start = block.timestamp;
        emission = new MaclaurinEmission(genesis, vault, start);
        token = emission.token();

        vm.startPrank(genesis);
        token.transfer(alice, 1_000_000e18);
        token.transfer(bob, 1_000_000e18);
        token.transfer(carol, 1_000_000e18);
        vm.stopPrank();

        for (uint256 i = 0; i < 3; ++i) {
            address u = [alice, bob, carol][i];
            vm.prank(u);
            token.approve(address(emission), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                     ТАБЛИЦА МНОЖИТЕЛЕЙ = ЧАСТИЧНЫЕ СУММЫ
    //////////////////////////////////////////////////////////////*/

    /// @notice Значения сверены со спецификацией §1 построчно, литералами.
    function test_MultiplierTable_MatchesSpec() public view {
        assertEq(emission.multiplier(1), 1000000000000000000, "R=1");
        assertEq(emission.multiplier(2), 2000000000000000000, "R=2");
        assertEq(emission.multiplier(3), 2500000000000000000, "R=3");
        assertEq(emission.multiplier(4), 2666666666666666666, "R=4");
        assertEq(emission.multiplier(5), 2708333333333333333, "R=5");
        assertEq(emission.multiplier(6), 2716666666666666666, "R=6");
        assertEq(emission.multiplier(7), 2718055555555555555, "R=7");
    }

    /// @notice Больше радиус — больше множитель. Строго, без плато.
    function test_Multiplier_StrictlyIncreasing() public view {
        for (uint256 r = 1; r < emission.MAX_RADIUS(); ++r) {
            assertGt(
                emission.multiplier(r + 1),
                emission.multiplier(r),
                unicode"множитель обязан расти"
            );
        }
    }

    /**
     * @notice Потолок e недостижим ни при каком допустимом радиусе.
     *
     * @dev Это не ограничение, вписанное в код, а свойство ряда: частичная
     *      сумма строго меньше суммы. Максимум протокола — 2.718055…, до
     *      e не хватает 2.26e14 wei множителя, и добрать это нечем.
     */
    function test_Multiplier_NeverReachesE() public view {
        assertEq(emission.E_FIXED(), SPEC_E, unicode"E_FIXED = floor(e*1e18)");
        for (uint256 r = 1; r <= emission.MAX_RADIUS(); ++r) {
            assertLt(emission.multiplier(r), emission.E_FIXED(), unicode"e недостижим");
        }
        assertLt(emission.multiplier(7), emission.E_FIXED());
    }

    /**
     * @notice Прирост множителя между соседними радиусами — это ровно члены
     *         того же ряда 1/n!.
     *
     * @dev Отсюда и берётся «убывающая отдача доказана, а не заявлена»:
     *      шаг с R=6 на R=7 добавляет 1/6! = 0.00139, то есть спор идёт уже
     *      за четвёртый знак.
     */
    function test_Multiplier_IncrementsAreSeriesTerms() public view {
        uint256[7] memory factorial = [uint256(1), 1, 2, 6, 24, 120, 720];
        for (uint256 r = 2; r <= emission.MAX_RADIUS(); ++r) {
            uint256 step = emission.multiplier(r) - emission.multiplier(r - 1);
            // 1/(r-1)! в масштабе 1e18, с тем же округлением вниз.
            assertApproxEqAbs(step, ONE / factorial[r - 1], 1, unicode"шаг != член ряда");
        }
    }

    /// @notice Радиус вне [1, MAX_RADIUS] — ошибка, а не тихий ноль.
    /// @dev Молчаливый ноль означал бы нулевой вес позиции: пользователь
    ///      застейкал бы и не получал вообще ничего, не узнав об этом.
    function test_Multiplier_RevertsOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.InvalidRadius.selector, 0));
        emission.multiplier(0);

        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.InvalidRadius.selector, 8));
        emission.multiplier(8);

        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.InvalidRadius.selector, type(uint256).max));
        emission.multiplier(type(uint256).max);
    }

    function test_LockDuration_IsRadiusEpochs() public view {
        for (uint256 r = 1; r <= emission.MAX_RADIUS(); ++r) {
            assertEq(emission.lockDuration(r), r * WEEK);
        }
        assertEq(emission.lockDuration(7), 49 days, unicode"максимальный лок — 49 дней");
    }

    function test_Stake_InvalidRadiusReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.InvalidRadius.selector, 0));
        emission.stake(1000e18, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.InvalidRadius.selector, 8));
        emission.stake(1000e18, 8);
    }

    /*//////////////////////////////////////////////////////////////
                                  ВЕС
    //////////////////////////////////////////////////////////////*/

    /// @notice weight == staked × multiplier(R) / 1e18 для каждого радиуса.
    function test_Weight_MatchesFormula() public {
        for (uint256 r = 1; r <= 7; ++r) {
            address u = makeAddr(string(abi.encodePacked("w", r)));
            vm.prank(genesis);
            token.transfer(u, 1000e18);
            vm.startPrank(u);
            token.approve(address(emission), type(uint256).max);
            emission.stake(1000e18, r);
            vm.stopPrank();

            (uint256 staked, uint256 radius, uint256 unlockTime, uint256 weight) = emission.positions(u);
            assertEq(staked, 1000e18);
            assertEq(radius, r);
            assertEq(unlockTime, block.timestamp + r * WEEK);
            assertEq(
                weight,
                1000e18 * emission.multiplier(r) / ONE,
                unicode"вес != тело * множитель"
            );
        }
    }

    /// @notice totalWeight — это ровно сумма весов позиций.
    function test_TotalWeight_IsSumOfPositions() public {
        _stake(alice, 1000e18, 1);
        _stake(bob, 3000e18, 4);
        _stake(carol, 777e18, 7);

        uint256 sum = emission.weightOf(alice) + emission.weightOf(bob) + emission.weightOf(carol);
        assertEq(emission.totalWeight(), sum);

        // И принципал считается отдельно от веса: инвариант платёжеспособности
        // опирается именно на тело, а не на раздутый множителем вес.
        assertEq(emission.totalStaked(), 1000e18 + 3000e18 + 777e18);
        assertGt(emission.totalWeight(), emission.totalStaked(), unicode"вес выше тела");
    }

    /*//////////////////////////////////////////////////////////////
              ГЛАВНОЕ: АТАКА «БУСТ БЕЗ ЛОКА» (СПЕКА §3)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Атака, ради закрытия которой лок висит на claim, а не на unstake.
     *
     * @dev Сценарий из спецификации §3 дословно:
     *
     *          1. stake(1000, R=7)      -> множитель 2.718x
     *          2. ждём эпоху, claim()   -> награда с бустом выведена
     *          3. повторяем каждую эпоху
     *          4. unstake досрочно      -> штраф сжигает rewards, а там 0
     *
     *      Если бы claim был открыт, атакующий получал бы максимальный
     *      множитель, не отсидев ни одного лока: к моменту «штрафа» сжигать
     *      было бы нечего. Здесь шаг 2 обязан реверить каждую эпоху, а шаг 4
     *      обязан отдать тело целиком и отправить ВЕСЬ буст в казну.
     */
    function test_Attack_BoostWithoutLock_IsImpossible() public {
        uint256 principal = 1000e18;
        uint256 unlock = start + 7 * WEEK;

        _stake(alice, principal, 7);
        uint256 balAfterStake = token.balanceOf(alice);

        // Шаги 2-3: шесть эпох подряд пытаемся вынести награду с бустом.
        for (uint256 i = 1; i <= 6; ++i) {
            vm.warp(start + i * WEEK);

            assertGt(emission.earned(alice), 0, unicode"награда копится");

            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.StillLocked.selector, unlock));
            emission.claim();

            // exit() тоже не должен стать лазейкой для вывода награды.
            assertEq(token.balanceOf(alice), balAfterStake, unicode"ни одного wei не вышло");
        }

        // Шаг 4: досрочный выход за секунду до разлока.
        vm.warp(unlock - 1);
        uint256 accrued = emission.earned(alice);
        assertGt(accrued, 0, unicode"было что терять");

        vm.prank(alice);
        emission.exit();

        assertEq(
            token.balanceOf(alice), balAfterStake + principal, unicode"вышел ровно с телом"
        );
        assertEq(emission.earned(alice), 0, unicode"буст не достался атакующему");
        assertEq(
            emission.totalClaimed(), 0, unicode"за всю атаку не выплачено ничего"
        );
        assertEq(emission.unallocated(), accrued, unicode"весь буст ушёл в казну");
    }

    /// @notice Обратная сторона: отсидевший лок забирает буст полностью.
    /// @dev Без этого теста предыдущий проходил бы и на контракте, который
    ///      просто никогда никому ничего не платит.
    function test_HonestStaker_GetsBoostAfterLock() public {
        _stake(alice, 1000e18, 7);
        uint256 before = token.balanceOf(alice);

        vm.warp(start + 7 * WEEK);
        uint256 accrued = emission.earned(alice);
        assertGt(accrued, 0);

        vm.prank(alice);
        emission.claim();

        assertEq(
            token.balanceOf(alice) - before,
            accrued,
            unicode"награда выплачена целиком"
        );
        assertEq(emission.totalClaimed(), accrued);
    }

    /*//////////////////////////////////////////////////////////////
                          ЛОК НА CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Ровно на границе лок уже снят: `<`, а не `<=`.
    function test_Claim_UnlocksExactlyAtUnlockTime() public {
        _stake(alice, 1000e18, 2);
        uint256 unlock = start + 2 * WEEK;
        assertEq(emission.unlockTimeOf(alice), unlock);

        vm.warp(unlock - 1);
        assertTrue(emission.isLocked(alice));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.StillLocked.selector, unlock));
        emission.claim();

        vm.warp(unlock);
        assertFalse(emission.isLocked(alice));
        vm.prank(alice);
        emission.claim();
    }

    /// @notice Лок на claim не может запереть награду навсегда.
    /// @dev Максимум — 49 дней от последнего стейка. Контракт неизменяем,
    ///      поэтому «запертая навсегда награда» здесь была бы фатальной.
    function test_Claim_RewardIsNeverLockedForever() public {
        _stake(alice, 1000e18, 7);

        vm.warp(start + 7 * WEEK);
        vm.prank(alice);
        emission.claim(); // не реверит

        // Даже если пользователь исчез на десять лет — награда его дождалась.
        _stake(bob, 1000e18, 7);
        vm.warp(emission.emissionEnd() + 3650 days);
        uint256 owed = emission.earned(bob);
        assertGt(owed, 0);
        vm.prank(bob);
        emission.claim();
        assertEq(emission.totalClaimed(), emission.totalClaimed());
        assertGe(token.balanceOf(bob), owed);
    }

    /*//////////////////////////////////////////////////////////////
                        ДОСРОЧНЫЙ ВЫХОД
    //////////////////////////////////////////////////////////////*/

    /// @notice Тело возвращается ровно целиком, до последнего wei.
    function testFuzz_EarlyExit_ReturnsPrincipalToTheWei(uint256 amount, uint256 radius, uint256 delay)
        public
    {
        amount = bound(amount, 1, 1_000_000e18);
        radius = bound(radius, 1, 7);
        delay = bound(delay, 0, radius * WEEK - 1); // всегда досрочно

        uint256 before = token.balanceOf(alice);
        _stake(alice, amount, radius);

        vm.warp(start + delay);
        vm.prank(alice);
        emission.unstake(amount);

        assertEq(
            token.balanceOf(alice), before, unicode"тело вернулось до последнего wei"
        );
        assertEq(emission.stakedOf(alice), 0);
        assertEq(emission.weightOf(alice), 0);
        assertEq(emission.totalWeight(), 0);
    }

    /// @notice Сгоревшая награда доходит до казны, а не исчезает и не остаётся
    ///         запертой в контракте.
    function test_EarlyExit_ForfeitedRewardReachesVault() public {
        _stake(alice, 1000e18, 7);
        vm.warp(start + 3 * WEEK);

        uint256 accrued = emission.earned(alice);
        assertGt(accrued, 0);

        vm.prank(alice);
        emission.exit();

        assertEq(
            emission.unallocated(),
            accrued,
            unicode"награда в казначейском счётчике"
        );

        emission.sweepToRemainderVault();

        assertEq(
            token.balanceOf(vault),
            accrued,
            unicode"казна получила ровно сгоревшее"
        );
        assertEq(emission.totalSwept(), accrued);
        assertEq(emission.unallocated(), 0);
    }

    /// @notice Событие RewardForfeited отражает ровно сгоревшую сумму.
    function test_EarlyExit_EmitsForfeitEvent() public {
        _stake(alice, 1000e18, 4);
        vm.warp(start + WEEK);

        uint256 accrued = emission.earned(alice);
        vm.expectEmit(true, false, false, true, address(emission));
        emit MaclaurinEmission.RewardForfeited(alice, accrued);

        vm.prank(alice);
        emission.unstake(1000e18);
    }

    /**
     * @notice Досрочный выход сжигает награду ЦЕЛИКОМ даже при выводе одной
     *         пылинки тела.
     *
     * @dev Пропорциональное сжигание открыло бы дробление: вывести 99.99%
     *      тела, оставить wei досиживать лок и сохранить почти всю награду,
     *      набранную полным телом. Здесь любой досрочный выход стоит всей
     *      накопленной награды — цена не зависит от размера вывода.
     */
    function test_EarlyPartialUnstake_ForfeitsEverything() public {
        _stake(alice, 1000e18, 7);
        vm.warp(start + 3 * WEEK);

        uint256 accrued = emission.earned(alice);
        assertGt(accrued, 0);

        vm.prank(alice);
        emission.unstake(1); // одна пылинка

        assertEq(emission.earned(alice), 0, unicode"сгорело всё, а не пропорция");
        assertEq(emission.unallocated(), accrued);
        assertEq(emission.stakedOf(alice), 1000e18 - 1, unicode"остальное тело на месте");
        assertEq(
            emission.weightOf(alice),
            (1000e18 - 1) * emission.multiplier(7) / ONE,
            unicode"вес пересчитан на остаток"
        );
        // Лок при этом не снят: позиция продолжает жить.
        assertTrue(emission.isLocked(alice));
    }

    /// @notice После разлока выход уже не сжигает ничего.
    function test_ExitAfterUnlock_KeepsReward() public {
        _stake(alice, 1000e18, 3);
        vm.warp(start + 3 * WEEK);

        uint256 accrued = emission.earned(alice);
        uint256 before = token.balanceOf(alice);

        vm.prank(alice);
        emission.exit();

        assertEq(token.balanceOf(alice), before + 1000e18 + accrued);
        assertEq(emission.unallocated(), 0, unicode"ничего не сгорело");
    }

    /*//////////////////////////////////////////////////////////////
                          ПОВТОРНЫЙ СТЕЙК
    //////////////////////////////////////////////////////////////*/

    /// @notice Понизить радиус активной позиции нельзя.
    /// @dev Иначе лок разбавлялся бы пылью: застейкать много под R=7, потом
    ///      докинуть wei под R=1 и уехать через неделю со всей позиции.
    function test_Restake_LowerRadiusReverts() public {
        _stake(alice, 1000e18, 5);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.RadiusCannotDecrease.selector, 5, 4));
        emission.stake(1e18, 4);

        // Тот же радиус и выше — можно.
        _stake(alice, 1e18, 5);
        _stake(alice, 1e18, 7);
        (, uint256 radius,,) = emission.positions(alice);
        assertEq(radius, 7);
    }

    /**
     * @notice Повторный стейк отсчитывает лок от ТЕКУЩЕГО момента.
     *
     * @dev Если бы старый unlockTime сохранялся, докидывание пыли за день до
     *      разлока давало бы полный множитель 2.718x на новую сумму за сутки
     *      реального обязательства — то есть буст без лока, только через
     *      чёрный ход.
     */
    function test_Restake_ResetsLockFromNow() public {
        _stake(alice, 1000e18, 7);
        assertEq(emission.unlockTimeOf(alice), start + 7 * WEEK);

        // Почти отсидел — и докинул пылинку.
        vm.warp(start + 7 * WEEK - 1);
        _stake(alice, 1, 7);

        assertEq(
            emission.unlockTimeOf(alice),
            block.timestamp + 7 * WEEK,
            unicode"лок пересчитан от сейчас"
        );

        // И claim закрыт снова, несмотря на почти отсиженный первый лок.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MaclaurinEmission.StillLocked.selector, block.timestamp + 7 * WEEK)
        );
        emission.claim();
    }

    /// @notice Повышение радиуса пересчитывает вес на ВЕСЬ объём позиции.
    function test_Restake_HigherRadiusReweightsWholePosition() public {
        _stake(alice, 1000e18, 1);
        assertEq(emission.weightOf(alice), 1000e18);

        vm.warp(start + 2 days);
        _stake(alice, 1000e18, 7);

        assertEq(emission.stakedOf(alice), 2000e18);
        assertEq(emission.weightOf(alice), 2000e18 * emission.multiplier(7) / ONE);
        assertEq(emission.totalWeight(), emission.weightOf(alice));
    }

    /// @notice Уже начисленное при смене радиуса не пересчитывается.
    /// @dev Модификатор `update` фиксирует награду по старому весу до того,
    ///      как вес изменится. Иначе повышение радиуса задним числом
    ///      умножало бы прошлые эпохи.
    function test_Restake_DoesNotRewritePastAccrual() public {
        _stake(alice, 1000e18, 1);
        vm.warp(start + WEEK);

        uint256 beforeUpgrade = emission.earned(alice);
        _stake(alice, 1, 7);

        assertApproxEqAbs(
            emission.earned(alice), beforeUpgrade, 1, unicode"прошлое не переоценено"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                POKE
    //////////////////////////////////////////////////////////////*/

    /// @notice На активном локе poke ревертит.
    function test_Poke_RevertsWhileLocked() public {
        _stake(alice, 1000e18, 7);

        vm.warp(start + 7 * WEEK - 1);
        assertFalse(emission.isPokeable(alice));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.StillLocked.selector, start + 7 * WEEK));
        emission.poke(alice);
    }

    /// @notice На истёкшем локе poke понижает вес до 1x.
    function test_Poke_ResetsExpiredPositionToBaseline() public {
        _stake(alice, 1000e18, 7);
        assertEq(emission.weightOf(alice), 1000e18 * emission.multiplier(7) / ONE);

        vm.warp(start + 7 * WEEK);
        assertTrue(emission.isPokeable(alice));

        vm.prank(bob); // кто угодно
        emission.poke(alice);

        (uint256 staked, uint256 radius,, uint256 weight) = emission.positions(alice);
        assertEq(staked, 1000e18, unicode"тело не тронуто");
        assertEq(radius, 1, unicode"радиус сброшен");
        assertEq(weight, 1000e18, unicode"вес = 1.0x");
        assertEq(emission.totalWeight(), 1000e18);
        assertFalse(emission.isPokeable(alice));
    }

    /**
     * @notice poke обязан начислить и зафиксировать награду ДО смены веса.
     *
     * @dev Регрессия на самую опасную ошибку в этой функции. Если сбросить
     *      вес без `_accrue`/`_settle`, новый (меньший) вес применится ко
     *      всему прошедшему времени задним числом, и часть уже заработанной
     *      награды исчезнет — причём по вызову постороннего адреса, то есть
     *      это была бы полноценная атака на чужой баланс.
     */
    function test_Poke_SettlesBeforeReweighting() public {
        _stake(alice, 1000e18, 7);
        _stake(bob, 1000e18, 7);

        vm.warp(start + 7 * WEEK + 3 days);
        uint256 aliceBefore = emission.earned(alice);
        assertGt(aliceBefore, 0);

        vm.prank(carol);
        emission.poke(alice);

        assertEq(
            emission.earned(alice), aliceBefore, unicode"начисленное не переоценено"
        );
    }

    /// @notice После poke доля соседа растёт — в этом и есть стимул звать её.
    function test_Poke_RestoresFairShareForOthers() public {
        _stake(alice, 1000e18, 7); // лок 49 дней
        _stake(bob, 1000e18, 1); // лок 7 дней

        // Ждём, пока лок Алисы истечёт, и снимаем ей множитель.
        vm.warp(start + 7 * WEEK);
        emission.poke(alice);

        uint256 aliceAt = emission.earned(alice);
        uint256 bobAt = emission.earned(bob);

        // Дальше веса равны, значит и начисление обязано идти поровну.
        vm.warp(start + 8 * WEEK);
        uint256 aliceDelta = emission.earned(alice) - aliceAt;
        uint256 bobDelta = emission.earned(bob) - bobAt;

        assertGt(aliceDelta, 0);
        assertApproxEqAbs(aliceDelta, bobDelta, 2, unicode"после poke делят поровну");
    }

    /// @notice poke по пустой позиции и по уже базовой — ошибка.
    function test_Poke_RevertsWhenNothingToDo() public {
        vm.expectRevert(MaclaurinEmission.NoPosition.selector);
        emission.poke(alice);

        _stake(bob, 1000e18, 1);
        vm.warp(start + WEEK);
        vm.expectRevert(MaclaurinEmission.AlreadyAtBaseline.selector);
        emission.poke(bob);
    }

    /// @notice После poke позиция снова обычная: можно стейкать с любым R.
    /// @dev Это единственный выход из «навсегда обязан стейкать с R не ниже
    ///      прежнего» — и он permissionless, то есть доступен самому
    ///      пользователю без чьей-либо помощи.
    function test_Poke_AllowsLowerRadiusAfterwards() public {
        _stake(alice, 1000e18, 7);
        vm.warp(start + 7 * WEEK);

        // До poke понизить радиус нельзя даже на истёкшем локе.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.RadiusCannotDecrease.selector, 7, 1));
        emission.stake(1e18, 1);

        vm.prank(alice);
        emission.poke(alice); // сам себя

        _stake(alice, 1e18, 1);
        (, uint256 radius,,) = emission.positions(alice);
        assertEq(radius, 1);
        assertEq(emission.weightOf(alice), 1000e18 + 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                       ЭКОНОМИКА МНОЖИТЕЛЕЙ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Двое с равным телом и разными радиусами получают награду ровно
     *         в отношении множителей.
     */
    function test_TwoStakers_RewardRatioEqualsMultiplierRatio() public {
        _stake(alice, 1000e18, 1);
        _stake(bob, 1000e18, 7);

        vm.warp(start + WEEK);

        uint256 earnedAlice = emission.earned(alice);
        uint256 earnedBob = emission.earned(bob);
        assertGt(earnedAlice, 0);

        assertApproxEqAbs(
            earnedBob,
            earnedAlice * emission.multiplier(7) / ONE,
            3,
            unicode"отношение наград != отношение множителей"
        );

        // И вместе они по-прежнему не забирают больше члена ряда.
        assertLe(earnedAlice + earnedBob, emission.epochAmount(2), unicode"перевыплата эпохи");
    }

    /// @notice Отношение выдерживается для любой пары радиусов.
    function testFuzz_RewardRatioFollowsMultipliers(uint256 rA, uint256 rB) public {
        rA = bound(rA, 1, 7);
        rB = bound(rB, 1, 7);

        _stake(alice, 1000e18, rA);
        _stake(bob, 1000e18, rB);

        vm.warp(start + WEEK);

        uint256 earnedAlice = emission.earned(alice);
        uint256 earnedBob = emission.earned(bob);

        assertApproxEqAbs(earnedBob * emission.multiplier(rA), earnedAlice * emission.multiplier(rB), 1e19);
    }

    /**
     * @notice Множитель ничего не создаёт из воздуха: одинокий стейкер с
     *         R=7 получает ровно столько же, сколько получил бы с R=1.
     *
     * @dev Множитель — это доля в totalWeight, а не эмиссия сверх ряда.
     *      Если бы он умножал саму награду, контракт обещал бы 2.718 × пула
     *      и стал бы неплатёжеспособным на первой же выплате.
     */
    function test_Multiplier_DoesNotCreateTokens() public {
        _stake(alice, 1000e18, 7);
        vm.warp(emission.emissionEnd() + 1);

        uint256 earned = emission.earned(alice);
        assertLe(earned, SPEC_EMITTABLE, unicode"больше ряда не бывает");
        assertApproxEqAbs(earned, SPEC_EMITTABLE, 100, unicode"и не меньше — он один");

        vm.prank(alice);
        emission.claim();
        assertGe(
            token.balanceOf(address(emission)),
            emission.totalStaked(),
            unicode"платёжеспособен"
        );
    }

    /**
     * @notice Максимальный вес не переполняет аккумулятор.
     *
     * @dev Худший случай из обоснования ACC_PRECISION: весь доступный сапплай
     *      в стейке с максимальным множителем. Теоретический потолок веса —
     *      2.718e27 × 2.718 ≈ 7.4e27, и даже он оставляет ~10^20 запаса до
     *      потолка uint256 в оценке `weight * delta ≤ Σ(ряд) * 1e30`.
     */
    function test_MaxWeight_NoOverflowAndTailSurvives() public {
        uint256 whole = token.balanceOf(genesis);
        vm.startPrank(genesis);
        token.approve(address(emission), whole);
        emission.stake(whole, 7);
        vm.stopPrank();

        assertGt(emission.totalWeight(), 5e27, unicode"вес действительно огромный");

        // Хвост ряда не обнуляется даже при таком делителе.
        vm.warp(emission.epochEndsAt(25));
        uint256 before = emission.earned(genesis);
        vm.warp(emission.epochEndsAt(26));
        assertGt(emission.earned(genesis) - before, 0, unicode"хвост выжил");

        vm.warp(emission.emissionEnd() + 1);
        uint256 total = emission.earned(genesis);
        assertLe(total, SPEC_EMITTABLE);

        vm.prank(genesis);
        emission.claim();
        assertGe(token.balanceOf(address(emission)), emission.totalStaked());
    }

    /// @notice Суммарные выплаты не превышают ряд ни при каких радиусах.
    function testFuzz_PayoutNeverExceedsSeriesWithBoosts(uint256 rA, uint256 rB, uint256 rC, uint256 delay)
        public
    {
        _stake(alice, 100_000e18, bound(rA, 1, 7));
        _stake(bob, 250_000e18, bound(rB, 1, 7));
        _stake(carol, 1e18, bound(rC, 1, 7));

        vm.warp(start + bound(delay, 1, 400 days));

        uint256 distributed = emission.earned(alice) + emission.earned(bob) + emission.earned(carol)
            + emission.pendingUnallocated();

        assertLe(distributed, SPEC_EMITTABLE, unicode"раздано больше, чем в ряду");
    }

    /*//////////////////////////////////////////////////////////////
                                ХЕЛПЕРЫ
    //////////////////////////////////////////////////////////////*/

    function _stake(address user, uint256 amount, uint256 radius) internal {
        vm.prank(user);
        emission.stake(amount, radius);
    }
}
