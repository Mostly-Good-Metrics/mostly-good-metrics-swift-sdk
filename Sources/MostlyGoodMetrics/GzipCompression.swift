import Foundation
#if canImport(Compression)
import Compression
#endif

/// Utility for gzip compression following RFC 1952
enum GzipCompression {

    /// Compresses data using gzip format (RFC 1952)
    /// - Parameter data: The data to compress
    /// - Returns: Gzip-compressed data, or nil if compression fails
    static func compress(_ data: Data) -> Data? {
        #if canImport(Compression)
        guard !data.isEmpty else { return nil }

        // Allocate buffer for compressed data (worst case: slightly larger than input)
        let bufferSize = data.count + 512
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePtr = sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return compression_encode_buffer(
                destinationBuffer,
                bufferSize,
                sourcePtr,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else { return nil }

        // Build proper gzip format
        var gzipData = Data()
        gzipData.reserveCapacity(compressedSize + 18) // header (10) + trailer (8)

        // Gzip header (10 bytes)
        gzipData.append(contentsOf: [
            0x1f, 0x8b,             // Magic number
            0x08,                   // Compression method (deflate)
            0x00,                   // Flags (none)
            0x00, 0x00, 0x00, 0x00, // Modification time (none)
            0x00,                   // Extra flags
            0xff                    // OS (unknown)
        ])

        // Compressed data (raw deflate from COMPRESSION_ZLIB)
        gzipData.append(destinationBuffer, count: compressedSize)

        // Gzip trailer (8 bytes)
        let crcValue = crc32(data)
        let size = UInt32(truncatingIfNeeded: data.count)

        // CRC32 (little-endian)
        gzipData.append(UInt8(crcValue & 0xff))
        gzipData.append(UInt8((crcValue >> 8) & 0xff))
        gzipData.append(UInt8((crcValue >> 16) & 0xff))
        gzipData.append(UInt8((crcValue >> 24) & 0xff))

        // Original size mod 2^32 (little-endian)
        gzipData.append(UInt8(size & 0xff))
        gzipData.append(UInt8((size >> 8) & 0xff))
        gzipData.append(UInt8((size >> 16) & 0xff))
        gzipData.append(UInt8((size >> 24) & 0xff))

        return gzipData
        #else
        return nil
        #endif
    }

    /// Calculates CRC32 checksum (used by gzip)
    /// - Parameter data: The data to checksum
    /// - Returns: CRC32 checksum value
    static func crc32(_ data: Data) -> UInt32 {
        // CRC32 lookup table (polynomial 0xedb88320)
        let table: [UInt32] = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 == 1 {
                    c = 0xedb88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }

        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }

    /// Checks if data has a valid gzip header
    /// - Parameter data: The data to check
    /// - Returns: True if the data starts with gzip magic bytes
    static func isGzipCompressed(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == 0x1f && data[1] == 0x8b
    }
}
