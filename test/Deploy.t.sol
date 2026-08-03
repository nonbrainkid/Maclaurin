// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

/**
 * @title  DeployTest
 * @notice Прогон боевого скрипта развёртывания целиком, включая `_verify`.
 *
 * @dev Зачем это отдельный тест. Скрипт деплоя — единственный код проекта,
 *      который исполняется РОВНО ОДИН РАЗ и необратимо. Контракты неизменяемы,
 *      второй попытки не будет: ошибка в скрипте стоит всего бюджета. При этом
 *      без теста у него нулевое покрытие, а slither его не смотрит.
 *
 *      Проверки внутри `_verify` — это require'ы на развёрнутых контрактах.
 *      Пока `run()` никто не вызывал, они не исполнялись НИ РАЗУ, то есть
 *      «страховка на деплое» сама была непроверенной. Здесь `run()` вызывается
 *      целиком, вместе со всеми require.
 *
 *      ПРО «anvil-форк». Тесты Foundry исполняются на том же самом revm, на
 *      котором работает anvil, — форк живой сети здесь ничего не добавил бы:
 *      деплой не читает состояние цепочки, у него нет внешних зависимостей.
 *      Зато форк потребовал бы RPC-эндпоинта, то есть сети и ключа в CI, и
 *      падал бы по причинам, не связанным с кодом. Поэтому основной прогон
 *      локальный, а вариант с форком включается переменной окружения и
 *      пропускается, когда её нет (`test_Run_OnFork`).
 */
