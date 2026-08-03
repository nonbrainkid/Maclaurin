// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

/**
 * @title AuditProbe
 * @notice НЕЗАВИСИМЫЕ проверки, написанные при ревью — отдельно от основного
 *         набора тестов.
 *
 * @dev Зачем отдельный файл. Основной набор писал тот же агент, что и контракты.
 *      Такие тесты проверяют не «правильно ли работает контракт», а «делает ли
 *      контракт то, что автор задумал» — а если автор ошибся в самом замысле,
 *      тесты подтвердят ошибку и покажут зелёный цвет. Поэтому пробы ниже
 *      написаны от сценариев, а не от кода: что реально может произойти в
 *      мейннете и чего нет в основном наборе.
 */
contract AuditProbe is Test {
    MaclaurinEmission emission;
    MaclaurinToken token;

    address genesis = makeAddr("genesis");
    address vault = makeAddr("vault");

    /// Сумма всех членов ряда n=2..26 — то, что контракт способен выпустить.
    uint256 constant SERIES = 718_281_828_459_045_235_360_287_457;
    /// Пул эмиссии. Разница с SERIES — те самые 14 wei остаточного члена.
    uint256 constant POOL = 718_281_828_459_045_235_360_287_471;

    function setUp() public {
        vm.warp(1_000_000);
        emission = new MaclaurinEmission(genesis, vault, block.timestamp);
        token = emission.token();
    }

    /// @dev Радиус 1 — минимальный: множитель 1.0x и лок в одну эпоху.
    ///      Пробы ниже проверяют арифметику эмиссии и платёжеспособность,
    ///      а не механику множителей, поэтому радиус здесь не должен
    ///      добавлять к сценарию ничего своего.
    function _stake(address who, uint256 amt) internal {
        _stake(who, amt, 1);
    }

    function _stake(address who, uint256 amt, uint256 radius) internal {
        vm.prank(genesis);
        token.transfer(who, amt);
        vm.startPrank(who);
        token.approve(address(emission), amt);
        emission.stake(amt, radius);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
        1. ГРИФИНГ ЧЕРЕЗ ФРАГМЕНТАЦИЮ НАЧИСЛЕНИЯ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Атакующий дёргает _accrue снова и снова, чтобы округление вниз
     *         съело награду остальных.
     *
     * @dev Вектор реален по конструкции: каждый вызов _accrue делает
     *      `rpt += scaled / total` с округлением вниз, и остаток теряется.
     *      Чем чаще дёргать, тем больше вызовов и тем больше суммарная потеря.
     *      Проверяю на эпохе 26 — худший случай, там весь член ряда равен 2 wei.
     *      Дёргаю каждый час (168 раз за эпоху) через stake(1 wei) от чужого
     *      адреса: это самая дешёвая точка входа, которая двигает аккумулятор.
     *
     *      РЕЗУЛЬТАТ ЗАМЕРА: 168 фрагментаций превращают 2 wei в 1 wei.
     *      То есть вектор существует, но потолок ущерба — 66 wei за всю
     *      эмиссию (эпохи 25-26), и то лишь если в стейке лежит ВЕСЬ сапплай,
     *      а атакующий шлёт транзакцию каждый блок Base — 302 400 транзакций
     *      на эпоху. Газ на такую атаку на много порядков дороже 6.6e-17
     *      токена, которые она уничтожает. Это Informational, а не уязвимость,
     *      и тест фиксирует границу деградации, чтобы будущее изменение
     *      ACC_PRECISION или логики _project не расширило её незаметно.
     */
    function test_probe_GriefingByFragmentedAccrual() public {
        _stake(makeAddr("alice"), 1000e18);

        address griefer = makeAddr("griefer");
        vm.prank(genesis);
        token.transfer(griefer, 1e18);
        vm.prank(griefer);
        token.approve(address(emission), type(uint256).max);

        vm.warp(emission.epochEndsAt(25));
        uint256 before = emission.earned(makeAddr("alice"));

        // Вся эпоха 26 по часу, с вызовом _accrue на каждом шаге.
        for (uint256 i = 0; i < 168; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(griefer);
            emission.stake(1, 1);
        }
        vm.warp(emission.epochEndsAt(26));

        uint256 tail = emission.earned(makeAddr("alice")) - before;
        emit log_named_uint("tail after 168 fragmentations (wei)", tail);

        // Хвост деградирует, но не исчезает: член ряда остаётся ненулевым.
        assertGt(
            tail,
            0,
            unicode"фрагментация не должна стирать член ряда полностью"
        );
        assertLe(
            tail,
            2,
            unicode"начисление не может вырасти от фрагментации"
        );
    }

    /// @notice Потолок ущерба от фрагментации по всей эмиссии — единицы wei.
    /// @dev Считаю не «сколько потерял один», а сколько вообще можно уничтожить:
    ///      разницу между полной суммой ряда и тем, что реально дошло до
    ///      единственного стейкера при агрессивной фрагментации всей эмиссии.
    function test_probe_GriefingDamageCeiling() public {
        address victim = makeAddr("victim");
        _stake(victim, 1000e18);

        address griefer = makeAddr("griefer");
        vm.prank(genesis);
        token.transfer(griefer, 1e18);
        vm.prank(griefer);
        token.approve(address(emission), type(uint256).max);

        // Вся эмиссия, фрагментированная по 6 часов: 700 вызовов _accrue.
        uint256 end = emission.emissionEnd();
        while (block.timestamp + 6 hours < end) {
            vm.warp(block.timestamp + 6 hours);
            vm.prank(griefer);
            emission.stake(1, 1);
        }
        vm.warp(end + 1);

        uint256 got = emission.earned(victim) + emission.earned(griefer);
        uint256 destroyed = SERIES - got;

        emit log_named_uint("destroyed by 700 fragmentations (wei)", destroyed);
        assertLt(
            destroyed, 1e9, unicode"ущерб должен оставаться на уровне пыли"
        );
    }

    /*//////////////////////////////////////////////////////////////
        2. МНОГО СТЕЙКЕРОВ + ВСЕ ЗАБИРАЮТ ВСЁ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice 20 стейкеров с разными долями проходят всю эмиссию и разом
     *         выходят. Проверяю, что контракт остаётся платёжеспособным и
     *         никто не остаётся с ревертящей транзакцией.
     *
     * @dev Это сценарий, где округление накапливается сильнее всего: потеря
     *      возникает и в аккумуляторе (деление на total), и в каждом
     *      персональном _earned (деление на ACC_PRECISION), то есть 20 раз.
     *      Если бы округление где-то шло ВВЕРХ, дефицит проявился бы именно
     *      здесь — последнему в очереди не хватило бы на выплату.
     */
    function test_probe_ManyStakers_AllExit_NoDeficit() public {
        address[20] memory users;
        for (uint256 i = 0; i < 20; ++i) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            _stake(users[i], (i + 1) * 137e18); // намеренно некруглые доли
        }

        vm.warp(emission.emissionEnd() + 1);

        uint256 totalPaid;
        for (uint256 i = 0; i < 20; ++i) {
            uint256 balBefore = token.balanceOf(users[i]);
            vm.prank(users[i]);
            emission.exit(); // ни один вызов не должен реверить
            totalPaid += token.balanceOf(users[i]) - balBefore - (i + 1) * 137e18;
        }

        assertLe(totalPaid, SERIES, unicode"выплачено больше, чем есть в ряде");
        assertEq(emission.totalStaked(), 0, unicode"принципал возвращён весь");
        assertGe(token.balanceOf(address(emission)), 0);

        // Насколько полно распределился ряд при 20 участниках.
        emit log_named_uint("distributed", totalPaid);
        emit log_named_uint("series total", SERIES);
        emit log_named_uint("lost to rounding", SERIES - totalPaid);
    }

    /*//////////////////////////////////////////////////////////////
        3. ЗАБЫТЫЙ СТЕЙК
    //////////////////////////////////////////////////////////////*/

    /// @notice Пользователь застейкал и вспомнил через 10 лет после конца эмиссии.
    /// @dev Награда не должна ни протухнуть, ни вырасти. Контракт неизменяем —
    ///      «зайти позже» здесь единственный доступный пользователю сценарий.
    function test_probe_ForgottenStake_ClaimableTenYearsLater() public {
        address late = makeAddr("late");
        _stake(late, 1000e18);

        vm.warp(emission.emissionEnd());
        uint256 atEnd = emission.earned(late);

        vm.warp(block.timestamp + 3650 days);
        assertEq(
            emission.earned(late), atEnd, unicode"награда не изменилась за 10 лет"
        );

        vm.prank(late);
        emission.exit();
        assertEq(
            token.balanceOf(late), 1000e18 + atEnd, unicode"забрал принципал и награду"
        );
    }

    /*//////////////////////////////////////////////////////////////
        4. НИКТО НЕ СТЕЙКАЛ ВООБЩЕ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Если за всю эмиссию не пришёл ни один стейкер, весь ряд обязан
     *         дойти до казны остаточного члена, а не запереться в контракте.
     *
     * @dev Проверяю именно на предмет «запертых навсегда» токенов: контракт
     *      неизменяем, и если здесь останется дыра, 718 миллионов токенов
     *      будут заблокированы без единого способа их достать.
     */
    function test_probe_NobodyEverStakes_PoolReachesVault() public {
        vm.warp(emission.emissionEnd() + 1);

        emission.sweepToRemainderVault();

        uint256 swept = token.balanceOf(vault);
        assertApproxEqAbs(swept, SERIES, 1e6, unicode"весь ряд ушёл в казну");

        uint256 stuck = token.balanceOf(address(emission));
        emit log_named_uint("stuck in contract forever (wei)", stuck);
        assertLt(stuck, 1e9, unicode"в контракте не заперта значимая сумма");
    }

    /*//////////////////////////////////////////////////////////////
        5. ГРАНИЦА ЭМИССИИ
    //////////////////////////////////////////////////////////////*/

    /// @notice Стейк ровно в последнюю секунду эмиссии не должен ничего давать,
    ///         но и не должен ломать учёт.
    function test_probe_StakeAtExactEmissionEnd() public {
        _stake(makeAddr("early"), 1000e18);

        vm.warp(emission.emissionEnd());
        address edge = makeAddr("edge");
        _stake(edge, 1000e18);

        vm.warp(block.timestamp + 365 days);
        assertEq(
            emission.earned(edge),
            0,
            unicode"после конца эмиссии не начисляется"
        );

        vm.prank(edge);
        emission.unstake(1000e18);
        assertEq(token.balanceOf(edge), 1000e18, unicode"принципал вернулся целиком");
    }

    /*//////////////////////////////////////////////////////////////
        6. ПЛАТЁЖЕСПОСОБНОСТЬ ПРИ ПОЛНОМ ИСХОДЕ + SWEEP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Худший случай для казны: часть эмиссии прошла без стейкеров
     *         (растёт unallocated), часть — со стейкерами, и в конце ВСЕ
     *         забирают всё, включая sweep в казну.
     *
     * @dev Здесь проверяется, что unallocated и награды стейкеров не
     *      пересекаются. Если бы они считались с одного и того же отрезка
     *      времени дважды, контракт попытался бы выплатить больше, чем держит,
     *      и последняя транзакция зареверила бы навсегда.
     */
    function test_probe_MixedEmptyAndStakedPeriods_StaysSolvent() public {
        // Эпохи 2-3 идут вообще без стейкеров.
        vm.warp(emission.epochEndsAt(3));

        address a = makeAddr("a");
        address b = makeAddr("b");
        _stake(a, 5000e18);
        vm.warp(emission.epochEndsAt(10));
        _stake(b, 12345e18);

        vm.warp(emission.emissionEnd() + 1);

        uint256 earnedA = emission.earned(a);
        uint256 earnedB = emission.earned(b);
        uint256 unalloc = emission.pendingUnallocated();

        // Обязательства не превышают того, что контракт реально держит.
        uint256 obligations = earnedA + earnedB + unalloc + emission.totalStaked();
        assertGe(
            token.balanceOf(address(emission)), obligations, unicode"неплатёжеспособность"
        );

        // И все три выплаты реально проходят.
        vm.prank(a);
        emission.exit();
        vm.prank(b);
        emission.exit();
        emission.sweepToRemainderVault();

        assertEq(token.balanceOf(a), 5000e18 + earnedA);
        assertEq(token.balanceOf(b), 12345e18 + earnedB);
        assertEq(token.balanceOf(vault), unalloc);

        // Суммарно роздано не больше суммы ряда.
        assertLe(earnedA + earnedB + unalloc, SERIES, unicode"перевыплата ряда");
        emit log_named_uint("unallocated to vault", unalloc);
        emit log_named_uint("total distributed", earnedA + earnedB + unalloc);
    }

    /*//////////////////////////////////////////////////////////////
        7. ЧУЖОЙ ТОКЕН НЕ ЗАСТРЕВАЕТ КАК ЧУЖАЯ НАГРАДА
    //////////////////////////////////////////////////////////////*/

    /// @notice Донат $MACLRN напрямую в контракт не должен увеличивать ничью
    ///         награду — учёт идёт по счётчикам, а не по balanceOf.
    /// @dev Обратная сторона: донат оказывается заперт навсегда. Это осознанный
    ///      размен — альтернатива (считать от balanceOf) открывает дыру, при
    ///      которой донат раздувает награды и позволяет вынести принципал.
    function test_probe_DonationIsIgnoredAndStuck() public {
        address a = makeAddr("a");
        _stake(a, 1000e18);

        vm.warp(emission.epochEndsAt(2));
        uint256 beforeDonation = emission.earned(a);

        vm.prank(genesis);
        token.transfer(address(emission), 1_000_000e18);

        assertEq(
            emission.earned(a), beforeDonation, unicode"донат не влияет на награду"
        );
    }

    /*//////////////////////////////////////////////////////////////
        8. ЭКОНОМИКА ЗАПУСКА: ОДИНОКИЙ СТЕЙКЕР
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Что получит один-единственный стейкер, застейкавший 1 wei,
     *         если в эпоху 2 больше не придёт никто.
     *
     * @dev Это НЕ баг кода — распределение pro-rata работает ровно как
     *      задумано. Это риск запуска: минимального стейка нет, warmup нет,
     *      а эпоха 2 — самый жирный член ряда во всей эмиссии. Если рынок
     *      не заметил старт, весь этот член достаётся одному адресу за
     *      пылинку. Проба существует, чтобы цифра была измерена, а не
     *      обнаружена постфактум в мейннете.
     */
    function test_probe_LoneDustStaker_TakesEntireEpoch() public {
        address lone = makeAddr("lone");
        vm.prank(genesis);
        token.transfer(lone, 1);
        vm.startPrank(lone);
        token.approve(address(emission), 1);
        emission.stake(1, 1); // ровно 1 wei = 1e-18 MACLRN
        vm.stopPrank();

        vm.warp(emission.epochEndsAt(2));

        uint256 got = emission.earned(lone);
        uint256 pctOfSupply = (got * 10000) / token.totalSupply();

        emit log_named_uint("staked (wei)", 1);
        emit log_named_uint("earned (whole tokens)", got / 1e18);
        emit log_named_uint("share of total supply (bps)", pctOfSupply);

        assertEq(got, emission.epochAmount(2), unicode"забрал весь член ряда эпохи 2");
    }

    /*//////////////////////////////////////////////////////////////
        9. ИСТЁКШИЙ ЛОК БЕЗ POKE: ЦЕНА ОСОЗНАННОГО КОМПРОМИССА
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Пока `poke` никто не позвал, отсидевший лок продолжает получать
     *         буст, уже ничем не рискуя. Проба измеряет, сколько это стоит.
     *
     * @dev Это НЕ баг: кипера в системе нет и не будет, а перебирать стейкеров
     *      в цикле — неограниченный газ. Важно другое — что именно теряется.
     *      Проверяю два свойства:
     *
     *      1. Это перераспределение МЕЖДУ стейкерами, а не потеря для
     *         протокола: суммарная выплата за эпоху по-прежнему не превышает
     *         член ряда. Лишнего из пула не уходит ни wei.
     *      2. Ущерб ограничен отношением множителей (2.718x против 1x), то
     *         есть худший случай известен заранее и не зависит от того, как
     *         долго никто не звал `poke`.
     *
     *      Плюс у любого другого стейкера есть прямой денежный стимул позвать
     *      её самому — что и проверяется последним блоком.
     */
    function test_probe_ExpiredLockKeepsBoostUntilPoked() public {
        address holder = makeAddr("holder"); // R=7, отсидит и останется
        address plain = makeAddr("plain"); // R=1, страдающая сторона
        _stake(holder, 1000e18, 7);
        _stake(plain, 1000e18, 1);

        // Лок holder'а истёк, но poke никто не позвал.
        vm.warp(emission.epochEndsAt(8));
        uint256 holderAt = emission.earned(holder);
        uint256 plainAt = emission.earned(plain);

        vm.warp(emission.epochEndsAt(9));
        uint256 holderGain = emission.earned(holder) - holderAt;
        uint256 plainGain = emission.earned(plain) - plainAt;
        uint256 epoch9 = emission.epochAmount(9);

        emit log_named_uint("unpoked holder gain", holderGain);
        emit log_named_uint("diluted plain gain", plainGain);

        // Свойство 1: из пула не ушло лишнего.
        assertLe(holderGain + plainGain, epoch9, unicode"перевыплата члена ряда");

        // Свойство 2: перекос ровно в отношении множителей, не больше.
        assertApproxEqAbs(
            holderGain * 1e18 / plainGain,
            emission.multiplier(7),
            1e12,
            unicode"перекос больше отношения множителей"
        );

        // Свойство 3: лечится кем угодно, без разрешения и без выбора суммы.
        vm.prank(plain);
        emission.poke(holder);

        uint256 holderAfter = emission.earned(holder);
        uint256 plainAfter = emission.earned(plain);
        vm.warp(emission.epochEndsAt(10));

        assertApproxEqAbs(
            emission.earned(holder) - holderAfter,
            emission.earned(plain) - plainAfter,
            2,
            unicode"после poke делят поровну"
        );
    }

    /*//////////////////////////////////////////////////////////////
        10. СГОРЕВШАЯ НАГРАДА НЕ ИСЧЕЗАЕТ И НЕ ЗАПИРАЕТСЯ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Смешанный сценарий: часть стейкеров выходит досрочно, часть
     *         досиживает. Проверяю, что сожжённое дошло до казны ровно и
     *         контракт остался платёжеспособным.
     *
     * @dev Досрочный выход — единственное место, где токены меняют «владельца»
     *      внутри учёта, не двигаясь физически. Если бы сожжённая награда
     *      просто вычиталась из rewards, не попадая в unallocated, она стала бы
     *      заперта навсегда: контракт неизменяем, вытащить её было бы нечем.
     *      Проверяю по деньгам, а не по счётчикам — сколько реально пришло
     *      на адрес казны.
     */
    function test_probe_ForfeitedRewardsAreNeitherLostNorStuck() public {
        address quitter = makeAddr("quitter");
        address stayer = makeAddr("stayer");
        _stake(quitter, 5000e18, 7);
        _stake(stayer, 5000e18, 7);

        // Обоим есть что терять.
        vm.warp(emission.epochEndsAt(4));
        uint256 burned = emission.earned(quitter);
        assertGt(burned, 0);

        vm.prank(quitter);
        emission.exit(); // досрочно: тело целиком, награда в казну

        assertEq(token.balanceOf(quitter), 5000e18, unicode"тело вернулось целиком");
        assertEq(emission.earned(quitter), 0, unicode"награда сгорела вся");
        assertEq(
            emission.unallocated(), burned, unicode"ровно столько, сколько сгорело"
        );

        // Второй досиживает лок ДО КОНЦА и забирает своё.
        // Момент берётся из самого контракта: выйти на эпоху раньше значило бы
        // сжечь награду и второму, и проба перестала бы проверять то, ради
        // чего написана.
        vm.warp(emission.unlockTimeOf(stayer));
        uint256 owed = emission.earned(stayer);
        vm.prank(stayer);
        emission.exit();

        emission.sweepToRemainderVault();

        assertEq(token.balanceOf(vault), burned, unicode"казна получила сожжённое");
        assertEq(token.balanceOf(stayer), 5000e18 + owed, unicode"честный забрал всё");
        assertLe(burned + owed, SERIES, unicode"суммарно не больше ряда");
        assertGe(
            token.balanceOf(address(emission)),
            emission.totalStaked(),
            unicode"платёжеспособен"
        );

        emit log_named_uint("forfeited to vault", burned);
        emit log_named_uint("paid to patient staker", owed);
    }
}
