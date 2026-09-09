// PetController+Play
// ลูบหัว ลูกบอล และจิ้งจก — ของเล่นทั้งหมดที่ไม่เกี่ยวกับงาน
//
// แยกออกมาจาก PetController.swift เป็น extension ของคลาสเดิม

import Cocoa

extension PetController {

    // MARK: ลูบ

    func startPetting() {
        held = false
        petting = true
        napForced = false
        landAction = nil
        purrCount = 0
        setState("sit", duration: 9999)
        say("ครืดๆ", for: 2.2)
        CatVoice.shared.play(.purr, minGap: 1.0)
    }

    func petStroke() {
        guard petting, !reduceMotionEnabled else { return }
        let s = scale * 0.8
        hearts.append(HeartsView.Heart(x: CGFloat.random(in: 0...(spriteW - 7 * s)),
                                       y: 0, vy: CGFloat.random(in: 34...52),
                                       life: 1.3, s: s))
        purrCount += 1
        if purrCount % 3 == 0 {
            say(["ครืดๆ", "อีกๆ", "ตรงนั้นแหละ", "ครืดดด", "สบายจัง"].randomElement()!, for: 2.0)
            CatVoice.shared.play(.purr, minGap: 2.0)
        }
    }

    func stopPetting() {
        guard petting else { return }
        petting = false
        say(["อีกสิ", "หมดแล้วเหรอ", "เอาอีก"].randomElement()!, for: 1.7)
        CatVoice.shared.play(.mew, minGap: 3.0)
        setState("stretch", duration: 0.8) { [weak self] in self?.pickIdle() }
    }

    func stepHearts(_ dt: Double) {
        if hearts.isEmpty {
            if heartWindow.isVisible { heartWindow.orderOut(nil) }
            return
        }
        for i in hearts.indices {
            hearts[i].y += hearts[i].vy * CGFloat(dt)
            hearts[i].life -= CGFloat(dt)
        }
        hearts.removeAll { $0.life <= 0 }
        heartWindow.setContentSize(NSSize(width: spriteW, height: spriteW))
        heartWindow.setFrameOrigin(NSPoint(x: x.rounded(), y: (y + winH * 0.5).rounded()))
        if !heartWindow.isVisible { heartWindow.orderFront(nil); heartWindow.alphaValue = 1 }
        heartsView.hearts = hearts
        heartsView.needsDisplay = true
    }

    // MARK: ลูกบอล กับ จิ้งจก

    func propImage(_ name: String, _ i: Int) -> CGImage {
        let p = POSES[name]!
        return Sheet.shared.frames[p.start + ((i % p.count) + p.count) % p.count]
    }

    func setupProp(_ w: NSWindow, _ v: NSView) {
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = window.level
        w.collectionBehavior = window.collectionBehavior
        w.ignoresMouseEvents = true
        w.contentView = v
        w.alphaValue = 0
    }

    @objc func throwBall() {
        let side: CGFloat = Bool.random() ? 1 : -1
        bx = min(max(x + spriteW / 2 + side * spriteW * 2.2, plat.minX + 30), plat.maxX - 30)
        by = plat.y + 180
        bvx = (x + spriteW / 2 - bx) > 0 ? 60 : -60
        bvy = 0
        ballOn = true; ballLife = 80; ballHits = 0; ballRest = nil
        ballWindow.setContentSize(NSSize(width: spriteW, height: CGFloat(SPRITE_H) * scale))
        ballWindow.alphaValue = 1
        ballWindow.orderFront(nil)
        say(["ลูกบอล!", "อะไรน่ะ", "เอาละ"].randomElement()!, for: 1.4)
        if !airborne && !held && !petting {
            setState("tilt", duration: 0.9) { [weak self] in self?.pickIdle() }
        }
    }

    func despawnBall() {
        ballOn = false
        ballWindow.orderOut(nil)
    }

