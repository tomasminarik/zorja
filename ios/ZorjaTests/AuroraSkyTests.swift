import Foundation
import Metal
import Synchronization
import SwiftUI
import Testing
@testable import Zorja

@Suite("Aurora sky")
struct AuroraSkyTests {
    @Test("The sky moves only when the app is active, Low Power Mode is off and Reduce Motion is off")
    func pauseRules() {
        #expect(!SkyMotion.isPaused(scenePhase: .active, isLowPowerMode: false, reduceMotion: false))
        #expect(SkyMotion.isPaused(scenePhase: .background, isLowPowerMode: false, reduceMotion: false))
        #expect(SkyMotion.isPaused(scenePhase: .inactive, isLowPowerMode: false, reduceMotion: false))
        #expect(SkyMotion.isPaused(scenePhase: .active, isLowPowerMode: true, reduceMotion: false))
        #expect(SkyMotion.isPaused(scenePhase: .active, isLowPowerMode: false, reduceMotion: true))
        #expect(SkyMotion.isPaused(scenePhase: .background, isLowPowerMode: true, reduceMotion: true))
    }

    @Test("Sky levels use the Figma layer opacities")
    func levelOpacities() {
        #expect(SkyLevel.full.opacity == 1)
        #expect(SkyLevel.partlyCloudy.opacity == 0.6)
        #expect(SkyLevel.dim.opacity == 0.3)
        #expect(SkyLevel.off.opacity == 0)
    }

    @Test("Shader time stands still while paused and carries on without a jump")
    func clockHoldsWhilePaused() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var clock = SkyClock()
        #expect(clock.elapsed(at: start) == 0)

        clock.setRunning(true, at: start)
        #expect(clock.elapsed(at: start + 10) == 10)

        clock.setRunning(false, at: start + 10)
        #expect(!clock.isRunning)
        #expect(clock.elapsed(at: start + 600) == 10)

        clock.setRunning(true, at: start + 600)
        #expect(clock.elapsed(at: start + 605) == 15)
    }

    @Test("Repeated running or pausing changes nothing, and a clock never runs backwards")
    func clockIsIdempotent() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var clock = SkyClock()
        clock.setRunning(true, at: start)
        clock.setRunning(true, at: start + 5)
        #expect(clock.elapsed(at: start + 8) == 8)
        #expect(clock.elapsed(at: start - 3) == 0)

        clock.setRunning(false, at: start + 8)
        clock.setRunning(false, at: start + 20)
        #expect(clock.elapsed(at: start + 30) == 8)
    }

    @Test("Never started, a reduced-motion sky shows its first frame")
    func clockStillFrame() {
        let clock = SkyClock()
        #expect(clock.elapsed(at: .distantFuture) == 0)
    }

    @Test("The Low Power Mode monitor reads the state at start and after each change")
    @MainActor
    func lowPowerMonitor() async throws {
        let center = NotificationCenter()
        let state = Mutex(true)
        let monitor = LowPowerModeMonitor(center: center, read: { state.withLock { $0 } })
        #expect(monitor.isEnabled)

        state.withLock { $0 = false }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await waitUntil { !monitor.isEnabled }
        #expect(!monitor.isEnabled)

        state.withLock { $0 = true }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await waitUntil { monitor.isEnabled }
        #expect(monitor.isEnabled)
    }

    @Test("The two-pass sky draws the same image as the one-pass shader, for both looks, within rounding", arguments: [
        (SIMD2(402, 874), Float(3), Float(0)),
        (SIMD2(375, 667), Float(2), Float(37.5)),
        (SIMD2(131, 289), Float(3), Float(2000)),
    ])
    func twoPassMatchesReference(points: SIMD2<Int>, scale: Float, time: Float) throws {
        let renderer = try #require(AuroraSkyRenderer())
        let pixels = SIMD2<Int>(SIMD2<Float>(points) * scale)
        var classic = AuroraSkyParameters()
        classic.style = .classic
        var photo = AuroraSkyParameters()
        photo.style = .photo
        for parameters in [classic, photo, .figma] {
            try twoPassMatches(renderer, pixels: pixels, scale: scale, time: time, parameters: parameters)
        }
    }

    private func twoPassMatches(_ renderer: AuroraSkyRenderer, pixels: SIMD2<Int>, scale: Float, time: Float, parameters: AuroraSkyParameters) throws {
        let fast = try render(renderer, pixels: pixels, scale: scale, time: time, parameters: parameters, reference: false)
        let reference = try render(renderer, pixels: pixels, scale: scale, time: time, parameters: parameters, reference: true)
        #expect(fast.count == reference.count)
        let differences = zip(fast, reference).map { abs(Int($0) - Int($1)) }
        let largest = differences.max() ?? 0
        let mean = Double(differences.reduce(0, +)) / Double(differences.count)
        // Both paths run the same maths, but Metal's fast maths may round each a little
        // differently; measured at most 5 of 255 in a channel and about 0.03 on average.
        #expect(largest <= 8, "largest channel difference \(largest) of 255")
        #expect(mean < 0.1, "mean channel difference \(mean)")
        // Not a blank frame: the full sky has bright green curtains (BGRA, so index 1).
        let greens = stride(from: 1, to: fast.count, by: 4).map { fast[$0] }
        #expect((greens.max() ?? 0) > 120)
    }

    @Test("The curtains visibly move within a few seconds, far more than with Figma's still values")
    func motionIsVisible() throws {
        let renderer = try #require(AuroraSkyRenderer())
        let pixels = SIMD2(402, 874)
        func change(_ parameters: AuroraSkyParameters) throws -> Double {
            // Four real seconds apart, after the sky has run for a minute.
            let start = Float(60 * parameters.speed)
            let end = Float(64 * parameters.speed)
            let a = try render(renderer, pixels: pixels, scale: 1, time: start, parameters: parameters, reference: false)
            let b = try render(renderer, pixels: pixels, scale: 1, time: end, parameters: parameters, reference: false)
            // Green channel only (BGRA): the curtains, not the grain or stars.
            let greens = stride(from: 1, to: a.count, by: 4)
            let total = greens.reduce(0) { $0 + abs(Int(a[$1]) - Int(b[$1])) }
            return Double(total) / Double(greens.underestimatedCount)
        }
        let figma = try change(.figma)
        for style in AuroraSkyStyle.allCases {
            var parameters = AuroraSkyParameters()
            parameters.style = style
            let app = try change(parameters)
            // The ratio is about the classic look, Figma's own shader with the app's motion.
            if style == .classic { #expect(app > 3 * figma, "\(style) \(app), Figma \(figma)") }
            #expect(app > 2, "\(style): mean green change \(app) of 255 in 4 s")
        }
    }

    private func render(_ renderer: AuroraSkyRenderer, pixels: SIMD2<Int>, scale: Float, time: Float, parameters: AuroraSkyParameters = AuroraSkyParameters(), reference: Bool) throws -> [UInt8] {
        let device = renderer.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: AuroraSkyRenderer.pixelFormat, width: pixels.x, height: pixels.y, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytesPerRow = pixels.x * 4
        let readback = try #require(device.makeBuffer(length: bytesPerRow * pixels.y, options: .storageModeShared))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        let commandBuffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.encode(
            into: commandBuffer, pass: pass, pixelSize: pixels, pixelScale: scale, time: time,
            parameters: parameters, reference: reference)
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: pixels.x, height: pixels.y, depth: 1),
            to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * pixels.y)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        return Array(UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: UInt8.self), count: readback.length))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
