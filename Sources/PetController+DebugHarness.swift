// PetController+DebugHarness
// ทางเข้าเดียวของโหมดจำลองที่สั่งด้วย env var
//
// เดิมทั้งหมดนี้เขียนคาไว้กลาง init() ที่ยาว 2,221 บรรทัด ตอนนี้ init เหลือ
// การตั้งค่าจริงอย่างเดียว แล้วเรียกที่นี่ทีเดียว ตัวจำลองแยกไปตามหมวด

import Cocoa

extension PetController {

    /// รันโหมดจำลองตาม env var ถ้าถูกสั่งมา — เรียงตามลำดับเดิมใน init
    /// - Returns: true = โหมดจำลองยึดการทำงานไปแล้ว init ไม่ต้องเดินนาฬิกาต่อ
    func runDebugHarness() -> Bool {
        if runDebugWorkHarness() { return true }
        if runDebugMotionHarness() { return true }
        if runDebugSnapshotHarness() { return true }
        return false
    }
}
