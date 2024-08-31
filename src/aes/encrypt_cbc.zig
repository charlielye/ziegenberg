const std = @import("std");

pub fn encrypt_cbc(src: []u8, key: *const [16]u8, iv: *const [16]u8) void {
    const ctx = std.crypto.core.aes.AesEncryptCtx(std.crypto.core.aes.Aes128).init(key.*);
    const BlockSize = 16;
    std.debug.assert(src.len >= BlockSize and (src.len % BlockSize) == 0);

    var previousBlock: [BlockSize]u8 = iv.*;
    var i: usize = 0;

    while (i < src.len / 16) {
        var blockToEncrypt: [BlockSize]u8 = undefined;
        // XOR current plaintext block with the previous ciphertext block (or IV for the first block)
        for (0..BlockSize) |j| {
            blockToEncrypt[j] = src[i + j] ^ previousBlock[j];
        }

        // Encrypt the XORed block
        ctx.encrypt(&blockToEncrypt, &blockToEncrypt);

        // Store the encrypted block in the destination buffer
        for (0..BlockSize) |j| {
            src[i + j] = blockToEncrypt[j];
        }

        // Update the previousBlock with the current ciphertext block
        std.mem.copyForwards(u8, &previousBlock, &blockToEncrypt);

        i += BlockSize;
    }
}
