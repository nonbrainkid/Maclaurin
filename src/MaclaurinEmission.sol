// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {MaclaurinToken} from "./MaclaurinToken.sol";

/**
 * @title  MaclaurinEmission
 * @notice Держит EMISSION_POOL и распределяет его между стейкерами по эпохам.
 *         Награда эпохи n равна ровно n-му члену ряда Маклорена для e:
 *
 *             EPOCH_AMOUNT[n] = 1e27 / n!     (целочисленное деление, вниз)
 *
 *         Эмиссия идёт с эпохи 2 (эпохи 0 и 1 — это GENESIS) по эпоху 26.
 *         На эпохе 27 член ряда впервые меньше одной базовой единицы, и
 *         целочисленное деление даёт ноль: 1e27 / 27! == 0. Эмиссия
 *         заканчивается не решением мультисига, а свойством арифметики uint256.
 *
 * @dev    АРХИТЕКТУРА. У контракта нет внешних зависимостей: ни оракула, ни
 *         кипер-бота, ни админской функции. Размер награды — чистая функция от
 *         `block.timestamp`. Это исключает целый класс атак сразу: манипуляцию
 *         ценой оракула, отказ кипера, front-running обновления параметров.
 *         Единственная остаточная поверхность — сдвиг таймстампа валидатором на
 *         несколько секунд, что при длине эпохи в 7 дней не значит ничего.
 *
 *         УЧЁТ. Награды начисляются аккумулятором (`rewardPerTokenStored`),
 *         пропорционально доле ВЕСА и времени внутри эпохи. Это даёт O(1) на
 *         пользователя вместо перебора стейкеров, и корректно обрабатывает
 *         вход/выход в середине эпохи.
 *
 *         RADIUS OF CONVERGENCE (фаза 2). Стейкер выбирает радиус R — число
 *         эпох лока. Множитель наград равен частичной сумме того же ряда до
 *         R-го члена: 1, 2, 2.5, 2.666…, 2.708…, 2.716…, 2.718… Предел — e,
 *         и он недостижим ни при каком R, потому что частичная сумма строго
 *         меньше суммы ряда. Убывающая отдача здесь не фигура речи: прирост
 *         множителя между радиусами — это ровно члены 1/n!.
 *
 *         Вес позиции = принципал × множитель, награда делится по totalWeight.
 *         `totalStaked` остаётся отдельным счётчиком принципала и участвует
 *         в инварианте платёжеспособности — множитель не должен иметь никакой
 *         возможности повлиять на возврат тела депозита.
 *
 *         КЛЮЧЕВОЕ ОГРАНИЧЕНИЕ: `claim()` закрыт до `unlockTime`, а `unstake()`
 *         открыт всегда. Разбор, почему иначе механика ломается — над claim().
 *
 *         КРИТИЧНО: контракт держит и пул эмиссии, и принципал стейкеров в одном
 *         и том же токене. Поэтому `balanceOf(address(this))` НИГДЕ не
 *         используется для расчётов — весь учёт идёт по явным счётчикам
 *         (`totalStaked`, `totalClaimed`, `unallocated`). Использование
 *         balanceOf здесь было бы классической дырой: чужой donation в контракт
 *         раздувал бы награды, а принципал стейкеров стал бы выплачиваемым.
 */
