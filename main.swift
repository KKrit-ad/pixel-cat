// main.swift
// จุดเริ่มของแอป — โค้ดจริงอยู่ใน Sources/

import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let pet = PetController()
app.run()
