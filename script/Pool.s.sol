// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/**
 * @title  Pool — вспомогательные скрипты для пула ликвидности Uniswap V3
 * @notice Создание пула, внесение ликвидности и безвозвратное сжигание LP-позиции.
 *
 * @dev    ЭТОТ ФАЙЛ НАМЕРЕННО НЕ ИМПОРТИРУЕТ НИЧЕГО ИЗ `src/`.
 *         Он работает с уже развёрнутым токеном по адресу из окружения. Это не
 *         стилистика, а развязка сборки: пул создаётся после деплоя токена, и
 *         скрипт пула не должен ломаться от изменений в контрактах.
 *
 *         Каждый шаг — отдельный контракт-скрипт и отдельная транзакция. Причина
 *         прагматичная: бюджет $15, и между шагами надо своими глазами посмотреть
 *         на результат предыдущего. Один скрипт «сделай всё» при ошибке в середине
 *         оставляет наполовину созданный пул и сожжённый газ.
 *
 *         Порядок: PoolQuote (без транзакций) -> CreatePool -> AddLiquidity ->
 *         PoolStatus -> BurnLp.
 *
 *         СЕТЬ: Robinhood Chain (Arbitrum L2). Адреса Uniswap V3 сверены с
 *         официальным списком Uniswap и проверены on-chain 2026-08-01:
 *         NPM.factory(), SwapRouter02.factory() и QuoterV2.factory() указывают
 *         на одну фабрику, NPM.WETH9() == 0x0Bd7...aD73.
 *         Источник: https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
 *
 *         ВНИМАНИЕ: WETH здесь НЕ 0x4200...0006. Предеплой по этому адресу —
 *         особенность OP Stack; Robinhood Chain построена на Arbitrum, и WETH
 *         там обычный контракт по обычному адресу. Раньше WETH9 был в этом
 *         файле константой — теперь он часть Cfg и берётся по chainid, потому
 *         что захардкоженный адрес из другой сети означает потерю средств.
 *
 *         В ТЕСТНЕТЕ Robinhood Chain (46630) Uniswap НЕ РАЗВЁРНУТ: по адресам
 *         фабрики, NPM и WETH нет кода вообще. Репетировать пул можно только
 *         на локальном форке мейннета (DEPLOY-RUNBOOK.md §8.0).
 */

/*//////////////////////////////////////////////////////////////
                              ИНТЕРФЕЙСЫ
//////////////////////////////////////////////////////////////*/

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
}

interface IWETH9 {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @dev Нужны для сверки адресов на цепочке — см. _cfg().
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

/*//////////////////////////////////////////////////////////////
                            ОБЩАЯ БАЗА
//////////////////////////////////////////////////////////////*/

abstract contract PoolBase is Script {
    /// @dev Uniswap V3 на Robinhood Chain mainnet (chainid 4663).
    ///
    ///      NPM сверен трижды: `SwapRouter02.positionManager()`, официальный
    ///      список деплоев Uniswap и `cast code` (48 771 байт, `symbol()`
    ///      возвращает "UNI-V3-POS"). Здесь ранее стоял адрес с потерянной
    ///      буквой в середине — `…1128dEAb1492…` вместо `…1128dEAaB1492…`,
    ///      длина добита лишней `D` в конце. Такой адрес остаётся валидным по
    ///      формату и проходит проверку контрольной суммы, но кода по нему нет:
    ///      `approve` ушёл бы в пустоту, а `mint` отреверил бы уже после того,
    ///      как деньги списаны с кошелька. Любой адрес, через который идут
    ///      средства, обязан подтверждаться вызовом на цепочке, а не глазами.
    address internal constant NPM_RH = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address internal constant FACTORY_RH = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant ROUTER_RH = 0xCaf681a66D020601342297493863E78C959E5cb2;

    /// @dev WETH на Robinhood Chain mainnet. НЕ предеплой: это Arbitrum, а не
    ///      OP Stack, и адреса 0x4200...0006 здесь не существует.
    address internal constant WETH_RH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @dev Адрес сжигания. Именно 0x...dEaD, а не address(0): ERC-721 от OZ
    ///      реверит перевод на нулевой адрес, и «сжечь» позицию туда нельзя.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    struct Cfg {
        address npm;
        address factory;
        address weth;
        address maclaurin;
        uint24 fee;
        uint256 maclaurinAmount;
        uint256 ethAmount;
    }

