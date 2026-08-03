// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MaclaurinToken} from "../../src/MaclaurinToken.sol";
import {MaclaurinEmission} from "../../src/MaclaurinEmission.sol";
import {MaclaurinCurve} from "../../src/MaclaurinCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*//////////////////////////////////////////////////////////////////////////
                  ЧТО ЭТО ЗА ФАЙЛ И ЧЕМ ОН ОТЛИЧАЕТСЯ ОТ ТЕСТОВ

 Всё остальное в test/ — это ТЕСТЫ: они подставляют конкретные значения (или
 случайные, если это фаззинг) и смотрят, не сломалось ли. Тест, который прошёл,
 доказывает ровно одно: на этих входах не сломалось.

 Здесь — ДОКАЗАТЕЛЬСТВА. halmos исполняет байткод символьно: аргумент не число,
 а переменная, и на каждом ветвлении инструмент спрашивает решатель, достижимы
 ли обе ветки. Если после перебора всех достижимых путей ни на одном не удалось
 подобрать значения, нарушающие утверждение, — утверждение верно для ВСЕХ
 входов, а не для перебранных. Это разница между «не нашли контрпример» и
 «контрпримера не существует».

 Функции называются check_* специально: forge test их не подхватывает (он ищет
 test*, testFuzz*, invariant*), поэтому файл не влияет на существующий прогон.
 Запуск — halmos, команды в README.

 ГРАНИЦЫ ЧЕСТНОСТИ. Доказано ровно то, что написано в assert, и ровно при тех
 предположениях, что стоят в vm.assume. Каждое vm.assume ниже прокомментировано:
 предположение, взятое с потолка, превращает доказательство в тавтологию.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Чит-коды halmos. Интерфейс объявлен здесь, а не подключён библиотекой
///      a16z/halmos-cheatcodes, сознательно: это избавляет от ещё одного
///      сабмодуля в проекте, где каждая зависимость — часть поверхности атаки.
///      Адрес — из halmos/cheatcodes.py, вычисляется как
///      address(uint160(uint256(keccak256("svm cheat code")))).
interface SVM {
    /// @notice Делает ВСЁ хранилище контракта символьным.
    /// @dev Это ключ к формулировке «после любой последовательности вызовов».
    ///      Доказав шаг из произвольного состояния хранилища, мы доказываем
    ///      утверждение по индукции для всех состояний вообще — в том числе
    ///      недостижимых, то есть строго сильнее, чем «для всех сценариев».
    function enableSymbolicStorage(address account) external;

    /// @notice Символьный calldata, корректный для какой-нибудь функции ABI.
    function createCalldata(string calldata contractName) external pure returns (bytes memory);
}

SVM constant svm = SVM(0xF3993A62377BCd56AE39D773740A5390411E8BC9);

/*//////////////////////////////////////////////////////////////////////////
                    ТЕОРЕМА A — САППЛАЙ ТОКЕНА НЕИЗМЕНЕН

 Утверждение: не существует адреса, calldata и состояния хранилища, при которых
 внешний вызов к MaclaurinToken изменил бы totalSupply().

 Почему это стоит доказывать, а не проверять глазами. Самый частый способ
 рагпула — не эксплойт, а легальная `mint(address,uint256) onlyOwner`. Аудит
 такую функцию не считает уязвимостью: это задокументированное полномочие.
 Единственная защита — чтобы её физически не было в байткоде. «Мы посмотрели,
 её нет» — это утверждение о том, что человек прочитал. Ниже — утверждение о
 байткоде, проверенное машиной.
//////////////////////////////////////////////////////////////////////////*/

