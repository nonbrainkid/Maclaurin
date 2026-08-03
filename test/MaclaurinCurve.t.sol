// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MaclaurinCurve} from "../src/MaclaurinCurve.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

/*//////////////////////////////////////////////////////////////
                      ВСПОМОГАТЕЛЬНЫЕ КОНТРАКТЫ
//////////////////////////////////////////////////////////////*/

/// @dev Пытается войти в `sell` повторно из `receive`. Ошибку глотает, чтобы
///      внешняя продажа завершилась и стало видно: повторный вход отбит, а
///      честная выплата прошла ровно один раз.
contract SellReenterer {
    MaclaurinCurve public immutable curve;
    IERC20 public immutable token;

    bool public attempted;
    bool public reentryReverted;
    uint256 public received;

    constructor(MaclaurinCurve c, IERC20 t) {
        curve = c;
        token = t;
        t.approve(address(c), type(uint256).max);
    }

    function buy(uint256 value) external payable returns (uint256) {
        return curve.buy{value: value}(1, block.timestamp);
    }

    function sell(uint256 amount) external returns (uint256) {
        return curve.sell(amount, 1, block.timestamp);
    }

    receive() external payable {
        received += msg.value;
        if (!attempted) {
            attempted = true;
            try curve.sell(1e18, 1, block.timestamp) returns (uint256) {}
            catch {
                reentryReverted = true;
            }
        }
    }
}

/// @dev Кошелёк, который не принимает ETH. Нужен, чтобы убедиться: неудачный
///      перевод ревертит всю продажу, а не съедает токены молча.
contract EthRejector {
    MaclaurinCurve public immutable curve;

    constructor(MaclaurinCurve c, IERC20 t) {
        curve = c;
        t.approve(address(c), type(uint256).max);
    }

    function buy(uint256 value) external payable returns (uint256) {
        return curve.buy{value: value}(1, block.timestamp);
    }

    function sell(uint256 amount) external returns (uint256) {
        return curve.sell(amount, 1, block.timestamp);
    }

    receive() external payable {
        revert("no eth");
    }
}

/*//////////////////////////////////////////////////////////////
                            ЮНИТ-ТЕСТЫ
//////////////////////////////////////////////////////////////*/

