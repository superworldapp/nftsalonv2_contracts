// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract ERC1155Mock is ERC1155 {
    constructor() ERC1155("ipfs://mockURL") {}

    function mint(
        address account,
        uint256 id,
        uint256 amount
    ) external {
        _mint(account, id, amount, "");
    }
}
