import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum ProcessingMode: String, CaseIterable, Identifiable {
    case none
    case stack
    case additive
    case hdr
    case denoise
    case enhance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "なし"
        case .stack: return "スタック合成"
        case .additive: return "加算合成"
        case .hdr: return "HDR"
        case .denoise: return "ノイズ除去"
        case .enhance: return "自動補正"
        }
    }

    var icon: String {
        switch self {
        case .none: return "photo"
        case .stack: return "rectangle.stack"
        case .additive: return "plus.rectangle.on.rectangle"
        case .hdr: return "circle.lefthalf.filled"
        case .denoise: return "wand.and.stars"
        case .enhance: return "slider.horizontal.3"
        }
    }

    var description: String {
        switch self {
        case .none: return "画像処理なし"
        case .stack: return "複数フレームを合成してノイズを低減"
        case .additive: return "複数フレームを加算合成して明るさを向上"
        case .hdr: return "複数露光を合成してダイナミックレンジを拡大"
        case .denoise: return "高度なノイズ除去"
        case .enhance: return "明るさ・コントラスト・彩度を自動調整"
        }
    }
}

protocol ImageProcessorProtocol {
    var processingProgress: Float { get }
    var isProcessing: Bool { get }

    func processFrames(
        _ frames: [CVPixelBuffer],
        mode: ProcessingMode,
        intensity: Float
    ) async -> UIImage?
}

@Observable
final class ImageProcessor: ImageProcessorProtocol {

    private(set) var processingProgress: Float = 0
    private(set) var isProcessing = false

    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func processFrames(
        _ frames: [CVPixelBuffer],
        mode: ProcessingMode,
        intensity: Float = 1.0
    ) async -> UIImage? {
        guard !frames.isEmpty else { return nil }

        await MainActor.run {
            isProcessing = true
            processingProgress = 0
        }

        defer {
            Task { @MainActor in
                isProcessing = false
                processingProgress = 1.0
            }
        }

        let result: UIImage?

        switch mode {
        case .none:
            result = frames.first.flatMap { pixelBufferToUIImage($0) }
        case .stack:
            result = await stackFrames(frames, method: .average, intensity: intensity)
        case .additive:
            result = await additiveStack(frames, intensity: intensity)
        case .hdr:
            result = await processHDR(frames, intensity: intensity)
        case .denoise:
            result = await denoiseFrames(frames, intensity: intensity)
        case .enhance:
            result = await autoEnhance(frames.first!, intensity: intensity)
        }

        return result
    }

    enum StackMethod {
        case average
        case median
    }

    func stackFrames(
        _ frames: [CVPixelBuffer],
        method: StackMethod,
        intensity: Float
    ) async -> UIImage? {
        guard frames.count >= 2 else {
            return frames.first.flatMap { pixelBufferToUIImage($0) }
        }

        let ciImages = frames.compactMap { CIImage(cvPixelBuffer: $0) }
        guard ciImages.count >= 2 else { return nil }

        await MainActor.run { processingProgress = 0.1 }

        let alignedImages = await alignImages(ciImages)

        await MainActor.run { processingProgress = 0.4 }

        let stacked: CIImage?

        switch method {
        case .average:
            stacked = await averageStack(alignedImages, intensity: intensity)
        case .median:
            stacked = await medianStack(alignedImages, intensity: intensity)
        }

        await MainActor.run { processingProgress = 0.9 }

        guard let finalImage = stacked else { return nil }

        let sharpened = applySharpen(to: finalImage, amount: 0.3 * intensity)
        let denoised = applyDenoise(to: sharpened, intensity: 0.2 * intensity)

        return ciImageToUIImage(denoised)
    }

