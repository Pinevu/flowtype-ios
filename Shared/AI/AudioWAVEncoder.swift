import Foundation

public enum AudioWAVEncoder {
    public static func encodePCM16Mono(samples: [Int16], sampleRate: Int = 16000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let riffSize = 36 + dataSize

        var data = Data(capacity: Int(44 + dataSize))
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(riffSize, to: &data)
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        appendUInt32LE(16, to: &data) // PCM subchunk size
        appendUInt16LE(1, to: &data)  // AudioFormat = 1 (PCM)
        appendUInt16LE(numChannels, to: &data)
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(byteRate, to: &data)
        appendUInt16LE(blockAlign, to: &data)
        appendUInt16LE(bitsPerSample, to: &data)

        data.append(contentsOf: "data".utf8)
        appendUInt32LE(dataSize, to: &data)

        samples.withUnsafeBytes { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
        return data
    }

    public static func floatSamplesToInt16(_ floats: [Float]) -> [Int16] {
        floats.map { sample in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