contract MaclaurinCurveTest is Test {
    MaclaurinToken internal token;
    MaclaurinCurve internal curve;

    address internal genesis = makeAddr("genesis");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant INVENTORY = 1_000_000_000e18;
    uint256 internal constant SPEC_E = 2_718_281_828_459_045_235;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MaclaurinToken(genesis, makeAddr("emission"));
        curve = new MaclaurinCurve(IERC20(address(token)), feeRecipient);

        vm.prank(genesis);
        token.transfer(address(curve), INVENTORY);

        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; ++i) {
            vm.prank(users[i]);
            token.approve(address(curve), type(uint256).max);
        }

        // Окно анти-снайпа мешает почти всем сценариям (лимит — 1% инвентаря,
        // это ~0.02 ETH). Тесты самого окна разворачивают свою кривую.
        vm.warp(block.timestamp + curve.ANTI_SNIPE_WINDOW() + 1);
    }

    function _buy(address who, uint256 value) internal returns (uint256) {
        vm.deal(who, who.balance + value);
        vm.prank(who);
        return curve.buy{value: value}(1, block.timestamp);
    }

    function _sell(address who, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return curve.sell(amount, 1, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
        1. КОНСТАНТЫ: ЦЕНА РАСТЁТ РОВНО В e РАЗ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Главное утверждение §2.2: p(S)/p(0) == e, БЕЗ остатка.
     *
     * @dev Именно «без остатка» здесь и проверяется. Отношение, совпадающее с
     *      e в первых 15 разрядах, — это «примерно e», и тезис проекта
     *      («не обещание, а арифметика») на нём не держится. Деление обязано
     *      быть точным, иначе константы подобраны неверно.
     */
    function test_Const_PriceRatioIsExactlyE() public view {
        uint256 p0 = curve.priceAt(0);
        uint256 pS = curve.priceAt(INVENTORY);

        assertEq(p0, curve.P0(), unicode"цена в нуле");
        assertEq(pS, curve.P_FINAL(), unicode"цена на конце инвентаря");
        assertEq(
            (pS * 1e18) % p0, 0, unicode"отношение обязано делиться нацело"
        );
        assertEq((pS * 1e18) / p0, SPEC_E, unicode"p(S)/p(0) != e");
        assertEq(curve.E_FIXED(), SPEC_E, unicode"константа e разошлась со спекой");
    }

    /// @notice Наклон совпадает с формулой спеки K = P0·(e−1)/(S·1e18):
    ///         числитель SLOPE == P0·(E_FIXED − 1e18)/1e18, деление точное.
    function test_Const_SlopeMatchesSpecFormula() public view {
        uint256 p0 = curve.P0();
        assertEq((p0 * (SPEC_E - 1e18)) % 1e18, 0, unicode"наклон обязан быть целым");
        assertEq(curve.SLOPE(), (p0 * (SPEC_E - 1e18)) / 1e18, unicode"SLOPE != P0(e-1)/1e18");
        assertEq(curve.SLOPE(), curve.P_FINAL() - curve.P0(), unicode"SLOPE != P_FINAL - P0");
    }

    /// @notice Побочное точное равенство: весь инвентарь стоит ровно (1+e) ETH.
    function test_Const_TotalRaiseIsEPlusOne() public view {
        assertEq(curve.TOTAL_RAISE(), 3_718_281_828_459_045_235, unicode"(1+e) ETH");
        assertEq(curve.TOTAL_RAISE(), SPEC_E + 1e18, unicode"TOTAL_RAISE != e + 1");
        assertEq(curve.quoteBuyCost(INVENTORY), curve.TOTAL_RAISE(), unicode"площадь != (1+e)");
    }

    /// @notice Цена одного целого токена — 2 gwei в начале, ~5.4366 gwei в конце.
    function test_Const_HumanReadablePrice() public {
        assertEq(curve.spotPrice(), 2 gwei, unicode"стартовая цена токена");
        _buy(alice, curve.maxEthIn());
        assertEq(curve.sold(), INVENTORY, unicode"инвентарь выкуплен целиком");
        assertEq(curve.spotPrice(), 5_436_563_656, unicode"конечная цена токена");
    }

    /*//////////////////////////////////////////////////////////////
        2. ПЕРЕПОЛНЕНИЕ (§2.3)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Оценка максимума произведения в формуле площади и запас до
     *         потолка uint256, посчитанные независимо от контракта.
     *
     * @dev Максимум достигается на самом широком отрезке [0, S]:
     *          (x2−x1)·(2·P0·S + SLOPE·(x1+x2)) = 7.4365...e71
     *      против 1.1579e77. Запас — 155 706 раз, то есть даже инвентарь,
     *      увеличенный в сто раз, формулу бы не переполнил.
     */
    function test_Overflow_MaxProductHasHeadroom() public view {
        uint256 costBase = 2 * curve.P0() * INVENTORY;
        uint256 maxNumerator = INVENTORY * (costBase + curve.SLOPE() * INVENTORY);

        assertEq(maxNumerator, 743_656_365_691_809_047 * 1e54, unicode"максимум числителя");
        assertGt(type(uint256).max / maxNumerator, 100_000, unicode"запас меньше 10^5");
    }

    /// @notice Границы области определения реально считаются, а не «должны бы».
    function test_Overflow_BoundaryQuotesAreComputable() public {
        assertEq(curve.quoteBuyCost(INVENTORY), curve.TOTAL_RAISE());

        _buy(alice, curve.maxEthIn());
        assertEq(curve.sold(), INVENTORY);

        // Обратный ход по всему инвентарю — второй экстремум того же произведения.
        assertEq(curve.quoteSellGross(INVENTORY), curve.TOTAL_RAISE(), unicode"выкуп всего");
        assertGe(curve.reserve(), curve.quoteSellGross(INVENTORY), unicode"резерв покрывает");
    }

    /// @notice Цена определена на всём [0, S] и не определена за ним.
    function testFuzz_PriceIsDefinedOnWholeDomain(uint256 x) public {
        x = bound(x, 0, INVENTORY);
        uint256 p = curve.priceAt(x);
        assertGe(p, curve.P0());
        assertLe(p, curve.P_FINAL());

        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.OutOfRange.selector, INVENTORY + 1));
        curve.priceAt(INVENTORY + 1);
    }

    /*//////////////////////////////////////////////////////////////
        3. ПОКУПКА
    //////////////////////////////////////////////////////////////*/

    function test_Buy_AccountingIsSplitBetweenReserveAndFees() public {
        uint256 value = 0.1 ether;
        uint256 got = _buy(alice, value);

        uint256 fee = (value * curve.FEE_BPS() + 9999) / 10_000;
        assertEq(curve.feesAccrued(), fee, unicode"комиссия начислена отдельно");
        assertEq(
            curve.reserve(),
            value - fee,
            unicode"в резерв ушло всё за вычетом комиссии"
        );
        assertEq(
            address(curve).balance,
            curve.reserve() + curve.feesAccrued(),
            unicode"баланс сходится"
        );
        assertEq(token.balanceOf(alice), got, unicode"токены у покупателя");
        assertEq(curve.sold(), got, unicode"sold == выданному");
        assertEq(
            token.balanceOf(address(curve)), INVENTORY - got, unicode"инвентарь уменьшился"
        );
    }

    /// @notice Комиссия НИКОГДА не берётся из резерва: резерв всегда покрывает
    ///         обратный выкуп всего проданного, сразу после покупки тоже.
    function testFuzz_Buy_FeeIsNeverTakenFromReserve(uint256 value) public {
        value = bound(value, 1e6, curve.maxEthIn());
        _buy(alice, value);

        assertGe(
            curve.reserve(),
            curve.quoteSellGross(curve.sold()),
            unicode"резерв ниже обязательств"
        );
        assertEq(
            curve.reserve() + curve.feesAccrued(), value, unicode"деньги не потерялись"
        );
    }

    /**
     * @notice Двоичный поиск не оставляет сдачи: netIn расходуется до последнего wei.
     *
     * @dev Свойство неочевидное и приятное. Поиск находит максимальное d с
     *      costCeil(d) ≤ netIn; если бы costCeil(d+1) == costCeil(d), то d+1
     *      тоже подошло бы, значит шаг ровно 1 wei, значит netIn == costCeil(d).
     *      Иначе говоря, «пыль» покупателя не оседает в резерве никогда.
     */
    function testFuzz_Buy_LeavesNoChange(uint256 value) public view {
        value = bound(value, 1e6, curve.maxEthIn());
        (uint256 tokensOut,, uint256 netIn) = curve.previewBuy(value);
        assertEq(curve.quoteBuyCost(tokensOut), netIn, unicode"сдача осела в резерве");
    }

    function test_Buy_RevertsOnZeroValueAndZeroMin() public {
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(MaclaurinCurve.ZeroAmount.selector);
        curve.buy{value: 0}(1, block.timestamp);

        // minTokensOut == 0 — это «согласен на любой результат». Параметр
        // обязателен по существу, а не формально, поэтому ноль не принимается.
        vm.prank(alice);
        vm.expectRevert(MaclaurinCurve.ZeroAmount.selector);
        curve.buy{value: 1 ether}(0, block.timestamp);
    }

    function test_Buy_RevertsOnExpiredDeadline() public {
        vm.deal(alice, 1 ether);
        uint256 past = block.timestamp - 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.DeadlineExpired.selector, past));
        curve.buy{value: 1 ether}(1, past);
    }

    function test_Buy_RevertsOnSlippage() public {
        vm.deal(alice, 1 ether);
        (uint256 expected,,) = curve.previewBuy(1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.SlippageBuy.selector, expected, expected + 1));
        curve.buy{value: 1 ether}(expected + 1, block.timestamp);
    }

    /// @notice Сэндвич: бот покупает перед жертвой, цена растёт, жертва
    ///         защищена minTokensOut и получает revert вместо худшей цены.
    function test_Buy_SlippageStopsSandwich() public {
        (uint256 quoted,,) = curve.previewBuy(0.1 ether);

        _buy(bob, 0.5 ether); // фронт-ран

        vm.deal(alice, 0.1 ether);
        vm.prank(alice);
        vm.expectRevert();
        curve.buy{value: 0.1 ether}(quoted, block.timestamp);
    }

    /**
     * @notice Переплата сверх остатка инвентаря ревертит, а `maxEthIn`
     *         возвращает точную границу — на wei больше уже нельзя.
     */
    function test_Buy_MaxEthInIsExact() public {
        uint256 max = curve.maxEthIn();

        vm.deal(alice, max + 1);
        vm.prank(alice);
        vm.expectRevert();
        curve.buy{value: max + 1}(1, block.timestamp);

        vm.prank(alice);
        uint256 got = curve.buy{value: max}(1, block.timestamp);
        assertEq(got, INVENTORY, unicode"весь инвентарь одним вызовом");
        assertEq(curve.remainingInventory(), 0);
        assertGe(
            curve.reserve(), curve.TOTAL_RAISE(), unicode"резерв покрывает всю кривую"
        );
    }

    function test_Buy_RevertsWhenSoldOut() public {
        _buy(alice, curve.maxEthIn());

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        curve.buy{value: 1 ether}(1, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
        4. ПРОДАЖА — ГЛАВНОЕ СВОЙСТВО ДЛЯ ПОКУПАТЕЛЯ
    //////////////////////////////////////////////////////////////*/

    function test_Sell_ReturnsEthAndBurnsPosition() public {
        uint256 got = _buy(alice, 0.5 ether);
        uint256 reserveBefore = curve.reserve();

        uint256 gross = curve.quoteSellGross(got);
        uint256 out = _sell(alice, got);

        assertEq(curve.sold(), 0, unicode"кривая вернулась в начало");
        assertEq(token.balanceOf(alice), 0);
        assertEq(alice.balance, out, unicode"ETH дошёл до продавца");
        assertEq(
            curve.reserve(), reserveBefore - gross, unicode"из резерва списан ровно gross"
        );
        assertGe(address(curve).balance, curve.reserve() + curve.feesAccrued());
    }

    /**
     * @notice Продажа работает после ЛЮБОЙ последовательности сделок и для
     *         последнего продавца тоже. Это и есть проба на honeypot.
     */
    function testFuzz_Sell_AlwaysWorksAfterRandomTrades(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];

        for (uint256 i = 0; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address u = users[seed % 3];

            if (seed % 2 == 0) {
                uint256 hi = curve.maxEthIn();
                if (hi < 1e9) continue;
                uint256 value = bound(seed >> 8, 1e9, hi > 1 ether ? 1 ether : hi);
                _buy(u, value);
            } else {
                uint256 cap = token.balanceOf(u);
                if (cap > curve.sold()) cap = curve.sold();
                if (cap == 0) continue;
                uint256 amount = bound(seed >> 8, 1, cap);
                (uint256 out,) = curve.previewSell(amount);
                if (out == 0) continue;
                _sell(u, amount);
            }
        }

        // Теперь все выходят полностью — последнему обязано хватить резерва.
        for (uint256 i = 0; i < users.length; ++i) {
            uint256 bal = token.balanceOf(users[i]);
            if (bal == 0) continue;
            (uint256 out,) = curve.previewSell(bal);
            if (out == 0) continue;
            _sell(users[i], bal);
        }

        assertEq(curve.sold(), 0, unicode"всё выпущенное выкуплено обратно");
        assertLe(
            curve.reserve(),
            1000,
            unicode"в резерве осталась только пыль округления"
        );
        assertGe(address(curve).balance, curve.reserve() + curve.feesAccrued());
        assertEq(
            token.balanceOf(address(curve)),
            INVENTORY,
            unicode"инвентарь вернулся целиком"
        );
    }

    /**
     * @notice ВТОРОЙ РУБЕЖ `amount <= sold` не мёртвый.
     *
     * @dev Из Σ boughtOf == sold следует, что штатно эта проверка сработать не
     *      может: право адреса всегда не больше суммы прав, а сумма прав равна
     *      `sold`. Проверять её обычными вызовами поэтому нечем — и именно так
     *      незаметно умирает защита в глубину.
     *
     *      Поэтому равенство ломается насильно, записью прямо в слот
     *      `boughtOf` (слот 6, см. `forge inspect MaclaurinCurve storageLayout`).
     *      Это модель одного-единственного события: будущая правка контракта
     *      разошлась с инвариантом. Кривая обязана в этом случае отреветить,
     *      а не уйти в минус на вычитании `sold - amount`.
     */
    function test_Sell_ExceedsSoldIsTheSecondLine() public {
        uint256 got = _buy(alice, 0.1 ether);

        // Гипотетический разрыв учёта: право есть, а проданного столько нет.
        vm.store(address(curve), keccak256(abi.encode(alice, uint256(6))), bytes32(got + 1));
        assertEq(curve.boughtOf(alice), got + 1, unicode"подготовка разрыва учёта");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.ExceedsSold.selector, got + 1, got));
        curve.sell(got + 1, 1, block.timestamp);

        // Ровно проданное всё ещё продаётся: рубеж не мешает честной сделке.
        vm.prank(alice);
        curve.sell(got, 1, block.timestamp);
        assertEq(curve.sold(), 0);
    }

    /// @notice Котировка `quoteSellGross` по-прежнему ограничена `sold`:
    ///         она не знает, кто спрашивает, и обязана отвергать невозможное.
    function test_Quote_SellGrossStillBoundedBySold() public {
        uint256 got = _buy(alice, 0.1 ether);

        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.ExceedsSold.selector, got + 1, got));
        curve.quoteSellGross(got + 1);
    }

    /*//////////////////////////////////////////////////////////////
        4bis. ПРАВО ВЫКУПА ИМЕННОЕ — РЕЗЕРВ ПРИНАДЛЕЖИТ ПОКУПАТЕЛЯМ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice ГЛАВНЫЙ ТЕСТ ФИКСА. Держатель токенов, полученных не от кривой,
     *         не может продать ей ничего — и деньги покупателя остаются его.
     *
     * @dev Сценарий, который до фикса уносил ВЕСЬ ETH покупателя:
     *
     *          1. покупатель вносит 1.000 ETH
     *             -> reserve 0.990 ETH, sold = 374 503 207 786 020 143 771 730 036
     *          2. держатель genesis-доли продаёт кривой столько же токенов,
     *             не купив у неё ни одного
     *             -> забирает 0.9801 ETH, reserve = 1 wei, sold = 0
     *          3. покупатель вызывает sell -> РЕВЕРТ, выйти нельзя вообще
     *             -> вернул 0 ETH, остался с 374 млн токенов
     *
     *      Инвариант платёжеспособности при этом НЕ нарушался: обязательство
     *      равнялось `sold`, резерв его покрывал. Инвариант был не тот —
     *      деньги покупателя защищает только именное право выкупа.
     */
    function test_Sell_GenesisHolderCannotDrainBuyerReserve() public {
        // 1. Покупатель заходит на 1 ETH. Цифры зафиксированы: если кривая
        //    поедет, сценарий обязан переписываться осознанно.
        uint256 got = _buy(alice, 1 ether);
        assertEq(got, 374_503_207_786_020_143_771_730_036, unicode"токенов за 1 ETH");
        assertEq(curve.sold(), got, unicode"sold после покупки");
        assertEq(curve.reserve(), 0.99 ether, unicode"резерв после покупки");

        // 2. Держатель genesis получает ровно столько же токенов бесплатно.
        address mallory = makeAddr("mallory");
        vm.prank(genesis);
        token.transfer(mallory, got);
        vm.prank(mallory);
        token.approve(address(curve), type(uint256).max);

        // Продать кривой он не может ни всё, ни один wei.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.ExceedsPurchased.selector, got, 0));
        curve.sell(got, 1, block.timestamp);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.ExceedsPurchased.selector, 1, 0));
        curve.sell(1, 1, block.timestamp);

        assertEq(curve.reserve(), 0.99 ether, unicode"резерв не тронут");
        assertEq(curve.sold(), got, unicode"учёт не сдвинут");
        assertEq(mallory.balance, 0, unicode"посторонний не получил ни wei");
        assertEq(token.balanceOf(mallory), got, unicode"токены остались у него");

        // 3. Покупатель ВСЁ ЕЩЁ выходит полностью — ради этого всё и делалось.
        (uint256 expected,) = curve.previewSell(got);
        uint256 out = _sell(alice, got);

        assertEq(out, expected, unicode"выплата разошлась с котировкой");
        assertEq(out, 980_099_999_999_999_999, unicode"покупатель получил ~0.9801 ETH");
        assertEq(alice.balance, out, unicode"ETH дошёл до покупателя");
        assertEq(curve.sold(), 0, unicode"кривая вернулась в начало");
        assertEq(curve.boughtOf(alice), 0, unicode"право выкупа погашено");
        assertEq(curve.reserve(), 1, unicode"в резерве только пыль округления");
    }

    /// @notice Право выкупа не появляется у постороннего и после того, как
    ///         кривая пережила несколько чужих сделок.
    function test_Sell_OutsiderStaysLockedOutAfterOtherTrades() public {
        address mallory = makeAddr("mallory");
        vm.prank(genesis);
        token.transfer(mallory, 250_000_000e18); // маркетинг + резерв + хвост
        vm.prank(mallory);
        token.approve(address(curve), type(uint256).max);

        _buy(alice, 0.3 ether);
        _buy(bob, 0.7 ether);
        _sell(bob, token.balanceOf(bob) / 2);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.ExceedsPurchased.selector, 1e18, 0));
        curve.sell(1e18, 1, block.timestamp);

        assertEq(curve.boughtOf(mallory), 0, unicode"право не возникает само");
    }

    /**
     * @notice Покупатель возвращает кривой РОВНО купленное — до последнего wei,
     *         и ни одним wei больше.
     */
    function testFuzz_Sell_BuyerReturnsExactlyWhatHeBought(uint256 value, uint256 warmup) public {
        warmup = bound(warmup, 0, 2 ether);
        if (warmup > 1e6) _buy(carol, warmup);

        value = bound(value, 1e9, curve.maxEthIn() > 1 ether ? 1 ether : curve.maxEthIn());
        uint256 got = _buy(alice, value);
        vm.assume(got > 0);

        assertEq(curve.boughtOf(alice), got, unicode"право == купленному");

        // На один wei больше — отказ, даже если токенов на балансе хватает.
        vm.prank(genesis);
        token.transfer(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.ExceedsPurchased.selector, got + 1, got));
        curve.sell(got + 1, 1, block.timestamp);

        // Ровно купленное — проходит целиком.
        (uint256 expected,) = curve.previewSell(got);
        vm.assume(expected > 0);
        uint256 out = _sell(alice, got);

        assertEq(out, expected);
        assertEq(curve.boughtOf(alice), 0, unicode"право погашено полностью");
        assertEq(token.balanceOf(alice), 1, unicode"чужой wei остался чужим");
    }

    /**
     * @notice Обычный `transfer` токенов НЕ переносит право продажи.
     *
     * @dev Право живёт на адресе покупателя, а не на токенах: иначе учёт
     *      пришлось бы вести хуком в самом токене — уже развёрнутом и
     *      неизменяемом, — и право выкупа получал бы любой, кому токены
     *      просто переслали.
     */
    function test_Sell_TransferDoesNotCarryTheRight() public {
        uint256 got = _buy(alice, 0.4 ether);

        vm.prank(alice);
        token.transfer(bob, got);

        assertEq(
            curve.boughtOf(bob), 0, unicode"право переехало вместе с токенами"
        );
        assertEq(curve.boughtOf(alice), got, unicode"право продавца стёрлось");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.ExceedsPurchased.selector, got, 0));
        curve.sell(got, 1, block.timestamp);

        // У alice право есть, но нет токенов — продажа падает на переводе.
        vm.prank(alice);
        vm.expectRevert();
        curve.sell(got, 1, block.timestamp);

        // Токены вернулись — и выход снова открыт.
        vm.prank(bob);
        token.transfer(alice, got);
        uint256 out = _sell(alice, got);
        assertGt(out, 0, unicode"покупатель обязан выйти");
        assertEq(curve.sold(), 0);
    }

    /// @notice Частичные продажи уменьшают `boughtOf` ровно на проданное.
    function test_Sell_PartialSalesDecrementTheRight() public {
        uint256 got = _buy(alice, 0.5 ether);
        uint256 chunk = got / 4;

        uint256 left = got;
        for (uint256 i = 0; i < 3; ++i) {
            _sell(alice, chunk);
            left -= chunk;
            assertEq(
                curve.boughtOf(alice), left, unicode"право после частичной продажи"
            );
            assertEq(curve.sold(), left, unicode"sold после частичной продажи");
        }

        // Остаток — тоже ровно право, и ни wei сверх него.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.ExceedsPurchased.selector, left + 1, left));
        curve.sell(left + 1, 1, block.timestamp);

        _sell(alice, left);
        assertEq(curve.boughtOf(alice), 0);
        assertEq(curve.sold(), 0);
    }

    /// @notice Право накапливается по нескольким покупкам и переживает
    ///         чередование покупок и продаж.
    function test_Sell_RightAccumulatesAcrossBuys() public {
        uint256 a1 = _buy(alice, 0.2 ether);
        uint256 a2 = _buy(alice, 0.3 ether);
        assertEq(curve.boughtOf(alice), a1 + a2, unicode"право суммируется");

        _sell(alice, a1);
        assertEq(curve.boughtOf(alice), a2);

        uint256 a3 = _buy(alice, 0.1 ether);
        assertEq(curve.boughtOf(alice), a2 + a3);

        _sell(alice, a2 + a3);
        assertEq(curve.boughtOf(alice), 0);
        assertEq(curve.sold(), 0, unicode"кривая пуста");
    }

    /// @notice Право одного покупателя не расходуется другим: у каждого своё.
    function test_Sell_RightsAreIndependentBetweenBuyers() public {
        uint256 ga = _buy(alice, 0.3 ether);
        uint256 gb = _buy(bob, 0.3 ether);

        // bob держит достаточно токенов, а sold покрывает обе позиции —
        // но продать он может только своё.
        vm.prank(genesis);
        token.transfer(bob, ga);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.ExceedsPurchased.selector, gb + 1, gb));
        curve.sell(gb + 1, 1, block.timestamp);

        _sell(bob, gb);
        assertEq(curve.boughtOf(alice), ga, unicode"чужая продажа съела право alice");

        _sell(alice, ga);
        assertEq(curve.sold(), 0, unicode"оба вышли полностью");
    }

    function test_Sell_RevertsOnZeroAmountAndZeroMin() public {
        uint256 got = _buy(alice, 0.1 ether);

        vm.prank(alice);
        vm.expectRevert(MaclaurinCurve.ZeroAmount.selector);
        curve.sell(0, 1, block.timestamp);

        vm.prank(alice);
        vm.expectRevert(MaclaurinCurve.ZeroAmount.selector);
        curve.sell(got, 0, block.timestamp);
    }

    function test_Sell_RevertsOnDeadlineAndSlippage() public {
        uint256 got = _buy(alice, 0.1 ether);
        (uint256 out,) = curve.previewSell(got);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.DeadlineExpired.selector, block.timestamp - 1));
        curve.sell(got, 1, block.timestamp - 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinCurve.SlippageSell.selector, out, out + 1));
        curve.sell(got, out + 1, block.timestamp);
    }

    /// @notice Неудачный перевод ETH откатывает всю продажу: токены не могут
    ///         уйти в кривую, не оплатившись.
    function test_Sell_RevertsIfPayoutRejected() public {
        EthRejector r = new EthRejector(curve, IERC20(address(token)));
        vm.deal(address(r), 0.1 ether);
        uint256 got = r.buy(0.1 ether);

        vm.expectRevert(MaclaurinCurve.EthTransferFailed.selector);
        r.sell(got);

        assertEq(
            token.balanceOf(address(r)), got, unicode"токены остались у владельца"
        );
        assertEq(curve.sold(), got, unicode"учёт не сдвинулся");
    }

    /*//////////////////////////////////////////////////////////////
        5. КРУГ «КУПИЛ — СРАЗУ ПРОДАЛ» ВСЕГДА УБЫТОЧЕН
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Инвариант §5.5. Если бы круг был безубыточным хоть на каких-то
     *         суммах, кривую доили бы бесплатно ботом в одном блоке.
     *
     * @dev Проверяется в том числе на суммах в единицы wei — там, где
     *      комиссия при округлении вниз обнулилась бы. Ровно поэтому
     *      комиссия округляется вверх.
     */
    function testFuzz_RoundTripIsAlwaysLossy(uint256 value, uint256 warmup) public {
        warmup = bound(warmup, 0, 2 ether);
        if (warmup > 1e6) _buy(carol, warmup);

        value = bound(value, 1, curve.maxEthIn());
        (uint256 tokensOut,,) = curve.previewBuy(value);
        vm.assume(tokensOut > 0);

        uint256 got = _buy(alice, value);
        (uint256 out,) = curve.previewSell(got);
        if (out == 0) return; // выплата меньше wei — продавать нечего

        uint256 back = _sell(alice, got);
        assertLt(back, value, unicode"круг обязан быть убыточным");
    }

    /// @notice Дробление круга на много мелких сделок тоже не даёт прибыли.
    function test_RoundTrip_FragmentationDoesNotHelp() public {
        uint256 spent;
        uint256 tokens;
        for (uint256 i = 0; i < 10; ++i) {
            spent += 0.05 ether;
            tokens += _buy(alice, 0.05 ether);
        }

        uint256 back;
        for (uint256 i = 0; i < 9; ++i) {
            back += _sell(alice, tokens / 10);
        }
        back += _sell(alice, token.balanceOf(alice));

        assertLt(back, spent, unicode"дробление не создаёт прибыли");
        assertEq(curve.sold(), 0);
    }

    /*//////////////////////////////////////////////////////////////
        6. МОНОТОННОСТЬ ЦЕНЫ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PriceRisesOnBuyAndFallsOnSell(uint256 value) public {
        value = bound(value, 1e9, curve.maxEthIn() > 1 ether ? 1 ether : curve.maxEthIn());

        uint256 before = curve.priceAt(curve.sold());
        uint256 got = _buy(alice, value);
        uint256 mid = curve.priceAt(curve.sold());
        assertGe(mid, before, unicode"покупка не может опустить цену");

        (uint256 out,) = curve.previewSell(got);
        if (out == 0) return;
        _sell(alice, got);
        assertLe(
            curve.priceAt(curve.sold()), mid, unicode"продажа не может поднять цену"
        );
    }

    /*//////////////////////////////////////////////////////////////
        7. DONATION ATTACK (§4.2)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Принудительный ETH на адрес кривой не двигает ни цену, ни
     *         котировки, ни резерв.
     *
     * @dev `vm.deal` моделирует ровно то, что делает `selfdestruct`: баланс
     *      появляется без единого вызова кода контракта. Если бы резерв
     *      считался как `address(this).balance`, донат в 1000 ETH сместил бы
     *      всю экономику кривой и позволил бы выкачать чужие деньги.
     */
    function test_Donation_DoesNotAffectAnything() public {
        uint256 got = _buy(alice, 0.3 ether);

        uint256 priceBefore = curve.spotPrice();
        uint256 quoteBefore = curve.quoteSellGross(got);
        uint256 reserveBefore = curve.reserve();

        vm.deal(address(curve), address(curve).balance + 1000 ether);

        assertEq(curve.spotPrice(), priceBefore, unicode"донат сдвинул цену");
        assertEq(
            curve.quoteSellGross(got), quoteBefore, unicode"донат сдвинул котировку"
        );
        assertEq(curve.reserve(), reserveBefore, unicode"донат попал в резерв");

        uint256 out = _sell(alice, got);
        assertEq(
            out, quoteBefore - (quoteBefore * 100 + 9999) / 10_000, unicode"выплата по кривой"
        );
        // Донат остаётся в контракте навсегда и никому не достаётся.
        assertGe(address(curve).balance, 1000 ether);
    }

    /// @notice Прямой перевод ETH на кривую невозможен: нет ни receive, ни fallback.
    function test_Donation_PlainTransferIsRejected() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(curve).call{value: 1 ether}("");
        assertFalse(ok, unicode"кривая не должна принимать ETH просто так");
    }

    /*//////////////////////////////////////////////////////////////
        8. РЕЕНТРАНСИ (§4.3)
    //////////////////////////////////////////////////////////////*/

    function test_Reentrancy_SellIsGuarded() public {
        SellReenterer r = new SellReenterer(curve, IERC20(address(token)));
        vm.deal(address(r), 1 ether);
        uint256 got = r.buy(1 ether);

        uint256 out = r.sell(got);

        assertTrue(r.attempted(), unicode"повторный вход должен был случиться");
        assertTrue(r.reentryReverted(), unicode"повторный вход обязан быть отбит");
        assertEq(r.received(), out, unicode"выплата ровно одна");
        assertEq(curve.sold(), 0);
        assertGe(address(curve).balance, curve.reserve() + curve.feesAccrued());
    }

    /*//////////////////////////////////////////////////////////////
        9. АНТИ-СНАЙП (§4.5)
    //////////////////////////////////////////////////////////////*/

    function _freshCurve() internal returns (MaclaurinCurve c) {
        c = new MaclaurinCurve(IERC20(address(token)), feeRecipient);
        vm.prank(genesis);
        token.transfer(address(c), INVENTORY);
    }

    function test_AntiSnipe_CapsPurchaseInsideWindow() public {
        MaclaurinCurve c = _freshCurve();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert();
        c.buy{value: 1 ether}(1, block.timestamp);

        vm.prank(alice);
        uint256 got = c.buy{value: 0.005 ether}(1, block.timestamp);
        assertGt(got, 0);
        assertEq(c.boughtInWindow(alice), got, unicode"учёт окна");
    }

    function test_AntiSnipe_LimitIsCumulativePerAddress() public {
        MaclaurinCurve c = _freshCurve();
        vm.deal(alice, 10 ether);

        // Набираем лимит мелкими покупками — он суммируется по адресу,
        // поэтому дробление транзакций не обходит его.
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(alice);
            c.buy{value: 0.005 ether}(1, block.timestamp);
        }
        assertLe(c.boughtInWindow(alice), c.ANTI_SNIPE_MAX());

        vm.prank(alice);
        vm.expectRevert();
        c.buy{value: 0.02 ether}(1, block.timestamp);
    }

    function test_AntiSnipe_ExpiresAfterWindow() public {
        MaclaurinCurve c = _freshCurve();

        vm.warp(c.antiSnipeEnd());
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 got = c.buy{value: 1 ether}(1, block.timestamp);

        assertGt(got, c.ANTI_SNIPE_MAX(), unicode"после окна лимита нет");
        assertEq(c.boughtInWindow(alice), 0, unicode"после окна счётчик не пишется");
    }

    /*//////////////////////////////////////////////////////////////
        10. КОМИССИЯ И ОТСУТСТВИЕ ДОСТУПА К РЕЗЕРВУ
    //////////////////////////////////////////////////////////////*/

    function test_Fees_WithdrawIsPermissionlessAndFixedRecipient() public {
        _buy(alice, 1 ether);
        uint256 fees = curve.feesAccrued();
        uint256 reserveBefore = curve.reserve();

        vm.prank(bob); // не создатель — и это ничего не меняет
        curve.withdrawFees();

        assertEq(
            feeRecipient.balance, fees, unicode"комиссия ушла только получателю"
        );
        assertEq(curve.feesAccrued(), 0);
        assertEq(curve.feesWithdrawn(), fees);
        assertEq(
            curve.reserve(),
            reserveBefore,
            unicode"резерв не тронут выводом комиссии"
        );
        assertGe(address(curve).balance, curve.reserve());

        vm.expectRevert(MaclaurinCurve.NothingToWithdraw.selector);
        curve.withdrawFees();
    }

    /// @notice После вывода всей комиссии резерва хватает на полный выкуп —
    ///         то есть комиссия действительно бралась не из него.
    function test_Fees_WithdrawalKeepsCurveSolvent() public {
        _buy(alice, 1 ether);
        _buy(bob, 0.7 ether);
        curve.withdrawFees();

        assertGe(
            curve.reserve(),
            curve.quoteSellGross(curve.sold()),
            unicode"неплатёжеспособность"
        );

        _sell(bob, token.balanceOf(bob));
        _sell(alice, token.balanceOf(alice));
        assertEq(curve.sold(), 0);
    }

    /**
     * @notice У создателя нет способа изъять резерв — ни одной функции.
     *
     * @dev Проверяется не чтением исходника, а по факту: у контракта нет
     *      fallback, поэтому любой неизвестный селектор ревертит. Ниже —
     *      типовой набор «легальных» рагпульных полномочий, которые чаще
     *      всего и оказываются в подобных контрактах.
     */
    function test_NoRugFunctionsExist() public {
        _buy(alice, 1 ether);
        uint256 reserveBefore = curve.reserve();

        string[12] memory sigs = [
            "withdraw()",
            "withdrawAll()",
            "emergencyWithdraw()",
            "rescueETH(uint256)",
            "rescueTokens(address,uint256)",
            "setFeeRecipient(address)",
            "setFee(uint256)",
            "pause()",
            "unpause()",
            "owner()",
            "transferOwnership(address)",
            "blacklist(address)"
        ];

        for (uint256 i = 0; i < sigs.length; ++i) {
            (bool ok,) = address(curve).call(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, sigs[i]);
        }
        assertEq(curve.reserve(), reserveBefore, unicode"резерв неприкосновенен");
    }

    function test_Constructor_RejectsZeroAddresses() public {
        vm.expectRevert(MaclaurinCurve.ZeroAddress.selector);
        new MaclaurinCurve(IERC20(address(0)), feeRecipient);

        vm.expectRevert(MaclaurinCurve.ZeroAddress.selector);
        new MaclaurinCurve(IERC20(address(token)), address(0));
    }
}

