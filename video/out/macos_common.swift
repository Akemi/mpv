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

protocol Common: class {
    var window: MetalWindow? { get }
    var view: MetalEvents? { get }
    var video: MetalView? { get }
    var titleBar: TitleBar2? { get }
    //var view: EventsView?
    var mpv: MPVHelper2 { get }

    var cursorHidden: Bool { get }
    var cursorVisibilityWanted: Bool { get }

    var title: String { get }

    func getTargetScreen(forFullscreen fs: Bool) -> NSScreen?
    func flagEvents(_ ev: Int)
    func updateCusorVisibility()
    func setCursorVisiblility(_ visible: Bool)
    func updateDisplaylink()
}

class MacosCommon: NSObject, Common {

    @objc var video: MetalView?
    var view: MetalEvents?
    var window: MetalWindow?
    var titleBar: TitleBar2?
    var mpv: MPVHelper2
    var link: CVDisplayLink?

    var cursorHidden: Bool = false
    var cursorVisibilityWanted: Bool = true

    let eventsLock = NSLock()
    var events: Int = 0

    var lightSensor: io_connect_t = 0
    var lastLmu: UInt64 = 0
    var lightSensorIOPort: IONotificationPortRef?
    var displaySleepAssertion: IOPMAssertionID = IOPMAssertionID(0)

    let queue: DispatchQueue = DispatchQueue(label: "io.mpv.queue")

    var title: String = "mpv" {
        didSet { if let window = window { window.title = title } }
    }


    // functions called by context
    @objc init(_ vo: UnsafeMutablePointer<vo>) {
        mpv = MPVHelper2(vo, "mac")
        super.init()

        DispatchQueue.main.sync {
            video = MetalView(common: self)
            startDisplayLink(vo)
            initLightSensor()
            addDisplayReconfigureObserver()
        }
    }