    function _cfg() internal view returns (Cfg memory c) {
        c.npm = vm.envOr("UNISWAP_NPM", NPM_RH);
        c.factory = vm.envOr("UNISWAP_FACTORY", FACTORY_RH);
        c.weth = vm.envOr("UNISWAP_WETH", WETH_RH);
        c.maclaurin = vm.envAddress("MACLAURIN_TOKEN");
        c.fee = uint24(vm.envOr("POOL_FEE", uint256(10000)));
        c.maclaurinAmount = vm.envUint("MACLAURIN_AMOUNT");
        c.ethAmount = vm.envUint("ETH_AMOUNT");

        require(c.maclaurin != c.weth, "MACLAURIN_TOKEN == WETH");
        require(c.maclaurinAmount > 0, "MACLAURIN_AMOUNT == 0");
        require(c.ethAmount > 0, "ETH_AMOUNT == 0");
        require(c.npm.code.length > 0, "UNISWAP_NPM: no code at address");
        require(c.factory.code.length > 0, "UNISWAP_FACTORY: no code at address");
        require(c.weth.code.length > 0, "UNISWAP_WETH: no code at address");
        require(c.maclaurin.code.length > 0, "MACLAURIN_TOKEN: no code at address");

        // Связность стека проверяется на цепочке, а не принимается на слово:
        // ошибка в одном адресе стоит всей ликвидности. В тестнете Robinhood
        // Chain по этим адресам кода нет вообще, и падение произойдёт выше.
        require(INonfungiblePositionManager(c.npm).factory() == c.factory, "NPM.factory() mismatch");
        require(INonfungiblePositionManager(c.npm).WETH9() == c.weth, "NPM.WETH9() mismatch");
    }