/*//////////////////////////////////////////////////////////////
                   ХЕНДЛЕР ДЛЯ STATEFUL-ФАЗЗИНГА
//////////////////////////////////////////////////////////////*/

/**
 * @dev Единственная точка входа фаззера. Он бьёт по кривой случайными
 *      последовательностями покупок, продаж, выводов комиссии, донатов и
 *      скачков времени, а инвариантный тест после каждого шага проверяет
 *      свойства из §5, которые обязаны выполняться ВСЕГДА.
 *
 *      ПОЧЕМУ НАРУШЕНИЯ ЗАПИСЫВАЮТСЯ ФЛАГАМИ, А НЕ assert-АМИ. Два инварианта
 *      (§5.4 монотонность цены и §5.5 убыточность круга) — свойства ОТДЕЛЬНОЙ
 *      операции, а не состояния, поэтому проверять их можно только здесь.
 *      Но `assert*` внутри хендлера ревертит вызов, а при `fail_on_revert =
 *      false` реверт хендлера просто пропускается — нарушение было бы
 *      проглочено вместе с откатом состояния. Поэтому нарушение не ревертит,
 *      а поднимает флаг, который переживает шаг и проверяется в invariant_.
 *
 *      Хендлер намеренно не ревертит вообще: невозможные действия он
 *      отсеивает заранее, чтобы фаззер не тратил шаги впустую.
 */
