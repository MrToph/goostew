// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

/// @title LibPackedArray
/// @author cmichel
/// @dev tighly packs values in range [1, 10_000] into an array. slots are filled with values from lsb to msb
library LibPackedArray {
    error ArrayLengthMismatch();
    error ArrayNotSorted();
    error ValueNotFound(uint256 value);
    error ExpectedNonZeroId();

    uint256 constant MAX_VALUE_BITS = 14; // log_2(10_000) = 13.82 bits < 14 bits;
    uint256 constant VALUE_MASK = (2 ** MAX_VALUE_BITS) - 1; // MAX_VALUE_BITS-bit mask of 1's
    uint256 constant MAX_VALUES_PER_SLOT = 256 / MAX_VALUE_BITS; // 256 slot bits / 14 MAX_VALUE_BITS = 18.25 ~ 18

    /// @dev does NOT check if items already exist in the array. caller needs to ensure no duplicates can happen
    function add(uint256[] storage arr, uint256[] calldata values) internal {
        uint256 valuesLength = values.length;
        uint256 arrLength = arr.length;
        // if there is no previous slot, act as if the previous slot was full which will create a new slot
        uint256 lastSlot = arrLength == 0 ? type(uint256).max : arr[arrLength - 1];
        uint256 valuesIndex = 0;

        {
            uint256 lastSlotUpdated = lastSlot;
            // check if there's still space in lastSlot
            for (uint256 i = 0; i < MAX_VALUES_PER_SLOT; ++i) {
                uint256 value = _getValueAtIndex(lastSlot, i);
                // if this condiition is true once, it'll be true until rest of loop. for readability reasons we keep it
                if (value != 0) continue;
                if (valuesIndex >= valuesLength) break;
                lastSlotUpdated |= (values[valuesIndex++] & VALUE_MASK) << (i * MAX_VALUE_BITS);
            }
            // if they differ, lastSlot must have been a real slot
            if (lastSlotUpdated != lastSlot) {
                arr[arrLength - 1] = lastSlotUpdated;
            }
        }

        // check if we can fill the previous slot
        while (valuesIndex < valuesLength) {
            uint256 newSlot = 0;
            // fill slot with remaining values
            for (uint256 i = 0; i < MAX_VALUES_PER_SLOT && valuesIndex < valuesLength; ++i) {
                newSlot |= (values[valuesIndex++] & VALUE_MASK) << (i * MAX_VALUE_BITS);
            }
            arr.push(newSlot);
        }
    }

    /// @dev verifies that value at `removalIndexesDesc[i]` equals `expectedRemovedValues[i]` (and `expectedRemovedValues[i] != 0`).
    /// this ensures that all values in `expectedRemovedValues` have indeed been found and removed
    function remove(
        uint256[] storage arr,
        uint256[] calldata removalIndexesDesc,
        uint256[] calldata expectedRemovedValues
    ) external {
        if (removalIndexesDesc.length != expectedRemovedValues.length) {
            revert ArrayLengthMismatch();
        }
        if (removalIndexesDesc.length == 0) {
            return;
        }
        // ensure sorted in descending order (highest index to lowest)
        for (uint256 i = 1; i < removalIndexesDesc.length; ++i) {
            // require(removalIndexesDesc[i] < removalIndexesDesc[i - 1])
            if (removalIndexesDesc[i] >= removalIndexesDesc[i - 1]) {
                revert ArrayNotSorted();
            }
        }
        uint256 arrLength = arr.length;
        if (arrLength == 0) {
            revert ValueNotFound(expectedRemovedValues[0]);
        }

        // at this point removalIndexesDesc.length > 0 && arrLength > 0
        // 1. count the number of values in the last slot
        uint256[] memory arrCopy = new uint256[](arrLength);
        uint256 runningLastSlotIndex = arrLength - 1; // decreased by 1 whenever we remove the entire last slot
        arrCopy[runningLastSlotIndex] = arr[runningLastSlotIndex];
        uint256 currentNumValuesLastSlot = _countValues(arrCopy[runningLastSlotIndex]); // >= 1 as slot exists

        // 2. cache only the slots that we're going to touch for removalIndexes (& last slot)
        for (uint256 i = 0; i < removalIndexesDesc.length; ++i) {
            uint256 slotIndex = removalIndexesDesc[i] / MAX_VALUES_PER_SLOT;
            // prevent reading a slot twice. any slot in arr is non-zero as zero slots are removed
            if (arrCopy[slotIndex] == 0) {
                arrCopy[slotIndex] = arr[slotIndex];
            }
        }

        // 3. now iterate over removals and remove value by swapping it with last value + "pop" last value
        // we need to keep reading and writing to arrCopy each iteration as runningLastSlotIndex might be the same as slotIndex, which would then work on outdated data
        for (uint256 i = 0; i < removalIndexesDesc.length; ++i) {
            // a) read last value
            uint256 lastSlot = arrCopy[runningLastSlotIndex];
            uint256 lastValue = _getValueAtIndex(lastSlot, currentNumValuesLastSlot - 1);

            // b) set new value
            uint256 slotIndex = removalIndexesDesc[i] / MAX_VALUES_PER_SLOT;
            uint256 valueIndex = removalIndexesDesc[i] % MAX_VALUES_PER_SLOT;
            uint256 slot = arrCopy[slotIndex];
            uint256 value = _getValueAtIndex(slot, valueIndex);
            // check that we're not expecting the uninitialized value => we only remove values that have been set
            if (expectedRemovedValues[i] == 0) revert ExpectedNonZeroId();
            if (value != expectedRemovedValues[i]) revert ValueNotFound(expectedRemovedValues[i]);
            slot = _setValueAtIndex(slot, valueIndex, lastValue);
            // write it back to cache
            arrCopy[slotIndex] = slot;

            // c) set last value to zero. (this order works if index to remove is same index as runningLastSlotIndex)
            lastSlot = arrCopy[runningLastSlotIndex];
            lastSlot = _setValueAtIndex(lastSlot, currentNumValuesLastSlot - 1, 0);
            // write it back
            arrCopy[runningLastSlotIndex] = lastSlot;

            // d) we swapped last value => decrement currentNumValuesLastSlot and adjust lastSlot config
            if (--currentNumValuesLastSlot == 0) {
                // we also need to decrement runningLastSlotIndex
                if (runningLastSlotIndex == 0) {
                    // require that this was the last iteration, `i >= removalIndexesDesc.length - 1`. otherwise outstanding removals
                    if (i + 1 < removalIndexesDesc.length) {
                        revert ValueNotFound(expectedRemovedValues[i + 1]);
                    }
                } else {
                    // decrement and potentially read fresh slot from storage (if slot not fresh, it has been modified through a removal swap already)
                    --runningLastSlotIndex;
                    if (arrCopy[runningLastSlotIndex] == 0) {
                        arrCopy[runningLastSlotIndex] = arr[runningLastSlotIndex];
                    }
                    currentNumValuesLastSlot = MAX_VALUES_PER_SLOT; // a lower-index slot is always full because we replace holes
                }
            }
        }

        // 4. write back all touched slots to storage
        // handle special case that all items were removed (runningLastSlotIndex == 0 && currentNumValuesLastSlot == 0) above where we couldn't decrement runningLastSlotIndex
        if (runningLastSlotIndex == 0 && currentNumValuesLastSlot == 0) {
            for (uint256 i = 0; i < arrLength; i++) {
                arr.pop();
            }
            return;
        }

        // runningLastSlotIndex is now accurate and points to a non-empty slot. pop all greater ones
        for (uint256 i = arrLength - 1; i > runningLastSlotIndex; i--) {
            arr.pop();
        }
        // write runningLastSlotIndex
        arr[runningLastSlotIndex] = arrCopy[runningLastSlotIndex];
        delete arrCopy[runningLastSlotIndex];
        // what's left are only the slots where values have been removed
        for (uint256 i = 0; i < removalIndexesDesc.length; ++i) {
            uint256 slotIndex = removalIndexesDesc[i] / MAX_VALUES_PER_SLOT;
            // prevent writing a slot twice. a legitimately touched slot cannot be zero, only `i > runningLastSlotIndex` which have already been written
            if (arrCopy[slotIndex] != 0) {
                arr[slotIndex] = arrCopy[slotIndex];
                delete arrCopy[slotIndex];
            }
        }
    }

    /// @dev unpacks the packed array into a normal array of values
    function getValues(uint256[] storage arr) internal view returns (uint256[] memory values) {
        // count how many values are in the last slot
        uint256 arrLength = arr.length;
        if (arrLength == 0) {
            return new uint256[](0);
        }

        // create copy of arr in memory as we need to iterate over all of them anyway
        uint256[] memory _arr = arr;
        uint256 lastSlot = _arr[arrLength - 1];
        uint256 numValuesLastSlot = _countValues(lastSlot);

        // all previous slots are full + number of values in last slot
        uint256 valuesLength = MAX_VALUES_PER_SLOT * (arrLength - 1) + numValuesLastSlot;
        values = new uint256[](valuesLength);

        for (uint256 i = 0; i < valuesLength; ++i) {
            uint256 slotIndex = i / MAX_VALUES_PER_SLOT;
            uint256 valueIndex = i % MAX_VALUES_PER_SLOT;
            values[i] = _getValueAtIndex(_arr[slotIndex], valueIndex);
        }
    }

    function _countValues(uint256 slot) private pure returns (uint256 numValues) {
        for (; numValues < MAX_VALUES_PER_SLOT; ++numValues) {
            uint256 value = _getValueAtIndex(slot, numValues);
            if (value == 0) break;
        }
    }

    function _getValueAtIndex(uint256 slot, uint256 index) private pure returns (uint256 value) {
        value = (slot >> (index * MAX_VALUE_BITS)) & VALUE_MASK;
    }

    function _setValueAtIndex(uint256 slot, uint256 index, uint256 value) private pure returns (uint256 newSlot) {
        newSlot = slot & ~((VALUE_MASK) << (index * MAX_VALUE_BITS)); // clear bits
        newSlot |= (value & VALUE_MASK) << (index * MAX_VALUE_BITS); // set new bits
    }
}