    func additiveStack(
        _ frames: [CVPixelBuffer],
        intensity: Float
    ) async -> UIImage? {
        guard frames.count >= 2 else {
            return frames.first.flatMap { pixelBufferToUIImage($0) }
        }

        let ciImages = frames.compactMap { CIImage(cvPixelBuffer: $0) }
        guard ciImages.count >= 2 else { return nil }

        await MainActor.run { processingProgress = 0.1 }

        let alignedImages = await alignImages(ciImages)

        await MainActor.run { processingProgress = 0.4 }

        let extent = alignedImages[0].extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        let bytesPerRow = width * 4

        var resultPixels: [Float]?

        for (index, image) in alignedImages.enumerated() {
            guard let cgImage = context.createCGImage(image, from: extent) else { continue }

            var pixelData = [UInt8](repeating: 0, count: width * height * 4)
            guard let cgContext = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            if resultPixels == nil {
                resultPixels = [Float](repeating: 0, count: width * height * 4)
            }

            for i in 0..<(width * height * 4) {
                resultPixels![i] += Float(pixelData[i])
            }

            let progress = 0.4 + 0.4 * Float(index + 1) / Float(alignedImages.count)
            await MainActor.run { processingProgress = progress }
        }

        guard let finalPixels = resultPixels else { return nil }

        var outputPixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<outputPixels.count {
            outputPixels[i] = UInt8(max(0, min(255, finalPixels[i])))
        }

        guard let outputContext = CGContext(
            data: &outputPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
              let outputCGImage = outputContext.makeImage() else {
            return nil
        }

        let stacked = CIImage(cgImage: outputCGImage)

        await MainActor.run { processingProgress = 0.9 }

        let blendFactor = intensity
        let blended = applyBlend(original: alignedImages[0], processed: stacked, factor: blendFactor)

        return ciImageToUIImage(blended)
    }

    func processHDR(
        _ frames: [CVPixelBuffer],
        intensity: Float
    ) async -> UIImage? {
        guard frames.count >= 2 else {
            return frames.first.flatMap { pixelBufferToUIImage($0) }
        }

        let ciImages = frames.compactMap { CIImage(cvPixelBuffer: $0) }
        guard ciImages.count >= 2 else { return nil }

        await MainActor.run { processingProgress = 0.1 }

        let exposedImages = createExposureBracket(images: ciImages)

        await MainActor.run { processingProgress = 0.3 }

        let merged = await mergeHDR(exposedImages, intensity: intensity)

        await MainActor.run { processingProgress = 0.7 }

        guard let hdrImage = merged else { return nil }

        let toneMapped = applyToneMapping(to: hdrImage, intensity: intensity)

        await MainActor.run { processingProgress = 0.9 }

        return ciImageToUIImage(toneMapped)
    }

    func denoiseFrames(
        _ frames: [CVPixelBuffer],
        intensity: Float
    ) async -> UIImage? {
        guard let firstFrame = frames.first else { return nil }

        let ciImage = CIImage(cvPixelBuffer: firstFrame)

        await MainActor.run { processingProgress = 0.2 }

        var result = applyDenoise(to: ciImage, intensity: intensity)

        await MainActor.run { processingProgress = 0.5 }

        if frames.count >= 3 {
            let ciImages = frames.prefix(5).compactMap { CIImage(cvPixelBuffer: $0) }
            if let stacked = await temporalDenoise(ciImages, intensity: intensity) {
                result = stacked
            }
        }

        await MainActor.run { processingProgress = 0.8 }

        let sharpened = applySharpen(to: result, amount: 0.2 * intensity)

        await MainActor.run { processingProgress = 0.95 }

        return ciImageToUIImage(sharpened)
    }

    func autoEnhance(
        _ pixelBuffer: CVPixelBuffer,
        intensity: Float
    ) async -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        await MainActor.run { processingProgress = 0.2 }

        var result = applyAutoAdjustment(to: ciImage, intensity: intensity)

        await MainActor.run { processingProgress = 0.5 }

        result = applyColorEnhancement(to: result, intensity: intensity)

        await MainActor.run { processingProgress = 0.7 }

        result = applySharpen(to: result, amount: 0.3 * intensity)

        await MainActor.run { processingProgress = 0.9 }

        return ciImageToUIImage(result)
    }

    // MARK: - Private Processing Methods