contract DeployTest is Test {
    /// @dev Совпадает с константой скрипта. Дублируется литералом намеренно:
    ///      тест на «минимальную задержку» не должен читать её из того же
    ///      места, которое проверяет.
    uint256 internal constant SPEC_MIN_START_DELAY = 300;

    uint256 internal constant SPEC_TOTAL_SUPPLY = 2718281828459045235360287471;
    uint256 internal constant SPEC_GENESIS = 2000000000000000000000000000;
    uint256 internal constant SPEC_EMISSION_POOL = 718281828459045235360287471;
    uint256 internal constant SPEC_EMITTABLE = 718281828459045235360287457;

    address internal genesisRecipient = makeAddr("genesisRecipient");
    address internal remainderVault = makeAddr("remainderVault");

    /**
     * @dev ВАЖНО про переменные окружения. Forge исполняет тесты одного
     *      контракта параллельно, а окружение у процесса общее — `vm.setEnv`
     *      из одного теста виден всем остальным. Поэтому здесь пишутся только
     *      значения, одинаковые для всех тестов (сколько бы потоков их ни
     *      записало, результат один и тот же), а EMISSION_START_DELAY меняет
     *      ровно один тест — `test_Run_StartDelayIsAppliedAndClamped`.
     *      Остальные тесты не привязываются к конкретной задержке и проверяют
     *      только гарантированную нижнюю границу.
     */
    function setUp() public {
        vm.warp(1_700_000_000);
        vm.setEnv("GENESIS_RECIPIENT", vm.toString(genesisRecipient));
        vm.setEnv("REMAINDER_VAULT", vm.toString(remainderVault));
    }

    /*//////////////////////////////////////////////////////////////
                          ОСНОВНОЙ ПРОГОН
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice `run()` разворачивает связку и проходит все проверки `_verify`.
     * @dev Если хоть один require внутри `_verify` не выполнится, тест упадёт
     *      здесь — то есть ровно там, где это ещё можно починить.
     */
    function test_Run_DeploysAndPassesVerification() public {
        Deploy deployer = new Deploy();
        (MaclaurinEmission emission, MaclaurinToken token) = deployer.run();

        assertTrue(address(emission) != address(0), unicode"эмиссия не развёрнута");
        assertTrue(address(token) != address(0), unicode"токен не развёрнут");
        assertEq(address(emission.token()), address(token), unicode"связь контрактов");

        // Те же инварианты, что и в _verify, но проверенные независимо от него:
        // если бы _verify оказался пустым, это заметил бы именно этот блок.
        assertEq(token.totalSupply(), SPEC_TOTAL_SUPPLY);
        assertEq(token.GENESIS(), SPEC_GENESIS);
        assertEq(token.EMISSION_POOL(), SPEC_EMISSION_POOL);
        assertEq(token.balanceOf(genesisRecipient), SPEC_GENESIS, unicode"GENESIS доставлен");
        assertEq(token.balanceOf(address(emission)), SPEC_EMISSION_POOL, unicode"пул доставлен");
        assertEq(emission.totalEmittable(), SPEC_EMITTABLE);
        assertEq(token.EMISSION_POOL() - emission.totalEmittable(), 14, unicode"пыль = 14 wei");
        assertEq(emission.epochAmount(26), 2);
        assertEq(emission.epochAmount(27), 0, unicode"эмиссия завершается сама");
    }

    /// @notice Адреса берутся из окружения, а не зашиты в скрипт.
    function test_Run_UsesEnvironmentAddresses() public {
        Deploy deployer = new Deploy();
        (MaclaurinEmission emission, MaclaurinToken token) = deployer.run();

        assertEq(emission.remainderVault(), remainderVault, unicode"казна из окружения");
        assertEq(token.balanceOf(genesisRecipient), token.GENESIS());
    }

    /**
     * @notice Старт эмиссии всегда отложен минимум на MIN_START_DELAY.
     *
     * @dev Задержка не косметическая. `forge script --broadcast` сначала
     *      прогоняет `run()` в симуляции на снимке текущего блока и только
     *      потом отправляет транзакцию — она попадёт уже в следующий блок,
     *      где `block.timestamp` больше. Без запаса конструктор отреверит
     *      StartTimeInPast, причём симуляция при этом пройдёт успешно.
     */
    function test_Run_StartTimeIsAlwaysInTheFuture() public {
        Deploy deployer = new Deploy();
        (MaclaurinEmission emission,) = deployer.run();

        assertGe(
            emission.startTime(),
            block.timestamp + SPEC_MIN_START_DELAY,
            unicode"старт не ближе минимального запаса"
        );
        assertEq(emission.emissionEnd(), emission.startTime() + 175 days);
    }

    /**
     * @notice Задержка берётся из окружения, а слишком малая поднимается до
     *         MIN_START_DELAY.
     *
     * @dev Три варианта проверяются одним тестом намеренно: это единственный
     *      писатель EMISSION_START_DELAY во всём наборе (см. комментарий к
     *      setUp), поэтому гонки за общую переменную окружения быть не может.
     *
     *      Клампинг важен: без него достаточно опечатки в .env, чтобы деплой
     *      ушёл с нулевым запасом и отреверил StartTimeInPast на реальном
     *      блоке — уже после того, как симуляция показала успех.
     */
    function test_Run_StartDelayIsAppliedAndClamped() public {
        assertEq(
            new Deploy().MIN_START_DELAY(), SPEC_MIN_START_DELAY, unicode"минимум из скрипта"
        );

        vm.setEnv("EMISSION_START_DELAY", "600");
        (MaclaurinEmission normal,) = new Deploy().run();
        assertEq(normal.startTime(), block.timestamp + 600, unicode"задержка как задана");

        vm.setEnv("EMISSION_START_DELAY", "1");
        (MaclaurinEmission tooSmall,) = new Deploy().run();
        assertEq(
            tooSmall.startTime(),
            block.timestamp + SPEC_MIN_START_DELAY,
            unicode"задержка поднята до минимума"
        );

        vm.setEnv("EMISSION_START_DELAY", "86400");
        (MaclaurinEmission large,) = new Deploy().run();
        assertEq(
            large.startTime(),
            block.timestamp + 86400,
            unicode"большая задержка принята"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    РАЗВЁРНУТОЕ РЕАЛЬНО РАБОТАЕТ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Полный цикл на том, что вышло из скрипта: стейк с радиусом,
     *         отсидка лока, claim.
     *
     * @dev Проверок `_verify` недостаточно: они смотрят на константы и
     *      балансы, но не на то, что механика вообще работает после деплоя.
     *      Здесь развёрнутый контракт проходит путь настоящего пользователя.
     */
    function test_Run_DeployedSystemIsUsable() public {
        Deploy deployer = new Deploy();
        (MaclaurinEmission emission, MaclaurinToken token) = deployer.run();

        address user = makeAddr("user");
        vm.prank(genesisRecipient);
        token.transfer(user, 1000e18);

        vm.startPrank(user);
        token.approve(address(emission), type(uint256).max);
        emission.stake(1000e18, 2);
        vm.stopPrank();

        // До unlockTime награда копится, но не выходит.
        vm.warp(emission.startTime() + 7 days);
        assertGt(emission.earned(user), 0);

        // unlockTime читается ДО vm.prank: внешний вызов в аргументе
        // expectRevert израсходовал бы prank, и claim ушёл бы от имени
        // тест-контракта — то есть проверялась бы не та ветка.
        uint256 unlock = emission.unlockTimeOf(user);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(MaclaurinEmission.StillLocked.selector, unlock));
        emission.claim();

        vm.warp(unlock);
        uint256 reward = emission.earned(user);
        vm.prank(user);
        emission.exit();

        assertEq(token.balanceOf(user), 1000e18 + reward, unicode"тело и награда на руках");
        assertGe(token.balanceOf(address(emission)), emission.totalStaked());
    }

    /*//////////////////////////////////////////////////////////////
                         ВАРИАНТ С ФОРКОМ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Тот же прогон, но на форке реальной сети.
     *
     * @dev Включается наличием DEPLOY_FORK_RPC_URL (годится и локальный
     *      anvil: `anvil --fork-url ...`, затем
     *      `DEPLOY_FORK_RPC_URL=http://127.0.0.1:8545 forge test`).
     *      Без переменной тест пропускается, чтобы CI не зависел от сети:
     *      деплой не читает состояние цепочки, поэтому форк здесь —
     *      дополнительная страховка, а не источник истины.
     */
    function test_Run_OnFork() public {
        string memory rpc = vm.envOr("DEPLOY_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc);

        Deploy deployer = new Deploy();
        (MaclaurinEmission emission, MaclaurinToken token) = deployer.run();

        assertEq(token.totalSupply(), SPEC_TOTAL_SUPPLY);
        assertEq(token.balanceOf(genesisRecipient), SPEC_GENESIS);
        assertEq(token.balanceOf(address(emission)), SPEC_EMISSION_POOL);
        assertGe(emission.startTime(), block.timestamp + SPEC_MIN_START_DELAY);
    }
}
