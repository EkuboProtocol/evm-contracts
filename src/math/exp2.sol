// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

/// @dev Computes 2^x where x is a 5.64 number and result is a 64.64 number
/// @dev Uses gated bit manipulation for gas efficiency, similar to tickToSqrtRatio
function exp2(uint256 x) pure returns (uint256 result) {
    unchecked {
        require(x < 0x400000000000000000); // Overflow

        assembly ("memory-safe") {
            // Start with 2^127 in Q128 format
            result := 0x80000000000000000000000000000000

            // -------- Gate 8: bits 56..63 (mask 0xFF00000000000000) --------
            if and(x, 0xFF00000000000000) {
                if and(x, 0x8000000000000000) { result := shr(128, mul(result, 0x16A09E667F3BCC908B2FB1366EA957D3E)) }
                if and(x, 0x4000000000000000) { result := shr(128, mul(result, 0x1306FE0A31B7152DE8D5A46305C85EDEC)) }
                if and(x, 0x2000000000000000) { result := shr(128, mul(result, 0x1172B83C7D517ADCDF7C8C50EB14A791F)) }
                if and(x, 0x1000000000000000) { result := shr(128, mul(result, 0x10B5586CF9890F6298B92B71842A98363)) }
                if and(x, 0x800000000000000) { result := shr(128, mul(result, 0x1059B0D31585743AE7C548EB68CA417FD)) }
                if and(x, 0x400000000000000) { result := shr(128, mul(result, 0x102C9A3E778060EE6F7CACA4F7A29BDE8)) }
                if and(x, 0x200000000000000) { result := shr(128, mul(result, 0x10163DA9FB33356D84A66AE336DCDFA3F)) }
                if and(x, 0x100000000000000) { result := shr(128, mul(result, 0x100B1AFA5ABCBED6129AB13EC11DC9543)) }
            }

            // -------- Gate 7: bits 48..55 (mask 0xFF000000000000) --------
            if and(x, 0xFF000000000000) {
                if and(x, 0x80000000000000) { result := shr(128, mul(result, 0x10058C86DA1C09EA1FF19D294CF2F679B)) }
                if and(x, 0x40000000000000) { result := shr(128, mul(result, 0x1002C605E2E8CEC506D21BFC89A23A00F)) }
                if and(x, 0x20000000000000) { result := shr(128, mul(result, 0x100162F3904051FA128BCA9C55C31E5DF)) }
                if and(x, 0x10000000000000) { result := shr(128, mul(result, 0x1000B175EFFDC76BA38E31671CA939725)) }
                if and(x, 0x8000000000000) { result := shr(128, mul(result, 0x100058BA01FB9F96D6CACD4B180917C3D)) }
                if and(x, 0x4000000000000) { result := shr(128, mul(result, 0x10002C5CC37DA9491D0985C348C68E7B3)) }
                if and(x, 0x2000000000000) { result := shr(128, mul(result, 0x1000162E525EE054754457D5995292026)) }
                if and(x, 0x1000000000000) { result := shr(128, mul(result, 0x10000B17255775C040618BF4A4ADE83FC)) }
            }

            // -------- Gate 6: bits 40..47 (mask 0xFF0000000000) --------
            if and(x, 0xFF0000000000) {
                if and(x, 0x800000000000) { result := shr(128, mul(result, 0x1000058B91B5BC9AE2EED81E9B7D4CFAB)) }
                if and(x, 0x400000000000) { result := shr(128, mul(result, 0x100002C5C89D5EC6CA4D7C8ACC017B7C9)) }
                if and(x, 0x200000000000) { result := shr(128, mul(result, 0x10000162E43F4F831060E02D839A9D16D)) }
                if and(x, 0x100000000000) { result := shr(128, mul(result, 0x100000B1721BCFC99D9F890EA06911763)) }
                if and(x, 0x80000000000) { result := shr(128, mul(result, 0x10000058B90CF1E6D97F9CA14DBCC1628)) }
                if and(x, 0x40000000000) { result := shr(128, mul(result, 0x1000002C5C863B73F016468F6BAC5CA2B)) }
                if and(x, 0x20000000000) { result := shr(128, mul(result, 0x100000162E430E5A18F6119E3C02282A5)) }
                if and(x, 0x10000000000) { result := shr(128, mul(result, 0x1000000B1721835514B86E6D96EFD1BFE)) }
            }

            // -------- Gate 5: bits 32..39 (mask 0xFF00000000) --------
            if and(x, 0xFF00000000) {
                if and(x, 0x8000000000) { result := shr(128, mul(result, 0x100000058B90C0B48C6BE5DF846C5B2EF)) }
                if and(x, 0x4000000000) { result := shr(128, mul(result, 0x10000002C5C8601CC6B9E94213C72737A)) }
                if and(x, 0x2000000000) { result := shr(128, mul(result, 0x1000000162E42FFF037DF38AA2B219F06)) }
                if and(x, 0x1000000000) { result := shr(128, mul(result, 0x10000000B17217FBA9C739AA5819F44F9)) }
                if and(x, 0x800000000) { result := shr(128, mul(result, 0x1000000058B90BFCDEE5ACD3C1CEDC823)) }
                if and(x, 0x400000000) { result := shr(128, mul(result, 0x100000002C5C85FE31F35A6A30DA1BE50)) }
                if and(x, 0x200000000) { result := shr(128, mul(result, 0x10000000162E42FF0999CE3541B9FFFCF)) }
                if and(x, 0x100000000) { result := shr(128, mul(result, 0x100000000B17217F80F4EF5AADDA45554)) }
            }

            // -------- Gate 4: bits 24..31 (mask 0xFF000000) --------
            if and(x, 0xFF000000) {
                if and(x, 0x80000000) { result := shr(128, mul(result, 0x10000000058B90BFBF8479BD5A81B51AD)) }
                if and(x, 0x40000000) { result := shr(128, mul(result, 0x1000000002C5C85FDF84BD62AE30A74CC)) }
                if and(x, 0x20000000) { result := shr(128, mul(result, 0x100000000162E42FEFB2FED257559BDAA)) }
                if and(x, 0x10000000) { result := shr(128, mul(result, 0x1000000000B17217F7D5A7716BBA4A9AE)) }
                if and(x, 0x8000000) { result := shr(128, mul(result, 0x100000000058B90BFBE9DDBAC5E109CCE)) }
                if and(x, 0x4000000) { result := shr(128, mul(result, 0x10000000002C5C85FDF4B15DE6F17EB0D)) }
                if and(x, 0x2000000) { result := shr(128, mul(result, 0x1000000000162E42FEFA494F1478FDE05)) }
                if and(x, 0x1000000) { result := shr(128, mul(result, 0x10000000000B17217F7D20CF927C8E94C)) }
            }

            // -------- Gate 3: bits 16..23 (mask 0xFF0000) --------
            if and(x, 0xFF0000) {
                if and(x, 0x800000) { result := shr(128, mul(result, 0x1000000000058B90BFBE8F71CB4E4B33D)) }
                if and(x, 0x400000) { result := shr(128, mul(result, 0x100000000002C5C85FDF477B662B26945)) }
                if and(x, 0x200000) { result := shr(128, mul(result, 0x10000000000162E42FEFA3AE53369388C)) }
                if and(x, 0x100000) { result := shr(128, mul(result, 0x100000000000B17217F7D1D351A389D40)) }
                if and(x, 0x80000) { result := shr(128, mul(result, 0x10000000000058B90BFBE8E8B2D3D4EDE)) }
                if and(x, 0x40000) { result := shr(128, mul(result, 0x1000000000002C5C85FDF4741BEA6E77E)) }
                if and(x, 0x20000) { result := shr(128, mul(result, 0x100000000000162E42FEFA39FE95583C2)) }
                if and(x, 0x10000) { result := shr(128, mul(result, 0x1000000000000B17217F7D1CFB72B45E1)) }
            }

            // -------- Gate 2: bits 8..15 (mask 0xFF00) --------
            if and(x, 0xFF00) {
                if and(x, 0x8000) { result := shr(128, mul(result, 0x100000000000058B90BFBE8E7CC35C3F0)) }
                if and(x, 0x4000) { result := shr(128, mul(result, 0x10000000000002C5C85FDF473E242EA38)) }
                if and(x, 0x2000) { result := shr(128, mul(result, 0x1000000000000162E42FEFA39F02B772C)) }
                if and(x, 0x1000) { result := shr(128, mul(result, 0x10000000000000B17217F7D1CF7D83C1A)) }
                if and(x, 0x800) { result := shr(128, mul(result, 0x1000000000000058B90BFBE8E7BDCBE2E)) }
                if and(x, 0x400) { result := shr(128, mul(result, 0x100000000000002C5C85FDF473DEA871F)) }
                if and(x, 0x200) { result := shr(128, mul(result, 0x10000000000000162E42FEFA39EF44D91)) }
                if and(x, 0x100) { result := shr(128, mul(result, 0x100000000000000B17217F7D1CF79E949)) }
            }

            // -------- Gate 1: bits 0..7 (mask 0xFF) --------
            if and(x, 0xFF) {
                if and(x, 0x80) { result := shr(128, mul(result, 0x10000000000000058B90BFBE8E7BCE544)) }
                if and(x, 0x40) { result := shr(128, mul(result, 0x1000000000000002C5C85FDF473DE6ECA)) }
                if and(x, 0x20) { result := shr(128, mul(result, 0x100000000000000162E42FEFA39EF366F)) }
                if and(x, 0x10) { result := shr(128, mul(result, 0x1000000000000000B17217F7D1CF79AFA)) }
                if and(x, 0x8) { result := shr(128, mul(result, 0x100000000000000058B90BFBE8E7BCD6D)) }
                if and(x, 0x4) { result := shr(128, mul(result, 0x10000000000000002C5C85FDF473DE6B2)) }
                if and(x, 0x2) { result := shr(128, mul(result, 0x1000000000000000162E42FEFA39EF358)) }
                if and(x, 0x1) { result := shr(128, mul(result, 0x10000000000000000B17217F7D1CF79AB)) }
            }
        }

        // Final shift based on integer part (done outside assembly to match original behavior)
        result >>= uint256(63 - (x >> 64));
    }
}
