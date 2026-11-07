#!/usr/bin/env swift
//
// Generates the Mac App Store screenshot: the current macOS wallpaper with a
// CrabAlert notification on top, rendered at 2880×1800 (16:10, accepted by App Store Connect).
//
// Usage:
//   swift scripts/app-store-screenshot.swift [--wallpaper <image or .mov>] [--output <png>]
//
// Without --wallpaper it uses the dynamic "macOS" wallpaper (light, landscape) that macOS
// downloads to ~/Library/Application Support/com.apple.wallpaper/aerials. If it's missing,
// pick that wallpaper once in System Settings → Wallpaper so it gets downloaded, or pass
// any image/video with --wallpaper. The wallpaper is read from your Mac and never committed.
//

import AppKit
import AVFoundation
import CoreImage
import SwiftUI

// MARK: - Configuration

let canvasPoints = CGSize(width: 1440, height: 900)   // rendered @2x → 2880×1800
let renderScale: CGFloat = 2
let cardScale: CGFloat = 1.6                            // notification size relative to real life

let notification = (
    title: "Confirm your e-mail",
    subtitle: "From: no-reply@yellowred.blue",
    body: "To continue signing in to your account, please click this link. If you did not attempt to sign in you can ignore this e-mail."
)

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconURL = repoRoot.appending(path: "CrabAlert/CrabAlert/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
let aerialsURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/com.apple.wallpaper/aerials")

// MARK: - Arguments

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}

let outputURL = URL(fileURLWithPath: argument("--output") ?? repoRoot.appending(path: "screenshots/app-store-2880x1800.png").path)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - Wallpaper

/// Finds the downloaded light, landscape variant of the dynamic "macOS" wallpaper.
func defaultWallpaperVideo() async -> URL? {
    struct Manifest: Decodable {
        struct Asset: Decodable {
            let id: String
            let localizedNameKey: String?
            let accessibilityLabel: String?
            let preferredOrder: Int?
        }
        let assets: [Asset]
    }

    guard let data = try? Data(contentsOf: aerialsURL.appending(path: "manifest/entries.json")),
          let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }

    let candidates = manifest.assets
        .filter { $0.localizedNameKey == "DYNAMIC_LIGHT_KEY" && $0.accessibilityLabel == "macOS" }
        .sorted { ($0.preferredOrder ?? .max) < ($1.preferredOrder ?? .max) }
        .map { aerialsURL.appending(path: "videos/\($0.id).mov") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

    for url in candidates {
        if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), size.width > size.height {
            return url
        }
    }
    return nil
}

func loadWallpaper(from url: URL) async throws -> CGImage {
    if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: .zero).image
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("couldn't read image at \(url.path)")
    }
    return image
}

/// Scales to fill the canvas and crops the center, so every layer shares exact pixel geometry.
func aspectFill(_ image: CGImage, to size: CGSize) -> CGImage {
    let width = Int(size.width), height = Int(size.height)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
    let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2,
                                   width: drawSize.width, height: drawSize.height))
    return context.makeImage()!
}

func blurred(_ image: CGImage, radius: Double) -> CGImage {
    let input = CIImage(cgImage: image)
    let output = input.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: input.extent)
    return CIContext().createCGImage(output, from: input.extent)!
}

// MARK: - Notification

struct NotificationCard: View {
    let icon: NSImage
    var isMask = false

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(notification.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("now")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(notification.subtitle)
                    .font(.system(size: 13, weight: .medium))
                Text(notification.body)
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 360, alignment: .leading)
        .background {
            if isMask {
                shape.fill(.black)
            } else {
                shape
                    .fill(.white.opacity(0.5))
                    .overlay(shape.strokeBorder(.white.opacity(0.7), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            }
        }
    }
}

struct Screenshot: View {
    let wallpaper: CGImage
    let blurredWallpaper: CGImage
    let icon: NSImage

    var body: some View {
        ZStack {
            fullBleed(wallpaper)

            // Frosted glass: the blurred wallpaper, cut to the notification's shape.
            fullBleed(blurredWallpaper)
                .mask { NotificationCard(icon: icon, isMask: true).scaleEffect(cardScale) }

            NotificationCard(icon: icon).scaleEffect(cardScale)
        }
        .frame(width: canvasPoints.width, height: canvasPoints.height)
        .environment(\.colorScheme, .light)
    }

    private func fullBleed(_ image: CGImage) -> some View {
        Image(decorative: image, scale: renderScale)
            .frame(width: canvasPoints.width, height: canvasPoints.height)
    }
}

// MARK: - Render

@MainActor
func render(wallpaper: CGImage, icon: NSImage) -> CGImage {
    let pixelSize = CGSize(width: canvasPoints.width * renderScale, height: canvasPoints.height * renderScale)
    let background = aspectFill(wallpaper, to: pixelSize)
    let view = Screenshot(wallpaper: background,
                          blurredWallpaper: blurred(background, radius: 60),
                          icon: icon)

    let renderer = ImageRenderer(content: view)
    renderer.scale = renderScale
    guard let rendered = renderer.cgImage else { fail("rendering failed") }

    // Flatten onto an opaque sRGB canvas; App Store Connect rejects screenshots with alpha.
    return aspectFill(rendered, to: pixelSize)
}

let wallpaperURL: URL
if let path = argument("--wallpaper") {
    wallpaperURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
} else if let url = await defaultWallpaperVideo() {
    wallpaperURL = url
} else {
    fail("""
    couldn't find the dynamic "macOS" wallpaper. Select it once in System Settings → Wallpaper \
    so macOS downloads it, or pass --wallpaper <image or video>.
    """)
}

guard let icon = NSImage(contentsOf: iconURL) else { fail("missing app icon at \(iconURL.path)") }

let wallpaper = try await loadWallpaper(from: wallpaperURL)
let image = await render(wallpaper: wallpaper, icon: icon)

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fail("couldn't encode PNG")
}
try png.write(to: outputURL)
print("Wallpaper: \(wallpaperURL.path)")
print("Wrote \(image.width)×\(image.height) screenshot to \(outputURL.path)")