    /// @dev Uniswap упорядочивает пару по возрастанию адреса. Какой из токенов
    ///      окажется token0, заранее неизвестно: адрес MACLRN получается из
    ///      CREATE и зависит от нонса деплоера. Поэтому оба порядка обязаны
    ///      обрабатываться одинаково — захардкодить «MACLRN это token0» нельзя.
    function _order(Cfg memory c)
        internal
        pure
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        return c.maclaurin < c.weth
            ? (c.maclaurin, c.weth, c.maclaurinAmount, c.ethAmount)
            : (c.weth, c.maclaurin, c.ethAmount, c.maclaurinAmount);
    }

    /**
     * @dev sqrtPriceX96 = sqrt(amount1 / amount0) * 2**96.
     *
     *      Стартовая цена задаётся не «мнением», а тем же соотношением, в каком
     *      вносится ликвидность. Совпадение обязательно: если инициализировать
     *      пул по одной цене, а вносить по другой, Uniswap возьмёт лишь часть
     *      одной из сторон, а остаток вернёт — и позиция окажется не той,
     *      которую планировали.
     *
     *      Две ветки нужны из-за переполнения. Точная формула сдвигает amount1
     *      на 192 бита, что безопасно только пока amount1 < 2**64. Сторона ETH
     *      (~7e15 wei) в этот предел укладывается, сторона MACLRN (~2e26 wei) —
     *      нет. Для неё используется сдвиг на 96 с добором 48 бит после корня:
     *      это дешевле по точности (относительная ошибка ~2**-60), но не
     *      переполняется.
     */
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        require(amount0 > 0 && amount1 > 0, "zero amount");
        uint256 r = amount1 <= type(uint256).max >> 192
            ? _sqrt((amount1 << 192) / amount0)
            : _sqrt((amount1 << 96) / amount0) << 48;
        require(r > 0 && r <= type(uint160).max, "sqrtPriceX96 out of range");
        // Сужение проверено строкой выше.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(r);
    }

    /// @dev Целочисленный квадратный корень, метод Ньютона (вавилонский).
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev Границы full range, выровненные по шагу тиков.
    ///
    ///      Выравнивание сделано через остаток, а не через `(t / s) * s`.
    ///      Результат тот же, но деление с последующим умножением — это шаблон,
    ///      на который срабатывают и forge lint, и Slither (divide-before-multiply),
    ///      а CI падает на находках уровня low и выше.
    ///
    ///      Оператор `%` в Solidity берёт знак от делимого, поэтому
    ///      `-887272 % 200 == -72` и `-887272 - (-72) == -887200`: округление
    ///      идёт к нулю, и обе границы гарантированно остаются внутри
    ///      допустимого диапазона тиков.
    function _fullRange(int24 spacing) internal pure returns (int24 lower, int24 upper) {
        lower = MIN_TICK - (MIN_TICK % spacing);
        upper = MAX_TICK - (MAX_TICK % spacing);
    }

    function _ticks(Cfg memory c) internal view returns (int24 lower, int24 upper) {
        int24 spacing = IUniswapV3Factory(c.factory).feeAmountTickSpacing(c.fee);
        require(spacing != 0, "POOL_FEE: fee tier not enabled on factory");

        (int24 fullLo, int24 fullHi) = _fullRange(spacing);
        lower = int24(vm.envOr("TICK_LOWER", int256(fullLo)));
        upper = int24(vm.envOr("TICK_UPPER", int256(fullHi)));

        require(lower < upper, "TICK_LOWER >= TICK_UPPER");
        require(lower >= MIN_TICK && upper <= MAX_TICK, "tick out of range");
        require(lower % spacing == 0 && upper % spacing == 0, "ticks not aligned to tickSpacing");
    }

    function _logPrice(Cfg memory c, address token0, uint256 amount0, uint256 amount1) internal view {
        console2.log("chain id:        ", block.chainid);
        console2.log("MACLRN:          ", c.maclaurin);
        console2.log("WETH:            ", c.weth);
        console2.log("fee tier (ppm):  ", uint256(c.fee));
        console2.log("token0 is MACLRN:", token0 == c.maclaurin);
        console2.log("amount0 (wei):   ", amount0);
        console2.log("amount1 (wei):   ", amount1);
        console2.log("MACLRN in pool:  ", c.maclaurinAmount / 1e18);
        console2.log("ETH in pool (wei):", c.ethAmount);
    }
}

/*//////////////////////////////////////////////////////////////
                        1. РАСЧЁТ БЕЗ ТРАНЗАКЦИЙ
//////////////////////////////////////////////////////////////*/

/**
 * @notice Печатает стартовую цену, тики и состояние пула. Ничего не отправляет.
 * @dev Запускать БЕЗ `--broadcast`. Это единственный шаг, который ничего не стоит,
 *      поэтому здесь и надо ловить ошибки в числах.
 */
contract PoolQuote is PoolBase {
    function run() external view {
        Cfg memory c = _cfg();
        (address token0, address token1, uint256 amount0, uint256 amount1) = _order(c);
        _logPrice(c, token0, amount0, amount1);

        uint160 sp = _sqrtPriceX96(amount0, amount1);
        (int24 lower, int24 upper) = _ticks(c);

        console2.log("");
        console2.log("sqrtPriceX96:    ", uint256(sp));
        console2.log("tickLower:");
        console2.logInt(int256(lower));
        console2.log("tickUpper:");
        console2.logInt(int256(upper));

        address pool = IUniswapV3Factory(c.factory).getPool(token0, token1, c.fee);
        console2.log("");
        if (pool == address(0)) {
            console2.log(unicode"pool: NOT CREATED YET (следующий шаг — CreatePool)");
        } else {
            (uint160 curSp, int24 curTick,,,,,) = IUniswapV3Pool(pool).slot0();
            console2.log("pool:            ", pool);
            console2.log("current sqrtP:   ", uint256(curSp));
            console2.log("current tick:");
            console2.logInt(int256(curTick));
            console2.log("active liquidity:", uint256(IUniswapV3Pool(pool).liquidity()));
        }
    }
}

