// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MaclaurinEmission} from "../src/MaclaurinEmission.sol";
import {MaclaurinToken} from "../src/MaclaurinToken.sol";

/**
 * @title Deploy
 * @notice Разворачивает всю связку одной транзакцией.
 *
 * @dev Разворачивается ТОЛЬКО MaclaurinEmission — токен он создаёт сам в своём
 *      конструкторе. Это не экономия транзакции, а требование безопасности:
 *      при раздельном деплое EMISSION_POOL пришлось бы сначала сминтить на
 *      EOA, а потом переводить, и между этими двумя транзакциями 718 миллионов
 *      токенов лежали бы под приватным ключом. Здесь такого окна нет вообще.
 *
 *      После деплоя скрипт проверяет инварианты прямо на цепочке. Если что-то
 *      разошлось — скрипт падает, и это видно сразу, а не через неделю.
 */
contract Deploy is Script {
    /// @notice Минимальная задержка старта эмиссии. Служит запасом на дрейф
    ///         block.timestamp между симуляцией скрипта и попаданием транзакции
    ///         в реальный блок. Ниже этого значения задержка не опускается,
    ///         даже если переменная окружения задана меньшей или не задана вовсе.
    uint256 public constant MIN_START_DELAY = 300;

    function run() external returns (MaclaurinEmission emission, MaclaurinToken token) {
        address genesisRecipient = vm.envAddress("GENESIS_RECIPIENT");
        address remainderVault = vm.envAddress("REMAINDER_VAULT");

        // Задержка старта эмиссии в секундах. Задаётся отступом от момента
        // деплоя, а не абсолютным таймстампом: абсолютный успевает протухнуть
        // между подготовкой и отправкой, и конструктор ревертит StartTimeInPast.
        //
        // Дефолт НЕ нулевой, и это важно. `forge script --broadcast` сначала
        // прогоняет run() в симуляции на снимке текущего блока, и только потом
        // отправляет транзакцию — она попадёт уже в следующий блок, где
        // block.timestamp больше. При delay = 0 значение startTime, посчитанное
        // в симуляции, окажется в прошлом относительно реального блока, и
        // конструктор отревертит StartTimeInPast (src/MaclaurinEmission.sol:178).
        // Симуляция при этом проходит успешно — время внутри неё не течёт, —
        // поэтому ошибка проявляется только на реальном broadcast.
        // MIN_START_DELAY даёт запас на дрейф блока.
        uint256 delay = vm.envOr("EMISSION_START_DELAY", MIN_START_DELAY);
        if (delay < MIN_START_DELAY) delay = MIN_START_DELAY;
        uint256 startTime = block.timestamp + delay;

        console2.log("chain id:          ", block.chainid);
        console2.log("genesis recipient: ", genesisRecipient);
        console2.log("remainder vault:   ", remainderVault);
        console2.log("emission start:    ", startTime);

        vm.startBroadcast();
        emission = new MaclaurinEmission(genesisRecipient, remainderVault, startTime);
        token = emission.token();
        vm.stopBroadcast();

        console2.log("");
        console2.log("MaclaurinToken:    ", address(token));
        console2.log("MaclaurinEmission: ", address(emission));

        _verify(emission, token, genesisRecipient);
    }

    /// @dev Проверки на развёрнутом контракте. Всё, что здесь может упасть,
    ///      в мейннете уже не чинится — контракт неизменяем.
    function _verify(MaclaurinEmission emission, MaclaurinToken token, address genesisRecipient)
        internal
        view
    {
        require(token.totalSupply() == 2718281828459045235360287471, "supply != floor(e*1e27)");
        require(token.GENESIS() + token.EMISSION_POOL() == token.TOTAL_SUPPLY(), "split mismatch");
        require(token.balanceOf(genesisRecipient) == token.GENESIS(), "genesis not delivered");
        require(token.balanceOf(address(emission)) == token.EMISSION_POOL(), "pool not delivered");
        require(emission.epochAmount(26) == 2, "epoch 26 != 2 wei");
        require(emission.epochAmount(27) == 0, "emission does not terminate");
        require(emission.totalEmittable() == 718281828459045235360287457, "series sum mismatch");
        require(token.EMISSION_POOL() - emission.totalEmittable() == 14, "Lagrange dust != 14 wei");
        require(address(emission.token()) == address(token), "token link broken");

        console2.log("");
        console2.log("all post-deploy invariants hold");
        console2.log("total supply (wei):", token.totalSupply());
        console2.log("emission ends at:  ", emission.emissionEnd());
    }
}
