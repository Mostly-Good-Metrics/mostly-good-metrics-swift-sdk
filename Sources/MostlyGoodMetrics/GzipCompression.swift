import Foundation
#if canImport(zlib)
import zlib
#endif

/// Utility for gzip compression following RFC 1952
enum GzipCompression {

    /// Compresses data using gzip format (RFC 1952)
    /// - Parameter data: The data to compress
    /// - Returns: Gzip-compressed data, or nil if compression fails
    static func compress(_ data: Data) -> Data? {
        #if canImport(zlib)
        guard !data.isEmpty else { return nil }

        var stream = z_stream()

        // Initialize for gzip encoding (windowBits 15 + 16 = gzip format)
        let initResult = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16, // 15 + 16 = gzip format
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard initResult == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        // Allocate output buffer
        let bufferSize = deflateBound(&stream, UInt(data.count))
        var outputBuffer = [UInt8](repeating: 0, count: Int(bufferSize))

        // Compress the data
        let result: Int32 = data.withUnsafeBytes { inputBuffer in
            outputBuffer.withUnsafeMutableBufferPointer { outputBufferPtr in
                guard let inputPtr = inputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let outputPtr = outputBufferPtr.baseAddress else {
                    return Z_DATA_ERROR
                }

                stream.next_in = UnsafeMutablePointer(mutating: inputPtr)
                stream.avail_in = UInt32(data.count)
                stream.next_out = outputPtr
                stream.avail_out = UInt32(bufferSize)

                return deflate(&stream, Z_FINISH)
            }
        }

        guard result == Z_STREAM_END else { return nil }

        let compressedSize = Int(bufferSize) - Int(stream.avail_out)
        return Data(outputBuffer.prefix(compressedSize))
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