    func stepBall(_ dt: Double) {
        guard ballOn else { return }
        ballLife -= dt
        if ballLife <= 0 { despawnBall(); return }

        let prevY = by
        bvy -= 2000 * CGFloat(dt)
        bx += bvx * CGFloat(dt)
        by += bvy * CGFloat(dt)

        if bvy <= 0 {
            let hit = platforms.filter { bx >= $0.minX && bx <= $0.maxX && prevY >= $0.y - 3 && by <= $0.y }
                               .max(by: { $0.y < $1.y })
            if let p = hit {
                by = p.y
                bvy = -bvy * 0.50
                if abs(bvy) < 45 { bvy = 0 }
                bvx *= 0.86
                ballRest = p.y
            } else if let r = ballRest, by < r - 0.5, abs(bvy) < 80 {
                by = r; bvy = 0            // กันบอลไถลจมลงไปใต้พื้น
            }
        }
        if abs(bvy) < 1 { bvx *= CGFloat(pow(0.52, dt)) }        // แรงเสียดทานตอนกลิ้ง
        let f = currentScreen().frame
        if bx < f.minX + 10 { bx = f.minX + 10; bvx = abs(bvx) * 0.55 }
        if bx > f.maxX - 10 { bx = f.maxX - 10; bvx = -abs(bvx) * 0.55 }
        if by < f.minY - 300 { despawnBall(); return }

        ballSpin += Double(bvx) * dt * 0.09
        ballView.image = propImage("ball", Int(ballSpin.rounded()))
        ballView.needsDisplay = true
        ballWindow.setFrameOrigin(NSPoint(x: (bx - 16 * scale).rounded(), y: by.rounded()))
    }

    func spawnGecko() {
        let vf = currentScreen().visibleFrame        // จิ้งจกต้องโผล่บนจอเดียวกับแมว
        let here = platforms.filter { $0.y >= vf.minY - 2 && $0.y <= vf.maxY }
        var pool = here.filter { !$0.isFloor && $0.y > y + 40 }
        if pool.isEmpty { pool = here.filter { !$0.isFloor } }
        if pool.isEmpty { pool = here }               // ไม่มีขอบหน้าต่างเลย → ให้วิ่งบนพื้น
        guard let p = pool.randomElement(), p.maxX - p.minX > 140 else {
            geckoIn = Double.random(in: 25...45); return
        }
        geckoPlat = p
        gx = CGFloat.random(in: (p.minX + 40)...(p.maxX - 40))
        gy = p.y
        gdir = Bool.random() ? 1 : -1
        geckoOn = true; geckoLife = 26; geckoWait = 0.8; geckoFrame = 0
        geckoWindow.setContentSize(NSSize(width: spriteW, height: CGFloat(SPRITE_H) * scale))
        updateGeckoFrame()
        geckoWindow.alphaValue = 1
        geckoWindow.orderFront(nil)
        // ถ้าแมวกำลังอยู่เฉย ๆ ให้หันไปสนใจทันที ไม่ต้องรอรอบ idle ถัดไป
        guard !airborne, !held, !climbing else { return }
        if state == "sleep" {
            guard !napForced else { return }          // ถ้าสั่งให้นอนจากเมนู ก็ปล่อยให้นอน
            say(["เอ๊ะ อะไรน่ะ", "ตื่นแล้ว!", "ได้ยินเสียง"].randomElement()!, for: 1.7)
            setState("stretch", duration: 0.9) { [weak self] in self?.pickIdle() }
        } else if ["sit", "lick", "stretch"].contains(state) {
            pickIdle()
        }
    }

    func despawnGecko(escaped: Bool) {
        geckoOn = false
        geckoPlat = nil
        geckoWindow.orderOut(nil)
        geckoIn = Double.random(in: 45...110)
        if escaped { say(["หนีไปได้…", "แง หลุด", "ไว้เจอกันใหม่"].randomElement()!, for: 1.8) }
    }

    func dismissGeckoByClick() {
        guard geckoOn else { return }
        despawnGecko(escaped: false)
        guard focusPhase == .idle, !held, !airborne, !climbing, !chatBusy else { return }
        say(["แวบ! หายไปแล้ว", "จ๊ะเอ๋!", "พ่อจับได้ก่อนน้องอีก"].randomElement()!, for: 2.0)
        setState("tilt", duration: 0.7) { [weak self] in self?.pickIdle() }
    }