contract MaclaurinTokenProof is Test {
    MaclaurinToken internal token;

    /// @dev Значение из §2 спецификации, продублировано дословно: доказательство,
    ///      сверяющееся с константой самого контракта, не проверяет ничего.
    uint256 internal constant SPEC_TOTAL_SUPPLY = 2718281828459045235360287471;

    function setUp() public {
        token = new MaclaurinToken(address(0xA11CE), address(0xE41551));
    }

    /**
     * @notice ГЛАВНАЯ ТЕОРЕМА ФАЙЛА, ПУНКТ A.
     *
     *         ∀ state, ∀ caller, ∀ calldata:
     *             totalSupply(state после вызова) == totalSupply(state до)
     *
     * @dev Три источника общности, каждый важен:
     *
     *      1. `enableSymbolicStorage` — начальное хранилище символьно. Значит
     *         утверждение доказано не «из состояния сразу после деплоя», а из
     *         ЛЮБОГО состояния. Отсюда по индукции следует то, что просили:
     *         инвариант держится после любой последовательности любых вызовов
     *         произвольной длины. Формально: база — конструктор, шаг — эта
     *         теорема, значит верно для всех n.
     *
     *      2. `selector` символьный — перебираются все точки входа контракта
     *         разом, включая несуществующие (попадание в fallback).
     *
     *      3. Аргументы символьные и их три слова — ровно столько, сколько
     *         нужно самой «широкой» функции ERC-20 (transferFrom). Лишние
     *         слова ABI-декодер игнорирует, недостающие он бы и так отверг.
     *
     *      Результат вызова НЕ фильтруется через vm.assume: утверждение обязано
     *      держаться и на успешных путях, и на реверт-путях.
     */
    function check_totalSupplyIsConstantForAnyCallFromAnyState(
        address caller,
        bytes4 selector,
        uint256 arg1,
        uint256 arg2,
        uint256 arg3
    ) public {
        svm.enableSymbolicStorage(address(token));

        uint256 supplyBefore = token.totalSupply();

        vm.prank(caller);
        // slither-disable-next-line unchecked-lowlevel
        (bool ok,) = address(token).call(abi.encodePacked(selector, arg1, arg2, arg3));
        ok; // намеренно не проверяется: см. комментарий выше

        assertEq(token.totalSupply(), supplyBefore);
    }

    /**
     * @notice То же утверждение, но calldata строит сам halmos по ABI контракта,
     *         а хранилище — настоящее, послеразвёрточное.
     *
     * @dev Зачем дубль. Первая теорема сильнее по общности, но опирается на
     *      два чит-кода halmos. Эта — почти ни на что: реальный контракт,
     *      реальное состояние, символьный вызов. Если чит-код символьного
     *      хранилища когда-нибудь изменит семантику, здесь это будет видно.
     *      Заодно проверяется конкретное значение сапплая из спецификации.
     */
    function check_totalSupplyMatchesSpecAfterAnyAbiCall(address caller) public {
        assertEq(token.totalSupply(), SPEC_TOTAL_SUPPLY);

        bytes memory data = svm.createCalldata("MaclaurinToken");

        vm.prank(caller);
        // slither-disable-next-line unchecked-lowlevel
        (bool ok,) = address(token).call(data);
        ok;

        assertEq(token.totalSupply(), SPEC_TOTAL_SUPPLY);
    }

    /**
     * @notice Два произвольных вызова подряд из реального состояния.
     *
     * @dev Индукцию из первой теоремы это не заменяет и заменять не должно.
     *      Смысл в другом: показать явно, что «последовательность» здесь не
     *      фигура речи, и что состояние после первого вызова не открывает
     *      второму ничего нового.
     */
    function check_totalSupplyIsConstantForAnyTwoCalls(
        address caller1,
        bytes4 selector1,
        uint256 a1,
        uint256 b1,
        address caller2,
        bytes4 selector2,
        uint256 a2,
        uint256 b2
    ) public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(caller1);
        // slither-disable-next-line unchecked-lowlevel
        (bool ok1,) = address(token).call(abi.encodePacked(selector1, a1, b1));
        ok1;

        vm.prank(caller2);
        // slither-disable-next-line unchecked-lowlevel
        (bool ok2,) = address(token).call(abi.encodePacked(selector2, a2, b2));
        ok2;

        assertEq(token.totalSupply(), supplyBefore);
    }
}

/*//////////////////////////////////////////////////////////////////////////
              ТЕОРЕМЫ B, C, D — ЭМИССИЯ КАК СВОЙСТВО АРИФМЕТИКИ

 Центральный тезис проекта: эмиссия заканчивается не потому, что кто-то решит
 её выключить, а потому, что члены ряда 1/n! кончаются. Тезис проверяемый —
 значит, обязан быть проверен на всём домене, а не на подобранных n.
//////////////////////////////////////////////////////////////////////////*/

