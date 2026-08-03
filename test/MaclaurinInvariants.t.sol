// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

/**
 * @dev Хендлер — единственная точка входа для фаззера. Он бьёт по контракту
 *      случайными последовательностями действий со случайными скачками
 *      времени, а инвариантный тест после каждого шага проверяет свойства,
 *      которые обязаны выполняться ВСЕГДА.
 *
 *      Смысл именно в последовательностях: одиночные тесты проверяют сценарии,
 *      которые придумал автор. Инварианты ловят то, что автор не придумал —
 *      например «стейк, скачок через конец эмиссии, claim, снова стейк, sweep».
 */
contract Handler is Test {
    MaclaurinEmission public immutable emission;
    MaclaurinToken public immutable token;

    address[4] public actors;
    uint256 public totalPaidOut;

    constructor(MaclaurinEmission e, MaclaurinToken t, address[4] memory a) {
        emission = e;
        token = t;
        actors = a;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Радиус берётся случайным, но не ниже текущего — контракт такой
    ///      стейк отвергает по построению (иначе лок разбавлялся бы пылью),
    ///      и фаззер тратил бы шаги на заведомо ревертящий вызов.
    function stake(uint256 actorSeed, uint256 amount, uint256 radiusSeed) external {
        address a = _actor(actorSeed);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        (, uint256 currentRadius,,) = emission.positions(a);
        uint256 floorRadius = currentRadius == 0 ? 1 : currentRadius;
        uint256 radius = bound(radiusSeed, floorRadius, emission.MAX_RADIUS());

        vm.prank(a);
        emission.stake(amount, radius);
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 staked = emission.stakedOf(a);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);

        vm.prank(a);
        emission.unstake(amount);
    }

    function claim(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        if (emission.earned(a) == 0) return;
        if (emission.isLocked(a)) return; // до unlockTime claim закрыт

        uint256 before = token.balanceOf(a);
        vm.prank(a);
        emission.claim();
        totalPaidOut += token.balanceOf(a) - before - 0;
    }

    /// @dev Сброс множителя истёкшей позиции. Permissionless, поэтому зовёт
    ///      его произвольный актор по произвольной жертве — ровно так, как
    ///      это будет происходить в мейннете.
    function poke(uint256 targetSeed) external {
        address target = _actor(targetSeed);
        if (!emission.isPokeable(target)) return;

        emission.poke(target);
    }

    function exit(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        if (emission.stakedOf(a) == 0 && emission.earned(a) == 0) return;

        vm.prank(a);
        emission.exit();
    }

    function sweep() external {
        if (emission.pendingUnallocated() == 0) return;
        emission.sweepToRemainderVault();
    }

    /// @dev Скачки времени — от минут до месяцев, чтобы фаззер проходил и
    ///      внутри эпох, и через границы, и через конец эмиссии целиком.
    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 40 days));
    }
}

