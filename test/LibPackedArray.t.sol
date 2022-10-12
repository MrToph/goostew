// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {LibPackedArray} from "src/LibPackedArray.sol";

// create wrapper so we can work with calldata
contract PackedArray {
    using LibPackedArray for uint256[];

    uint256[] internal _arr;

    function add(uint256[] calldata values) external {
        _arr.add(values);
    }

    function remove(
        uint256[] calldata removalIndexesDesc,
        uint256[] calldata expectedRemovedValues
    ) external {
        _arr.remove(removalIndexesDesc, expectedRemovedValues);
    }

    function getValues() external view returns (uint256[] memory values) {
        return _arr.getValues();
    }
}

contract SimpleArray {
    uint256[] internal _arr;

    function add(uint256[] calldata values) external {
        for (uint256 i = 0; i < values.length; ++i) {
            _arr.push(values[i]);
        }
    }

    function remove(
        uint256[] calldata removalIndexesDesc,
        uint256[] calldata expectedRemovedValues
    ) external {
        require(
            removalIndexesDesc.length == expectedRemovedValues.length,
            "!length"
        );
        for (uint256 i = 1; i < removalIndexesDesc.length; ++i) {
            require(
                removalIndexesDesc[i] < removalIndexesDesc[i - 1],
                "!sorted"
            );
        }

        for (uint256 i = 0; i < removalIndexesDesc.length; ++i) {
            // we always remove from the back so we don't need to adjust the index
            require(
                _arr[removalIndexesDesc[i]] == expectedRemovedValues[i],
                "!valueEqual"
            );
            _arr[removalIndexesDesc[i]] = _arr[_arr.length - 1];
            _arr.pop();
        }
    }

    function getValues() external view returns (uint256[] memory values) {
        return _arr;
    }
}

contract RandomDrawTest is Test {
    uint256[] private values;
    uint256[] private indexes;
    uint256 private valuesDrawSeed;
    uint256 private indexesDrawSeed;

    function resetValues(
        uint256 minInclusive,
        uint256 maxInclusive,
        uint256 seed
    ) internal {
        delete values;
        for (uint256 i = minInclusive; i <= maxInclusive; ++i) {
            values.push(i);
        }
        valuesDrawSeed = seed;
    }

    function drawUniqueValue() internal returns (uint256 value) {
        assert(values.length > 0);

        uint256 valuesIndex = uint256(
            keccak256(abi.encodePacked(valuesDrawSeed, uint256(0)))
        ) % values.length;
        value = values[valuesIndex];
        values[valuesIndex] = values[values.length - 1];
        values.pop();

        valuesDrawSeed = uint256(keccak256(abi.encodePacked(valuesDrawSeed)));
    }

    function resetIndexes(
        uint256 minInclusive,
        uint256 maxInclusive,
        uint256 seed
    ) internal {
        delete indexes;
        for (uint256 i = minInclusive; i <= maxInclusive; ++i) {
            indexes.push(i);
        }
        indexesDrawSeed = seed;
    }

    function drawUniqueIndex() internal returns (uint256 value) {
        assert(indexes.length > 0);

        uint256 indexesIndex = uint256(
            keccak256(abi.encodePacked(indexesDrawSeed, uint256(1)))
        ) % indexes.length;
        value = indexes[indexesIndex];
        indexes[indexesIndex] = indexes[indexes.length - 1];
        indexes.pop();

        indexesDrawSeed = uint256(keccak256(abi.encodePacked(indexesDrawSeed)));
    }

    function sort(uint256[] memory arr) public pure {
        if (arr.length > 0) {
            quickSort(arr, 0, arr.length - 1);
        }
    }

    function quickSort(
        uint256[] memory arr,
        uint256 left,
        uint256 right
    ) public pure {
        if (left >= right) {
            return;
        }
        uint256 p = arr[(left + right) / 2]; // p = the pivot element
        uint256 i = left;
        uint256 j = right;
        while (i < j) {
            while (arr[i] > p) ++i;
            while (arr[j] < p) --j; // arr[j] > p means p still to the left, so j > 0
            if (arr[i] < arr[j]) {
                (arr[i], arr[j]) = (arr[j], arr[i]);
            } else {
                ++i;
            }
        }

        // Note --j was only done when a[j] > p.  So we know: a[j] == p, a[<j] <= p, a[>j] > p
        if (j > left) {
            quickSort(arr, left, j - 1);
        } // j > left, so j > 0
        quickSort(arr, j + 1, right);
    }
}

