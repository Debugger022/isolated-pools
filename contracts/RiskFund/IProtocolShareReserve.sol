// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

interface IProtocolShareReserve {
    function updateAssetsState(
        address comptroller,
        address asset,
        uint256 kind,
        uint256 amount
    ) external;
}