contract MaclaurinInvariantsTest is Test {
    MaclaurinEmission internal emission;
    MaclaurinToken internal token;
    Handler internal handler;

    address internal genesis = makeAddr("genesis");
    address internal vault = makeAddr("remainderVault");
    address[4] internal actors;

    uint256 internal constant SPEC_TOTAL_SUPPLY = 2718281828459045235360287471;
    uint256 internal constant SPEC_EMITTABLE = 718281828459045235360287457;

    function setUp() public {
        vm.warp(1_700_000_000);
        emission = new MaclaurinEmission(genesis, vault, block.timestamp);
        token = emission.token();

        actors = [makeAddr("a1"), makeAddr("a2"), makeAddr("a3"), makeAddr("a4")];

        for (uint256 i = 0; i < actors.length; ++i) {
            vm.prank(genesis);
            token.transfer(actors[i], 100_000e18);
            vm.prank(actors[i]);
            token.approve(address(emission), type(uint256).max);
        }

        handler = new Handler(emission, token, actors);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                               ИНВАРИАНТЫ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ПЛАТЁЖЕСПОСОБНОСТЬ. Контракт всегда способен вернуть каждому
     *         стейкеру его принципал И выплатить всю начисленную награду.
     *
     * @dev Самый важный инвариант. Если он падает, то последний пользователь
     *      в очереди не сможет ничего забрать — его транзакция будет реверить
     *      вечно, а исправить неизменяемый контракт нельзя.
     */
    function invariant_ContractIsAlwaysSolvent() public view {
        uint256 obligations = emission.totalStaked() + emission.pendingUnallocated();
        for (uint256 i = 0; i < actors.length; ++i) {
            obligations += emission.earned(actors[i]);
        }
        assertGe(
            token.balanceOf(address(emission)),
            obligations,
            unicode"контракт обязан покрывать все обязательства"
        );
    }

    /**
     * @notice Принципал стейкеров неприкосновенен: баланс контракта никогда
     *         не опускается ниже суммы всех стейков.
     * @dev Контракт держит пул эмиссии и принципал в одном токене. Именно
     *      поэтому нигде не используется balanceOf для расчётов — иначе
     *      награды считались бы от чужих денег.
     */
    function invariant_PrincipalIsNeverSpent() public view {
        assertGe(token.balanceOf(address(emission)), emission.totalStaked());
    }

    /**
     * @notice Из ряда нельзя достать больше, чем в нём есть.
     * @dev Ограничение чисто арифметическое: каждый член округлён вниз,
     *      поэтому их сумма строго меньше пула на 14 wei.
     */
    function invariant_PayoutNeverExceedsSeries() public view {
        uint256 distributed = emission.totalClaimed() + emission.totalSwept() + emission.unallocated();
        for (uint256 i = 0; i < actors.length; ++i) {
            distributed += emission.earned(actors[i]);
        }
        assertLe(
            distributed, SPEC_EMITTABLE, unicode"больше суммы ряда раздать нельзя"
        );
    }

    /// @notice Сапплай неизменен при любой последовательности действий.
    function invariant_TotalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SPEC_TOTAL_SUPPLY);
    }

    /// @notice Учёт стейков сходится: сумма долей равна общему счётчику.
    function invariant_StakeAccountingReconciles() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; ++i) {
            sum += emission.stakedOf(actors[i]);
        }
        assertEq(sum, emission.totalStaked());
    }

    /**
     * @notice Учёт весов сходится: сумма весов позиций равна totalWeight.
     *
     * @dev totalWeight — делитель, по которому раздаётся ВСЯ эмиссия. Если он
     *      разойдётся с суммой весов хотя бы на единицу, разойдётся и вся
     *      экономика: при завышенном totalWeight часть ряда не достанется
     *      никому, при заниженном контракт пообещает больше, чем держит, и
     *      последняя выплата будет реверить вечно.
     */
    function invariant_WeightAccountingReconciles() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; ++i) {
            sum += emission.weightOf(actors[i]);
        }
        assertEq(sum, emission.totalWeight(), unicode"сумма весов != totalWeight");
    }

    /**
     * @notice Вес каждой позиции равен телу, умноженному на множитель её
     *         радиуса. Проверяется после любой последовательности действий,
     *         включая частичные выходы, повторные стейки и poke.
     */
    function invariant_WeightMatchesRadius() public view {
        for (uint256 i = 0; i < actors.length; ++i) {
            (uint256 staked, uint256 radius,, uint256 weight) = emission.positions(actors[i]);
            if (staked == 0) {
                assertEq(weight, 0, unicode"пустая позиция с ненулевым весом");
                assertEq(radius, 0, unicode"пустая позиция с радиусом");
                continue;
            }
            assertEq(
                weight,
                staked * emission.multiplier(radius) / 1e18,
                unicode"вес != тело * множитель"
            );
        }
    }

    /// @notice Вес никогда не меньше тела и никогда не больше тела × e.
    /// @dev Верхняя граница — та самая, из которой считался запас
    ///      ACC_PRECISION до потолка uint256.
    function invariant_WeightIsBoundedByE() public view {
        for (uint256 i = 0; i < actors.length; ++i) {
            uint256 staked = emission.stakedOf(actors[i]);
            uint256 weight = emission.weightOf(actors[i]);
            assertGe(weight, staked, unicode"вес не может быть меньше тела");
            assertLe(weight, staked * emission.E_FIXED() / 1e18, unicode"вес выше потолка e");
        }
    }

    /// @notice Аккумулятор монотонно неубывающий — награда не может «отмотаться».
    function invariant_AccumulatorNeverDecreases() public view {
        assertGe(emission.rewardPerToken(), emission.rewardPerTokenStored());
    }

    /// @notice После конца эмиссии новых начислений не появляется.
    function invariant_NoEmissionAfterEnd() public view {
        if (!emission.emissionFinished()) return;
        assertLe(emission.totalClaimed() + emission.totalSwept(), SPEC_EMITTABLE);
    }
}