    func updateGeckoFrame() {
        let pose = POSES["gecko"]!
        let index = pose.start + (Int(geckoFrame * pose.fps) % pose.count)
        geckoView.image = Sheet.shared.frames[index]
        geckoView.pixelMask = Sheet.shared.masks[index]
        geckoView.needsDisplay = true
    }

    func stepGecko(_ dt: Double) {
        if !geckoOn {
            geckoIn -= dt
            if geckoIn <= 0 { spawnGecko() }
            return
        }
        geckoLife -= dt
        if geckoLife <= 0 { despawnGecko(escaped: false); return }
        guard let p = geckoPlat else { despawnGecko(escaped: false); return }

        geckoWait -= dt
        if geckoWait <= 0 {                                   // วิ่งเป็นช่วง ๆ แบบจิ้งจก
            gx += gdir * 150 * CGFloat(dt)
            if gx < p.minX + 20 { gdir = 1 }
            if gx > p.maxX - 20 { gdir = -1 }
            if Double.random(in: 0..<1) < dt * 1.6 { geckoWait = Double.random(in: 0.5...1.8) }
            geckoFrame += dt
        }
        // แมวเข้ามาใกล้ → เผ่น
        if !airborne, abs(gy - y) < 12, abs(gx - (x + spriteW / 2)) < 70 {
            despawnGecko(escaped: true)
            transitionState(to: "jump", duration: 0.4) { [weak self] in
                self?.transitionState(to: "sit", duration: 2)
            }
            return
        }
        updateGeckoFrame()
        geckoWindow.setFrameOrigin(NSPoint(x: (gx - 16 * scale).rounded(), y: gy.rounded()))
    }

    /// ไล่ลูกบอลถ้าอยู่แพลตฟอร์มเดียวกัน
    func maybeChaseBall() -> Bool {
        guard ballOn, !airborne, abs(by - plat.y) < 10,
              bx >= plat.minX, bx <= plat.maxX else { return false }
        hurry = true
        target = clampX(bx - spriteW / 2)
        setState("walk", duration: 99) { [weak self] in self?.swatBall() }
        return true
    }

    func swatBall() {
        hurry = false
        dir = bx > x + spriteW / 2 ? 1 : -1
        setState("crouch", duration: 0.45) { [weak self] in
            guard let self else { return }
            self.bvx = self.dir * CGFloat.random(in: 280...560)
            self.bvy = CGFloat.random(in: 190...330)
            self.ballHits += 1
            self.say(["ตึ่ง!", "ตะปบ!", "ไปเลย!", "อีกที"].randomElement()!, for: 1.3)
            self.setState("jump", duration: 0.35) { [weak self] in
                guard let self else { return }
                if self.ballHits >= 7 { self.despawnBall(); self.say("เบื่อแล้ว", for: 1.5) }
                self.pickIdle()
            }
        }
    }

    func maybeChaseGecko() -> Bool {
        guard geckoOn, let gp = geckoPlat, !airborne else { return false }
        if abs(gp.y - plat.y) < 6 {
            hurry = true
            target = clampX(gx - spriteW / 2)
            setState("walk", duration: 99)
            if Double.random(in: 0..<1) < 0.5 { say(["จิ้งจก!", "เจอแล้ว!"].randomElement()!, for: 1.5) }
            return true
        }
        return maybeClimb()
    }

    func maybeDescend() -> Bool {
        guard !plat.isFloor, !airborne else { return false }
        let cx = x + spriteW / 2
        let below = platforms.filter { $0.y < plat.y - 20 }
        guard !below.isEmpty else { return false }

        // ต้องเล็งให้พ้นขอบ ไม่งั้นตอนตกลงมาจะไปเกาะแพลตฟอร์มเดิมซ้ำ
        let goLeft = (cx - plat.minX) < (plat.maxX - cx)
        let landX = goLeft ? plat.minX - spriteW * 1.3 : plat.maxX + spriteW * 0.3
        let landCx = landX + spriteW / 2
        guard below.contains(where: { landCx >= $0.minX && landCx <= $0.maxX }) else { return false }

        dir = goLeft ? -1 : 1
        target = goLeft ? plat.minX : plat.maxX - spriteW      // เดินไปที่ขอบก่อน
        autoDescending = true
        setState("walk", duration: 99) { [weak self] in
            guard let self else { return }
            guard self.effectiveMotionLevel != .calm else {
                self.autoDescending = false
                self.target = nil
                self.setState("sit", duration: 3.0)
                return
            }
            self.say(["ลงละ", "โดดดด", "หื่ม", "สูงจัง"].randomElement()!, for: 1.3)
            self.setState("crouch", duration: 0.4) { [weak self] in
                guard let self else { return }
                self.leap(toX: landX, up: 55)
                self.landAction = { [weak self] in
                    guard let self else { return }
                    self.autoDescending = false
                    self.setState("stretch", duration: 0.8) { self.pickIdle() }
                }
            }
        }
        return true
    }

