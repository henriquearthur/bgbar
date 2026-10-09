import SwiftUI
import XCTest
@testable import BGBar

/// A linha não pode exigir mais largura do que a lista oferece: uma linha larga demais
/// alarga a lista inteira e o popover corta o conteúdo dos dois lados.
@MainActor
final class RowLayoutTests: XCTestCase {
    /// Largura útil de uma linha: popover menos o padding da lista e do cartão.
    static let rowWidth = UI.width - 2 * UI.pad - 6

    private func crowded() -> Item {
        var i = Item(id: "docker:gateway", key: "docker:gateway", kind: .docker,
                     name: "stack-gateway-with-a-rather-long-name-1", detail: "registry.example.com/team/gateway:v3.41.3",
                     status: .running)
        i.statusNote = "Up 24 hours (healthy)"
        i.startedAt = Date().addingTimeInterval(-88_000)
        i.cpu = 65.5
        i.memBytes = 1_083 * 1_048_576
        i.ports = [5055, 6767, 7878, 8989, 9696, 18080, 32400]
        i.pid = 3_292_306
        i.containerID = "abc"
        i.host = "devbox"
        return i
    }

    func testCrowdedRowFitsListWidth() throws {
        var plain = crowded()
        plain.ports = [3000]
        plain.statusNote = nil
        let rows = VStack(spacing: 0) {
            ItemRow(item: crowded()) {}
            ItemRow(item: plain) {}
        }
        let host = NSHostingController(rootView: rows)
        let size = host.sizeThatFits(in: CGSize(width: Self.rowWidth, height: 2000))
        XCTAssertLessThanOrEqual(size.width, Self.rowWidth + 0.5)

        // BGBAR_RENDER=<arquivo.png> grava a renderização para inspeção visual.
        if let path = ProcessInfo.processInfo.environment["BGBAR_RENDER"] {
            let renderer = ImageRenderer(content: rows.frame(width: Self.rowWidth).background(Color.black).environment(\.colorScheme, .dark))
            renderer.scale = 2
            let tiff = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