contract MaclaurinEmission is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                КОНСТАНТЫ
    //////////////////////////////////////////////////////////////*/

    uint256 public constant EPOCH_DURATION = 7 days;

    /// @notice Первая эмитируемая эпоха. Эпохи 0 и 1 — члены 1/0! и 1/1!,
    ///         они выданы как GENESIS в конструкторе токена.
    uint256 public constant FIRST_EPOCH = 2;

    /// @notice Последняя эмитируемая эпоха. На 27-й член ряда равен 0 wei.
    uint256 public constant LAST_EPOCH = 26;

    /// @notice 25 эпох × 7 дней = 175 дней полного цикла эмиссии.
    uint256 public constant EMISSION_DURATION = (LAST_EPOCH - FIRST_EPOCH + 1) * EPOCH_DURATION;

    /// @notice Максимальный радиус сходимости. Лок = R эпох, множитель =
    ///         частичная сумма ряда до R-го члена. После R=7 спор идёт за
    ///         0.0002 множителя — дальше расширять нечего.
    uint256 public constant MAX_RADIUS = 7;

    /// @notice Масштаб множителей: 1.0x == 1e18. Отдельно от decimals токена.
    uint256 private constant MULTIPLIER_ONE = 1e18;

    /**
     * @notice floor(e × 1e18) — потолок множителя.
     *
     * @dev Записан в контракт, но НЕДОСТИЖИМ ни при каком R: множитель равен
     *      частичной сумме ряда, а она строго меньше его суммы. Константа
     *      существует именно затем, чтобы это свойство можно было проверить
     *      на цепочке, а не принимать на слово: multiplier(R) < E_FIXED.
     */
    uint256 public constant E_FIXED = 2_718_281_828_459_045_235;

    /**
     * @notice Масштаб аккумулятора наград. Не путать с decimals токена — это
     *         внутренняя фикс-точка, чтобы деление на totalWeight не съедало
     *         значащие разряды.
     *
     * @dev Значение выбрано не «на глаз», а из двух встречных ограничений.
     *      Обе границы пересчитаны под ВЕС (фаза 2): делитель аккумулятора —
     *      это totalWeight, а он до 2.718 раза больше принципала.
     *
     *      СНИЗУ — точность. Награда поздних эпох измеряется единицами wei:
     *      на эпохе 26 это 2 wei. Аккумулятор растёт на `amount * P / total`,
     *      и при P = 1e18 со стейком в 1000 токенов (1e21) получаем
     *      2 * 1e18 / 1e21 == 0. Хвост ряда просто исчез бы: члены, ради
     *      которых весь концепт и построен, выплачивали бы ноль.
     *      При P = 1e30 худший случай — весь сапплай в стейке с максимальным
     *      множителем: 2.718e27 × 2.718 ≈ 7.4e27 веса. Для 2 wei это даёт
     *      2 × 1e30 / 7.4e27 = 270, то есть член ряда всё ещё не обнуляется.
     *      (В фазе 1 та же оценка давала 735 — запас сократился втрое и
     *      остался с двумя с половиной порядками до нуля.)
     *
     *      СВЕРХУ — переполнение. В `_earned` считается `weight * delta`.
     *      Пока пользователь в стейке, его вес входит в totalWeight, поэтому
     *      totalWeight_i ≥ weight на всём интервале начисления, а значит
     *      weight * delta ≤ Σ(члены ряда) * P = 7.18e26 * P.
     *      Множитель эту оценку не сдвигает: он входит и в числитель, и в
     *      знаменатель, и сокращается. При P = 1e30 это 7.2e56 против потолка
     *      uint256 в 1.16e77 — запас более чем в 10^20 раз, тот же, что и
     *      в фазе 1.
     *
     *      1e30 лежит с огромным зазором от обеих границ.
     */
    uint256 private constant ACC_PRECISION = 1e30;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice $MACLRN. Развёртывается этим контрактом в его конструкторе.
    MaclaurinToken public immutable token;

    /// @notice Момент старта эпохи 2.
    uint256 public immutable startTime;

    /// @notice startTime + 175 дней. После него награды не начисляются никогда.
    uint256 public immutable emissionEnd;

    /// @notice Казна остаточного члена Лагранжа (§5 спецификации).
    ///         Адрес зафиксирован при развёртывании и не может быть изменён.
    address public immutable remainderVault;

    /*//////////////////////////////////////////////////////////////
                                СОСТОЯНИЕ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Одна позиция на адрес.
     *
     * @dev Массив позиций с разными радиусами потребовал бы цикла при клейме,
     *      то есть неограниченного газа — и DoS получил бы сам пользователь,
     *      наплодивший позиций. Одна позиция делает стоимость всех операций
     *      константной. Кому нужны разные радиусы — использует разные адреса,
     *      и платит за это своим газом, а не чужим.
     *
     *      `weight` хранится, а не вычисляется на лету, потому что он входит
     *      в totalWeight: пересчёт «по требованию» разошёлся бы с суммой при
     *      первой же смене радиуса задним числом.
     */
    struct Position {
        /// Принципал. Возвращается целиком и всегда, ни при каких условиях
        /// не удерживается и не штрафуется.
        uint256 staked;
        /// Выбранный радиус, 1..MAX_RADIUS. Ноль означает «позиции нет».
        uint256 radius;
        /// До этого момента закрыт claim(). unstake() открыт всегда.
        uint256 unlockTime;
        /// staked × multiplier(radius) / 1e18.
        uint256 weight;
    }

    /// @notice Позиция пользователя. Одна на адрес.
    mapping(address => Position) public positions;

    /// @notice Сумма принципалов всех стейкеров. Никогда не расходуется на награды.
    uint256 public totalStaked;

    /// @notice Сумма весов всех позиций. Именно по нему делится награда.
    /// @dev totalWeight == 0 тогда и только тогда, когда totalStaked == 0:
    ///      множитель всегда ≥ 1e18, поэтому вес непустой позиции ≥ её тела.
    uint256 public totalWeight;

    /// @notice Накопленная награда на единицу веса, масштаб ACC_PRECISION.
    uint256 public rewardPerTokenStored;

    /// @notice Значение аккумулятора на момент последнего пересчёта пользователя.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Начисленная, но ещё не забранная награда пользователя (в wei токена).
    mapping(address => uint256) public rewards;

    /// @notice Время последнего пересчёта аккумулятора.
    uint256 public lastUpdateTime;

    /// @notice Сколько всего наград было выплачено. Служит инвариантом:
    ///         totalClaimed + unallocated + totalSwept ≤ EMISSION_POOL.
    uint256 public totalClaimed;

    /// @notice Награда эпох, в течение которых не было ни одного стейкера.
    ///         Не сгорает и не перераспределяется — уходит в казну остаточного члена.
    uint256 public unallocated;

    /// @notice Сколько уже отправлено в казну остаточного члена.
    uint256 public totalSwept;

    /*//////////////////////////////////////////////////////////////
                                 СОБЫТИЯ
    //////////////////////////////////////////////////////////////*/

    event Staked(address indexed user, uint256 amount, uint256 radius, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    /// @notice Награда эпох, в которые не было ни одного стейкера.
    event Unallocated(uint256 amount);
    /// @notice Награда, сгоревшая при досрочном выходе. Второй (и последний)
    ///         источник роста `unallocated` — отдельным событием, чтобы
    ///         индексатор мог отличить «никто не стейкал» от «вышли раньше».
    event RewardForfeited(address indexed user, uint256 amount);
    event Poked(address indexed user, address indexed caller);
    event SweptToRemainderVault(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ОШИБКИ
    //////////////////////////////////////////////////////////////*/

    error ZeroAmount();
    error InsufficientStake(uint256 requested, uint256 available);
    error NothingToClaim();
    error NothingToSweep();
    error StartTimeInPast();
    error ZeroAddress();
    error InvalidRadius(uint256 radius);
    error RadiusCannotDecrease(uint256 current, uint256 requested);
    error StillLocked(uint256 unlockTime);
    error NoPosition();
    error AlreadyAtBaseline();

    /*//////////////////////////////////////////////////////////////
                              КОНСТРУКТОР
    //////////////////////////////////////////////////////////////*/

    /**
     * @param genesisRecipient  Получатель GENESIS (2e27 wei).
     * @param remainderVault_   Казна остаточного члена Лагранжа.
     * @param startTime_        Момент старта эпохи 2 (unix-время).
     *
     * @dev Токен развёртывается ЗДЕСЬ, а не отдельной транзакцией. Причина —
     *      циклическая зависимость: токену в конструкторе нужен адрес эмиссии,
     *      эмиссии нужен адрес токена. Альтернатива (предсказать адрес по nonce
     *      деплоера) хрупкая, а вариант «сминтить пул на EOA и потом перевести»
     *      создаёт окно, в котором весь пул эмиссии лежит на ключе человека.
     *      Развёртывание изнутри конструктора делает всю связку атомарной: пул
     *      никогда не находится под контролем EOA даже на один блок.
     */
    constructor(address genesisRecipient, address remainderVault_, uint256 startTime_) {
        if (remainderVault_ == address(0)) revert ZeroAddress();
        // Старт в прошлом означал бы, что часть эпох «уже прошла» до появления
        // первого стейкера, и эта эмиссия целиком утекла бы в unallocated.
        if (startTime_ < block.timestamp) revert StartTimeInPast();

        remainderVault = remainderVault_;
        startTime = startTime_;
        emissionEnd = startTime_ + EMISSION_DURATION;
        lastUpdateTime = startTime_;

        // msg.sender для токена — этот контракт, поэтому EMISSION_POOL минтится
        // сразу сюда. genesisRecipient проверять на ноль не нужно: OZ _mint
        // реверит сам.
        token = new MaclaurinToken(genesisRecipient, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            ТАБЛИЦА ЭМИССИИ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Награда эпохи `n` в wei. Значения предвычислены офчейн.
     *
     * @dev Факториал НЕ вычисляется циклом сознательно. Во-первых, это лишний
     *      газ в каждой транзакции стейкера. Во-вторых, 27! ≈ 1.09e28 — это
     *      выходит за uint64 уже на n = 21; на Solidity 0.8.x переполнение
     *      даёт revert, то есть эмиссия просто встала бы намертво на последних
     *      эпохах, и починить это в неизменяемом контракте было бы нельзя.
     *      Таблица из 25 значений и дешевле, и безопаснее, и её можно
     *      построчно сверить с разделом 2.1 спецификации.
     *
     *      Возвращает 0 для n < 2 и для n > 26 — это и есть «конец эмиссии».
     */
    function epochAmount(uint256 n) public pure returns (uint256) {
        if (n < FIRST_EPOCH || n > LAST_EPOCH) return 0;

        // 1e27 / n!
        if (n == 2) return 500_000_000_000_000_000_000_000_000; //  2! = 2
        if (n == 3) return 166_666_666_666_666_666_666_666_666; //  3! = 6
        if (n == 4) return 41_666_666_666_666_666_666_666_666; //  4! = 24
        if (n == 5) return 8_333_333_333_333_333_333_333_333; //  5! = 120
        if (n == 6) return 1_388_888_888_888_888_888_888_888; //  6! = 720
        if (n == 7) return 198_412_698_412_698_412_698_412; //  7! = 5040
        if (n == 8) return 24_801_587_301_587_301_587_301; //  8! = 40320
        if (n == 9) return 2_755_731_922_398_589_065_255; //  9! = 362880
        if (n == 10) return 275_573_192_239_858_906_525; // 10! = 3628800
        if (n == 11) return 25_052_108_385_441_718_775; // 11!
        if (n == 12) return 2_087_675_698_786_809_897; // 12!
        if (n == 13) return 160_590_438_368_216_145; // 13!
        if (n == 14) return 11_470_745_597_729_724; // 14!
        if (n == 15) return 764_716_373_181_981; // 15!
        if (n == 16) return 47_794_773_323_873; // 16!
        if (n == 17) return 2_811_457_254_345; // 17!
        if (n == 18) return 156_192_069_685; // 18!
        if (n == 19) return 8_220_635_246; // 19!
        if (n == 20) return 411_031_762; // 20!
        if (n == 21) return 19_572_941; // 21!
        if (n == 22) return 889_679; // 22!
        if (n == 23) return 38_681; // 23!
        if (n == 24) return 1_611; // 24!
        if (n == 25) return 64; // 25!
        return 2; // n == 26, 26!
        // n == 27: 1e27 / 27! == 0 → отсечено проверкой в начале функции.
    }

    /*//////////////////////////////////////////////////////////////
                          ТАБЛИЦА МНОЖИТЕЛЕЙ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Множитель наград за радиус `r`. Fixed-point, 1.0x == 1e18.
     *
     * @dev Значения — частичные суммы Σ 1/n! (n = 0..r-1), предвычислены
     *      офчейн и сверяются со спецификацией построчно.
     *
     *      Считать их в рантайме нельзя по той же причине, что и факториалы
     *      в epochAmount: в Solidity нет дробей, и «честное» суммирование
     *      1/n! потребовало бы деления на каждом шаге, то есть накопления
     *      ошибки округления прямо в экономике. `5/2` даёт `2`, а не `2.5`,
     *      и это не ошибка компиляции, а тихо неверные выплаты.
     *
     *      Прирост между соседними радиусами — это ровно члены того же ряда:
     *      +1/1!, +1/2!, +1/3! … Отдача убывает факториально, и это свойство
     *      арифметики, а не параметр, который кто-то может подкрутить.
     *
     *      Ревертит на r вне [1, MAX_RADIUS]: молчаливый ноль здесь означал бы
     *      нулевой вес позиции, то есть тихо отключённые награды.
     */
    function multiplier(uint256 r) public pure returns (uint256) {
        if (r == 0 || r > MAX_RADIUS) revert InvalidRadius(r);

        if (r == 1) return 1_000_000_000_000_000_000; // 1
        if (r == 2) return 2_000_000_000_000_000_000; // + 1/1!
        if (r == 3) return 2_500_000_000_000_000_000; // + 1/2!
        if (r == 4) return 2_666_666_666_666_666_666; // + 1/3!
        if (r == 5) return 2_708_333_333_333_333_333; // + 1/4!
        if (r == 6) return 2_716_666_666_666_666_666; // + 1/5!
        return 2_718_055_555_555_555_555; // r == 7, + 1/6!
        // Предел последовательности — E_FIXED = 2718281828459045235.
        // Он строго больше любого значения выше и недостижим по построению.
    }

    /// @notice Длительность лока для радиуса `r` в секундах.
    function lockDuration(uint256 r) public pure returns (uint256) {
        if (r == 0 || r > MAX_RADIUS) revert InvalidRadius(r);
        return r * EPOCH_DURATION;
    }

    /// @dev Вес позиции. Единственное место, где вес вообще вычисляется, —
    ///      иначе инвариант `weight == staked * multiplier(radius) / 1e18`
    ///      пришлось бы поддерживать в четырёх местах руками.
    ///      Округление вниз, как и везде: в пользу протокола.
    function _weight(uint256 amount, uint256 r) private pure returns (uint256) {
        return (amount * multiplier(r)) / MULTIPLIER_ONE;
    }

    /*//////////////////////////////////////////////////////////////
                             ВРЕМЯ И ЭПОХИ
    //////////////////////////////////////////////////////////////*/

    /// @notice Текущая эпоха. До старта — FIRST_EPOCH, после конца — LAST_EPOCH+1
    ///         (эпоха 27, на которой член ряда равен нулю).
    function currentEpoch() public view returns (uint256) {
        if (block.timestamp <= startTime) return FIRST_EPOCH;
        uint256 e = FIRST_EPOCH + (block.timestamp - startTime) / EPOCH_DURATION;
        return e > LAST_EPOCH + 1 ? LAST_EPOCH + 1 : e;
    }

    /// @notice true, если эмиссия полностью завершена.
    function emissionFinished() public view returns (bool) {
        return block.timestamp >= emissionEnd;
    }

    /// @notice Момент окончания эпохи `n`.
    function epochEndsAt(uint256 n) public view returns (uint256) {
        return startTime + (n - FIRST_EPOCH + 1) * EPOCH_DURATION;
    }

    /*//////////////////////////////////////////////////////////////
                           НАЧИСЛЕНИЕ НАГРАД
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Проходит отрезок [from, to] по эпохам и считает, сколько награды
     *      на нём начислилось. Разбиение по эпохам нужно потому, что ставка
     *      эмиссии меняется на каждой границе.
     *
     *      Внутри эпохи начисление линейно по времени:
     *          amount = EPOCH_AMOUNT[e] * dt / EPOCH_DURATION
     *
     *      Порядок операций здесь не косметика. Сначала умножение, потом
     *      деление. Если сделать наоборот (посчитать «награду в секунду» как
     *      EPOCH_AMOUNT[e] / EPOCH_DURATION), то для поздних эпох это даст
     *      ноль: на эпохе 26 член ряда равен 2 wei, а 2 / 604800 == 0, и
     *      последние эпохи не выплатили бы вообще ничего.
     *
     *      Цикл ограничен: он не может сделать больше 25 итераций, потому что
     *      обрывается на emissionEnd. Газ не растёт неограниченно, даже если
     *      контракт не трогали годами.
     *
     * @param weightTotal суммарный ВЕС всех позиций, не сумма принципалов:
     *                    награда делится по весу (фаза 2, множители за лок).
     *
     * @return rptOut     новое значение аккумулятора
     * @return unallocOut награда, начисленная в моменты, когда стейкеров не было
     */
    function _project(uint256 from, uint256 to, uint256 weightTotal, uint256 rpt)
        private
        view
        returns (uint256 rptOut, uint256 unallocOut)
    {
        uint256 horizon = to < emissionEnd ? to : emissionEnd;
        uint256 cursor = from;
        uint256 unallocScaled;

        while (cursor < horizon) {
            uint256 e = FIRST_EPOCH + (cursor - startTime) / EPOCH_DURATION;
            uint256 eEnd = epochEndsAt(e);
            uint256 segEnd = horizon < eEnd ? horizon : eEnd;

            // Начисление отрезка СРАЗУ в единицах аккумулятора, одним делением.
            //
            // Промежуточное округление до целых wei здесь было бы ошибкой:
            // при коротких отрезках оно обнуляет поздние члены ряда. Для эпохи
            // 26 (2 wei за неделю) отрезок в 2 секунды даёт 2*2/604800 == 0,
            // то есть любой, кто дёргает контракт каждый блок, стёр бы хвост
            // ряда целиком. Суммы там мизерные, но хвост — это и есть весь
            // смысл концепта, и терять его из-за порядка операций нельзя.
            //
            // Переполнения нет: максимум множителей — 5e26 * 604800 * 1e30
            // = 3.0e62 против потолка uint256 1.16e77.
            uint256 scaled = (epochAmount(e) * (segEnd - cursor) * ACC_PRECISION) / EPOCH_DURATION;

            if (scaled != 0) {
                if (weightTotal == 0) {
                    // Никто не стейкал — награда не достаётся никому и уходит
                    // в казну остаточного члена. Она не сгорает и не
                    // перераспределяется на будущие эпохи (иначе появился бы
                    // стимул ждать пустых эпох).
                    unallocScaled += scaled;
                } else {
                    // Деление вниз. Остаток оседает в контракте и никогда
                    // никем не выплачивается — округление всегда в пользу
                    // протокола, поэтому выплатить больше, чем есть,
                    // невозможно арифметически, без единой проверки в коде.
                    rpt += scaled / weightTotal;
                }
            }
            cursor = segEnd;
        }

        rptOut = rpt;
        unallocOut = unallocScaled / ACC_PRECISION;
    }

    /// @dev Двигает аккумулятор до текущего момента.
    function _accrue() private {
        uint256 last = lastUpdateTime;
        if (block.timestamp <= last) return; // старт ещё не наступил
        if (last >= emissionEnd) {
            lastUpdateTime = block.timestamp;
            return; // эмиссия закончена, считать нечего
        }

        (uint256 rpt, uint256 unalloc) = _project(last, block.timestamp, totalWeight, rewardPerTokenStored);

        rewardPerTokenStored = rpt;
        if (unalloc != 0) {
            unallocated += unalloc;
            emit Unallocated(unalloc);
        }
        lastUpdateTime = block.timestamp;
    }

    /// @dev Фиксирует награду пользователя по текущему аккумулятору.
    function _settle(address user) private {
        rewards[user] = _earned(user, rewardPerTokenStored);
        userRewardPerTokenPaid[user] = rewardPerTokenStored;
    }

    function _earned(address user, uint256 rpt) private view returns (uint256) {
        uint256 delta = rpt - userRewardPerTokenPaid[user];
        return rewards[user] + (positions[user].weight * delta) / ACC_PRECISION;
    }

    /// @dev Порядок важен: сначала общий аккумулятор, потом персональный расчёт.
    modifier update(address user) {
        _accrue();
        _settle(user);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             ПОЛЬЗОВАТЕЛЬ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Застейкать $MACLRN с радиусом `radius` и получать долю эмиссии,
     *         умноженную на частичную сумму ряда до `radius`-го члена.
     *
     * @param amount Сколько добавить к позиции.
     * @param radius Радиус сходимости, 1..MAX_RADIUS. Лок = radius эпох.
     *
     * @dev Повторный стейк в активную позицию разрешён с двумя условиями.
     *
     *      1. Новый радиус не меньше текущего. Иначе лок можно было бы
     *         разбавить: застейкать много с R=7, получить множитель, а потом
     *         докинуть wei с R=1 и уехать через неделю со всей позиции.
     *
     *      2. `unlockTime` пересчитывается от ТЕКУЩЕГО момента, а не
     *         продлевается от старого. Иначе докидывание пыли за день до
     *         разлока давало бы полный множитель 2.718x на новую сумму за
     *         сутки реального обязательства — то есть буст без лока.
     *
     *      Checks-Effects-Interactions: состояние обновляется до внешнего вызова.
     */
    function stake(uint256 amount, uint256 radius) external nonReentrant update(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (radius == 0 || radius > MAX_RADIUS) revert InvalidRadius(radius);

        Position storage p = positions[msg.sender];
        uint256 currentRadius = p.radius;
        if (radius < currentRadius) revert RadiusCannotDecrease(currentRadius, radius);

        // EFFECTS
        uint256 newStaked = p.staked + amount;
        uint256 newWeight = _weight(newStaked, radius);
        uint256 unlock = block.timestamp + lockDuration(radius);

        totalStaked += amount;
        // Вес позиции меняется целиком: старый снимается, новый ставится.
        // Вычитание не может уйти в минус — totalWeight по построению есть
        // сумма всех p.weight, и слагаемое этого пользователя в ней уже есть.
        totalWeight = totalWeight - p.weight + newWeight;

        p.staked = newStaked;
        p.radius = radius;
        p.unlockTime = unlock;
        p.weight = newWeight;

        // INTERACTIONS
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, radius, unlock);
    }

    /**
     * @notice Забрать принципал. Доступно ВСЕГДА, включая активный лок.
     *
     * @dev Тело депозита не блокируется ни при каких условиях — это жёсткое
     *      правило спецификации, и оно важнее любой механики поверх него.
     *      Лок ограничивает только `claim()`.
     *
     *      Цена досрочного выхода — вся накопленная награда: она обнуляется
     *      и уходит в казну остаточного члена. Ряд разошёлся — приближение
     *      потеряно, но вложенное возвращается до последнего wei.
     *
     *      Сгорает награда целиком даже при частичном выходе. Пропорциональное
     *      сжигание выглядело бы «справедливее», но открывало бы дробление:
     *      выйти на 99.99% телом, оставить пыль и досидеть лок пылинкой,
     *      сохранив почти всю награду, набранную полным телом.
     */
    function unstake(uint256 amount) public nonReentrant update(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        Position storage p = positions[msg.sender];
        uint256 staked = p.staked;
        if (amount > staked) revert InsufficientStake(amount, staked);

        uint256 unlock = p.unlockTime;
        uint256 oldWeight = p.weight;

        // EFFECTS
        uint256 remaining;
        unchecked {
            remaining = staked - amount; // проверено выше
        }
        totalStaked -= amount;

        // Ноль — это и есть правильный новый вес при полном выходе; пишется
        // явно, чтобы ветка «позиция закрыта» не полагалась на умолчание.
        uint256 newWeight = 0;
        if (remaining == 0) {
            // Позиция закрыта полностью: радиус и лок обнуляются, следующий
            // стейк начинается с чистого листа и может выбрать любой радиус.
            delete positions[msg.sender];
        } else {
            newWeight = _weight(remaining, p.radius);
            p.staked = remaining;
            p.weight = newWeight;
        }
        totalWeight = totalWeight - oldWeight + newWeight;

        if (block.timestamp < unlock) {
            // `update` уже зафиксировал в rewards всё начисленное до этой
            // секунды, поэтому здесь сгорает ровно вся награда позиции.
            uint256 forfeited = rewards[msg.sender];
            if (forfeited != 0) {
                rewards[msg.sender] = 0;
                unallocated += forfeited;
                emit RewardForfeited(msg.sender, forfeited);
            }
        }

        // INTERACTIONS
        IERC20(address(token)).safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Забрать накопленную награду. Недоступно до `unlockTime`.
     *
     * @dev ПОЧЕМУ ЛОК ВИСИТ ИМЕННО НА CLAIM. Наивная реализация даёт множитель
     *      сразу, оставляет claim открытым, а за досрочный выход штрафует
     *      сжиганием награды. Такая схема не работает вообще:
     *
     *          1. stake(1000, R=7)      -> множитель 2.718x
     *          2. ждём эпоху, claim()   -> награда с бустом уже выведена
     *          3. повторяем каждую эпоху
     *          4. unstake досрочно      -> штраф сжигает rewards, а там 0
     *
     *      Атакующий получает 2.718x, не отсидев ни одного лока: к моменту
     *      штрафа отбирать нечего. Штраф за досрочный выход имеет смысл
     *      ровно до тех пор, пока награда физически не может покинуть
     *      контракт раньше срока.
     *
     *      Поэтому награда копится, но выходит только вместе с отсиженным
     *      обязательством. Принципала это не касается: `unstake` открыт всегда.
     *
     *      Заперта навсегда награда быть не может: unlockTime ≤ момент стейка
     *      + 49 дней, а полный выход из позиции обнуляет lock вместе с ней.
     *
     *      Дальше — самый опасный класс багов в стейкинге, поэтому по шагам:
     *      `rewards[msg.sender]` обнуляется ДО `safeTransfer`. Если сделать
     *      наоборот, то злоумышленник с контрактом-получателем может из хука
     *      рекурсивно вызвать `claim()`, пока баланс не обнулится, и вынести
     *      весь пул эмиссии за одну транзакцию — это классический reentrancy
     *      (так вынесли The DAO). У $MACLRN хуков на трансфере нет, так что
     *      атака неисполнима, но порядок операций всё равно правильный:
     *      безопасность не должна зависеть от свойств другого контракта.
     *      `nonReentrant` — второй независимый рубеж.
     */
    function claim() public nonReentrant update(msg.sender) {
        uint256 unlock = positions[msg.sender].unlockTime;
        if (block.timestamp < unlock) revert StillLocked(unlock);

        uint256 reward = rewards[msg.sender];
        if (reward == 0) revert NothingToClaim();

        // EFFECTS
        rewards[msg.sender] = 0;
        totalClaimed += reward;

        // INTERACTIONS
        IERC20(address(token)).safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    /**
     * @notice Забрать всё сразу: принципал целиком плюс награду, если она
     *         ещё есть.
     *
     * @dev Намеренно БЕЗ `nonReentrant`: это внешняя точка входа, а `unstake`
     *      и `claim` вызываются последовательно, а не вложенно, и каждая
     *      защищена сама. Свой `nonReentrant` здесь заблокировал бы их обе.
     *      `unstake` первым не случайно — его модификатор `update` фиксирует
     *      награду в `rewards`, поэтому следующая строка читает уже свежее
     *      значение, а не устаревший ноль.
     *
     *      При досрочном выходе `unstake` сжигает награду, `earned` после него
     *      равен нулю, и `claim` просто не вызывается — вместо того чтобы
     *      отреверить весь `exit` по StillLocked. То есть выйти из лока
     *      одной транзакцией можно всегда, ценой награды и только её.
     *
     *      Обратный порядок (сначала claim, потом unstake) сломал бы это:
     *      claim внутри лока реверит, и досрочный выход стал бы невозможен.
     */
    function exit() external {
        uint256 staked = positions[msg.sender].staked;
        if (staked != 0) unstake(staked);
        if (earned(msg.sender) != 0) claim();
    }

    /**
     * @notice Сбросить множитель истёкшей позиции до 1.0x. Permissionless.
     *
     * @dev Зачем это нужно. После `unlockTime` пользователь уже ничем не
     *      рискует, но вес позиции всё ещё умножен на 2.718 — он продолжал бы
     *      получать буст за обязательство, которого больше нет. Пересчитать
     *      вес автоматически нельзя: в системе нет кипера, а перебирать
     *      стейкеров в цикле — неограниченный газ.
     *
     *      Поэтому пересчёт вынесен наружу и открыт кому угодно. Это НЕ
     *      админское полномочие: адрес не выбирается (условие проверяется на
     *      цепочке), сумма не выбирается, новый вес однозначен. Вызвать `poke`
     *      на активном локе нельзя.
     *
     *      Стимул звать её есть у любого другого стейкера: снижение чужого
     *      веса поднимает его собственную долю в totalWeight.
     *
     *      Осознанный компромисс: пока `poke` никто не позвал, вес завышен.
     *      Это перераспределение между стейкерами, а не потеря для протокола —
     *      суммарные выплаты по-прежнему ограничены суммой ряда.
     *
     *      Радиус сбрасывается вместе с весом, а не только вес. Иначе
     *      инвариант `weight == staked * multiplier(radius) / 1e18` перестал
     *      бы выполняться, а пользователь навсегда остался бы обязан
     *      стейкать с R не меньше прежнего. После `poke` позиция снова
     *      обычная 1x, и следующий стейк выбирает любой радиус.
     *
     *      `_accrue` и `_settle` ОБЯЗАНЫ отработать до смены веса: иначе
     *      новый вес применился бы к уже прошедшему времени задним числом.
     *      `nonReentrant` не нужен — внешних вызовов здесь нет вообще.
     */
    function poke(address user) external {
        Position storage p = positions[user];
        if (p.staked == 0) revert NoPosition();

        uint256 unlock = p.unlockTime;
        if (block.timestamp < unlock) revert StillLocked(unlock);
        if (p.radius == 1) revert AlreadyAtBaseline();

        _accrue();
        _settle(user);

        uint256 newWeight = _weight(p.staked, 1);
        totalWeight = totalWeight - p.weight + newWeight;
        p.radius = 1;
        p.weight = newWeight;

        emit Poked(user, msg.sender);
    }

    /**
     * @notice Отправить в казну остаточного члена награду эпох, в которые
     *         никто не стейкал.
     *
     * @dev Функция намеренно БЕЗ доступа: вызвать её может кто угодно, но
     *      получатель (`remainderVault`) immutable и задан при развёртывании,
     *      а сумма ограничена счётчиком `unallocated`. То есть это не
     *      админское полномочие — тут нечего выбирать: ни адрес, ни сумму.
     *      Принципал стейкеров сюда попасть не может: `unallocated` растёт
     *      только из членов ряда и только когда totalStaked == 0.
     *
     *      Почему это вообще есть в фазе 1, хотя казна — это фаза 3: контракт
     *      неизменяем, и если не зафиксировать адрес получателя сейчас, эти
     *      токены останутся заперты навсегда и фаза 3 станет неисполнима.
     */
    function sweepToRemainderVault() external nonReentrant {
        _accrue();

        uint256 amount = unallocated;
        if (amount == 0) revert NothingToSweep();

        // EFFECTS
        unallocated = 0;
        totalSwept += amount;

        // INTERACTIONS
        IERC20(address(token)).safeTransfer(remainderVault, amount);

        emit SweptToRemainderVault(amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW-ФУНКЦИИ
    //////////////////////////////////////////////////////////////*/

    /// @notice Аккумулятор с учётом ещё не зафиксированного времени.
    function rewardPerToken() public view returns (uint256) {
        if (block.timestamp <= lastUpdateTime || lastUpdateTime >= emissionEnd) {
            return rewardPerTokenStored;
        }
        (uint256 rpt,) = _project(lastUpdateTime, block.timestamp, totalWeight, rewardPerTokenStored);
        return rpt;
    }

    /// @notice Сколько пользователь может забрать прямо сейчас.
    /// @dev Начислено — не значит доступно: до `unlockTime` claim() закрыт.
    function earned(address user) public view returns (uint256) {
        return _earned(user, rewardPerToken());
    }

    /// @notice Принципал пользователя. Возвращается ему целиком и всегда.
    /// @dev Отдельный геттер поверх `positions`, потому что именно эта
    ///      величина участвует в инварианте платёжеспособности
    ///      (`balanceOf(this) >= totalStaked`), а не вес.
    function stakedOf(address user) external view returns (uint256) {
        return positions[user].staked;
    }

    /// @notice Вес позиции: принципал × множитель радиуса.
    function weightOf(address user) external view returns (uint256) {
        return positions[user].weight;
    }

    /// @notice Момент, после которого пользователю открывается claim().
    function unlockTimeOf(address user) external view returns (uint256) {
        return positions[user].unlockTime;
    }

    /// @notice true, если позиция ещё в локе и claim() закрыт.
    function isLocked(address user) external view returns (bool) {
        return block.timestamp < positions[user].unlockTime;
    }

    /// @notice true, если лок истёк, а множитель всё ещё выше 1.0x —
    ///         то есть позицию имеет смысл `poke`-нуть.
    function isPokeable(address user) external view returns (bool) {
        Position storage p = positions[user];
        return p.staked != 0 && p.radius > 1 && block.timestamp >= p.unlockTime;
    }

    /// @notice Сколько награды уйдёт в казну остаточного члена, включая
    ///         ещё не зафиксированное время без стейкеров.
    function pendingUnallocated() external view returns (uint256) {
        if (block.timestamp <= lastUpdateTime || lastUpdateTime >= emissionEnd) return unallocated;
        (, uint256 unalloc) = _project(lastUpdateTime, block.timestamp, totalWeight, rewardPerTokenStored);
        return unallocated + unalloc;
    }

    /// @notice Сумма всех членов ряда, которые контракт когда-либо выпустит.
    ///         Ровно EMISSION_POOL минус 14 wei округления вниз.
    function totalEmittable() external pure returns (uint256 sum) {
        for (uint256 n = FIRST_EPOCH; n <= LAST_EPOCH; ++n) {
            sum += epochAmount(n);
        }
    }
}
