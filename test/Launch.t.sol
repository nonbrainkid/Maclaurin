// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Launch} from "../script/Launch.s.sol";
import {MaclaurinCurve} from "../src/MaclaurinCurve.sol";
import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";
import {MaclaurinVesting} from "../src/MaclaurinVesting.sol";

/**
 * @title  LaunchTest
 * @notice Полный прогон боевого скрипта запуска фазы 4: развернуть казну и
 *         кривую, разложить genesis, проверить результат.
 *
 * @dev ЗАЧЕМ ЭТО ОТДЕЛЬНЫЙ НАБОР — та же причина, что у DeployTest и
 *      DistributeTest: скрипт исполняется ровно один раз и необратимо, а
 *      контракты, которые он разворачивает, неизменяемы. Пока `launch()`
 *      никто не вызывал, ни один его `require` не исполнялся, то есть
 *      страховка сама была непроверенной.
 *
 *      ГЛАВНЫЙ ТЕСТ НАБОРА — test_Launch_AntiSnipeWindowIsStillOpenAfterRun.
 *      Ради него скрипт и написан: окно анти-снайпа стартует в конструкторе
 *      кривой, а торговать ей нечем до прихода инвентаря. Раздельные команды
 *      оставляли между этими двумя точками сколько угодно времени, и если бы
 *      его набралось больше часа, лимит §4.5 не сработал бы ни разу.
 *
 *      ПРО «локальный форк». Тесты Foundry исполняются на том же revm, на
 *      котором работает anvil, поэтому основной прогон здесь локальный — как
 *      и объяснено в DeployTest. Вариант с форком живой сети включается
 *      переменной `DEPLOY_FORK_RPC_URL` (та же, что у DeployTest — новых
 *      переменных набор не заводит) и пропускается, когда её нет.
 *
 *      ПРО ОКРУЖЕНИЕ. Этот набор НЕ вызывает `vm.setEnv` ни разу, и это
 *      осознанно. Переменные окружения у процесса общие, а forge исполняет
 *      наборы параллельно: запись `MACLAURIN_TOKEN` или `EXPECTED_UNLOCK_TIME`
 *      отсюда сломала бы DistributeTest, который читает их же в `run()`.
 *      Поэтому тесты зовут параметризованную `launch(Config)` — тот же самый
 *      код, только без чтения `.env`. Само чтение окружения проверяется
 *      сухим прогоном скрипта против сети (DEPLOY-RUNBOOK §12).
 */
