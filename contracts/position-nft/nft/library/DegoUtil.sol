// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <=0.8.4;

library DegoUtil {
    function uintToString(uint256 v)
        internal
        pure
        returns (string memory _uintAsString)
    {
        uint256 maxlength = 100;
        bytes memory reversed = new bytes(maxlength);
        uint256 i = 0;
        while (v != 0) {
            uint256 remainder = v % 10;
            v = v / 10;
            reversed[i++] = bytes1(uint8(48 + remainder));
        }
        bytes memory s = new bytes(i); // i + 1 is inefficient
        for (uint256 j = 0; j < i; j++) {
            s[j] = reversed[i - j - 1]; // to avoid the off-by-one error
        }
        _uintAsString = string(s); // memory isn't implicitly convertible to storage
    }
}
