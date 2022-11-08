// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// solhint-disable avoid-low-level-calls
// solhint-disable no-inline-assembly

/**
 * Base: Mix of https://github.com/boringcrypto/BoringSolidity/blob/78f4817d9c0d95fe9c45cd42e307ccd22cf5f4fc/contracts/BoringBatchable.sol and https://github.com/Uniswap/v3-periphery/blob/0.8/contracts/base/Multicall.sol
 * modified:
 * - replace external IERC20 import with local IERC20Permit interface
 * - we use multicall interface for better wallet decoding support
 * - added multicall with revertOnFail
 */

// WARNING!!!
// Combining Multicall with msg.value can cause double spending issues
// https://www.paradigm.xyz/2021/08/two-rights-might-make-a-wrong/

interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

abstract contract MulticallBase {
    error MulticallError(bytes innerError);

    /// @dev Helper function to extract a useful revert message from a failed call.
    /// If the returned data is malformed or not correctly abi encoded then this call can fail itself.
    function _getRevertMsg(bytes memory _returnData) internal pure {
        // If the _res length is less than 68, then
        // the transaction failed with custom error or silently (without a revert message)
        if (_returnData.length < 68) revert MulticallError(_returnData);

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        revert(abi.decode(_returnData, (string))); // All that remains is the revert string
    }

    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    /// @dev The `msg.value` should not be trusted for any method callable from multicall.
    /// @param data The encoded function data for each of the calls to make to this contract
    /// @return results The results from each of the calls passed in via data
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                _getRevertMsg(result);
            }

            results[i] = result;
        }
    }

    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    /// @dev The `msg.value` should not be trusted for any method callable from multicall.
    /// @param data The encoded function data for each of the calls to make to this contract
    /// @param revertOnFail The booleans indicating if the call should revert if it fails
    /// @return results The results from each of the calls passed in via data
    function multicall(bytes[] calldata data, bool[] calldata revertOnFail)
        external
        payable
        returns (bytes[] memory results)
    {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success && revertOnFail[i]) {
                _getRevertMsg(result);
            }

            results[i] = result;
        }
    }
}

// to set Goo approvals for users to this contract
abstract contract Multicall is MulticallBase {
    /// @notice Call wrapper that performs `ERC20.permit` on `token`.
    /// Lookup `IERC20.permit`.
    // F6: Parameters can be used front-run the permit and the user's permit will fail (due to nonce or other revert)
    //     if part of a batch this could be used to grief once as the second call would not need the permit
    function permitToken(
        IERC20Permit token,
        address from,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        token.permit(from, to, amount, deadline, v, r, s);
    }
}