/*//////////////////////////////////////////////////////////////
                          2. СОЗДАНИЕ ПУЛА
//////////////////////////////////////////////////////////////*/

/**
 * @notice Создаёт и инициализирует пул MACLRN/WETH выбранного fee tier.
 * @dev Самая дорогая транзакция во всём запуске (~4.65M газа): здесь
 *      разворачивается сам контракт пула. Токены на этом шаге не тратятся.
 *      Повторный запуск безопасен — `createAndInitializePoolIfNecessary`
 *      вернёт уже существующий пул и не тронет цену.
 */
contract CreatePool is PoolBase {
    function run() external returns (address pool) {
        Cfg memory c = _cfg();
        (address token0, address token1, uint256 amount0, uint256 amount1) = _order(c);
        _logPrice(c, token0, amount0, amount1);

        uint160 sp = _sqrtPriceX96(amount0, amount1);
        console2.log("sqrtPriceX96:    ", uint256(sp));

        address existing = IUniswapV3Factory(c.factory).getPool(token0, token1, c.fee);
        if (existing != address(0)) {
            console2.log("");
            console2.log(
                unicode"пул уже существует, инициализация пропущена:",
                existing
            );
        }

        vm.startBroadcast();
        pool =
            INonfungiblePositionManager(c.npm).createAndInitializePoolIfNecessary(token0, token1, c.fee, sp);
        vm.stopBroadcast();

        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        console2.log("");
        console2.log("pool:            ", pool);
        console2.log("start tick:");
        console2.logInt(int256(tick));
    }
}

/*//////////////////////////////////////////////////////////////
                       3. ВНЕСЕНИЕ ЛИКВИДНОСТИ
//////////////////////////////////////////////////////////////*/

/**
 * @notice Оборачивает ETH в WETH (если нужно), выдаёт апрувы и минтит позицию.
 *
 * @dev По умолчанию диапазон — full range. Это осознанный выбор для позиции,
 *      которую сразу сжигают: сожжённую позицию невозможно ребалансировать
 *      никогда. Узкий диапазон, из которого цена вышла, превращается в мёртвую
 *      ликвидность, и торговать станет физически нечем. Подробности и цифры
 *      проскальзывания — в DEPLOY-RUNBOOK.md, раздел «Выбор диапазона».
 *
 *      Апрувы выдаются ровно на нужную сумму, а не `type(uint256).max`.
 *      Бесконечный апрув на NPM — это постоянное разрешение тратить остаток
 *      токенов на кошельке; для одноразовой операции он не нужен.
 */
