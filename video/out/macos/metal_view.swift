/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

import Cocoa

class MetalView: NSView {

    weak var common: Common! = nil

    override var wantsUpdateLayer: Bool { return true }

    init(common com: Common) {
        common = com
        super.init(frame: NSMakeRect(0, 0, 960, 480))
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layerContentsPlacement = .scaleProportionallyToFit
        //layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        //layer.framebufferOnly = false
        //layer.drawableSize = NSSize(width: 1024, height: 576)
        layer.pixelFormat = .rgba16Float
        if #available(macOS 10.13, *) {
            layer.displaySyncEnabled = true
        }

        return layer
    }
}