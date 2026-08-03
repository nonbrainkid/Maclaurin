// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MaclaurinCurve} from "../src/MaclaurinCurve.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

/**
 * @title CurveProbe
 * @notice Независимые пробы на кривую, написанные при ревью.
 *
 * @dev Тесты кривой писал тот же агент, что и контракт. Пробы ниже идут не
 *      от кода, а от одного вопроса: может ли человек, купивший последним,
 *      не получить свои деньги обратно. Это единственный отказ, который
 *      нельзя починить — контракт неизменяем.
 */
contract CurveProbe is Test {
    MaclaurinToken token;
    MaclaurinCurve curve;

    address genesis = makeAddr("genesis");
    address feeRecipient = makeAddr("feeRecipient");

    uint256 constant INVENTORY = 1e27;
    uint256 constant FAR = type(uint256).max;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MaclaurinToken(genesis, makeAddr("emission"));
        curve = new MaclaurinCurve(IERC20(address(token)), feeRecipient);
        vm.prank(genesis);
        token.transfer(address(curve), INVENTORY);
        // Уходим за окно анти-снайпа: оно не предмет этих проб.
        vm.warp(block.timestamp + 2 hours);
    }

    function _buy(address who, uint256 ethIn) internal returns (uint256 got) {
        vm.deal(who, ethIn);
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        curve.buy{value: ethIn}(1, FAR);
        got = token.balanceOf(who) - before;
    }

    /*//////////////////////////////////////////////////////////////
        1. ПОСЛЕДНИЙ ПРОДАВЕЦ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Двадцать покупателей заходят разными суммами, затем ВСЕ выходят
     *         по очереди. Последний обязан получить деньги.
     *
     * @dev Это тот самый отказ, ради которого в спеке §4.1 запрещено брать
     *      комиссию из резерва: он проявляется не в момент ошибки, а через
     *      недели, когда кто-то попытается выйти последним. Если резерв
     *      недосчитается хоть wei, его транзакция будет реверить вечно.
     */
    function test_probe_LastSellerAlwaysGetsPaid() public {
        address[20] memory buyers;
        uint256[20] memory holdings;

        for (uint256 i = 0; i < 20; ++i) {
            buyers[i] = address(uint160(0x1000 + i));
            holdings[i] = _buy(buyers[i], (i + 1) * 0.013 ether);
        }

        // Выходят в том же порядке — последнему достаётся то, что осталось.
        for (uint256 i = 0; i < 20; ++i) {
            vm.startPrank(buyers[i]);
            token.approve(address(curve), holdings[i]);
            uint256 ethBefore = buyers[i].balance;
            curve.sell(holdings[i], 1, FAR);
            vm.stopPrank();
            assertGt(buyers[i].balance, ethBefore, unicode"продавец не получил ETH");
        }

        assertEq(curve.sold(), 0, unicode"всё выкуплено обратно");
        assertGe(
            address(curve).balance,
            curve.feesAccrued() - curve.feesWithdrawn(),
            unicode"баланс не покрывает несобранную комиссию"
        );
    }

    /// @notice Тот же сценарий, но выходят в обратном порядке.
    /// @dev Порядок выхода не должен влиять: если он влияет, значит учёт
    ///      зависит от истории, а не от состояния.
    function test_probe_ReverseExitOrderAlsoWorks() public {
        address[10] memory buyers;
        uint256[10] memory holdings;
        for (uint256 i = 0; i < 10; ++i) {
            buyers[i] = address(uint160(0x2000 + i));
            holdings[i] = _buy(buyers[i], 0.02 ether);
        }
        for (uint256 i = 10; i > 0; --i) {
            uint256 j = i - 1;
            vm.startPrank(buyers[j]);
            token.approve(address(curve), holdings[j]);
            curve.sell(holdings[j], 1, FAR);
            vm.stopPrank();
        }
        assertEq(curve.sold(), 0);
    }

    /*//////////////////////////////////////////////////////////////
        2. КРИВУЮ НЕЛЬЗЯ ДОИТЬ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Круг «купил и сразу продал» обязан быть убыточным всегда.
     *
     * @dev Если хоть на каком-то размере круг выходит в плюс, кривая
     *      превращается в бесплатный насос: бот повторяет его в цикле и
     *      осушает резерв, ничем не рискуя.
     */
    function test_probe_RoundTripIsAlwaysUnprofitable() public {
        uint256[6] memory sizes = [uint256(1 wei), 1 gwei, 0.0001 ether, 0.01 ether, 0.1 ether, 0.5 ether];

        for (uint256 i = 0; i < sizes.length; ++i) {
            address a = address(uint160(0x3000 + i));
            vm.deal(a, sizes[i]);
            vm.prank(a);
            try curve.buy{value: sizes[i]}(1, FAR) {}
            catch {
                continue; // слишком мало для ненулевой покупки — не наш случай
            }
            uint256 got = token.balanceOf(a);
            if (got == 0) continue;

            vm.startPrank(a);
            token.approve(address(curve), got);
            curve.sell(got, 1, FAR);
            vm.stopPrank();

            assertLt(
                a.balance,
                sizes[i],
                unicode"круг вышел в плюс — кривую можно доить"
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
        3. ДОНАТ И ПРИНУДИТЕЛЬНЫЙ ETH
    //////////////////////////////////////////////////////////////*/

    /// @notice Насильно присланный ETH не меняет ни цену, ни выплаты.
    /// @dev Классика: расчёт от address(this).balance ломается доначислением
    ///      извне. selfdestruct пришлёт ETH даже без receive().
    function test_probe_ForcedEthDoesNotAffectPricing() public {
        _buy(makeAddr("someone"), 0.05 ether);

        uint256 priceBefore = curve.spotPrice();
        uint256 quoteBefore = curve.quoteSellGross(1e21);
        uint256 reserveBefore = curve.reserve();

        vm.deal(address(curve), address(curve).balance + 100 ether);

        assertEq(curve.spotPrice(), priceBefore, unicode"донат сдвинул цену");
        assertEq(curve.quoteSellGross(1e21), quoteBefore, unicode"донат сдвинул выплату");
        assertEq(curve.reserve(), reserveBefore, unicode"донат попал в резерв");
    }

    /*//////////////////////////////////////////////////////////////
        4. КОМИССИЯ НЕ ЕСТ РЕЗЕРВ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Вывод комиссии не должен уменьшать способность кривой выкупить
     *         выпущенные токены.
     *
     * @dev Проверяю в самом опасном порядке: сначала создатель забирает всю
     *      комиссию, и только потом держатели пытаются выйти. Если комиссия
     *      хоть частично бралась из резерва, здесь всё развалится.
     */
    function test_probe_FeeWithdrawalCannotStarveReserve() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        uint256 ga = _buy(a, 0.3 ether);
        uint256 gb = _buy(b, 0.2 ether);

        curve.withdrawFees();
        assertGt(feeRecipient.balance, 0, unicode"комиссия не дошла");

        vm.startPrank(a);
        token.approve(address(curve), ga);
        curve.sell(ga, 1, FAR);
        vm.stopPrank();

        vm.startPrank(b);
        token.approve(address(curve), gb);
        curve.sell(gb, 1, FAR);
        vm.stopPrank();

        assertEq(curve.sold(), 0, unicode"выкуплено не всё");
        assertGt(a.balance, 0);
        assertGt(b.balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
        5. ДРОБЛЕНИЕ СДЕЛОК
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Сто мелких покупок не должны дать больше токенов, чем одна
     *         крупная на ту же сумму.
     *
     * @dev Если округление где-то идёт в пользу пользователя, дробление
     *      становится бесплатной добавкой, а резерв недосчитывается по wei
     *      на каждой сделке. Автор контракта утверждает, что покупка платит
     *      ceil именно поэтому — проверяю независимо.
     */
    function test_probe_SplittingBuysGivesNoAdvantage() public {
        uint256 total = 0.1 ether;

        address whole = makeAddr("whole");
        uint256 gotWhole = _buy(whole, total);

        MaclaurinCurve c2 = new MaclaurinCurve(IERC20(address(token)), feeRecipient);
        vm.prank(genesis);
        token.transfer(address(c2), INVENTORY);
        vm.warp(block.timestamp + 2 hours);

        address split = makeAddr("split");
        vm.deal(split, total);
        uint256 chunk = total / 100;
        for (uint256 i = 0; i < 100; ++i) {
            vm.prank(split);
            c2.buy{value: chunk}(1, FAR);
        }
        uint256 gotSplit = token.balanceOf(split);

        assertLe(gotSplit, gotWhole, unicode"дробление даёт преимущество");
        emit log_named_uint("whole buy tokens", gotWhole);
        emit log_named_uint("split buy tokens", gotSplit);
    }

    /*//////////////////////////////////////////////////////////////
        6. РЕГРЕССИЯ НА КРАЖУ РЕЗЕРВА
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Держатель токенов, не покупавший у кривой, не может забрать
     *         ETH покупателя. Регрессия на найденную при ревью дыру.
     *
     * @dev До фикса этот сценарий проходил и обнулял покупателя: посторонний
     *      продавал в кривую токены, полученные бесплатно, забирал 0.9801 ETH
     *      из резерва, `sold` падал в ноль, и покупатель не мог выйти вообще.
     *      Формальная платёжеспособность при этом не нарушалась — обязательство
     *      равнялось `sold` и было покрыто. Инвариант выполнялся, деньги
     *      пропадали: он был сформулирован про контракт, а не про человека.
     */
    function test_probe_OutsiderCannotStealBuyerReserve() public {
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        curve.buy{value: 1 ether}(1, FAR);
        uint256 bought = token.balanceOf(buyer);
        uint256 reserveAfterBuy = curve.reserve();

        // Посторонний получает столько же токенов даром и пытается их слить.
        address outsider = makeAddr("outsider");
        vm.prank(genesis);
        token.transfer(outsider, bought);

        vm.startPrank(outsider);
        token.approve(address(curve), bought);
        vm.expectRevert();
        curve.sell(bought, 1, FAR);
        vm.stopPrank();

        assertEq(outsider.balance, 0, unicode"посторонний вынес ETH из резерва");
        assertEq(curve.reserve(), reserveAfterBuy, unicode"резерв уменьшился");

        // А покупатель по-прежнему выходит целиком.
        vm.startPrank(buyer);
        token.approve(address(curve), bought);
        curve.sell(bought, 1, FAR);
        vm.stopPrank();

        assertGt(
            buyer.balance, 0.97 ether, unicode"покупатель не вернул свои деньги"
        );
        emit log_named_uint("buyer recovered (wei)", buyer.balance);
    }
}