contract LaunchTest is Test {
    Launch internal script;
    MaclaurinEmission internal emission;
    MaclaurinToken internal token;

    address internal sender = makeAddr("launchGenesisRecipient");
    address internal beneficiary = makeAddr("launchTreasuryBeneficiary");
    address internal feeRecipient = makeAddr("launchFeeRecipient");
    address internal marketing = makeAddr("launchMarketingWallet");
    address internal reserveWallet = makeAddr("launchReserveWallet");
    address internal remainder = makeAddr("launchRemainderVault");

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Числа из §7 спеки, продублированные литералами намеренно: тест, который
    // читает долю из проверяемого скрипта, не проверяет ничего.
    uint256 internal constant SPEC_GENESIS = 2000000000000000000000000000;
    uint256 internal constant SPEC_CURVE = 1000000000000000000000000000;
    uint256 internal constant SPEC_VESTING = 500000000000000000000000000;
    uint256 internal constant SPEC_BURN = 250000000000000000000000000;
    uint256 internal constant SPEC_MARKETING = 125000000000000000000000000;
    uint256 internal constant SPEC_RESERVE = 62500000000000000000000000;
    uint256 internal constant SPEC_REMAINDER = 62500000000000000000000000;

    /// @dev Час, ANTI_SNIPE_WINDOW кривой. Литералом, а не чтением константы.
    uint256 internal constant SPEC_ANTI_SNIPE_WINDOW = 3600;

    /// @dev 1% инвентаря — потолок покупки на адрес внутри окна.
    uint256 internal constant SPEC_ANTI_SNIPE_MAX = 10000000000000000000000000;

    /**
     * @dev Токен и эмиссия разворачиваются здесь ровно так же, как это делает
     *      `Deploy.s.sol`: эмиссия создаёт токен в своём конструкторе и кладёт
     *      genesis на `sender`. Заглушка вместо эмиссии не подошла бы — скрипт
     *      сверяет дату разблокировки казны с её `emissionEnd()`.
     */
    function setUp() public {
        vm.warp(1_700_000_000);

        script = new Launch();
        emission = new MaclaurinEmission(sender, remainder, block.timestamp + 300);
        token = emission.token();
    }

    function _config() internal view returns (Launch.Config memory) {
        return Launch.Config({
            token: IERC20(address(token)),
            sender: sender,
            beneficiary: beneficiary,
            unlockTime: emission.emissionEnd(),
            feeRecipient: feeRecipient,
            marketing: marketing,
            reserve: reserveWallet,
            remainder: remainder,
            expectedUnlockTime: 0,
            emission: address(emission)
        });
    }

    /*//////////////////////////////////////////////////////////////
                             ОСНОВНОЙ ПРОГОН
    //////////////////////////////////////////////////////////////*/

    /// @notice Скрипт разворачивает оба контракта и наполняет их.
    function test_Launch_DeploysBothContractsAndFillsThem() public {
        (MaclaurinCurve curve, MaclaurinVesting vesting) = script.launch(_config());

        assertTrue(address(curve) != address(0), unicode"кривая не развёрнута");
        assertTrue(address(vesting) != address(0), unicode"казна не развёрнута");

        assertEq(token.balanceOf(address(curve)), SPEC_CURVE, unicode"инвентарь кривой");
        assertEq(token.balanceOf(address(vesting)), SPEC_VESTING, unicode"казна");

        // Инвентарь совпадает с тем, что кривая считает своим инвентарём.
        // Недостача означала бы, что последние покупки отревертят на переводе;
        // излишек застрял бы в контракте навсегда — функции спасения нет.
        assertEq(curve.INVENTORY(), token.balanceOf(address(curve)), unicode"INVENTORY == баланс");

        assertEq(address(curve.token()), address(token), unicode"кривая на том же токене");
        assertEq(address(vesting.token()), address(token), unicode"казна на том же токене");
        assertEq(curve.feeRecipient(), feeRecipient);
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(
            vesting.unlockTime(), emission.emissionEnd(), unicode"замок до конца эмиссии"
        );
    }

    /// @notice Главный итог §7: на личном адресе создателя после запуска ноль.
    function test_Launch_DrainsSenderToZero() public {
        assertEq(token.balanceOf(sender), SPEC_GENESIS, unicode"до запуска — весь genesis");

        script.launch(_config());

        assertEq(token.balanceOf(sender), 0, unicode"после запуска — ноль");
    }

    /// @notice Каждая доля таблицы §7 доехала до своего адреса.
    function test_Launch_DeliversEveryShareOfTheSpecTable() public {
        (MaclaurinCurve curve, MaclaurinVesting vesting) = script.launch(_config());

        assertEq(token.balanceOf(address(curve)), SPEC_CURVE, unicode"1/2 — инвентарь");
        assertEq(token.balanceOf(address(vesting)), SPEC_VESTING, unicode"1/4 — казна");
        assertEq(token.balanceOf(DEAD), SPEC_BURN, unicode"1/8 — сожжено");
        assertEq(token.balanceOf(marketing), SPEC_MARKETING, unicode"1/16 — маркетинг");
        assertEq(token.balanceOf(reserveWallet), SPEC_RESERVE, unicode"1/32 — резерв");
        assertEq(token.balanceOf(remainder), SPEC_REMAINDER, unicode"хвост ряда");

        uint256 handedOut = token.balanceOf(address(curve)) + token.balanceOf(address(vesting))
            + token.balanceOf(DEAD) + token.balanceOf(marketing) + token.balanceOf(reserveWallet)
            + token.balanceOf(remainder);

        assertEq(handedOut, SPEC_GENESIS, unicode"роздано ровно genesis");
        assertEq(
            token.balanceOf(address(emission)),
            token.EMISSION_POOL(),
            unicode"пул эмиссии не тронут"
        );
    }

    /// @notice Кривая после запуска чиста: ни продаж, ни резерва, ни комиссии.
    function test_Launch_CurveStartsEmpty() public {
        (MaclaurinCurve curve,) = script.launch(_config());

        assertEq(curve.sold(), 0);
        assertEq(curve.reserve(), 0);
        assertEq(curve.feesAccrued(), 0);
        assertEq(address(curve).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    РАДИ ЧЕГО ЭТОТ СКРИПТ СУЩЕСТВУЕТ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice К концу прогона окно анти-снайпа ещё открыто.
     *
     * @dev Это и есть смысл всей задачи. `startTime` кривой ставится в
     *      КОНСТРУКТОРЕ, а продавать ей нечего до прихода инвентаря отдельной
     *      транзакцией. Разнеси эти два шага на час — и лимит §4.5 истечёт
     *      раньше, чем начнутся торги: первый же бот выкупит существенную
     *      долю по минимальной цене, и чинить будет нечего.
     *
     *      Проверяется не только арифметика окна, но и то, что лимит реально
     *      кусается: попытка забрать больше 1% инвентаря одним адресом
     *      отбивается, а после истечения окна та же самая покупка проходит.
     *      Второе важно не меньше первого — оно доказывает, что отказ дало
     *      именно окно, а не нехватка ETH или инвентаря.
     */
    function test_Launch_AntiSnipeWindowIsStillOpenAfterRun() public {
        (MaclaurinCurve curve,) = script.launch(_config());

        assertEq(
            curve.startTime(),
            block.timestamp,
            unicode"кривая развёрнута этим прогоном"
        );
        assertEq(curve.ANTI_SNIPE_WINDOW(), SPEC_ANTI_SNIPE_WINDOW);
        assertEq(curve.ANTI_SNIPE_MAX(), SPEC_ANTI_SNIPE_MAX);
        assertLt(
            block.timestamp - curve.startTime(),
            SPEC_ANTI_SNIPE_WINDOW,
            unicode"между деплоем кривой и раздачей прошло меньше часа"
        );
        assertGt(curve.antiSnipeEnd(), block.timestamp, unicode"окно ещё не закрылось");

        // Снайпер хочет 11 млн токенов при потолке в 10 млн.
        address sniper = makeAddr("sniper");
        uint256 tooMuch = SPEC_ANTI_SNIPE_MAX + 1_000_000e18;
        uint256 net = curve.quoteBuyCost(tooMuch);
        // С запасом на комиссию: netIn обязан покрыть `net`, иначе покупка
        // упрётся в проскальзывание, а не в лимит, и тест проверит не то.
        uint256 gross = net + net / 90 + 10;
        vm.deal(sniper, gross);

        // Селектор, а не полные аргументы: `requested` в ошибке — это ровно
        // столько токенов, сколько купил бы `gross`, и привязывать тест к
        // этому числу значит переписывать его при любой правке констант.
        vm.prank(sniper);
        vm.expectPartialRevert(MaclaurinCurve.AntiSnipeLimit.selector);
        curve.buy{value: gross}(1, block.timestamp);

        assertEq(token.balanceOf(sniper), 0, unicode"снайперу не досталось ничего");
        assertEq(curve.sold(), 0);

        // То же самое после закрытия окна проходит — значит отказ выше дало
        // именно окно.
        vm.warp(curve.antiSnipeEnd());
        vm.prank(sniper);
        curve.buy{value: gross}(1, block.timestamp);

        assertGt(
            token.balanceOf(sniper), SPEC_ANTI_SNIPE_MAX, unicode"после окна лимита нет"
        );
    }

    /**
     * @notice Обычный покупатель может купить и выйти сразу после запуска.
     *
     * @dev Проверок балансов недостаточно: они не говорят, что механика вообще
     *      работает. Здесь развёрнутая связка проходит путь настоящего
     *      покупателя, включая гарантию §4.7 — кто вошёл через кривую, тот
     *      через неё и выходит.
     */
    function test_Launch_CurveIsUsableFromTheFirstBlock() public {
        (MaclaurinCurve curve,) = script.launch(_config());

        address buyer = makeAddr("buyer");
        uint256 spend = 0.001 ether;
        vm.deal(buyer, spend);

        vm.prank(buyer);
        uint256 bought = curve.buy{value: spend}(1, block.timestamp);

        assertGt(bought, 0, unicode"кривой было чем торговать");
        assertLt(
            bought,
            SPEC_ANTI_SNIPE_MAX,
            unicode"обычная покупка в лимит укладывается"
        );
        assertEq(token.balanceOf(buyer), bought);
        assertEq(curve.boughtOf(buyer), bought, unicode"право выкупа начислено");

        vm.prank(buyer);
        token.approve(address(curve), type(uint256).max);
        vm.prank(buyer);
        uint256 returned = curve.sell(bought, 1, block.timestamp);

        assertEq(token.balanceOf(buyer), 0, unicode"токены вернулись кривой");
        assertEq(curve.boughtOf(buyer), 0);
        assertGt(returned, 0, unicode"деньги вернулись покупателю");
        assertLt(returned, spend, unicode"круг купил-продал убыточен (§5.5)");
    }

    /**
     * @notice Доля казны после запуска лежит под замком, а не «у команды».
     * @dev 18.4% сапплая физически не могут двинуться до конца эмиссии —
     *      потому что функции досрочного вывода не существует, а не потому,
     *      что так обещано.
     */
    function test_Launch_TreasuryIsLockedUntilUnlockTime() public {
        (, MaclaurinVesting vesting) = script.launch(_config());

        uint256 unlock = vesting.unlockTime();
        assertEq(unlock, emission.emissionEnd(), unicode"замок до конца эмиссии");

        vm.expectRevert(abi.encodeWithSelector(MaclaurinVesting.StillLocked.selector, unlock));
        vesting.release();

        vm.warp(unlock);
        vesting.release();

        assertEq(token.balanceOf(beneficiary), SPEC_VESTING);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       ПРЕДУСЛОВИЯ: ЧТО НЕ ПРОЙДЁТ
    //////////////////////////////////////////////////////////////*/

    /// @notice Незаполненная строка в `.env` превращается в address(0).
    /// @dev Падать обязано ДО развёртывания: два неизменяемых контракта,
    ///      развёрнутых зря, — это уже не чинится, только новым запуском.
    function test_Launch_RevertsOnZeroAddresses() public {
        Launch.Config memory cfg = _config();
        cfg.token = IERC20(address(0));
        vm.expectRevert(bytes("MACLAURIN_TOKEN is zero"));
        script.launch(cfg);

        cfg = _config();
        cfg.beneficiary = address(0);
        vm.expectRevert(bytes("VESTING_BENEFICIARY is zero"));
        script.launch(cfg);

        cfg = _config();
        cfg.feeRecipient = address(0);
        vm.expectRevert(bytes("FEE_RECIPIENT is zero"));
        script.launch(cfg);

        cfg = _config();
        cfg.marketing = address(0);
        vm.expectRevert(bytes("MARKETING_WALLET is zero"));
        script.launch(cfg);

        assertEq(
            token.balanceOf(sender), SPEC_GENESIS, unicode"ни один перевод не прошёл"
        );
    }

    /// @notice Адрес токена, по которому нет кода, — это опечатка, а не токен.
    function test_Launch_RevertsIfTokenIsNotAContract() public {
        Launch.Config memory cfg = _config();
        cfg.token = IERC20(makeAddr("eoaByMistake"));

        vm.expectRevert(bytes("MACLAURIN_TOKEN is not a contract"));
        script.launch(cfg);
    }

    /**
     * @notice Уже открытая казна — это не казна, а кошелёк.
     * @dev Конструктор `MaclaurinVesting` отревертил бы `UnlockTimeInPast`,
     *      но голый селектор custom error в выводе скрипта не подсказывает,
     *      какую строку `.env` править.
     */
    function test_Launch_RevertsIfUnlockTimeIsNotInTheFuture() public {
        Launch.Config memory cfg = _config();
        cfg.unlockTime = block.timestamp;

        vm.expectRevert(bytes("VESTING_UNLOCK_TIME is not in the future"));
        script.launch(cfg);
    }

    /**
     * @notice `EXPECTED_UNLOCK_TIME` сверяется точным равенством и ДО деплоя.
     * @dev Проверка «дата в будущем» ловит только грубую ошибку. Дату,
     *      промахнувшуюся на год, не ловит ничто, кроме сверки с заранее
     *      посчитанным значением.
     */
    function test_Launch_UnlockTimeIsPinnedByExpectedValue() public {
        Launch.Config memory cfg = _config();
        cfg.expectedUnlockTime = cfg.unlockTime + 1;

        vm.expectRevert(bytes("VESTING_UNLOCK_TIME != EXPECTED_UNLOCK_TIME"));
        script.launch(cfg);

        assertEq(
            token.balanceOf(sender), SPEC_GENESIS, unicode"ни один перевод не прошёл"
        );

        cfg.expectedUnlockTime = cfg.unlockTime;
        (, MaclaurinVesting vesting) = script.launch(cfg);
        assertEq(vesting.unlockTime(), cfg.expectedUnlockTime);
    }

    /**
     * @notice Дата разблокировки сверяется с уже развёрнутой эмиссией.
     * @dev Это единственный источник даты, который нельзя набрать с опечаткой:
     *      он читается с цепочки. По §6 казна открывается ровно в конце
     *      эмиссии, `startTime + 175 дней`.
     */
    function test_Launch_RevertsIfUnlockTimeDoesNotMatchEmissionEnd() public {
        Launch.Config memory cfg = _config();
        cfg.unlockTime = emission.emissionEnd() + 1 days;

        vm.expectRevert(bytes("VESTING_UNLOCK_TIME != emission.emissionEnd()"));
        script.launch(cfg);
    }

    /// @notice Эмиссия от другого токена в `.env` — тоже опечатка, и ловится.
    function test_Launch_RevertsIfEmissionServesAnotherToken() public {
        MaclaurinEmission other =
            new MaclaurinEmission(makeAddr("otherGenesis"), makeAddr("otherVault"), block.timestamp + 300);

        Launch.Config memory cfg = _config();
        cfg.emission = address(other);

        vm.expectRevert(bytes("emission holds a different token"));
        script.launch(cfg);
    }

    /**
     * @notice Без `MACLAURIN_EMISSION` прогон проходит, но сверки с цепочкой
     *         не происходит — переменная необязательная.
     * @dev Нужно для репетиции на чистом anvil, где эмиссии может не быть.
     */
    function test_Launch_WorksWithoutEmissionCrossCheck() public {
        Launch.Config memory cfg = _config();
        cfg.emission = address(0);

        (MaclaurinCurve curve, MaclaurinVesting vesting) = script.launch(cfg);

        assertEq(token.balanceOf(address(curve)), SPEC_CURVE);
        assertEq(token.balanceOf(address(vesting)), SPEC_VESTING);
    }

    /**
     * @notice Запуск не начнётся, если на отправителе не ровно genesis.
     * @dev Меньше — кошелёк не тот или раскладка уже частично прошла. Больше —
     *      адрес используется ещё для чего-то, и обещание «после запуска ноль»
     *      стало бы ложным.
     */
    function test_Launch_RevertsIfSenderDoesNotHoldExactlyGenesis() public {
        vm.prank(sender);
        token.transfer(marketing, 1);

        // Конфигурация собирается ДО `expectRevert`: внутри `_config()` есть
        // внешний вызов `emission.emissionEnd()`, и он израсходовал бы
        // ожидание реверта на себя — проверялась бы не та ветка.
        Launch.Config memory cfg = _config();

        vm.expectRevert(bytes("sender does not hold exactly GENESIS"));
        script.launch(cfg);
    }

    /*//////////////////////////////////////////////////////////////
                        ПЕРЕИСПОЛЬЗОВАНИЕ DISTRIBUTE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Раздачу выполняет `Distribute`, а не копия его логики.
     *
     * @dev Проверяется по его собственным сообщениям об ошибках: попарная
     *      различность получателей — предусловие `Distribute._checkRecipients`,
     *      и в `Launch` такой проверки нет вовсе. Если однажды логику раздачи
     *      скопируют в скрипт запуска, этот тест погаснет вместе с ней.
     */
    function test_Launch_DelegatesDistributionToDistributeScript() public {
        Launch.Config memory cfg = _config();
        cfg.reserve = cfg.marketing;

        vm.expectRevert(bytes("duplicate address among recipients"));
        script.launch(cfg);

        cfg = _config();
        cfg.remainder = DEAD;

        vm.expectRevert(bytes("duplicate address among recipients"));
        script.launch(cfg);

        assertEq(
            token.balanceOf(sender), SPEC_GENESIS, unicode"ни один перевод не прошёл"
        );
    }

    /// @notice Сожжённая доля — тоже работа `Distribute`: адрес сжигания
    ///         константа в его байткоде, настроить его нечем.
    function test_Launch_BurnsTheEighthShareToTheCanonicalDeadAddress() public {
        script.launch(_config());

        assertEq(token.balanceOf(DEAD), SPEC_BURN, unicode"1/8 в 0x…dEaD");
    }

    /*//////////////////////////////////////////////////////////////
                            ВАРИАНТ С ФОРКОМ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Тот же прогон, но на форке реальной сети.
     *
     * @dev Включается наличием `DEPLOY_FORK_RPC_URL` — той же переменной, что
     *      у DeployTest (годится и локальный anvil). Без неё тест
     *      пропускается, чтобы CI не зависел от сети: запуск не читает
     *      состояние цепочки, поэтому форк здесь — дополнительная страховка,
     *      а не источник истины.
     *
     *      Всё разворачивается заново после `createSelectFork`: переключение
     *      форка уносит состояние, и контракты из `setUp` на нём не существуют.
     */
    function test_Launch_OnFork() public {
        string memory rpc = vm.envOr("DEPLOY_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc);

        Launch forkScript = new Launch();
        MaclaurinEmission forkEmission = new MaclaurinEmission(sender, remainder, block.timestamp + 300);
        MaclaurinToken forkToken = forkEmission.token();

        Launch.Config memory cfg = Launch.Config({
            token: IERC20(address(forkToken)),
            sender: sender,
            beneficiary: beneficiary,
            unlockTime: forkEmission.emissionEnd(),
            feeRecipient: feeRecipient,
            marketing: marketing,
            reserve: reserveWallet,
            remainder: remainder,
            expectedUnlockTime: forkEmission.emissionEnd(),
            emission: address(forkEmission)
        });

        (MaclaurinCurve curve, MaclaurinVesting vesting) = forkScript.launch(cfg);

        assertEq(forkToken.balanceOf(address(curve)), SPEC_CURVE);
        assertEq(forkToken.balanceOf(address(vesting)), SPEC_VESTING);
        assertEq(forkToken.balanceOf(sender), 0);
        assertGt(curve.antiSnipeEnd(), block.timestamp);
    }
}