contract AddLiquidity is PoolBase {
    function run() external returns (uint256 tokenId) {
        Cfg memory c = _cfg();
        (address token0, address token1, uint256 amount0, uint256 amount1) = _order(c);
        (int24 lower, int24 upper) = _ticks(c);
        _logPrice(c, token0, amount0, amount1);

        address pool = IUniswapV3Factory(c.factory).getPool(token0, token1, c.fee);
        require(
            pool != address(0), unicode"пул не создан: сначала запусти CreatePool"
        );

        // Защита от того, что цена в пуле уехала между CreatePool и этим шагом.
        // По умолчанию 0 (принять любой расклад): в свежем пуле без ликвидности
        // свопать не обо что, поэтому сдвинуть цену некому. Если между шагами
        // прошло заметное время или пул уже торговался — выставить LP_MIN_BPS.
        uint256 minBps = vm.envOr("LP_MIN_BPS", uint256(0));
        require(minBps <= 10000, "LP_MIN_BPS > 10000");

        address me = msg.sender;
        uint256 wethNeeded = c.ethAmount;

        console2.log("");
        console2.log("MACLRN balance:  ", IERC20Min(c.maclaurin).balanceOf(me));
        console2.log("WETH balance:    ", IWETH9(c.weth).balanceOf(me));
        require(
            IERC20Min(c.maclaurin).balanceOf(me) >= c.maclaurinAmount,
            unicode"не хватает MACLRN на кошельке"
        );

        vm.startBroadcast();

        uint256 wethHave = IWETH9(c.weth).balanceOf(me);
        if (wethHave < wethNeeded) {
            uint256 toWrap = wethNeeded - wethHave;
            require(me.balance >= toWrap, unicode"не хватает нативного ETH для wrap");
            IWETH9(c.weth).deposit{value: toWrap}();
        }

        // Возврат `approve` проверяется, а не игнорируется. Токены, которые
        // возвращают false вместо revert, — классический источник «молча не
        // сработавшего» апрува: mint потом падает без внятной причины.
        require(IERC20Min(c.maclaurin).approve(c.npm, c.maclaurinAmount), "approve MACLRN failed");
        require(IWETH9(c.weth).approve(c.npm, wethNeeded), "approve WETH failed");

        (tokenId,,,) = INonfungiblePositionManager(c.npm)
            .mint(
                INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: c.fee,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: (amount0 * minBps) / 10000,
                amount1Min: (amount1 * minBps) / 10000,
                recipient: me,
                deadline: block.timestamp + 1200
            })
            );

        vm.stopBroadcast();

        (,,,,,,, uint128 liq,,,,) = INonfungiblePositionManager(c.npm).positions(tokenId);
        console2.log("");
        console2.log("LP tokenId:      ", tokenId);
        console2.log("position liquidity:", uint256(liq));
        console2.log("pool liquidity:  ", uint256(IUniswapV3Pool(pool).liquidity()));
        console2.log("");
        console2.log(
            unicode"ЗАПИШИ tokenId — без него нельзя ни собрать комиссии, ни сжечь позицию."
        );
    }
}

/*//////////////////////////////////////////////////////////////
                          4. СОСТОЯНИЕ ПУЛА
//////////////////////////////////////////////////////////////*/