    private func alignImages(_ images: [CIImage]) async -> [CIImage] {
        guard images.count >= 2 else { return images }

        let reference = images[0]
        var aligned = [reference]

        for i in 1..<images.count {
            let offset = estimateMotion(reference: reference, target: images[i])
            let transform = CGAffineTransform(translationX: offset.x, y: offset.y)
            aligned.append(images[i].transformed(by: transform))
        }

        return aligned
    }

    private func estimateMotion(reference: CIImage, target: CIImage) -> CGPoint {
        let scale = min(Constants.ImageProcessing.motionEstimationScale / reference.extent.width, Constants.ImageProcessing.motionEstimationScale / reference.extent.height)

        let resizedRef = reference.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let resizedTarget = target.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let blockSize = Constants.ImageProcessing.motionEstimationBlockSize
        let refW = Int(resizedRef.extent.width)
        let refH = Int(resizedRef.extent.height)

        guard refW > blockSize * 2, refH > blockSize * 2 else {
            return .zero
        }

        let centerX = refW / 2
        let centerY = refH / 2
        let regionSize = blockSize * 2

        let region = CGRect(
            x: centerX - regionSize / 2,
            y: centerY - regionSize / 2,
            width: regionSize,
            height: regionSize
        )

        guard let refCG = context.createCGImage(resizedRef, from: region),
              let targetCG = context.createCGImage(resizedTarget, from: resizedTarget.extent) else {
            return .zero
        }

        let refData = getGrayscaleData(from: refCG)
        let targetData = getGrayscaleData(from: targetCG)

        guard let refPixels = refData, let targetPixels = targetData else {
            return .zero
        }

        var bestOffset = CGPoint.zero
        var bestScore = Float.greatestFiniteMagnitude

        let searchRange = Constants.ImageProcessing.motionSearchRange
        let step = Constants.ImageProcessing.motionSearchStep

        for dy in stride(from: -searchRange, through: searchRange, by: step) {
            for dx in stride(from: -searchRange, through: searchRange, by: step) {
                var sad: Float = 0
                var count = 0

                for y in 0..<regionSize {
                    for x in 0..<regionSize {
                        let refIdx = y * regionSize + x
                        let tgtX = x + dx + (centerX - regionSize / 2)
                        let tgtY = y + dy + (centerY - regionSize / 2)

                        if tgtX >= 0, tgtX < refW, tgtY >= 0, tgtY < refH {
                            let tgtIdx = tgtY * refW + tgtX
                            sad += abs(Float(refPixels[refIdx]) - Float(targetPixels[tgtIdx]))
                            count += 1
                        }
                    }
                }

                if count > 0 {
                    let avgSad = sad / Float(count)
                    if avgSad < bestScore {
                        bestScore = avgSad
                        bestOffset = CGPoint(x: CGFloat(dx) / scale, y: CGFloat(dy) / scale)
                    }
                }
            }
        }

        return bestOffset
    }

    private func getGrayscaleData(from cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width

        var data = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return data
    }