    @objc func config(_ vo: UnsafeMutablePointer<vo>) -> Bool {
        mpv.vo = vo

        DispatchQueue.main.sync {
            NSApp.setActivationPolicy(.regular)
            setAppIcon()

            guard let video = self.video else {
                mpv.sendError("Something went wrong, no Video was initialized")
                exit(1)
            }
            guard let targetScreen = getScreenBy(id: Int(mpv.opts.screen_id)) ?? NSScreen.main else {
                mpv.sendError("Something went wrong, no Screen was found")
                exit(1)
            }

            print(mpv.vout.dwidth)
            print(mpv.vout.dheight)

            let wr = getWindowGeometry(forScreen: targetScreen, videoOut: vo)
            if window == nil {
                view = MetalEvents(frame: wr, common: self)
                guard let view = self.view else {
                    mpv.sendError("Something went wrong, no View was initialized")
                    exit(1)
                }

                window = MetalWindow(contentRect: wr, screen: targetScreen, view: view, common: self)
                guard let window = self.window else {
                    mpv.sendError("Something went wrong, no Window was initialized")
                    exit(1)
                }

                view.addSubview(video)
                video.frame = view.frame

                window.keepAspect = Bool(mpv.opts.keepaspect_window)
                window.border = Bool(mpv.opts.border)

                titleBar = TitleBar2(frame: wr, window: window, common: self)

                window.isRestorable = false
                window.makeMain()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            print(mpv.vout.dwidth)
            print(mpv.vout.dheight)
            print(wr)

            if !NSEqualSizes(
                window?.unfsContentFramePixel.size ?? NSZeroSize,
                NSSize(width: Int(mpv.vout.dwidth), height: Int(mpv.vout.dheight))
            ) {
                print("----update window size")
                window?.updateSize(wr.size)
            }


            window?.setOnTop(Bool(mpv.opts.ontop), Int(mpv.opts.ontop_level))
            window?.title = title


            //todo remove
            flagEvents(VO_EVENT_ICC_PROFILE_CHANGED)

            if Bool(mpv.opts.fullscreen) {
                DispatchQueue.main.async { [weak self] in
                    self?.window?.toggleFullScreen(nil)
                }
            } else {
                window?.isMovableByWindowBackground = true
            }
        }


        return true
    }

    @objc func control(_ vo: UnsafeMutablePointer<vo>,
                         events: UnsafeMutablePointer<Int32>,
                         request: UInt32,
                         arg: UnsafeMutableRawPointer) -> Int32 {
        switch mp_voctrl(request) {
        case VOCTRL_CHECK_EVENTS:
            events.pointee = Int32(checkEvents())
            return VO_TRUE
        case VOCTRL_FULLSCREEN:
            DispatchQueue.main.async { [weak self] in
                self?.window?.toggleFullScreen(nil)
            }
            return VO_TRUE
        case VOCTRL_GET_FULLSCREEN:
            let fsData = arg.assumingMemoryBound(to: Int32.self)
            fsData.pointee = (window?.isInFullscreen ?? false) ? 1 : 0
            return VO_TRUE
        case VOCTRL_ONTOP:
            DispatchQueue.main.async { [weak self] in
                self?.window?.setOnTop(Bool(self?.mpv.opts.ontop ?? 0), self?.mpv.opts.ontop_level ?? 0)
            }
            return VO_TRUE
        case VOCTRL_BORDER:
            DispatchQueue.main.async { [weak self] in
                self?.window?.border = Bool(self?.mpv.opts.border ?? 1)
            }
            return VO_TRUE
        case VOCTRL_GET_DISPLAY_FPS:
            let fps = arg.assumingMemoryBound(to: CDouble.self)
            fps.pointee = currentFps()
            return VO_TRUE

        case VOCTRL_GET_ICC_PROFILE:
            guard var iccData = window?.screen?.colorSpace?.iccProfileData else { return VO_TRUE }

            let icc = arg.assumingMemoryBound(to: bstr.self)
            iccData.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                guard let baseAddress = ptr.baseAddress, ptr.count > 0 else { return }
                let u8Ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

                //let ptrCopy = ta_xmemdup(nil, baseAddress, ptr.count)
                //let u8Ptr = ptrCopy!.assumingMemoryBound(to: UInt8.self)
                //icc.pointee.start = iccBstr.start
                //icc.pointee.len = iccBstr.len

                icc.pointee = bstrdup(nil, bstr(start: u8Ptr, len: ptr.count))
            }

            //TODO set colorspace on layer
            //layer?.colorspace = colorSpace.cgColorSpace
            return VO_TRUE
        case VOCTRL_GET_AMBIENT_LUX:
            if lightSensor != 0 {
                let lux = arg.assumingMemoryBound(to: Int32.self)
                lux.pointee = Int32(lmuToLux(lastLmu))
                return VO_TRUE;
            }
            return VO_NOTIMPL
        case VOCTRL_RESTORE_SCREENSAVER:
            enableDisplaySleep()
            return VO_TRUE
        case VOCTRL_KILL_SCREENSAVER:
            disableDisplaySleep()
            return VO_TRUE
        case VOCTRL_SET_CURSOR_VISIBILITY:
            let cursorVisibility = arg.assumingMemoryBound(to: CBool.self)
            cursorVisibilityWanted = cursorVisibility.pointee
            DispatchQueue.main.async { [weak self] in
                self?.setCursorVisiblility(self?.cursorVisibilityWanted ?? true)
            }
            return VO_TRUE
        case VOCTRL_GET_UNFS_WINDOW_SIZE:
            let sizeData = arg.assumingMemoryBound(to: Int32.self)
            let size = UnsafeMutableBufferPointer(start: sizeData, count: 2)
            var rect = window?.unfsContentFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
            if let screen = window?.currentScreen, !Bool(mpv.opts.hidpi_window_scale) {
                rect = screen.convertRectFromBacking(rect)
            }

            size[0] = Int32(rect.size.width)
            size[1] = Int32(rect.size.height)
            return VO_TRUE
        case VOCTRL_SET_UNFS_WINDOW_SIZE:
            let sizeData = arg.assumingMemoryBound(to: Int32.self)
            let size = UnsafeBufferPointer(start: sizeData, count: 2)
            var rect = NSRect(x: 0, y: 0, width: CGFloat(size[0]), height: CGFloat(size[1]))
            DispatchQueue.main.async { [weak self] in
                if let screen = self?.window?.currentScreen, !Bool(self?.mpv.opts.hidpi_window_scale ?? 0) {
                    rect = screen.convertRectFromBacking(rect)
                }
                self?.window?.updateSize(rect.size)
            }
            return VO_TRUE
        case VOCTRL_GET_WIN_STATE:
            let minimized = arg.assumingMemoryBound(to: Int32.self)
            minimized.pointee = window?.isMiniaturized ?? false ?
                VO_WIN_STATE_MINIMIZED : Int32(0)
            return VO_TRUE
        case VOCTRL_GET_DISPLAY_NAMES:
            let dnames = arg.assumingMemoryBound(to: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?.self)
            var array: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>? = nil
            var count: Int32 = 0
            let screen = window != nil ? window?.screen :
                                             getScreenBy(id: Int(mpv.opts.screen_id)) ??
                                             NSScreen.main
            let displayName = screen?.displayName ?? "Unknown"

            SWIFT_TARRAY_STRING_APPEND(nil, &array, &count, ta_xstrdup(nil, displayName))
            SWIFT_TARRAY_STRING_APPEND(nil, &array, &count, nil)
            dnames.pointee = array
            return VO_TRUE
        case VOCTRL_UPDATE_WINDOW_TITLE:
            let titleData = arg.assumingMemoryBound(to: Int8.self)
            DispatchQueue.main.async { [weak self] in
                self?.title = String(cString: titleData)
            }
            return VO_TRUE
        default:
            return VO_NOTIMPL
        }
    }