contract PackedArrayDifferentialFuzzTest is RandomDrawTest {
    PackedArray p;
    SimpleArray s;

    function setUp() public virtual {
        p = new PackedArray();
        s = new SimpleArray();
    }

    function testAddValuesSingle(uint256 seed, uint16 _length) public {
        resetValues(1, 10_000, seed);

        uint256 length = bound(_length, 0, 1_000);
        uint256[] memory values = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            values[i] = drawUniqueValue();
        }

        p.add(values);
        s.add(values);
        uint256[] memory received = p.getValues();
        uint256[] memory expected = s.getValues();

        assertEq(received.length, expected.length, "length mismatch");
        assertEq(
            keccak256(abi.encodePacked(received)),
            keccak256(abi.encodePacked(expected)),
            "value mismatch"
        );
    }

    function testAddValuesMultiple(uint256 seed, uint16 _length) public {
        resetValues(1, 10_000, seed);

        uint256 length = bound(_length, 0, 1_000);
        for (uint256 i = 0; i < length; i++) {
            uint256[] memory values = new uint256[](1);
            values[0] = drawUniqueValue();
            p.add(values);
            s.add(values);
        }

        uint256[] memory received = p.getValues();
        uint256[] memory expected = s.getValues();

        assertEq(received.length, expected.length, "length mismatch");
        assertEq(
            keccak256(abi.encodePacked(received)),
            keccak256(abi.encodePacked(expected)),
            "value mismatch"
        );
    }

    function testRemoveValuesSingle(
        uint256 seed,
        uint16 _length,
        uint16 _removeLength
    ) public {
        uint256 length = bound(_length, 1, 1_000); // at least length of 1
        uint256 removeLength = bound(_removeLength, 0, length);
        resetValues(1, 10_000, seed);
        resetIndexes(0, length - 1, seed);

        uint256[] memory values = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            values[i] = drawUniqueValue();
        }

        uint256[] memory removalIndexes = new uint256[](removeLength);
        uint256[] memory removalValues = new uint256[](removeLength);
        for (uint256 i = 0; i < removeLength; i++) {
            removalIndexes[i] = drawUniqueIndex();
        }
        sort(removalIndexes);
        for (uint256 i = 0; i < removeLength; i++) {
            removalValues[i] = values[removalIndexes[i]];
        }

        s.add(values);
        p.add(values);
        s.remove(removalIndexes, removalValues);
        p.remove(removalIndexes, removalValues);

        uint256[] memory received = p.getValues();
        uint256[] memory expected = s.getValues();

        assertEq(received.length, expected.length, "length mismatch");
        assertEq(
            keccak256(abi.encodePacked(received)),
            keccak256(abi.encodePacked(expected)),
            "value mismatch"
        );
    }

    function testRemoveValuesMultiple(
        uint256 seed,
        uint16 _length,
        uint16 _removeLength
    ) public {
        uint256 length = bound(_length, 1, 1_000); // at least length of 1
        uint256 removeLength = bound(_removeLength, 0, length);
        resetValues(1, 10_000, seed);
        resetIndexes(0, length - 1, seed);

        uint256[] memory values = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            values[i] = drawUniqueValue();
        }

        uint256[] memory removalIndexes = new uint256[](removeLength);
        uint256[] memory removalValues = new uint256[](removeLength);
        for (uint256 i = 0; i < removeLength; i++) {
            removalIndexes[i] = drawUniqueIndex();
        }
        sort(removalIndexes);
        for (uint256 i = 0; i < removeLength; i++) {
            removalValues[i] = values[removalIndexes[i]];
        }

        s.add(values);
        p.add(values);
        for (uint256 i = 0; i < removeLength; i++) {
            // the descending order of removalIndexes also makes single calls work correctly
            uint256[] memory tmpIndexes = new uint256[](1);
            uint256[] memory tmpValues = new uint256[](1);
            tmpIndexes[0] = removalIndexes[i];
            tmpValues[0] = removalValues[i];
            s.remove(tmpIndexes, tmpValues);
            p.remove(tmpIndexes, tmpValues);
        }

        uint256[] memory received = p.getValues();
        uint256[] memory expected = s.getValues();

        assertEq(received.length, expected.length, "length mismatch");
        assertEq(
            keccak256(abi.encodePacked(received)),
            keccak256(abi.encodePacked(expected)),
            "value mismatch"
        );
    }

    function testAddRemoveMixed(
        uint256[3] memory seeds,
        uint16[3] memory _lengths,
        uint16[3] memory _removeLengths
    ) public {
        resetValues(1, 10_000, seeds[0]);
        for (uint256 iterations = 0; iterations < 3; ++iterations) {
            uint256 length = bound(_lengths[iterations], 1, 1_000); // at least length of 1
            uint256 removeLength = bound(_removeLengths[iterations], 0, length);

            // 1. additions
            uint256[] memory values = new uint256[](length);
            for (uint256 i = 0; i < length; i++) {
                values[i] = drawUniqueValue();
            }
            s.add(values);
            p.add(values);

            // checks
            uint256[] memory expected = s.getValues();
            uint256[] memory received = p.getValues();
            {
                assertEq(received.length, expected.length, "length mismatch");
                assertEq(
                    keccak256(abi.encodePacked(received)),
                    keccak256(abi.encodePacked(expected)),
                    "value mismatch"
                );
            }

            // 2. removals
            // choose fresh random indexes over the _entire_ current values
            uint256 currentPackedArrayLength = s.getValues().length;
            resetIndexes(0, currentPackedArrayLength - 1, seeds[iterations]);

            uint256[] memory removalIndexes = new uint256[](removeLength);
            uint256[] memory removalValues = new uint256[](removeLength);
            for (uint256 i = 0; i < removeLength; i++) {
                removalIndexes[i] = drawUniqueIndex();
            }
            sort(removalIndexes);
            for (uint256 i = 0; i < removeLength; i++) {
                removalValues[i] = expected[removalIndexes[i]];
            }

            s.remove(removalIndexes, removalValues);
            p.remove(removalIndexes, removalValues);

            // checks
            {
                received = p.getValues();
                expected = s.getValues();
                assertEq(received.length, expected.length, "length mismatch");
                assertEq(
                    keccak256(abi.encodePacked(received)),
                    keccak256(abi.encodePacked(expected)),
                    "value mismatch"
                );
            }
        }
    }
}