/// @notice Читает состояние пула и позиции. Ничего не отправляет.
contract PoolStatus is PoolBase {
    function run() external view {
        Cfg memory c = _cfg();
        (address token0, address token1,,) = _order(c);

        address pool = IUniswapV3Factory(c.factory).getPool(token0, token1, c.fee);
        require(pool != address(0), unicode"пул не создан");

        (uint160 sp, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        console2.log("pool:            ", pool);
        console2.log("sqrtPriceX96:    ", uint256(sp));
        console2.log("tick:");
        console2.logInt(int256(tick));
        console2.log("active liquidity:", uint256(IUniswapV3Pool(pool).liquidity()));
        console2.log("pool MACLRN bal: ", IERC20Min(c.maclaurin).balanceOf(pool));
        console2.log("pool WETH bal:   ", IWETH9(c.weth).balanceOf(pool));

        uint256 tokenId = vm.envOr("LP_TOKEN_ID", uint256(0));
        if (tokenId != 0) {
            (,,,,, int24 lo, int24 hi, uint128 liq,,, uint128 owed0, uint128 owed1) =
                INonfungiblePositionManager(c.npm).positions(tokenId);
            console2.log("");
            console2.log("LP tokenId:      ", tokenId);
            console2.log("LP owner:        ", INonfungiblePositionManager(c.npm).ownerOf(tokenId));
            console2.log("tickLower:");
            console2.logInt(int256(lo));
            console2.log("tickUpper:");
            console2.logInt(int256(hi));
            console2.log("in range:        ", tick >= lo && tick < hi);
            console2.log("liquidity:       ", uint256(liq));
            console2.log("tokensOwed0:     ", uint256(owed0));
            console2.log("tokensOwed1:     ", uint256(owed1));
        }
    }
}

/*//////////////////////////////////////////////////////////////
                        5. СЖИГАНИЕ LP-ПОЗИЦИИ
//////////////////////////////////////////////////////////////*/

/**
 * @notice Отправляет LP-NFT на 0x...dEaD. НЕОБРАТИМО.
 *
 * @dev Что именно теряется вместе с позицией: право вывести ликвидность
 *      (`decreaseLiquidity`), право собрать накопленные комиссии (`collect`)
 *      и право сдвинуть диапазон. Ликвидность остаётся в пуле навсегда — именно
 *      это и есть пруф «рагпула не будет».
 *
 *      Комиссии тоже становятся недоступны навсегда. Если позиция уже поторговала
 *      и на ней что-то накопилось — собрать это надо ДО сжигания.
 *
 *      Защита от случайного запуска: переменная окружения BURN_CONFIRM должна
 *      быть равна строке "BURN". Скрипт дополнительно требует, чтобы диапазон
 *      позиции совпадал с ожидаемым (LP_EXPECT_FULL_RANGE=true по умолчанию) —
 *      сжечь узкую позицию по ошибке дороже, чем лишняя проверка.
 */
contract BurnLp is PoolBase {
    function run() external {
        Cfg memory c = _cfg();
        uint256 tokenId = vm.envUint("LP_TOKEN_ID");
        require(tokenId != 0, unicode"LP_TOKEN_ID не задан");

        require(
            keccak256(bytes(vm.envOr("BURN_CONFIRM", string("")))) == keccak256(bytes("BURN")),
            unicode"НЕОБРАТИМО. Для подтверждения задай BURN_CONFIRM=BURN"
        );

        address owner = INonfungiblePositionManager(c.npm).ownerOf(tokenId);
        (
            ,,
            address t0,
            address t1,
            uint24 fee,
            int24 lo,
            int24 hi,
            uint128 liq,,,
            uint128 owed0,
            uint128 owed1
        ) = INonfungiblePositionManager(c.npm).positions(tokenId);

        require(t0 == c.maclaurin || t1 == c.maclaurin, unicode"позиция не по паре с MACLRN");
        require(liq > 0, unicode"в позиции нет ликвидности");

        if (vm.envOr("LP_EXPECT_FULL_RANGE", true)) {
            int24 spacing = IUniswapV3Factory(c.factory).feeAmountTickSpacing(fee);
            (int24 fullLo, int24 fullHi) = _fullRange(spacing);
            require(
                lo == fullLo && hi == fullHi,
                unicode"позиция НЕ full range (см. LP_EXPECT_FULL_RANGE)"
            );
        }

        console2.log("tokenId:         ", tokenId);
        console2.log("owner:           ", owner);
        console2.log("liquidity:       ", uint256(liq));
        console2.log("uncollected fee0:", uint256(owed0));
        console2.log("uncollected fee1:", uint256(owed1));
        if (owed0 > 0 || owed1 > 0) {
            console2.log("");
            console2.log(
                unicode"ВНИМАНИЕ: на позиции есть несобранные комиссии, после сжигания они пропадут."
            );
        }

        vm.startBroadcast();
        INonfungiblePositionManager(c.npm).safeTransferFrom(owner, DEAD, tokenId);
        vm.stopBroadcast();

        console2.log("");
        console2.log("new owner:       ", INonfungiblePositionManager(c.npm).ownerOf(tokenId));
        console2.log(unicode"ликвидность заперта навсегда");
    }
}
