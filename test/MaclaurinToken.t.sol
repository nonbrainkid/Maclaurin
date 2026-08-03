// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

contract MaclaurinTokenTest is Test {
    MaclaurinToken internal token;

    address internal constant GENESIS_RECIPIENT = address(0xA11CE);
    address internal constant EMISSION = address(0xE41551);

    // Константы из §2 спецификации. Продублированы здесь ДОСЛОВНО и намеренно:
    // если кто-то поправит константу в контракте, тест обязан упасть. Тест,
    // который читает значение из тестируемого контракта, не проверяет ничего.
    uint256 internal constant SPEC_TOTAL_SUPPLY = 2718281828459045235360287471;
    uint256 internal constant SPEC_GENESIS = 2000000000000000000000000000;
    uint256 internal constant SPEC_EMISSION_POOL = 718281828459045235360287471;

    function setUp() public {
        token = new MaclaurinToken(GENESIS_RECIPIENT, EMISSION);
    }

    /*//////////////////////////////////////////////////////////////
                          МЕТАДАННЫЕ И КОНСТАНТЫ
    //////////////////////////////////////////////////////////////*/

    function test_Metadata() public view {
        assertEq(token.name(), "Maclaurin Series");
        assertEq(token.symbol(), "MACLRN");
        assertEq(token.decimals(), 18);
    }

    function test_TotalSupply_IsExactlyE() public view {
        assertEq(token.TOTAL_SUPPLY(), SPEC_TOTAL_SUPPLY);
        assertEq(token.totalSupply(), SPEC_TOTAL_SUPPLY);
    }

    function test_GenesisAndPool_SumToTotal() public view {
        assertEq(token.GENESIS(), SPEC_GENESIS);
        assertEq(token.EMISSION_POOL(), SPEC_EMISSION_POOL);
        assertEq(token.GENESIS() + token.EMISSION_POOL(), SPEC_TOTAL_SUPPLY);
    }

    /// @notice GENESIS — это первые два члена ряда: 1/0! + 1/1! = 2.
    function test_Genesis_IsFirstTwoSeriesTerms() public view {
        assertEq(token.GENESIS(), 2 * 1e27, "1/0! + 1/1! = 2");
    }

    function test_Distribution() public view {
        assertEq(token.balanceOf(GENESIS_RECIPIENT), SPEC_GENESIS);
        assertEq(token.balanceOf(EMISSION), SPEC_EMISSION_POOL);
    }

    /*//////////////////////////////////////////////////////////////
                    ГЛАВНОЕ: ЧЕГО В КОНТРАКТЕ НЕТ
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ни одной функции, способной изменить сапплай или дать привилегии,
     *         в контракте не существует.
     *
     * @dev Ищем селекторы прямо в РАЗВЁРНУТОМ байткоде, а не проверяем «вызов
     *      реверит». Разница принципиальная: вызов `mint(address,uint256)` без
     *      аргументов ревертнёт и в контракте, где mint есть — просто на
     *      декодировании calldata. Такой тест зелёный и бесполезный.
     *      Отсутствие селектора в диспетчере — это доказательство.
     *
     *      Атака, которую это предотвращает: владелец вызывает mint() на
     *      триллион токенов и сливает их в пул ликвидности. Формально не
     *      уязвимость — задокументированное полномочие. Защита одна: функции
     *      не должно существовать физически.
     */
    function test_NoPrivilegedFunctionsInBytecode() public view {
        string[10] memory forbidden = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "renounceOwnership()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "upgradeTo(address)",
            "setBlacklist(address,bool)"
        ];

        bytes memory code = address(token).code;
        assertGt(code.length, 0, "no code deployed");

        for (uint256 i = 0; i < forbidden.length; ++i) {
            bytes4 sel = bytes4(keccak256(bytes(forbidden[i])));
            assertFalse(_containsSelector(code, sel), forbidden[i]);
        }
    }

    /// @dev Контрольная проверка самого метода: селектор существующей функции
    ///      обязан находиться. Без этого тест выше мог бы «проходить» просто
    ///      потому, что поиск сломан.
    function test_SelectorScanner_IsSane() public view {
        bytes memory code = address(token).code;
        assertTrue(_containsSelector(code, bytes4(keccak256("transfer(address,uint256)"))));
        assertTrue(_containsSelector(code, bytes4(keccak256("totalSupply()"))));
    }

    function _containsSelector(bytes memory code, bytes4 sel) private pure returns (bool) {
        if (code.length < 4) return false;
        for (uint256 i = 0; i <= code.length - 4; ++i) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) return true;
        }
        return false;
    }

    /// @notice Сапплай не меняется ни от каких действий пользователей.
    function testFuzz_TotalSupply_ImmutableUnderTransfers(uint256 amount, address to) public {
        vm.assume(to != address(0) && to != GENESIS_RECIPIENT);
        amount = bound(amount, 0, SPEC_GENESIS);

        vm.prank(GENESIS_RECIPIENT);
        token.transfer(to, amount);

        assertEq(token.totalSupply(), SPEC_TOTAL_SUPPLY);
    }

    /// @notice Отправка на нулевой адрес — единственный способ сжечь. OZ v5
    ///         запрещает transfer на address(0), так что сжигать нужно на
    ///         0x...dead. Сапплай при этом формально не уменьшается.
    function test_CannotTransferToZeroAddress() public {
        vm.prank(GENESIS_RECIPIENT);
        vm.expectRevert();
        token.transfer(address(0), 1);
    }

    /*//////////////////////////////////////////////////////////////
                            ПОВЕДЕНИЕ ERC-20
    //////////////////////////////////////////////////////////////*/

    function test_TransferAndApprove() public {
        address bob = address(0xB0B);

        vm.prank(GENESIS_RECIPIENT);
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(bob), 100e18);

        vm.prank(bob);
        token.approve(address(this), 40e18);
        token.transferFrom(bob, address(this), 40e18);

        assertEq(token.balanceOf(bob), 60e18);
        assertEq(token.balanceOf(address(this)), 40e18);
        assertEq(token.allowance(bob, address(this)), 0);
    }

    function test_TransferMoreThanBalance_Reverts() public {
        address bob = address(0xB0B);
        vm.prank(bob);
        vm.expectRevert();
        token.transfer(GENESIS_RECIPIENT, 1);
    }

    /// @notice Нулевой адрес получателя ловится самим OZ ERC20._mint.
    function test_ZeroGenesisRecipient_RevertsOnDeploy() public {
        vm.expectRevert();
        new MaclaurinToken(address(0), EMISSION);
    }

    function test_ZeroEmissionContract_RevertsOnDeploy() public {
        vm.expectRevert();
        new MaclaurinToken(GENESIS_RECIPIENT, address(0));
    }
}