    /// ไต่ขึ้นข้างหน้าต่าง — ใช้เมื่อขอบบนสูงเกินกระโดดถึง
    func maybeScaleWall() -> Bool {
        guard !airborne, !climbing else { return false }
        var best: (p: Platform, left: Bool, standX: CGFloat)?
        for p in platforms where !p.isFloor && p.y > y + 70 && p.bottom <= y + 70 {
            for left in [true, false] {
                let sx = left ? p.minX - spriteW * 0.62 : p.maxX - spriteW * 0.38
                guard sx >= plat.minX, sx <= plat.maxX - spriteW else { continue }
                if best == nil || abs(sx - x) < abs(best!.standX - x) {
                    best = (p, left, sx)
                }
            }
        }
        guard let pick = best, abs(pick.standX - x) < 1000 else { return false }

        hurry = true
        target = pick.standX
        setState("walk", duration: 99) { [weak self] in
            guard let self else { return }
            self.hurry = false
            self.dir = pick.left ? 1 : -1            // หันหน้าเข้าหาผนัง
            self.x = pick.standX
            self.climbGoal = pick.p
            self.climbSideLeft = pick.left
            self.climbing = true
            self.say(self.geckoOn ? ["จิ้งจก! รอก่อน", "ไต่ขึ้นไปละ"].randomElement()!
                                  : ["ปีนขึ้นไปหน่อย", "ขึ้นไปดูข้างบน", "เกาะได้"].randomElement()!, for: 1.8)
            self.setState("climb", duration: 999)
        }
        return true
    }

    /// ปีนขึ้นขอบหน้าต่าง — ถ้ามีจิ้งจกอยู่ข้างบนจะเล็งไปที่จิ้งจก
    func maybeClimb() -> Bool {
        guard !airborne, !follow, platforms.count > 1 else { return false }
        let cx = x + spriteW / 2
        var candidates = platforms.filter {
            $0.y > y + 34 && $0.y < y + 250 && $0.maxX - $0.minX > spriteW * 2.2
        }
        if geckoOn, let gp = geckoPlat, gp.y > y + 20 { candidates = [gp] }
        guard let p = candidates.min(by: {
            abs(max($0.minX, min(cx, $0.maxX)) - cx) < abs(max($1.minX, min(cx, $1.maxX)) - cx)
        }) else { return maybeScaleWall() }

        let aimX = geckoOn && geckoPlat.map({ abs($0.y - p.y) < 2 }) == true ? gx : cx
        let landX = min(max(aimX, p.minX + spriteW), p.maxX - spriteW) - spriteW / 2
        guard abs(landX - x) < 460 else { return maybeScaleWall() }

        dir = landX > x ? 1 : -1
        say(geckoOn ? ["จิ้งจก!", "เจอแล้ว!", "อย่าหนีนะ"].randomElement()!
                    : ["มีอะไรอยู่ข้างบน", "ปีนหน่อย", "ขึ้นไปนั่งดีกว่า"].randomElement()!, for: 1.6)
        setState("crouch", duration: 0.8) { [weak self] in
            guard let self else { return }
            self.leap(toX: landX, up: (p.y - self.y) + 70)
            self.landAction = { [weak self] in
                guard let self else { return }
                if self.geckoOn, let gp = self.geckoPlat, abs(gp.y - self.plat.y) < 6 {
                    self.target = self.clampX(self.gx - self.spriteW / 2)
                    self.setState("walk", duration: 99)
                } else {
                    self.transitionState(to: "sit", duration: Double.random(in: 2...5))
                }
            }
        }
        return true
    }
}
