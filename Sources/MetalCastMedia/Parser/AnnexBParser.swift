import Foundation
import CoreMedia

public enum VideoCodec: String, Sendable {
    case h264 = "h264"
    case h265 = "h265"
}

public final class AnnexBParser: @unchecked Sendable {
    public var codec: VideoCodec = .h264

    private var buffer = Data()
    private var vps: Data? // For H.265 (HEVC)
    private var sps: Data?
    private var pps: Data?

    public var onFormatDescription: ((CMVideoFormatDescription) -> Void)?
    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var currentFormatDesc: CMVideoFormatDescription?

    public init(codec: VideoCodec = .h264) {
        self.codec = codec
    }

    /// Consumes raw chunk from H.264/H.265 video socket
    public func parse(chunk: Data) {
        buffer.append(chunk)

        while true {
            guard let (startCodeLen, startIndex) = findStartCode(in: buffer, offset: 0) else {
                break
            }

            // Find next start code to delineate the NAL unit
            guard let (_, nextIndex) = findStartCode(in: buffer, offset: startIndex + startCodeLen) else {
                // Incomplete NALU, wait for more data
                break
            }

            let nalData = buffer.subdata(in: (startIndex + startCodeLen)..<nextIndex)
            processNALU(nalData)

            buffer.removeSubrange(0..<nextIndex)
        }
    }

    private func findStartCode(in data: Data, offset: Int) -> (len: Int, index: Int)? {
        guard data.count >= offset + 3 else { return nil }
        let bytes = [UInt8](data)

        for i in offset..<(bytes.count - 2) {
            if bytes[i] == 0 && bytes[i+1] == 0 {
                if bytes[i+2] == 1 {
                    return (3, i)
                }
                if i + 3 < bytes.count && bytes[i+2] == 0 && bytes[i+3] == 1 {
                    return (4, i)
                }
            }
        }
        return nil
    }

    private func processNALU(_ nalu: Data) {
        guard !nalu.isEmpty else { return }

        switch codec {
        case .h264:
            let nalType = nalu[0] & 0x1F
            switch nalType {
            case 7: // SPS
                sps = nalu
                tryBuildFormatDescription()
            case 8: // PPS
                pps = nalu
                tryBuildFormatDescription()
            case 1, 5: // Non-IDR (1) or IDR (5) Slice
                guard let formatDesc = currentFormatDesc else { return }
                createSampleBuffer(from: nalu, formatDesc: formatDesc)
            default:
                break
            }

        case .h265:
            let nalType = (nalu[0] >> 1) & 0x3F
            switch nalType {
            case 32: // VPS (Video Parameter Set)
                vps = nalu
                tryBuildFormatDescription()
            case 33: // SPS
                sps = nalu
                tryBuildFormatDescription()
            case 34: // PPS
                pps = nalu
                tryBuildFormatDescription()
            case 0...31: // VCL Slices (IDR, CRA, Non-IDR)
                guard let formatDesc = currentFormatDesc else { return }
                createSampleBuffer(from: nalu, formatDesc: formatDesc)
            default:
                break
            }
        }
    }

    private func tryBuildFormatDescription() {
        switch codec {
        case .h264:
            guard let sps = sps, let pps = pps else { return }
            sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    guard let spsBase = spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsBase = ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                    let parameterSets = [spsBase, ppsBase]
                    let parameterSetSizes = [sps.count, pps.count]

                    var newFormatDesc: CMVideoFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: parameterSets,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &newFormatDesc
                    )

                    if status == noErr, let desc = newFormatDesc {
                        self.currentFormatDesc = desc
                        self.onFormatDescription?(desc)
                    }
                }
            }

        case .h265:
            guard let vps = vps, let sps = sps, let pps = pps else { return }
            vps.withUnsafeBytes { vpsPtr in
                sps.withUnsafeBytes { spsPtr in
                    pps.withUnsafeBytes { ppsPtr in
                        guard let vpsBase = vpsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let spsBase = spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let ppsBase = ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                        let parameterSets = [vpsBase, spsBase, ppsBase]
                        let parameterSetSizes = [vps.count, sps.count, pps.count]

                        var newFormatDesc: CMVideoFormatDescription?
                        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: parameterSets,
                            parameterSetSizes: parameterSetSizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &newFormatDesc
                        )

                        if status == noErr, let desc = newFormatDesc {
                            self.currentFormatDesc = desc
                            self.onFormatDescription?(desc)
                        } else {
                            print("❌ [AnnexBParser] 构建 HEVC 格式描述失败: \(status)")
                        }
                    }
                }
            }
        }
    }

    private func createSampleBuffer(from nalu: Data, formatDesc: CMVideoFormatDescription) {
        // Build AVCC/HVCC: 4-byte big endian length prefix followed by NALU bytes
        var lengthPrefix = UInt32(nalu.count).bigEndian
        var avccData = Data(bytes: &lengthPrefix, count: 4)
        avccData.append(nalu)

        var blockBuffer: CMBlockBuffer?
        let status = avccData.withUnsafeBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return }

        avccData.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: base,
                    blockBuffer: block,
                    offsetIntoDestination: 0,
                    dataLength: avccData.count
                )
            }
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(mach_absolute_time()), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )

        var sampleSize = avccData.count
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        if let sample = sampleBuffer {
            onSampleBuffer?(sample)
        }
    }
}