    private func averageStack(_ images: [CIImage], intensity: Float) async -> CIImage? {
        guard !images.isEmpty else { return nil }

        if images.count == 1 {
            return images[0]
        }

        let extent = images[0].extent

        let weights = images.enumerated().map { index, _ -> Float in
            let center = Float(images.count - 1) / 2.0
            let distance = abs(Float(index) - center)
            let weight = 1.0 - (distance / center) * 0.3
            return weight
        }

        let totalWeight = weights.reduce(0, +)

        var resultPixels: [Float]?
        let width = Int(extent.width)
        let height = Int(extent.height)
        let bytesPerRow = width * 4

        for (index, image) in images.enumerated() {
            guard let cgImage = context.createCGImage(image, from: extent) else { continue }

            var pixelData = [UInt8](repeating: 0, count: width * height * 4)
            guard let cgContext = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            let weight = weights[index] / totalWeight

            if resultPixels == nil {
                resultPixels = [Float](repeating: 0, count: width * height * 4)
            }

            for i in 0..<(width * height * 4) {
                resultPixels![i] += Float(pixelData[i]) * weight
            }
        }

        guard let finalPixels = resultPixels else { return nil }

        var outputPixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<outputPixels.count {
            outputPixels[i] = UInt8(max(0, min(255, finalPixels[i])))
        }

        guard let outputContext = CGContext(
            data: &outputPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
              let outputCGImage = outputContext.makeImage() else {
            return nil
        }

        let stacked = CIImage(cgImage: outputCGImage)

        let blendFactor = intensity
        let blended = applyBlend(original: images[0], processed: stacked, factor: blendFactor)

        return blended
    }

    private func medianStack(_ images: [CIImage], intensity: Float) async -> CIImage? {
        guard !images.isEmpty else { return nil }

        if images.count == 1 {
            return images[0]
        }

        let extent = images[0].extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        let bytesPerRow = width * 4

        var allPixels: [[UInt8]] = []

        for image in images {
            guard let cgImage = context.createCGImage(image, from: extent) else { continue }

            var pixelData = [UInt8](repeating: 0, count: width * height * 4)
            guard let cgContext = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            allPixels.append(pixelData)
        }

        guard !allPixels.isEmpty else { return nil }

        let pixelCount = width * height * 4
        var outputPixels = [UInt8](repeating: 0, count: pixelCount)

        for i in 0..<pixelCount {
            var values: [UInt8] = []
            for pixels in allPixels {
                values.append(pixels[i])
            }
            values.sort()
            outputPixels[i] = values[values.count / 2]
        }

        guard let outputContext = CGContext(
            data: &outputPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
              let outputCGImage = outputContext.makeImage() else {
            return nil
        }

        let medianImage = CIImage(cgImage: outputCGImage)
        return applyBlend(original: images[0], processed: medianImage, factor: intensity)
    }

    private func createExposureBracket(images: [CIImage]) -> [CIImage] {
        guard !images.isEmpty else { return [] }

        let exposures: [Float] = [-1.0, 0.0, 1.0]
        var result: [CIImage] = []

        for (index, image) in images.enumerated() {
            let exposureIndex = index % exposures.count
            let exposure = exposures[exposureIndex]

            if exposure == 0.0 {
                result.append(image)
            } else {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = image
                filter.ev = exposure
                if let output = filter.outputImage {
                    result.append(output)
                }
            }
        }

        return result
    }

    private func mergeHDR(_ images: [CIImage], intensity: Float) async -> CIImage? {
        guard images.count >= 2 else { return images.first }

        let extent = images[0].extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        let bytesPerRow = width * 4

        var allPixels: [[UInt8]] = []

        for image in images {
            guard let cgImage = context.createCGImage(image, from: extent) else { continue }

            var pixelData = [UInt8](repeating: 0, count: width * height * 4)
            guard let cgContext = CGContext(
                data: &pixelData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            allPixels.append(pixelData)
        }

        guard allPixels.count >= 2 else { return images.first }

        var outputPixels = [UInt8](repeating: 0, count: width * height * 4)

        for i in stride(from: 0, to: width * height * 4, by: 4) {
            var r: Float = 0
            var g: Float = 0
            var b: Float = 0
            var a: Float = 0
            var weightSum: Float = 0

            for pixels in allPixels {
                let pr = Float(pixels[i])
                let pg = Float(pixels[i + 1])
                let pb = Float(pixels[i + 2])
                let pa = Float(pixels[i + 3])

                let luminance = 0.299 * pr + 0.587 * pg + 0.114 * pb
                let weight = gaussianWeight(luminance / 255.0)

                r += pr * weight
                g += pg * weight
                b += pb * weight
                a += pa * weight
                weightSum += weight
            }

            if weightSum > 0 {
                outputPixels[i] = UInt8(max(0, min(255, r / weightSum)))
                outputPixels[i + 1] = UInt8(max(0, min(255, g / weightSum)))
                outputPixels[i + 2] = UInt8(max(0, min(255, b / weightSum)))
                outputPixels[i + 3] = UInt8(max(0, min(255, a / weightSum)))
            }
        }

        guard let outputContext = CGContext(
            data: &outputPixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
              let outputCGImage = outputContext.makeImage() else {
            return nil
        }

        let hdrImage = CIImage(cgImage: outputCGImage)
        return applyBlend(original: images[0], processed: hdrImage, factor: intensity)
    }

    private func gaussianWeight(_ x: Float) -> Float {
        let mu: Float = 0.5
        let sigma: Float = 0.2
        let diff = x - mu
        return exp(-diff * diff / (2 * sigma * sigma))
    }

    private func applyToneMapping(to image: CIImage, intensity: Float) -> CIImage {
        let exposureFilter = CIFilter.exposureAdjust()
        exposureFilter.inputImage = image
        exposureFilter.ev = -0.5 * intensity

        guard let output = exposureFilter.outputImage else { return image }

        return applyBlend(original: image, processed: output, factor: intensity)
    }

    private func temporalDenoise(_ images: [CIImage], intensity: Float) async -> CIImage? {
        guard images.count >= 3 else { return images.first }

        return await averageStack(images, intensity: intensity * 0.7)
    }

    private func applyDenoise(to image: CIImage, intensity: Float) -> CIImage {
        let filter = CIFilter.noiseReduction()
        filter.inputImage = image
        filter.noiseLevel = Constants.ImageProcessing.denoiseNoiseLevel * intensity
        filter.sharpness = Constants.ImageProcessing.denoiseSharpness * intensity

        guard let output = filter.outputImage else { return image }

        return applyBlend(original: image, processed: output, factor: intensity)
    }

    private func applySharpen(to image: CIImage, amount: Float) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.intensity = amount
        filter.radius = Constants.ImageProcessing.sharpenRadius

        guard let output = filter.outputImage else { return image }

        return output
    }

    private func applyAutoAdjustment(to image: CIImage, intensity: Float) -> CIImage {
        let autoAdjust = image.autoAdjustmentFilter(options: [
            .enhance: true,
            .redEye: false
        ])

        guard let output = autoAdjust else { return image }

        return applyBlend(original: image, processed: output, factor: intensity)
    }

    private func applyColorEnhancement(to image: CIImage, intensity: Float) -> CIImage {
        let vibranceFilter = CIFilter.vibrance()
        vibranceFilter.inputImage = image
        vibranceFilter.amount = Constants.ImageProcessing.vibranceAmount * intensity

        guard let vibranceOutput = vibranceFilter.outputImage else { return image }

        let colorControl = CIFilter.colorControls()
        colorControl.inputImage = vibranceOutput
        colorControl.contrast = 1.0 + Constants.ImageProcessing.contrastBoost * intensity
        colorControl.brightness = Constants.ImageProcessing.brightnessBoost * intensity
        colorControl.saturation = 1.0 + Constants.ImageProcessing.saturationBoost * intensity

        guard let output = colorControl.outputImage else { return vibranceOutput }

        return applyBlend(original: image, processed: output, factor: intensity)
    }

    private func applyBlend(original: CIImage, processed: CIImage, factor: Float) -> CIImage {
        guard factor < 1.0 else { return processed }

        let blendFilter = CIFilter.blendWithAlphaMask()

        let maskImage = CIImage(color: CIColor(red: CGFloat(factor), green: CGFloat(factor), blue: CGFloat(factor), alpha: 1.0))
            .cropped(to: original.extent)

        blendFilter.inputImage = processed
        blendFilter.backgroundImage = original
        blendFilter.maskImage = maskImage

        return blendFilter.outputImage ?? processed
    }

    // MARK: - Conversion Helpers

    private func pixelBufferToUIImage(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciImageToUIImage(ciImage)
    }

    private func ciImageToUIImage(_ ciImage: CIImage) -> UIImage? {
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }
}

extension CIImage {
    func autoAdjustmentFilter(options: [CIImageAutoAdjustmentOption: Any]) -> CIImage? {
        let filters = autoAdjustmentFilters(options: options)
        var result = self
        for filter in filters {
            filter.setValue(result, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                result = output
            }
        }
        return result
    }
}
