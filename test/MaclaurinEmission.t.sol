// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

contract MaclaurinEmissionTest is Test {
    MaclaurinEmission internal emission;
    MaclaurinToken internal token;

    address internal genesis = makeAddr("genesis");
    address internal vault = makeAddr("remainderVault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal start;

    uint256 internal constant WEEK = 7 days;
    uint256 internal constant SPEC_EMISSION_POOL = 718281828459045235360287471;
    /// @dev Σ epochAmount(2..26) — на 14 wei меньше пула. Это «пыль» из §2.1.
    uint256 internal constant SPEC_EMITTABLE = 718281828459045235360287457;

    function setUp() public {
        vm.warp(1_700_000_000);
        start = block.timestamp;
        emission = new MaclaurinEmission(genesis, vault, start);
        token = emission.token();

        // Раздаём тестовым пользователям из GENESIS.
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
                    ТАБЛИЦА ЭМИССИИ = РЯД ТЕЙЛОРА
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Каждое значение сверено со спецификацией §2.1 построчно.
     * @dev Числа продублированы литералами намеренно. Если сгенерировать их
     *      здесь тем же кодом, что в контракте, тест проверит лишь то, что
     *      код равен самому себе.
     */
    function test_EpochTable_MatchesSpec() public view {
        assertEq(emission.epochAmount(2), 500000000000000000000000000, "n=2");
        assertEq(emission.epochAmount(3), 166666666666666666666666666, "n=3");
        assertEq(emission.epochAmount(4), 41666666666666666666666666, "n=4");
        assertEq(emission.epochAmount(5), 8333333333333333333333333, "n=5");
        assertEq(emission.epochAmount(6), 1388888888888888888888888, "n=6");
        assertEq(emission.epochAmount(7), 198412698412698412698412, "n=7");
        assertEq(emission.epochAmount(8), 24801587301587301587301, "n=8");
        assertEq(emission.epochAmount(9), 2755731922398589065255, "n=9");
        assertEq(emission.epochAmount(10), 275573192239858906525, "n=10");
        assertEq(emission.epochAmount(11), 25052108385441718775, "n=11");
        assertEq(emission.epochAmount(12), 2087675698786809897, "n=12");
        assertEq(emission.epochAmount(13), 160590438368216145, "n=13");
        assertEq(emission.epochAmount(14), 11470745597729724, "n=14");
        assertEq(emission.epochAmount(15), 764716373181981, "n=15");
        assertEq(emission.epochAmount(16), 47794773323873, "n=16");
        assertEq(emission.epochAmount(17), 2811457254345, "n=17");
        assertEq(emission.epochAmount(18), 156192069685, "n=18");
        assertEq(emission.epochAmount(19), 8220635246, "n=19");
        assertEq(emission.epochAmount(20), 411031762, "n=20");
        assertEq(emission.epochAmount(21), 19572941, "n=21");
        assertEq(emission.epochAmount(22), 889679, "n=22");
        assertEq(emission.epochAmount(23), 38681, "n=23");
        assertEq(emission.epochAmount(24), 1611, "n=24");
        assertEq(emission.epochAmount(25), 64, "n=25");
        assertEq(emission.epochAmount(26), 2, "n=26");
    }

    /// @notice Эпохи 0 и 1 — это GENESIS, они не эмитируются.
    function test_EpochTable_GenesisEpochsEmitNothing() public view {
        assertEq(emission.epochAmount(0), 0);
        assertEq(emission.epochAmount(1), 0);
    }

    /**
     * @notice Ключевое свойство концепта: эмиссия заканчивается сама.
     * @dev 1e27 / 27! == 0, потому что 27! ≈ 1.089e28 > 1e27. Это не выбор
     *      команды и не таймлок — это поведение целочисленного деления.
     */
    function test_EpochTable_TerminatesAtEpoch27() public view {
        assertEq(emission.epochAmount(27), 0, "epoch 27 must be zero");
        assertEq(emission.epochAmount(28), 0);
        assertEq(emission.epochAmount(1000), 0);
        assertEq(emission.epochAmount(type(uint256).max), 0);
    }

    /// @notice Каждый следующий член строго меньше предыдущего — ряд убывает.
    function test_EpochTable_StrictlyDecreasing() public view {
        for (uint256 n = 2; n < 26; ++n) {
            assertGt(emission.epochAmount(n), emission.epochAmount(n + 1), "series must decrease");
        }
    }

    /**
     * @notice Сумма всех членов ряда на 14 wei меньше пула. Это и есть «пыль».
     * @dev Это не потеря, а гарантия: округление каждого члена вниз означает,
     *      что контракт физически не может пообещать больше, чем у него есть.
     *      Инвариант «нельзя выплатить больше баланса» выполняется арифметикой,
     *      а не проверкой в коде — то есть его нельзя обойти.
     */
    function test_TotalEmittable_LeavesExactly14WeiOfDust() public view {
        uint256 emittable = emission.totalEmittable();
        assertEq(emittable, SPEC_EMITTABLE);
        assertEq(SPEC_EMISSION_POOL - emittable, 14, "Lagrange dust must be 14 wei");
        assertLt(emittable, token.EMISSION_POOL(), "must never exceed the pool");
    }

    /// @notice 99.969% пула выходит за первые 5 эмитируемых эпох (n=2..6),
    ///         99.9999% — за первые 7. Хвост не обрывается, а затухает.
    function test_EmissionIsFactoriallyFrontLoaded() public view {
        uint256 throughEpoch6;
        for (uint256 n = 2; n <= 6; ++n) {
            throughEpoch6 += emission.epochAmount(n);
        }
        // Масштаб 1e6, чтобы разрешение теста было тоньше самой величины.
        // 999684 ppm — это floor, а не округление: 99.96849...%.
        uint256 ppmEpoch6 = throughEpoch6 * 1e6 / SPEC_EMISSION_POOL;
        assertEq(ppmEpoch6, 999684, unicode"99.9684% после эпохи 6");

        uint256 throughEpoch8 = throughEpoch6;
        for (uint256 n = 7; n <= 8; ++n) {
            throughEpoch8 += emission.epochAmount(n);
        }
        assertGe(throughEpoch8 * 1e6 / SPEC_EMISSION_POOL, 999995, unicode">99.9995% после эпохи 8");
    }

    /*//////////////////////////////////////////////////////////////
                              ВРЕМЯ И ЭПОХИ
    //////////////////////////////////////////////////////////////*/

    function test_Epochs_Advance() public {
        assertEq(emission.currentEpoch(), 2);
        vm.warp(start + WEEK - 1);
        assertEq(emission.currentEpoch(), 2);
        vm.warp(start + WEEK);
        assertEq(emission.currentEpoch(), 3);
        vm.warp(start + 24 * WEEK);
        assertEq(emission.currentEpoch(), 26);
        vm.warp(start + 25 * WEEK);
        assertEq(emission.currentEpoch(), 27);
        assertTrue(emission.emissionFinished());
    }

    function test_EmissionDuration_Is175Days() public view {
        assertEq(emission.EMISSION_DURATION(), 175 days);
        assertEq(emission.emissionEnd(), start + 175 days);
    }

    function test_Constructor_RejectsPastStart() public {
        vm.expectRevert(MaclaurinEmission.StartTimeInPast.selector);
        new MaclaurinEmission(genesis, vault, block.timestamp - 1);
    }

    function test_Constructor_RejectsZeroVault() public {
        vm.expectRevert(MaclaurinEmission.ZeroAddress.selector);
        new MaclaurinEmission(genesis, address(0), block.timestamp);
    }

    /// @notice Контракт эмиссии получил ровно пул и ничего больше.
    function test_Constructor_HoldsExactlyThePool() public view {
        assertEq(token.balanceOf(address(emission)), SPEC_EMISSION_POOL);
        assertEq(token.balanceOf(genesis) + 3_000_000e18, token.GENESIS());
    }

    /*//////////////////////////////////////////////////////////////
                            БАЗОВЫЙ СТЕЙКИНГ
    //////////////////////////////////////////////////////////////*/

    function test_SingleStaker_ReceivesWholeEpoch() public {
        _stake(alice, 1000e18);

        vm.warp(start + WEEK);
        assertEq(
            emission.earned(alice), emission.epochAmount(2), unicode"весь член ряда эпохи 2"
        );
    }

    function test_TwoStakers_SplitProRata() public {
        _stake(alice, 3000e18);
        _stake(bob, 1000e18);

        vm.warp(start + WEEK);

        uint256 epoch2 = emission.epochAmount(2);
        assertApproxEqAbs(emission.earned(alice), epoch2 * 3 / 4, 2, "alice 75%");
        assertApproxEqAbs(emission.earned(bob), epoch2 / 4, 2, "bob 25%");
        assertApproxEqAbs(emission.earned(alice) + emission.earned(bob), epoch2, 4);
    }

    /// @notice Вошедший в середине эпохи получает долю только за своё время.
    function test_MidEpochJoin_IsTimeWeighted() public {
        _stake(alice, 1000e18);
        vm.warp(start + WEEK / 2);
        _stake(bob, 1000e18);
        vm.warp(start + WEEK);

        uint256 epoch2 = emission.epochAmount(2);
        // Алиса: полпериода одна (1/2 награды) + полпериода 50/50 (1/4) = 3/4.
        assertApproxEqAbs(emission.earned(alice), epoch2 * 3 / 4, 1e6, "alice 3/4");
        assertApproxEqAbs(emission.earned(bob), epoch2 / 4, 1e6, "bob 1/4");
    }

    /// @notice Начисление линейно внутри эпохи.
    function test_AccrualIsLinearWithinEpoch() public {
        _stake(alice, 1000e18);
        vm.warp(start + WEEK / 4);
        assertApproxEqAbs(emission.earned(alice), emission.epochAmount(2) / 4, 1e6);
        vm.warp(start + WEEK / 2);
        assertApproxEqAbs(emission.earned(alice), emission.epochAmount(2) / 2, 1e6);
    }

    /// @notice Награда следующей эпохи ровно вчетверо меньше (3! / 2! ... = 1/3).
    function test_EpochRewardDropsByFactorial() public {
        _stake(alice, 1000e18);

        vm.warp(start + WEEK);
        uint256 afterEpoch2 = emission.earned(alice);

        vm.warp(start + 2 * WEEK);
        uint256 epoch3Only = emission.earned(alice) - afterEpoch2;

        assertEq(afterEpoch2, emission.epochAmount(2));
        assertEq(epoch3Only, emission.epochAmount(3));
        // 1/3! относительно 1/2! → ровно втрое меньше.
        assertApproxEqAbs(epoch3Only * 3, afterEpoch2, 3);
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM / UNSTAKE
    //////////////////////////////////////////////////////////////*/

    function test_Claim_TransfersReward() public {
        _stake(alice, 1000e18);
        vm.warp(start + WEEK);

        uint256 expected = emission.earned(alice);
        uint256 before = token.balanceOf(alice);

        vm.prank(alice);
        emission.claim();

        assertEq(token.balanceOf(alice) - before, expected);
        assertEq(emission.earned(alice), 0, unicode"награда обнулена");
        assertEq(emission.totalClaimed(), expected);
    }

    function test_Claim_Twice_RevertsSecondTime() public {
        _stake(alice, 1000e18);
        vm.warp(start + WEEK);

        vm.prank(alice);
        emission.claim();

        vm.prank(alice);
        vm.expectRevert(MaclaurinEmission.NothingToClaim.selector);
        emission.claim();
    }

    /// @notice Принципал возвращается целиком, без штрафов, в любой момент.
    /// @dev Здесь выход досрочный (3 дня из семи), то есть по правилам фазы 2
    ///      награда сгорает. Тело депозита это не затрагивает вообще: штраф
    ///      берётся только с награды и никогда с принципала.
    function test_Unstake_ReturnsPrincipalInFull() public {
        uint256 amount = 1000e18;
        uint256 before = token.balanceOf(alice);

        _stake(alice, amount);
        vm.warp(start + 3 days);

        vm.prank(alice);
        emission.unstake(amount);

        assertEq(token.balanceOf(alice), before, unicode"принципал вернулся целиком");
        assertEq(emission.stakedOf(alice), 0);
        assertEq(emission.totalStaked(), 0);
        assertEq(emission.totalWeight(), 0, unicode"вес снят вместе с позицией");
    }

    /// @notice Выход из стейка не сжигает уже начисленную награду.
    function test_Unstake_PreservesAccruedReward() public {
        _stake(alice, 1000e18);
        vm.warp(start + WEEK);
        uint256 accrued = emission.earned(alice);

        vm.prank(alice);
        emission.unstake(1000e18);

        assertEq(emission.earned(alice), accrued, unicode"награда сохранена");

        vm.prank(alice);
        emission.claim();
        assertEq(emission.totalClaimed(), accrued);
    }

    /// @notice После выхода награда больше не капает.
    function test_Unstake_StopsAccrual() public {
        _stake(alice, 1000e18);
        vm.warp(start + WEEK);

        vm.prank(alice);
        emission.unstake(1000e18);
        uint256 frozen = emission.earned(alice);

        vm.warp(start + 5 * WEEK);
        assertEq(emission.earned(alice), frozen, unicode"начисление остановлено");
    }

    function test_Exit_ReturnsEverything() public {
        uint256 before = token.balanceOf(alice);
        _stake(alice, 1000e18);
        vm.warp(start + WEEK);
        uint256 reward = emission.earned(alice);

        vm.prank(alice);
        emission.exit();

        assertEq(token.balanceOf(alice), before + reward);
        assertEq(emission.stakedOf(alice), 0);
    }

    function test_Stake_ZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(MaclaurinEmission.ZeroAmount.selector);
        emission.stake(0, 1);
    }

    /// @notice Симметрично стейку: снять ноль — ошибка, а не тихий no-op.
    /// @dev Без этой проверки unstake(0) прошёл бы насквозь и сжёг награду
    ///      досрочным выходом, ничего не вернув. То есть «пустой» вызов имел
    ///      бы разрушительный побочный эффект.
    function test_Unstake_ZeroReverts() public {
        _stake(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(MaclaurinEmission.ZeroAmount.selector);
        emission.unstake(0);
    }

    function test_Unstake_MoreThanStaked_Reverts() public {
        _stake(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MaclaurinEmission.InsufficientStake.selector, 1001e18, 1000e18)
        );
        emission.unstake(1001e18);
    }

    /*//////////////////////////////////////////////////////////////
                        ГРАНИЦЫ И КОНЕЦ ЭМИССИИ
    //////////////////////////////////////////////////////////////*/

    /// @notice До startTime не начисляется ничего.
    function test_NoAccrualBeforeStart() public {
        vm.warp(1_700_000_000);
        uint256 futureStart = block.timestamp + 30 days;
        MaclaurinEmission e2 = new MaclaurinEmission(genesis, vault, futureStart);
        MaclaurinToken t2 = e2.token();

        vm.prank(genesis);
        t2.transfer(alice, 1000e18);
        vm.startPrank(alice);
        t2.approve(address(e2), type(uint256).max);
        e2.stake(1000e18, 1);
        vm.stopPrank();

        vm.warp(futureStart - 1);
        assertEq(e2.earned(alice), 0, unicode"до старта наград нет");

        vm.warp(futureStart);
        assertEq(e2.earned(alice), 0);

        vm.warp(futureStart + WEEK);
        assertEq(e2.earned(alice), e2.epochAmount(2));
    }

    /// @notice После эпохи 26 эмиссия останавливается навсегда.
    function test_EmissionStopsForever() public {
        _stake(alice, 1000e18);

        vm.warp(emission.emissionEnd());
        uint256 atEnd = emission.earned(alice);

        vm.warp(emission.emissionEnd() + 3650 days); // +10 лет
        assertEq(emission.earned(alice), atEnd, unicode"ни одного wei после конца");
    }

    /**
     * @notice Полный цикл: один стейкер за 175 дней забирает весь пул минус пыль.
     * @dev Главный тест на сохранение стоимости. Проверяет и то, что ничего не
     *      потерялось, и то, что ничего не создалось из воздуха.
     */
    function test_FullEmission_PaysOutEntirePool() public {
        _stake(alice, 1000e18);

        vm.warp(emission.emissionEnd() + 1);
        uint256 earned = emission.earned(alice);

        assertLe(
            earned, SPEC_EMITTABLE, unicode"нельзя выплатить больше суммы ряда"
        );
        assertApproxEqAbs(earned, SPEC_EMITTABLE, 100, unicode"почти весь пул");

        vm.prank(alice);
        emission.claim();

        // В контракте остались принципал + пыль округления, и ни wei меньше.
        assertGe(token.balanceOf(address(emission)), emission.totalStaked());
    }

    /**
     * @notice Даже поздние эпохи с наградой в 2 wei выплачивают ненулевую сумму.
     *
     * @dev Регрессия на два независимых способа потерять хвост ряда:
     *
     *      1. Считать «награду в секунду» как EPOCH_AMOUNT/EPOCH_DURATION —
     *         2 / 604800 == 0, и последние эпохи не платят ничего. Поэтому в
     *         _project сначала умножение, потом деление.
     *      2. Взять слишком мелкий масштаб аккумулятора — 2 * 1e18 / 1e21 == 0
     *         при стейке всего в 1000 токенов. Поэтому ACC_PRECISION = 1e30.
     *
     *      Оба варианта тихо обнуляют именно те члены ряда, ради которых
     *      концепт и существует, и ни один не даёт ошибки компиляции.
     */
    function test_LateEpochs_DoNotRoundToZero() public {
        _stake(alice, 1000e18);

        // Начало эпохи 26 — последней.
        vm.warp(emission.epochEndsAt(25));
        uint256 before = emission.earned(alice);

        vm.warp(emission.epochEndsAt(26));
        uint256 epoch26 = emission.earned(alice) - before;

        assertEq(epoch26, 2, unicode"эпоха 26 = 2 wei, а не 0");
    }

    /// @notice Хвост ряда выплачивается даже когда в стейке лежит весь сапплай.
    /// @dev Худший случай для точности: максимальный делитель, минимальная награда.
    function test_LateEpochs_SurviveMaximumStake() public {
        // Баланс читаем ДО vm.prank: если поставить token.balanceOf(genesis)
        // прямо в аргумент stake(), этот внешний вызов израсходует prank,
        // и stake() уйдёт от имени тест-контракта.
        uint256 whole = token.balanceOf(genesis);
        vm.startPrank(genesis);
        token.approve(address(emission), whole);
        emission.stake(whole, 1);
        vm.stopPrank();

        vm.warp(emission.epochEndsAt(25));
        uint256 before = emission.earned(genesis);
        vm.warp(emission.epochEndsAt(26));

        assertGt(
            emission.earned(genesis) - before, 0, unicode"хвост не должен обнуляться"
        );
    }

    /// @notice Каждая эмитируемая эпоха от 2 до 26 выплачивает ровно свой член ряда.
    function test_EveryEpoch_PaysItsExactSeriesTerm() public {
        _stake(alice, 1000e18);

        uint256 prev = 0;
        for (uint256 n = 2; n <= 26; ++n) {
            vm.warp(emission.epochEndsAt(n));
            uint256 cumulative = emission.earned(alice);
            assertEq(cumulative - prev, emission.epochAmount(n), unicode"член ряда эпохи");
            prev = cumulative;
        }
        assertEq(prev, SPEC_EMITTABLE, unicode"сумма = весь ряд, без потерь");
    }

    /*//////////////////////////////////////////////////////////////
                     ЭПОХИ БЕЗ СТЕЙКЕРОВ → ОСТАТОЧНЫЙ ЧЛЕН
    //////////////////////////////////////////////////////////////*/

    function test_NoStakers_AccruesToUnallocated() public {
        vm.warp(start + WEEK); // эпоха 2 прошла без единого стейкера

        assertEq(emission.pendingUnallocated(), emission.epochAmount(2));

        _stake(alice, 1000e18); // любой вызов фиксирует аккумулятор
        assertEq(emission.unallocated(), emission.epochAmount(2));
        assertEq(
            emission.earned(alice), 0, unicode"опоздавший не получает прошлое"
        );
    }

    function test_Sweep_SendsUnallocatedToVault() public {
        vm.warp(start + WEEK);

        uint256 expected = emission.epochAmount(2);
        emission.sweepToRemainderVault();

        assertEq(token.balanceOf(vault), expected);
        assertEq(emission.unallocated(), 0);
        assertEq(emission.totalSwept(), expected);
    }

    /// @notice Sweep — не админское полномочие: адрес immutable, сумма фиксирована.
    function test_Sweep_IsPermissionlessButHarmless() public {
        vm.warp(start + WEEK);

        vm.prank(alice); // кто угодно
        emission.sweepToRemainderVault();
        assertEq(token.balanceOf(vault), emission.epochAmount(2));

        vm.prank(bob);
        vm.expectRevert(MaclaurinEmission.NothingToSweep.selector);
        emission.sweepToRemainderVault();
    }

    /// @notice Sweep не может забрать принципал стейкеров.
    function test_Sweep_CannotTouchPrincipal() public {
        vm.warp(start + WEEK); // эпоха 2 пустая → в unallocated
        _stake(alice, 1000e18);
        vm.warp(start + 2 * WEEK);

        emission.sweepToRemainderVault();

        // Ушла только награда пустой эпохи 2, не принципал и не награда алисы.
        assertEq(token.balanceOf(vault), emission.epochAmount(2));
        assertGe(token.balanceOf(address(emission)), emission.totalStaked() + emission.earned(alice));
    }

    /*//////////////////////////////////////////////////////////////
                         ГАЗ И ОГРАНИЧЕННОСТЬ ЦИКЛА
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Пропуск всей эмиссии одним вызовом не выходит за разумный газ.
     * @dev Цикл в _project идёт по эпохам, а не по секундам, и обрывается на
     *      emissionEnd — максимум 25 итераций. Если бы он шёл по времени,
     *      контракт после долгой паузы стало бы невозможно разморозить.
     */
    function test_Gas_LongGapIsBounded() public {
        _stake(alice, 1000e18);
        vm.warp(start + 400 days); // вся эмиссия и ещё сверху

        uint256 gasBefore = gasleft();
        vm.prank(bob);
        emission.stake(1000e18, 1);
        uint256 used = gasBefore - gasleft();

        console2.log("gas for stake after full-emission gap:", used);
        assertLt(used, 500_000, unicode"цикл должен быть ограничен 25 эпохами");
    }

    /*//////////////////////////////////////////////////////////////
                             REENTRANCY / CEI
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Повторный вход в claim() ничего не даёт.
     * @dev У $MACLRN нет хуков на трансфере, поэтому классический reentrancy
     *      структурно неисполним. Но контракт не должен полагаться на свойства
     *      другого контракта: атакующий здесь пытается войти повторно явно,
     *      и должен получить отказ и на CEI (награда уже обнулена), и на
     *      nonReentrant.
     */
    function test_Reentrancy_ClaimCannotBeDrained() public {
        ReentrantClaimer attacker = new ReentrantClaimer(emission, token);

        vm.prank(genesis);
        token.transfer(address(attacker), 1000e18);

        attacker.stakeAll();
        vm.warp(start + WEEK);

        uint256 entitled = emission.earned(address(attacker));
        attacker.attack();

        assertEq(token.balanceOf(address(attacker)), entitled, unicode"получил ровно своё");
        assertGe(
            token.balanceOf(address(emission)),
            emission.totalStaked(),
            unicode"пул эмиссии не выпотрошен"
        );
    }

    /**
     * @notice Частое начисление мелкими отрезками не съедает хвост ряда.
     *
     * @dev Сценарий грифинга: атакующий каждый блок дёргает функцию, которая
     *      двигает аккумулятор, дробя эпоху на двухсекундные отрезки. Если
     *      округлять награду отрезка до целых wei ДО перевода в единицы
     *      аккумулятора, то на поздних эпохах 2 * 2 / 604800 == 0, и весь
     *      хвост ряда обнуляется. Суммы там мизерные, но обнуляется ровно то,
     *      ради чего концепт и построен.
     *
     *      Сравниваем два пути через одну и ту же эпоху: одним скачком и
     *      сотней мелких шагов. Результат обязан совпасть.
     */
    function test_FragmentedAccrual_DoesNotDestroyTail() public {
        _stake(alice, 1000e18);

        // Эталон: проходим последнюю эпоху одним скачком.
        vm.warp(emission.epochEndsAt(25));
        uint256 baseline = emission.earned(alice);
        vm.warp(emission.epochEndsAt(26));
        uint256 wholeJump = emission.earned(alice) - baseline;

        // Тот же отрезок в свежем контракте, но аккумулятор двигается сто раз.
        vm.warp(1_700_000_000);
        MaclaurinEmission e2 = new MaclaurinEmission(genesis, vault, block.timestamp);
        MaclaurinToken t2 = e2.token();
        uint256 s2 = block.timestamp;

        vm.startPrank(genesis);
        t2.approve(address(e2), type(uint256).max);
        e2.stake(1000e18, 1);
        t2.transfer(bob, 1e18);
        vm.stopPrank();

        vm.prank(bob);
        t2.approve(address(e2), type(uint256).max);

        vm.warp(s2 + 24 * WEEK); // начало эпохи 26
        uint256 before = e2.earned(genesis);

        // Грифер дробит эпоху: stake(1)+unstake(1) форсируют _accrue(), но
        // к моменту замера его доля равна нулю и пропорцию не искажает.
        uint256 step = WEEK / 100;
        for (uint256 i = 0; i < 100; ++i) {
            vm.warp(s2 + 24 * WEEK + (i + 1) * step);
            vm.startPrank(bob);
            e2.stake(1, 1);
            e2.unstake(1);
            vm.stopPrank();
        }

        uint256 fragmented = e2.earned(genesis) - before;

        assertEq(wholeJump, 2, unicode"эпоха 26 = 2 wei одним скачком");
        assertEq(
            fragmented, wholeJump, unicode"дробление не должно стирать хвост"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     FLASH LOAN / ДОНАТ / ПЕРЕПОЛНЕНИЕ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Флеш-лоан не даёт ничего.
     *
     * @dev Сценарий атаки: занять флеш-лоаном огромный объём $MACLRN,
     *      застейкать, заклеймить награду, выйти и вернуть заём — всё в одной
     *      транзакции. Так выносят протоколы, где награда считается от
     *      мгновенного состояния (доля в моменте, снапшот на блоке).
     *
     *      Здесь это структурно невозможно: `stake` в модификаторе `update`
     *      ставит `userRewardPerTokenPaid` = текущему аккумулятору, а
     *      аккумулятор двигается только временем. В той же транзакции
     *      block.timestamp тот же, delta == 0, награда == 0.
     *
     *      Это свойство архитектуры, а не проверка в коде — обойти его нечем.
     */
    function test_FlashLoan_StakeAndClaimSameBlock_EarnsNothing() public {
        // Дать эмиссии поработать, чтобы аккумулятор был заведомо ненулевым.
        _stake(alice, 1000e18);
        vm.warp(start + 3 * WEEK);

        uint256 huge = token.balanceOf(bob);
        vm.startPrank(bob);
        // «Занял и застейкал» — с максимальным радиусом, чтобы попытка была
        // самой выгодной из возможных: множитель 2.718x.
        emission.stake(huge, 7);
        assertEq(emission.earned(bob), 0, unicode"в том же блоке награды нет");

        // Со второй фазы сюда добавился ещё один рубеж: claim закрыт локом.
        // Даже если бы delta была ненулевой, вынести награду в той же
        // транзакции нельзя — лок кончится через 49 дней, а флеш-заём нужно
        // вернуть в этом же блоке.
        vm.expectRevert(
            abi.encodeWithSelector(MaclaurinEmission.StillLocked.selector, block.timestamp + 7 * WEEK)
        );
        emission.claim();

        emission.unstake(huge); // «вернул заём» — тело отдают всегда
        vm.stopPrank();

        assertEq(token.balanceOf(bob), huge, unicode"ушёл ровно с тем, с чем пришёл");
    }

    /**
     * @notice Прямой перевод токенов на контракт не влияет на награды.
     *
     * @dev Классическая дыра: считать награду от `balanceOf(address(this))`.
     *      Тогда любой может «задонатить» токены и раздуть выплаты — а здесь
     *      это было бы вдвойне опасно, потому что контракт держит принципал
     *      стейкеров в том же токене, и раздутые награды съедали бы чужие
     *      депозиты. Поэтому весь учёт идёт по явным счётчикам.
     */
    function test_Donation_DoesNotInflateRewards() public {
        _stake(alice, 1000e18);
        vm.warp(start + WEEK);

        uint256 expected = emission.earned(alice);

        vm.prank(carol);
        token.transfer(address(emission), 500_000e18); // донат

        assertEq(emission.earned(alice), expected, unicode"донат не меняет награду");
        assertEq(emission.totalStaked(), 1000e18, unicode"донат не стал стейком");
    }

    /**
     * @notice Опоздавший не получает награду за прошедшее время.
     * @dev Обратная проверка к донату: `userRewardPerTokenPaid` фиксируется
     *      в момент стейка, поэтому ретроактивно забрать чужое нельзя.
     */
    function test_LateStaker_CannotClaimPastEmission() public {
        _stake(alice, 1000e18);
        vm.warp(start + 2 * WEEK);

        _stake(bob, 1_000_000e18); // огромный стейк, но поздно
        assertEq(emission.earned(bob), 0, unicode"прошлое не достаётся");
        assertEq(emission.earned(alice), emission.epochAmount(2) + emission.epochAmount(3));
    }

    /**
     * @notice Крайний случай для арифметики: одинокий стейкер в 1 wei
     *         раздувает аккумулятор до максимума, после чего входит кит.
     *
     * @dev Именно здесь переполнился бы `staked * delta`, если бы масштаб
     *      ACC_PRECISION был выбран без запаса. Проверяем, что транзакции
     *      проходят и обязательства остаются покрытыми.
     */
    function test_DustStakerThenWhale_NoOverflow() public {
        _stake(alice, 1); // 1 wei, единственный стейкер

        vm.warp(start + 12 * WEEK); // полэмиссии аккумулятор растёт с total = 1

        uint256 whale = token.balanceOf(genesis);
        vm.startPrank(genesis);
        token.approve(address(emission), whale);
        emission.stake(whale, 1);
        vm.stopPrank();

        vm.warp(emission.emissionEnd() + 1);

        uint256 aliceEarned = emission.earned(alice);
        uint256 whaleEarned = emission.earned(genesis);

        assertGt(aliceEarned, 0);
        assertLe(
            aliceEarned + whaleEarned, SPEC_EMITTABLE, unicode"суммарно не больше ряда"
        );

        // Обе выплаты реально проходят.
        vm.prank(alice);
        emission.claim();
        vm.prank(genesis);
        emission.claim();

        assertGe(token.balanceOf(address(emission)), emission.totalStaked());
    }

    /*//////////////////////////////////////////////////////////////
                                  ФАЗЗ
    //////////////////////////////////////////////////////////////*/

    /// @notice При любых суммах и таймингах принципал возвращается целиком.
    function testFuzz_PrincipalAlwaysFullyReturnable(uint256 amount, uint256 delay) public {
        amount = bound(amount, 1, 1_000_000e18);
        delay = bound(delay, 0, 400 days);

        uint256 before = token.balanceOf(alice);
        _stake(alice, amount);

        vm.warp(start + delay);

        vm.prank(alice);
        emission.unstake(amount);

        assertEq(token.balanceOf(alice), before, unicode"принципал не тронут");
    }

    /// @notice Сумма выплат никогда не превышает сумму ряда.
    function testFuzz_PayoutNeverExceedsSeries(uint256 a, uint256 b, uint256 delay) public {
        a = bound(a, 1e18, 1_000_000e18);
        b = bound(b, 1e18, 1_000_000e18);
        delay = bound(delay, 1, 400 days);

        _stake(alice, a);
        _stake(bob, b);
        vm.warp(start + delay);

        uint256 total = emission.earned(alice) + emission.earned(bob) + emission.unallocated();
        assertLe(
            total,
            SPEC_EMITTABLE,
            unicode"нельзя раздать больше, чем есть в ряду"
        );
    }

    /// @notice Двое с одинаковым стейком за одно время получают одинаково.
    function testFuzz_EqualStakes_EarnEqually(uint256 amount, uint256 delay) public {
        amount = bound(amount, 1e18, 1_000_000e18);
        delay = bound(delay, 1, 175 days);

        _stake(alice, amount);
        _stake(bob, amount);
        vm.warp(start + delay);

        assertApproxEqAbs(emission.earned(alice), emission.earned(bob), 1);
    }

    /*//////////////////////////////////////////////////////////////
                                ХЕЛПЕРЫ
    //////////////////////////////////////////////////////////////*/

    /// @dev Стейк с минимальным радиусом. R=1 — это ровно поведение фазы 1:
    ///      множитель 1.0x и лок в одну эпоху. Тесты этого файла проверяют
    ///      базовую механику эмиссии, поэтому радиус здесь везде минимальный;
    ///      всё, что касается множителей и локов, живёт в MaclaurinRadius.t.sol.
    function _stake(address user, uint256 amount) internal {
        _stake(user, amount, 1);
    }

    function _stake(address user, uint256 amount, uint256 radius) internal {
        vm.prank(user);
        emission.stake(amount, radius);
    }
}

/**
 * @dev Атакующий контракт: пытается войти в claim() повторно из своего
 *      receive-хука и напрямую, вторым вызовом внутри той же транзакции.
 */
contract ReentrantClaimer {
    MaclaurinEmission private immutable emission;
    MaclaurinToken private immutable token;
    bool private reentered;

    constructor(MaclaurinEmission e, MaclaurinToken t) {
        emission = e;
        token = t;
    }

    function stakeAll() external {
        uint256 bal = token.balanceOf(address(this));
        token.approve(address(emission), bal);
        emission.stake(bal, 1);
        emission.unstake(bal); // выходим, награда остаётся начисляться? нет — фиксируется
        token.approve(address(emission), bal);
        emission.stake(bal, 1);
    }

    function attack() external {
        emission.claim();
        // Повторный вызов в той же транзакции: награда уже обнулена (CEI),
        // поэтому получаем NothingToClaim, а не второй перевод.
        try emission.claim() {
            revert(unicode"reentrancy succeeded — CEI broken");
        } catch {}
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try emission.claim() {} catch {}
        }
    }
}