contract CurveHandler is Test {
    MaclaurinCurve public immutable curve;
    IERC20 public immutable token;
    address[4] public actors;

    /// Суммарно принято ETH и суммарно выплачено — призрачный учёт,
    /// независимый от счётчиков самого контракта.
    uint256 public ghostIn;
    uint256 public ghostOut;
    /// Максимум, который когда-либо видел суммарный счётчик комиссии.
    uint256 public ghostFeeHighWater;

    /// Флаги нарушений. Обязаны остаться false после любой последовательности.
    bool public brokeMonotonicity;
    bool public brokeRoundTripLoss;
    bool public brokePreview;
    bool public brokeFeeMonotonicity;
    /// Продажа без покрытия правом хоть раз прошла — это дыра, ради которой
    /// заведён `boughtOf`. Обязан остаться false навсегда.
    bool public brokePurchaseGuard;
    /// Сколько раз попытка продать чужое реально дошла до контракта. Нужен,
    /// чтобы `brokePurchaseGuard == false` не оказался пустым утверждением:
    /// флаг, который никто ни разу не пробовал поднять, ничего не доказывает.
    uint256 public unbackedAttempts;

    constructor(MaclaurinCurve c, IERC20 t, address[4] memory a) {
        curve = c;
        token = t;
        actors = a;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Комиссия только накапливается или уходит получателю — сумма
    ///      «начислено + выведено» обязана быть неубывающей (§5.6).
    modifier tracked() {
        _;
        uint256 total = curve.feesAccrued() + curve.feesWithdrawn();
        if (total < ghostFeeHighWater) brokeFeeMonotonicity = true;
        else ghostFeeHighWater = total;
    }

    /// @dev Отсекает заведомо невозможную покупку и возвращает её размер.
    ///      Ноль означает «сейчас купить нельзя, шаг пропускаем».
    function _plannedBuy(address a, uint256 ethSeed) internal view returns (uint256) {
        uint256 hi = curve.maxEthIn();
        if (hi < 1e6) return 0;
        uint256 value = bound(ethSeed, 1e6, hi);

        (uint256 tokensOut,,) = curve.previewBuy(value);
        if (tokensOut == 0) return 0;
        if (block.timestamp < curve.antiSnipeEnd()) {
            if (curve.boughtInWindow(a) + tokensOut > curve.ANTI_SNIPE_MAX()) return 0;
        }
        return value;
    }

    /// @dev ETH за покупку списывается с ПРАНКНУТОГО адреса, а не с хендлера:
    ///      `vm.prank` подменяет caller целиком, включая источник value.
    function _fund(address a, uint256 value) internal {
        vm.deal(a, a.balance + value);
    }

    function buy(uint256 actorSeed, uint256 ethSeed) external tracked {
        address a = _actor(actorSeed);
        uint256 value = _plannedBuy(a, ethSeed);
        if (value == 0) return;

        (uint256 expected,,) = curve.previewBuy(value);
        uint256 priceBefore = curve.priceAt(curve.sold());

        _fund(a, value);
        vm.prank(a);
        uint256 got = curve.buy{value: value}(1, block.timestamp);
        ghostIn += value;

        if (got != expected) brokePreview = true;
        if (curve.priceAt(curve.sold()) < priceBefore) brokeMonotonicity = true;
    }

    /// @dev Потолок продажи — минимум из трёх величин, и `boughtOf` среди них
    ///      главная: она и есть право адреса на резерв. Раньше здесь стояли
    ///      только баланс и `sold`, и ровно это скрывало дыру — фаззер по
    ///      построению никогда не пробовал продать чужое.
    function sell(uint256 actorSeed, uint256 amountSeed) external tracked {
        address a = _actor(actorSeed);
        uint256 cap = token.balanceOf(a);
        if (cap > curve.boughtOf(a)) cap = curve.boughtOf(a);
        if (cap > curve.sold()) cap = curve.sold();
        if (cap == 0) return;

        uint256 amount = bound(amountSeed, 1, cap);
        (uint256 expected,) = curve.previewSell(amount);
        if (expected == 0) return;

        uint256 priceBefore = curve.priceAt(curve.sold());

        vm.prank(a);
        uint256 out = curve.sell(amount, 1, block.timestamp);
        ghostOut += out;

        if (out != expected) brokePreview = true;
        if (curve.priceAt(curve.sold()) > priceBefore) brokeMonotonicity = true;
    }

    /// @dev Купить и тут же продать. Обязано быть убыточно (§5.5) — иначе
    ///      кривую можно доить ботом в одном блоке.
    function roundTrip(uint256 actorSeed, uint256 ethSeed) external tracked {
        address a = _actor(actorSeed);
        uint256 value = _plannedBuy(a, ethSeed);
        if (value == 0) return;

        _fund(a, value);
        vm.prank(a);
        uint256 got = curve.buy{value: value}(1, block.timestamp);
        ghostIn += value;

        (uint256 expected,) = curve.previewSell(got);
        if (expected == 0) return;

        vm.prank(a);
        uint256 out = curve.sell(got, 1, block.timestamp);
        ghostOut += out;

        if (out >= value) brokeRoundTripLoss = true;
    }

    /**
     * @dev Продажа БЕЗ ПРАВА: адрес пытается сдать кривой больше, чем купил.
     *      Обязана реветить всегда — иначе резерв покупателей разбирают
     *      держатели бесплатных токенов (genesis, награды стейкинга).
     *
     *      Успех здесь ловится флагом, а не assert-ом: при
     *      `fail_on_revert = false` реверт хендлера просто пропускается,
     *      и нарушение уехало бы вместе с откатом состояния.
     */
    function sellUnbacked(uint256 actorSeed, uint256 amountSeed) external tracked {
        // Случайный старт, но затем перебор: атакующим становится первый, у
        // кого действительно есть неоплаченные токены. Без перебора фаззер
        // тратил бы почти все шаги на адреса, которым и пробовать нечего, и
        // «атака не прошла» превращалось бы в утверждение ни о чём.
        uint256 start = actorSeed % actors.length;
        for (uint256 i = 0; i < actors.length; ++i) {
            address a = actors[(start + i) % actors.length];
            uint256 right = curve.boughtOf(a);
            uint256 bal = token.balanceOf(a);
            if (bal <= right) continue; // всё, что есть, оплачено
            if (curve.sold() <= right) continue; // кривая столько и не выпускала

            uint256 hi = bal < curve.sold() ? bal : curve.sold();
            uint256 amount = bound(amountSeed, right + 1, hi);
            ++unbackedAttempts;

            vm.prank(a);
            try curve.sell(amount, 1, block.timestamp) returns (uint256) {
                brokePurchaseGuard = true;
            } catch {}
            return;
        }
    }

    /**
     * @dev Обычный перевод токенов между держателями. Право выкупа за ними НЕ
     *      едет — именно это делает инвариант Σ boughtOf == sold нетривиальным
     *      и открывает фаззеру дорогу к `sellUnbacked`.
     */
    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external tracked {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;

        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;

        vm.prank(from);
        token.transfer(to, bound(amountSeed, 1, bal));
    }

    function withdrawFees() external tracked {
        if (curve.feesAccrued() == 0) return;
        curve.withdrawFees();
    }

    /// @dev Принудительный ETH без единого вызова кода — модель selfdestruct.
    function donate(uint256 amountSeed) external tracked {
        uint256 amount = bound(amountSeed, 1, 10 ether);
        vm.deal(address(curve), address(curve).balance + amount);
    }

    /// @dev Скачки времени нужны, чтобы фаззер проходил и внутри окна
    ///      анти-снайпа, и после него.
    function warp(uint256 secs) external tracked {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 3 days));
    }
}