    @objc func wakeup(_ vo: UnsafeMutablePointer<vo>) {


    }

    @objc func waitEvents(_ vo: UnsafeMutablePointer<vo>) {


    }

    @objc func uninit(_ vo: UnsafeMutablePointer<vo>) {
        DispatchQueue.main.sync {

            /*isShuttingDown = window?.isAnimating ?? false ||
                             window?.isInFullscreen ?? false && mpv.getBoolProperty("native-fs")*/
            //if window?.isInFullscreen ?? false && !(window?.isAnimating ?? false) {
                window?.delegate = nil
                window?.close()
            //}
            //if isShuttingDown { return }

            //TODO animation lock?

            setCursorVisiblility(true)
            stopDisplaylink()
            uninitLightSensor()
            removeDisplayReconfigureObserver()
            enableDisplaySleep()
            window?.orderOut(nil)

            video?.removeFromSuperview()
            titleBar?.removeFromSuperview()
            view?.removeFromSuperview()

            video = nil
            view = nil
            titleBar = nil
            //window = nil
            link = nil
            cursorHidden = false
            cursorVisibilityWanted = true
            events = 0
            displaySleepAssertion = IOPMAssertionID(0)
            lightSensor = 0
            lastLmu = 0
            lightSensorIOPort = nil

            //mpv.deinitRender()
            //mpv.deinitMPV(destroy)
        }
    }



    // helper functions
    func getScreenBy(id screenID: Int) -> NSScreen? {
        if screenID >= NSScreen.screens.count {
            mpv.sendInfo("Screen ID \(screenID) does not exist, falling back to current device")
            return nil
        } else if screenID < 0 {
            return nil
        }
        return NSScreen.screens[screenID]
    }