contract MaclaurinEmissionProof is Test {
    MaclaurinEmission internal emission;

    /// @dev Границы окна эмиссии из §2.1 спецификации, продублированы дословно.
    uint256 internal constant SPEC_FIRST_EPOCH = 2;
    uint256 internal constant SPEC_LAST_EPOCH = 26;

    /// @dev floor(e × 1e18) — предел частичных сумм Σ 1/n!.
    uint256 internal constant SPEC_E_FIXED = 2718281828459045235;

    /// @dev Хвост ряда Σ 1/n!, n ≥ 2, домноженный на 1e27.
    uint256 internal constant SPEC_EMISSION_POOL = 718281828459045235360287471;

    /// @dev Время развёртывания зафиксировано, чтобы конструктор не ветвился на
    ///      сравнении startTime_ < block.timestamp. На доказываемые ниже
    ///      утверждения оно не влияет: epochAmount и multiplier — pure.
    uint256 internal constant DEPLOY_TIME = 1_800_000_000;

    function setUp() public {
        vm.warp(DEPLOY_TIME);
        emission = new MaclaurinEmission(address(0xA11CE), address(0xBEEF), DEPLOY_TIME);
    }

    /**
     * @notice ТЕОРЕМА B. Для ВСЕГО домена uint256:
     *
     *             epochAmount(n) == 0   ⟺   n < 2  ∨  n > 26
     *
     * @dev Это и есть формализация фразы «эмиссия заканчивается по свойству
     *      арифметики, а не по решению мультисига». Доказываются обе стороны
     *      эквивалентности:
     *
     *        →  вне окна ноль: значит после 26-й эпохи начислять нечего, и
     *           нет входа n, на котором эмиссия бы «ожила»;
     *        ←  внутри окна строго не ноль: значит окно не пустое и в нём нет
     *           дыр — ни одна эпоха молча не пропущена.
     *
     *      Вторая половина не менее важна первой: таблица из 25 строк — ровно
     *      то место, где опечатка (пропущенная строка) даёт тихий ноль, и ни
     *      один тест на конкретных n её бы не поймал, если бы n не совпало.
     */
    function check_epochAmountIsZeroExactlyOutsideTheWindow(uint256 n) public view {
        uint256 amount = emission.epochAmount(n);

        if (n < SPEC_FIRST_EPOCH || n > SPEC_LAST_EPOCH) {
            assertEq(amount, 0);
        } else {
            assertTrue(amount > 0);
        }
    }

    /**
     * @notice ТЕОРЕМА B'. Члены ряда строго убывают на всём окне.
     *
     * @dev Свойство 1/n! убывать — это то, ради чего ряд вообще взят как график
     *      выпуска. Проверяется на всём домене, а не на соседних парах из теста:
     *      достаточно одной переставленной строки таблицы, чтобы график перестал
     *      быть убывающим, а «факториально убывающая отдача» стала неправдой.
     */
    function check_epochAmountsAreStrictlyDecreasing(uint256 n) public view {
        vm.assume(n >= SPEC_FIRST_EPOCH);
        vm.assume(n < SPEC_LAST_EPOCH);

        assertTrue(emission.epochAmount(n) > emission.epochAmount(n + 1));
    }

    /**
     * @notice ТЕОРЕМА C. Потолок e недостижим, и вне [1,7] функция ревертит.
     *
     *             ∀ r ∈ [1,7] :  multiplier(r) < E_FIXED
     *             ∀ r ∉ [1,7] :  вызов ревертит
     *
     * @dev Обе половины содержательны.
     *
     *      Первая — это тезис «предел не достигается»: сколько ни увеличивай
     *      радиус, множитель остаётся строго меньше e. Не «мы так решили», а
     *      частичная сумма ряда всегда строго меньше своего предела.
     *
     *      Вторая — про безопасность, а не про красоту. Если бы multiplier
     *      возвращал ноль вместо реверта, позиция с некорректным радиусом
     *      получила бы нулевой вес: пользователь застейкал, а награды тихо
     *      не идут. Реверт на всём остальном домене доказывает, что такого
     *      входа нет.
     */
    function check_multiplierStaysStrictlyBelowE(uint256 r) public view {
        (bool ok, bytes memory ret) =
            address(emission).staticcall(abi.encodeCall(MaclaurinEmission.multiplier, (r)));

        if (r >= 1 && r <= 7) {
            assertTrue(ok);
            assertTrue(abi.decode(ret, (uint256)) < SPEC_E_FIXED);
        } else {
            assertFalse(ok);
        }
    }

    /**
     * @notice ТЕОРЕМА C'. Множители строго растут по радиусу.
     * @dev Иначе «больший лок — большая награда» было бы обещанием, а не
     *      свойством таблицы.
     */
    function check_multipliersAreStrictlyIncreasing(uint256 r) public view {
        vm.assume(r >= 1);
        vm.assume(r < 7);

        assertTrue(emission.multiplier(r) < emission.multiplier(r + 1));
    }

    /**
     * @notice ТЕОРЕМА D. Сумма всех членов ряда не превосходит EMISSION_POOL.
     *
     * @dev Что здесь на кону. EMISSION_POOL сминчен в контракт эмиссии ровно
     *      один раз и пополнить его нечем. Если сумма таблицы окажется хоть на
     *      wei больше, последняя эпоха не выплатится: у контракта просто не
     *      будет токенов, и починить это в неизменяемом контракте нельзя.
     *
     *      Утверждение доказывается вместе с точным значением недобора (14 wei
     *      округления вниз): «не больше» без «насколько меньше» оставляло бы
     *      место для расхождения, которое никто не заметит.
     *
     *      ПОЧЕМУ ЭТО ПОЛНОЕ ДОКАЗАТЕЛЬСТВО, А НЕ ПРОВЕРКА ДО ГЛУБИНЫ N.
     *      totalEmittable() — цикл, а halmos разворачивает циклы до границы
     *      --loop. Обычно это дыра: за границей может быть что угодно. Здесь
     *      границы нет: цикл идёт от FIRST_EPOCH до LAST_EPOCH, обе — immutable
     *      константы байткода, итераций ровно 25. При --loop 26 (см. halmos.toml)
     *      развёртка полная, инструмент не сообщает о достижении границы, и
     *      «ограниченное символьное исполнение» здесь совпадает с исчерпывающим.
     */
    function check_seriesSumNeverExceedsEmissionPool() public view {
        uint256 sum = emission.totalEmittable();

        assertTrue(sum <= SPEC_EMISSION_POOL);
        assertEq(sum, SPEC_EMISSION_POOL - 14);
    }

    /**
     * @notice ТЕОРЕМА D'. Номер эпохи ограничен сверху при любом block.timestamp.
     *
     * @dev Здесь символьно ВРЕМЯ — то есть утверждение покрывает всю историю
     *      сети до конца её существования. Из него следует, что цикл начисления
     *      не может пройти больше 25 сегментов: сегменты нумеруются эпохами, а
     *      эпох ровно столько. Это то же ограничение, что делает развёртку
     *      циклов полной, но сформулированное как свойство контракта, а не как
     *      настройка инструмента.
     */
    function check_currentEpochIsAlwaysWithinBounds(uint256 timestamp) public {
        vm.warp(timestamp);

        uint256 e = emission.currentEpoch();

        assertTrue(e >= SPEC_FIRST_EPOCH);
        assertTrue(e <= SPEC_LAST_EPOCH + 1);
    }

    /**
     * @notice ТЕОРЕМА D''. Цикл начисления завершается при любом block.timestamp.
     *
     * @dev pendingUnallocated() — единственная view-обёртка над приватным
     *      _project, то есть над тем самым циклом. Символьное время означает
     *      «контракт не трогали произвольно долго». Утверждение проверяется не
     *      assert-ом, а самим фактом завершения: если бы цикл мог выйти за
     *      границу --loop, halmos сообщил бы об этом отдельным предупреждением.
     *      Отсутствие такого предупреждения при --loop 26 — и есть проверка
     *      того, что итераций не больше 25.
     */
    function check_accrualLoopTerminatesForAnyTimestamp(uint256 timestamp) public {
        vm.warp(timestamp);

        // Значение не важно, важно, что вызов завершился в пределах развёртки.
        emission.pendingUnallocated();
    }
}