/*//////////////////////////////////////////////////////////////
                      ИНВАРИАНТЫ (§5)
//////////////////////////////////////////////////////////////*/

contract MaclaurinCurveInvariantsTest is Test {
    MaclaurinToken internal token;
    MaclaurinCurve internal curve;
    CurveHandler internal handler;

    address internal genesis = makeAddr("genesis");
    address internal feeRecipient = makeAddr("feeRecipient");
    address[4] internal actors;

    uint256 internal constant INVENTORY = 1_000_000_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MaclaurinToken(genesis, makeAddr("emission"));
        curve = new MaclaurinCurve(IERC20(address(token)), feeRecipient);

        vm.prank(genesis);
        token.transfer(address(curve), INVENTORY);

        actors = [makeAddr("a1"), makeAddr("a2"), makeAddr("a3"), makeAddr("a4")];
        for (uint256 i = 0; i < actors.length; ++i) {
            vm.prank(actors[i]);
            token.approve(address(curve), type(uint256).max);
        }

        // a4 — держатель токенов, полученных НЕ от кривой: доля genesis
        // (маркетинг + резерв + хвост, §7). В мейннете такие адреса появятся
        // сразу после раскладки, и фаззер обязан пробовать сдавать эти токены
        // в кривую — до фикса именно так уносился резерв покупателей.
        vm.prank(genesis);
        token.transfer(actors[3], 250_000_000e18);

        handler = new CurveHandler(curve, IERC20(address(token)), actors);
        vm.deal(address(handler), 100 ether);
        targetContract(address(handler));
    }

    /**
     * @notice §5.1 ПЛАТЁЖЕСПОСОБНОСТЬ. Резерва хватает, чтобы выкупить всё
     *         выпущенное разом.
     *
     * @dev Самый важный инвариант. Его нарушение означает, что последний
     *      продавец получит revert навсегда — а починить неизменяемый
     *      контракт нельзя.
     */
    function invariant_ReserveCoversFullBuyback() public view {
        assertGe(
            curve.reserve(),
            curve.quoteSellGross(curve.sold()),
            unicode"резерв ниже обязательств"
        );
    }

    /// @notice §5.2 Баланс покрывает и резерв, и начисленную комиссию.
    function invariant_BalanceCoversReserveAndFees() public view {
        assertGe(address(curve).balance, curve.reserve() + curve.feesAccrued());
    }

    /// @notice §5.3 Продать больше, чем есть в инвентаре, невозможно.
    function invariant_SoldNeverExceedsInventory() public view {
        assertLe(curve.sold(), INVENTORY);
        assertEq(token.balanceOf(address(curve)), INVENTORY - curve.sold(), unicode"учёт токенов");
    }

    /**
     * @notice §5.8 УЧЁТ ПРАВ ВЫКУПА СХОДИТСЯ: Σ boughtOf[все] == sold.
     *
     * @dev Ключевой инвариант фикса. Он утверждает две вещи сразу:
     *
     *        - права выкупа ровно покрывают выпущенное, то есть каждый
     *          покупатель дойдёт до резерва и никто не займёт его место;
     *        - прав не больше, чем выпущено, то есть из воздуха право не
     *          берётся и резерв не обещан дважды.
     *
     *      Из него же следует, что проверка `amount <= sold` в `sell`
     *      недостижима: amount ≤ boughtOf[a] ≤ Σ boughtOf == sold. Она
     *      оставлена как защита в глубину — на случай, если этот инвариант
     *      сломает будущая правка.
     *
     *      Равенство проверяется по всем акторам, а держателем «чужих» токенов
     *      здесь выступает a4 с долей genesis: его баланс в сумму прав не
     *      входит никогда, сколько бы токенов он ни держал.
     */
    function invariant_PurchaseRightsSumToSold() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; ++i) {
            sum += curve.boughtOf(actors[i]);
        }
        assertEq(sum, curve.sold(), unicode"сумма прав выкупа != sold");
    }

    /// @notice Продажа без права не проходит НИ РАЗУ за всю последовательность.
    /// @dev Ровно та дыра, ради которой заведён `boughtOf`: держатель
    ///      бесплатных токенов извлекал ETH, внесённый покупателем, а
    ///      покупатель после этого не мог выйти вовсе.
    function invariant_UnbackedSellNeverSucceeds() public view {
        assertFalse(
            handler.brokePurchaseGuard(),
            unicode"кривая выкупила токены, которые не продавала этому адресу"
        );
    }

    /// @dev Утверждение «атака ни разу не прошла» стоит ровно столько, сколько
    ///      попыток было сделано. Если фаззер до атаки не добрался, тест выше
    ///      зелёный впустую — поэтому число попыток проверяется явно, в конце
    ///      каждого прогона.
    /**
     * @notice Действие `sellUnbacked` в хендлере не мёртвое: оно реально
     *         доходит до контракта и реально получает отказ.
     *
     * @dev Обычный детерминированный тест, а не инвариант, и это осознанно.
     *      Утверждение «атака ни разу не прошла» стоит ровно столько, сколько
     *      было попыток: если бы хендлер молча пропускал каждый шаг,
     *      invariant_UnbackedSellNeverSucceeds был бы зелёным впустую.
     *      Проверять это в `afterInvariant` нельзя — там число попыток
     *      зависит от того, какие шаги выпали фаззеру, и тест стал бы
     *      плавающим. Здесь же сценарий фиксирован.
     */
    function test_Handler_UnbackedSellIsReallyAttemptedAndRejected() public {
        handler.warp(2 hours); // за окно анти-снайпа
        handler.buy(0, 1 ether); // a1 покупает, резерв наполнен

        uint256 soldBefore = curve.sold();
        uint256 reserveBefore = curve.reserve();
        assertGt(
            soldBefore, 0, unicode"подготовка: кривая должна была продать"
        );

        // a4 держит genesis-долю и не купил ни одного токена у кривой.
        assertEq(curve.boughtOf(actors[3]), 0);
        assertEq(token.balanceOf(actors[3]), 250_000_000e18);

        handler.sellUnbacked(3, 12_345);

        assertEq(
            handler.unbackedAttempts(), 1, unicode"попытка не дошла до контракта"
        );
        assertFalse(handler.brokePurchaseGuard(), unicode"чужая продажа прошла");
        assertEq(curve.sold(), soldBefore, unicode"учёт сдвинулся");
        assertEq(curve.reserve(), reserveBefore, unicode"резерв тронут");
    }

    /// @notice Право выкупа никогда не превышает того, что кривая выпустила.
    function invariant_RightNeverExceedsSold() public view {
        for (uint256 i = 0; i < actors.length; ++i) {
            assertLe(curve.boughtOf(actors[i]), curve.sold(), unicode"право выше sold");
        }
    }

    /// @notice §5.6 Комиссия уменьшается только выводом получателю.
    /// @dev Монотонность суммы «начислено + выведено» проверяет хендлер после
    ///      каждого шага; здесь фиксируется, что вывод не трогает резерв.
    function invariant_FeesNeverEatReserve() public view {
        assertGe(
            curve.feesAccrued() + curve.feesWithdrawn(),
            handler.ghostFeeHighWater(),
            unicode"комиссия исчезла мимо получателя"
        );
    }

    /**
     * @notice §5.7 У создателя нет способа изъять резерв.
     *
     * @dev Формулировка «нет функции» проверяется здесь как точное
     *      тождество учёта: всё, что кривая приняла, лежит либо в резерве,
     *      либо в комиссии (начисленной или выведенной), либо ушло
     *      продавцам. Третьего пути для ETH не существует, и донаты в это
     *      тождество не попадают — оно построено на счётчиках, а не на балансе.
     */
    function invariant_EthAccountingReconciles() public view {
        assertEq(
            curve.reserve() + curve.feesAccrued() + curve.feesWithdrawn(),
            handler.ghostIn() - handler.ghostOut(),
            unicode"учёт ETH разошёлся"
        );
    }

    /**
     * @notice §5.4 Цена не убывает при покупках и не растёт при продажах.
     * @dev Проверяется пошагово внутри хендлера, сюда попадает результат.
     */
    function invariant_PriceIsMonotonicPerTrade() public view {
        assertFalse(
            handler.brokeMonotonicity(),
            unicode"сделка сдвинула цену не в ту сторону"
        );
    }

    /// @notice §5.5 Круг «купил и сразу продал» убыточен на любых суммах.
    function invariant_RoundTripIsNeverProfitable() public view {
        assertFalse(
            handler.brokeRoundTripLoss(), unicode"кривую можно подоить бесплатно"
        );
    }

    /// @notice Котировки не расходятся с исполнением: previewBuy/previewSell
    ///         возвращают ровно то, что дадут buy/sell.
    function invariant_PreviewsMatchExecution() public view {
        assertFalse(
            handler.brokePreview(), unicode"котировка разошлась с исполнением"
        );
    }

    /// @notice §5.6 Счётчик комиссии не уменьшается ничем, кроме вывода.
    function invariant_FeeCounterOnlyGrows() public view {
        assertFalse(
            handler.brokeFeeMonotonicity(),
            unicode"комиссия уменьшилась мимо вывода"
        );
    }

    /// @notice Цена всегда внутри [P0, P0·e] и однозначно определена `sold`.
    function invariant_PriceStaysInsideTheEnvelope() public view {
        uint256 p = curve.priceAt(curve.sold());
        assertGe(p, curve.P0());
        assertLe(p, curve.P_FINAL());
        assertEq(curve.P_FINAL() * 1e18 / curve.P0(), curve.E_FIXED(), unicode"размах != e");
    }
}