    func getWindowGeometry(forScreen targetScreen: NSScreen,
                           videoOut vo: UnsafeMutablePointer<vo>) -> NSRect {
        let r = targetScreen.convertRectToBacking(targetScreen.frame)
        var screenRC: mp_rect = mp_rect(x0: Int32(0),
                                        y0: Int32(0),
                                        x1: Int32(r.size.width),
                                        y1: Int32(r.size.height))

        var geo: vo_win_geometry = vo_win_geometry()
        vo_calc_window_geometry2(vo, &screenRC, Double(targetScreen.backingScaleFactor), &geo)
        vo_apply_window_geometry(vo, &geo)

        // flip y coordinates
        geo.win.y1 = Int32(r.size.height) - geo.win.y1
        geo.win.y0 = Int32(r.size.height) - geo.win.y0

        let wr = NSMakeRect(CGFloat(geo.win.x0), CGFloat(geo.win.y1),
                            CGFloat(geo.win.x1 - geo.win.x0),
                            CGFloat(geo.win.y0 - geo.win.y1))
        return targetScreen.convertRectFromBacking(wr)
    }

    func setAppIcon() {
        if let app = NSApp as? Application {
            NSApp.applicationIconImage = app.getMPVIcon()
        }
    }

    let linkCallback: CVDisplayLinkOutputCallback = {
                    (displayLink: CVDisplayLink,
                           inNow: UnsafePointer<CVTimeStamp>,
                    inOutputTime: UnsafePointer<CVTimeStamp>,
                         flagsIn: CVOptionFlags,
                        flagsOut: UnsafeMutablePointer<CVOptionFlags>,
              displayLinkContext: UnsafeMutableRawPointer?) -> CVReturn in
        let com = unsafeBitCast(displayLinkContext, to: MacosCommon.self)
        //com.mpv.reportRenderFlip()
        return kCVReturnSuccess
    }