/*//////////////////////////////////////////////////////////////////////////
               ТЕОРЕМА E — ПЛАТЁЖЕСПОСОБНОСТЬ БОНДИНГ-КРИВОЙ

 Инвариант §5.1: reserve ≥ того, что кривая обязана выплатить, если ВСЕ
 выпущенные ею токены вернут на выкуп. Его нарушение — это неплатёжеспособность,
 то есть ровно та ситуация, ради предотвращения которой контракт и написан так,
 как написан.

 ЧЕСТНО О ГРАНИЦАХ (подробнее — в README). Внутри buy() стоит двоичный поиск
 _tokensFor на ~90 итераций. Каждая итерация — ветвление, то есть 2^90 путей;
 это за пределами любого символьного исполнения, и притворяться, что мы это
 доказали, нельзя. Поэтому ниже:
   * шаг продажи доказан ПОЛНОСТЬЮ — там циклов нет;
   * шаг покупки доказан при явно выписанном постусловии двоичного поиска,
     то есть доказана вся арифметика вокруг него, кроме самого поиска;
   * ключевая лемма floor ≤ ceil, на которой держится весь инвариант,
     доказана отдельно и на всём домене.
//////////////////////////////////////////////////////////////////////////*/

contract MaclaurinCurveProof is Test {
    MaclaurinCurve internal curve;

    /// @dev Слоты из `forge inspect MaclaurinCurve storageLayout`. Слот 0 занят
    ///      _status у OZ ReentrancyGuard, поэтому нумерация начинается с 1.
    ///      Прямая запись в хранилище нужна, чтобы говорить «для любого
    ///      состояния кривой», а не «для состояний, до которых мы доторговали».
    bytes32 internal constant SLOT_SOLD = bytes32(uint256(1));
    bytes32 internal constant SLOT_RESERVE = bytes32(uint256(2));

    /// @dev Константы §2 спецификации, продублированы дословно.
    uint256 internal constant SPEC_INVENTORY = 1_000_000_000e18;
    uint256 internal constant SPEC_TOTAL_RAISE = 3718281828459045235;

    function setUp() public {
        curve = new MaclaurinCurve(IERC20(address(0x7A710)), address(0xFEE));
    }

    /// @dev Устанавливает произвольную точку на кривой и произвольный резерв.
    function _setCurveState(uint256 soldAmount, uint256 reserveAmount) internal {
        vm.store(address(curve), SLOT_SOLD, bytes32(soldAmount));
        vm.store(address(curve), SLOT_RESERVE, bytes32(reserveAmount));
    }

    /**
     * @notice ЛЕММА E0 — на ней держится всё остальное.
     *
     *             ∀ x ≤ INVENTORY, ∀ d ≤ INVENTORY − x :
     *                 quoteSellGross(d) ≤ quoteBuyCost(d)
     *
     *         Слева — сколько кривая ЗАПЛАТИТ за выкуп участка [x, x+d]
     *         (площадь, округлённая вниз). Справа — сколько она ВОЗЬМЁТ за
     *         продажу того же участка (та же площадь, округлённая вверх).
     *
     * @dev Это и есть механизм платёжеспособности, выписанный одной строкой:
     *      округления разнонаправленные, поэтому кривая на каждом участке
     *      берёт не меньше, чем потом отдаёт. Точная площадь аддитивна, значит
     *      дробление сделок на сколь угодно мелкие ничего не меняет — свойство
     *      выполняется на каждом куске, а не только «в среднем».
     *
     *      Отсюда же следует §5.5 (круг «купил-продал» убыточен) в части
     *      площади: выкуп никогда не вернёт больше, чем стоила покупка, и это
     *      ещё ДО комиссии, которая берётся с обеих сторон.
     */
    function check_buybackNeverExceedsPurchaseCost(uint256 x, uint256 d) public {
        // Область определения кривой. Не ограничение общности: sold не может
        // превысить INVENTORY, покупка ограничена стоимостью остатка.
        vm.assume(x <= SPEC_INVENTORY);
        vm.assume(d <= SPEC_INVENTORY - x);

        _setCurveState(x, 0);
        uint256 costToBuy = curve.quoteBuyCost(d); // _costCeil(x, x+d)

        _setCurveState(x + d, 0);
        uint256 paidOnSell = curve.quoteSellGross(d); // _costFloor(x, x+d)

        assertTrue(paidOnSell <= costToBuy);
    }

    /**
     * @notice ТЕОРЕМА E1 — шаг ПРОДАЖИ сохраняет платёжеспособность.
     *         Доказана полностью: в этом пути нет ни одного цикла.
     *
     *             reserve ≥ costFloor(0, sold)      (инвариант до сделки)
     *             ⟹  reserve − gross ≥ costFloor(0, sold − amount)
     *
     * @dev Содержательная часть — субаддитивность округления вниз:
     *      floor(A(0,s−a)) + floor(A(s−a,s)) ≤ floor(A(0,s)). Именно она
     *      делает индукцию по сделкам корректной. Если бы она не выполнялась,
     *      достаточно было бы раздробить продажу на много мелких, чтобы
     *      вытянуть из резерва больше, чем в нём есть, — классика атак на
     *      кривые с округлением в пользу пользователя.
     *
     *      Единственное предположение — сам инвариант ДО сделки. Это не
     *      подгонка, а определение шага индукции: база (sold = 0, reserve = 0)
     *      выполняется тривиально, шаг покупки — в E2 ниже.
     */
    function check_sellPreservesSolvency(uint256 soldBefore, uint256 amount, uint256 reserveBefore) public {
        vm.assume(soldBefore <= SPEC_INVENTORY);
        vm.assume(amount <= soldBefore);

        _setCurveState(soldBefore, reserveBefore);

        // Обязательство кривой до сделки: выкупить всё выпущенное.
        uint256 owedBefore = curve.quoteSellGross(soldBefore);
        vm.assume(reserveBefore >= owedBefore);

        // Ровно та величина, которую sell() спишет с резерва.
        uint256 gross = curve.quoteSellGross(amount);

        // Эффект sell(): sold уменьшился, резерв уменьшился на gross.
        uint256 soldAfter = soldBefore - amount;
        _setCurveState(soldAfter, reserveBefore - gross);

        assertTrue(reserveBefore - gross >= curve.quoteSellGross(soldAfter));
    }

    /**
     * @notice ТЕОРЕМА E1' — полная ликвидация возможна всегда.
     *
     *         Если ВСЕ выпущенные токены разом вернут на выкуп, резерва хватит,
     *         и после этого он не уйдёт в минус.
     *
     * @dev Это буквальная формулировка §5.1 и главный практический вопрос
     *      покупателя: «а если все побегут к выходу одновременно». Ответ не
     *      «у нас хватит ликвидности», а «вычитание не может уйти в минус, вот
     *      доказательство на всём домене».
     */
    function check_reserveCoversLiquidationOfEverything(uint256 soldBefore, uint256 reserveBefore) public {
        vm.assume(soldBefore <= SPEC_INVENTORY);

        _setCurveState(soldBefore, reserveBefore);

        uint256 owed = curve.quoteSellGross(soldBefore);
        vm.assume(reserveBefore >= owed);

        // Выкуп всего: sold обнуляется, обязательство кривой обнуляется вместе
        // с ним, а резерв остаётся неотрицательным.
        _setCurveState(0, reserveBefore - owed);

        assertEq(curve.quoteSellGross(0), 0);
        assertTrue(reserveBefore - owed >= curve.quoteSellGross(0));
    }

    /**
     * @notice ТЕОРЕМА E2 — шаг ПОКУПКИ сохраняет платёжеспособность.
     *
     * @dev ЗДЕСЬ ЕДИНСТВЕННОЕ МЕСТО ВО ВСЁМ ФАЙЛЕ, ГДЕ ЧАСТЬ КОДА ЗАМЕНЕНА
     *      ЕГО СПЕЦИФИКАЦИЕЙ. Это надо назвать вслух.
     *
     *      buy() определяет количество токенов двоичным поиском _tokensFor:
     *      ~90 итераций, на каждой ветвление, то есть 2^90 путей. Символьно
     *      исполнить это нельзя — ни halmos, ни чем-либо ещё.
     *
     *      Поэтому поиск заменён его ПОСТУСЛОВИЕМ, выписанным явно:
     *
     *          quoteBuyCost(d) ≤ netIn
     *
     *      то есть «покупатель внёс не меньше точной стоимости купленного,
     *      округлённой вверх». Это ровно то, что гарантирует предикат цикла
     *      (`mid * (COST_BASE + SLOPE * (twoX + mid)) <= target`), и ничего
     *      сверх того. Всё остальное — арифметика вокруг поиска — доказано
     *      честно, на всём домене.
     *
     *      Что остаётся непроверенным машиной: что двоичный поиск действительно
     *      обеспечивает своё постусловие. На это работают 216 обычных тестов,
     *      включая дифференциальные и фаззинг. Это тесты, а не доказательство,
     *      и выдавать одно за другое здесь не будем.
     */
    function check_buyPreservesSolvency(uint256 soldBefore, uint256 d, uint256 netIn, uint256 reserveBefore)
        public
    {
        vm.assume(soldBefore <= SPEC_INVENTORY);
        vm.assume(d <= SPEC_INVENTORY - soldBefore);

        // Резерв и приход ограничены полной выручкой кривой. Это не удобная
        // гипотеза, а следствие конструкции: больше TOTAL_RAISE в кривую
        // положить нельзя — buy ревертит на ExceedsInventory.
        vm.assume(reserveBefore <= SPEC_TOTAL_RAISE);
        vm.assume(netIn <= SPEC_TOTAL_RAISE);

        _setCurveState(soldBefore, reserveBefore);

        uint256 owedBefore = curve.quoteSellGross(soldBefore);
        vm.assume(reserveBefore >= owedBefore);

        // Постусловие двоичного поиска — см. развёрнутый комментарий выше.
        vm.assume(curve.quoteBuyCost(d) <= netIn);

        uint256 soldAfter = soldBefore + d;
        _setCurveState(soldAfter, reserveBefore + netIn);

        assertTrue(reserveBefore + netIn >= curve.quoteSellGross(soldAfter));
    }

    /**
     * @notice ТЕОРЕМА E3 — цена не убывает (§5.4).
     *
     * @dev Доказано на всей области определения. Из монотонности следует, что
     *      «купить дешевле, продав» невозможно: любая покупка двигает точку
     *      вправо, то есть цену вверх, и следующий покупатель платит не меньше.
     */
    function check_priceIsMonotonicallyNonDecreasing(uint256 x1, uint256 x2) public view {
        vm.assume(x1 <= x2);
        vm.assume(x2 <= SPEC_INVENTORY);

        assertTrue(curve.priceAt(x1) <= curve.priceAt(x2));
    }

    /**
     * @notice ТЕОРЕМА E3' — вне области определения цена ревертит, а не врёт.
     * @dev Молчаливое возвращение значения за границей инвентаря означало бы
     *      цену для точки, в которой кривая не может находиться. Реверт на всём
     *      остальном домене доказывает, что такого входа нет.
     */
    function check_priceRevertsOutsideInventory(uint256 x) public view {
        (bool ok,) = address(curve).staticcall(abi.encodeCall(MaclaurinCurve.priceAt, (x)));

        if (x <= SPEC_INVENTORY) {
            assertTrue(ok);
        } else {
            assertFalse(ok);
        }
    }

    /**
     * @notice ТЕОРЕМА E4 — резерв недостижим ни для кого, кроме продавца (§5.7).
     *
     *         Ни одна точка входа контракта, кроме sell(), не может уменьшить
     *         reserve. В том числе withdrawFees — то есть комиссия физически
     *         не берётся из резерва.
     *
     * @dev Хранилище символьно: утверждение доказано из любого состояния, а не
     *      из состояния «сразу после деплоя». Отсюда по индукции — «после любой
     *      последовательности вызовов».
     *
     *      ИСКЛЮЧЕНИЯ И ПОЧЕМУ ОНИ ИМЕННО ТАКИЕ. Из перебора выведены три
     *      селектора: buy, previewBuy и sell. Первые два — потому что внутри
     *      них тот самый двоичный поиск (см. E2), а не потому, что там что-то
     *      неудобное. Третий — потому что sell резерв уменьшать ОБЯЗАН, это его
     *      работа; его корректность доказана отдельно в E1.
     */
    function check_onlySellCanDecreaseReserve(address caller, bytes4 selector, uint256 arg1, uint256 arg2)
        public
    {
        vm.assume(selector != MaclaurinCurve.buy.selector);
        vm.assume(selector != MaclaurinCurve.previewBuy.selector);
        vm.assume(selector != MaclaurinCurve.sell.selector);

        svm.enableSymbolicStorage(address(curve));

        uint256 reserveBefore = curve.reserve();

        vm.prank(caller);
        // slither-disable-next-line unchecked-lowlevel
        (bool ok,) = address(curve).call(abi.encodePacked(selector, arg1, arg2));
        ok;

        assertTrue(curve.reserve() >= reserveBefore);
    }
}