    func startDisplayLink(_ vo: UnsafeMutablePointer<vo>) {
        CVDisplayLinkCreateWithActiveCGDisplays(&link)

        guard let screen = getScreenBy(id: Int(mpv.opts.screen_id)) ?? NSScreen.main,
              let link = self.link else
        {
            mpv.sendWarning("Couldn't start DisplayLink, no Screen or DisplayLink available")
            return
        }

        CVDisplayLinkSetCurrentCGDisplay(link, screen.displayID)
        if #available(macOS 10.12, *) {
            CVDisplayLinkSetOutputHandler(link) { [weak self] link, now, out, inFlags, outFlags -> CVReturn in
                //self?.mpv.reportRenderFlip()
                return kCVReturnSuccess
            }
        } else {
            CVDisplayLinkSetOutputCallback(link, linkCallback, MPVHelper2.bridge(obj: self))
        }
        CVDisplayLinkStart(link)
    }

    func stopDisplaylink() {
        if let link = self.link, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
    }

    func currentFps() -> Double {
        if let link = self.link {
            var actualFps = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
            let nominalData = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)

            if (nominalData.flags & Int32(CVTimeFlags.isIndefinite.rawValue)) < 1 {
                let nominalFps = Double(nominalData.timeScale) / Double(nominalData.timeValue)

                if actualFps > 0 {
                    actualFps = 1/actualFps
                }

                if fabs(actualFps - nominalFps) > 0.1 {
                    mpv.sendVerbose("Falling back to nominal display refresh rate: \(nominalFps)")
                    return nominalFps
                } else {
                    return actualFps
                }
            }
        } else {
            mpv.sendWarning("No DisplayLink available")
        }

        mpv.sendWarning("Falling back to standard display refresh rate: 60Hz")
        return 60.0
    }

    func enableDisplaySleep() {
        IOPMAssertionRelease(displaySleepAssertion)
        displaySleepAssertion = IOPMAssertionID(0)
    }

    func disableDisplaySleep() {
        if displaySleepAssertion != IOPMAssertionID(0) { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "io.mpv.video_playing_back" as CFString,
            &displaySleepAssertion)
    }

    func lmuToLux(_ v: UInt64) -> Int {
        // the polinomial approximation for apple lmu value -> lux was empirically
        // derived by firefox developers (Apple provides no documentation).
        // https://bugzilla.mozilla.org/show_bug.cgi?id=793728
        let power_c4: Double = 1 / pow(10, 27)
        let power_c3: Double = 1 / pow(10, 19)
        let power_c2: Double = 1 / pow(10, 12)
        let power_c1: Double = 1 / pow(10, 5)

        let lum = Double(v)
        let term4: Double = -3.0 * power_c4 * pow(lum, 4.0)
        let term3: Double = 2.6 * power_c3 * pow(lum, 3.0)
        let term2: Double = -3.4 * power_c2 * pow(lum, 2.0)
        let term1: Double = 3.9 * power_c1 * lum

        let lux = Int(ceil(term4 + term3 + term2 + term1 - 0.19))
        return lux > 0 ? lux : 0
    }

    var lightSensorCallback: IOServiceInterestCallback = { (ctx, service, messageType, messageArgument) -> Void in
        let com = unsafeBitCast(ctx, to: MacosCommon.self)

        var outputs: UInt32 = 2
        var values: [UInt64] = [0, 0]

        var kr = IOConnectCallMethod(com.lightSensor, 0, nil, 0, nil, 0, &values, &outputs, nil, nil)
        if kr == KERN_SUCCESS {
            var mean = (values[0] + values[1]) / 2
            if com.lastLmu != mean {
                com.lastLmu = mean
                com.flagEvents(VO_EVENT_AMBIENT_LIGHTING_CHANGED)
            }
        }
    }

    func initLightSensor() {
        let srv = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleLMUController"))
        if srv == IO_OBJECT_NULL {
            mpv.sendVerbose("Can't find an ambient light sensor")
            return
        }

        lightSensorIOPort = IONotificationPortCreate(kIOMasterPortDefault)
        IONotificationPortSetDispatchQueue(lightSensorIOPort, queue)
        var n = io_object_t()
        IOServiceAddInterestNotification(lightSensorIOPort, srv, kIOGeneralInterest, lightSensorCallback, MPVHelper2.bridge(obj: self), &n)
        let kr = IOServiceOpen(srv, mach_task_self_, 0, &lightSensor)
        IOObjectRelease(srv)

        if kr != KERN_SUCCESS {
            mpv.sendVerbose("Can't start ambient light sensor connection")
            return
        }
        lightSensorCallback(MPVHelper2.bridge(obj: self), 0, 0, nil)
    }

    func uninitLightSensor() {
        if lightSensorIOPort != nil {
            IONotificationPortDestroy(lightSensorIOPort)
            IOObjectRelease(lightSensor)
        }
    }

    var reconfigureCallback: CGDisplayReconfigurationCallBack = { (display, flags, userInfo) in
        if flags.contains(.setModeFlag) {
            let com = unsafeBitCast(userInfo, to: MacosCommon.self)
            let displayID = com.window?.screen?.displayID ?? display

            if displayID == display {
                com.mpv.sendVerbose("Detected display mode change, updating screen refresh rate");
                com.flagEvents(VO_EVENT_WIN_STATE)
            }
        }
    }

    func addDisplayReconfigureObserver() {
        CGDisplayRegisterReconfigurationCallback(reconfigureCallback, MPVHelper2.bridge(obj: self))
    }

    func removeDisplayReconfigureObserver() {
        CGDisplayRemoveReconfigurationCallback(reconfigureCallback, MPVHelper2.bridge(obj: self))
    }

    func checkEvents() -> Int {
        eventsLock.lock()
        let ev = events
        events = 0
        eventsLock.unlock()
        return ev
    }


    // protocol functions
    func getTargetScreen(forFullscreen fs: Bool) -> NSScreen? {
        let screenID = Int(fs ? mpv.opts.fsscreen_id : mpv.opts.screen_id)

        return getScreenBy(id: screenID)
    }

    func flagEvents(_ ev: Int) {
        eventsLock.lock()
        events |= ev
        eventsLock.unlock()
        vo_wakeup(mpv.vo)
    }

    func updateDisplaylink() {
        guard let screen = window?.screen, let link = self.link else {
            mpv.sendWarning("Couldn't update DisplayLink, no Screen or DisplayLink available")
            return
        }

        CVDisplayLinkSetCurrentCGDisplay(link, screen.displayID)
        queue.asyncAfter(deadline: DispatchTime.now() + 0.1) { [weak self] in
            self?.flagEvents(VO_EVENT_WIN_STATE)
        }
    }

    func setCursorVisiblility(_ visible: Bool) {
        let visibility = visible ? true : !(view?.canHideCursor() ?? false)
        if visibility && cursorHidden {
            NSCursor.unhide()
            cursorHidden = false;
        } else if !visibility && !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    func updateCusorVisibility() {
        setCursorVisiblility(cursorVisibilityWanted)
    }


/*

var mpv: MPVHelper
    @objc var isShuttingDown: Bool = false



    enum State {
        case uninitialized
        case needsInit
        case initialized
    }
    var backendState: State = .uninitialized


    func preinit(_ vo: UnsafeMutablePointer<vo>) {
        if backendState == .uninitialized {
            backendState = .needsInit

            view = EventsView(cocoaCB: self)
            view?.layer = layer
            view?.wantsLayer = true
            view?.layerContentsPlacement = .scaleProportionallyToFit
            startDisplayLink(vo)
            initLightSensor()
            addDisplayReconfigureObserver()
        }
    }

    func reconfig(_ vo: UnsafeMutablePointer<vo>) {
        mpv.vo = vo
        if backendState == .needsInit {
            DispatchQueue.main.sync { self.initBackend(vo) }
        } else {
            DispatchQueue.main.async {
                self.updateWindowSize(vo)
                self.layer?.update()
            }
        }
    }

    func updateWindowSize(_ vo: UnsafeMutablePointer<vo>) {
        let opts: mp_vo_opts = vo.pointee.opts.pointee
        guard let targetScreen = getScreenBy(id: Int(opts.screen_id)) ?? NSScreen.main else {
            mpv.sendWarning("Couldn't update Window size, no Screen available")
            return
        }

        let wr = getWindowGeometry(forScreen: targetScreen, videoOut: vo)
        if !(window?.isVisible ?? false) {
            window?.makeKeyAndOrderFront(nil)
        }
        layer?.atomicDrawingStart()
        window?.updateSize(wr.size)
    }

    func updateICCProfile() {
        guard let colorSpace = window?.screen?.colorSpace else {
            mpv.sendWarning("Couldn't update ICC Profile, no color space available")
            return
        }

        mpv.setRenderICCProfile(colorSpace)
        if #available(macOS 10.11, *) {
            layer?.colorspace = colorSpace.cgColorSpace
        }
    }


    func checkShutdown() {
        if isShuttingDown {
            shutdown(true)
        }
    }

    @objc func processEvent(_ event: UnsafePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_SHUTDOWN:
            shutdown()
        case MPV_EVENT_PROPERTY_CHANGE:
            if backendState == .initialized {
                handlePropertyChange(event)
            }
        default:
            break
        }
    }

    func handlePropertyChange(_ event: UnsafePointer<mpv_event>) {
        let pData = OpaquePointer(event.pointee.data)
        guard let property = UnsafePointer<mpv_event_property>(pData)?.pointee else {
            return
        }

        switch String(cString: property.name) {
        case "keepaspect-window":
            if let data = MPVHelper.mpvFlagToBool(property.data) {
                window?.keepAspect = data
            }
        case "macos-title-bar-appearance":
            if let data = MPVHelper.mpvStringArrayToString(property.data) {
                titleBar?.set(appearance: data)
            }
        case "macos-title-bar-material":
            if let data = MPVHelper.mpvStringArrayToString(property.data) {
                titleBar?.set(material: data)
            }
        case "macos-title-bar-color":
            if let data = MPVHelper.mpvStringArrayToString(property.data) {
                titleBar?.set(color: data)
            }
        default:
            break
        }
    }
*/



}