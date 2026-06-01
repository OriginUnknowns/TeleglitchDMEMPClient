import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;

public class CheckTPlayerExt extends GhidraScript {
    @Override
    public void run() throws Exception {
        long PURECALL = 0x0050d0eeL;
        long base = 0x00556b14L;  // TPlayer vftable
        println("=== TPlayer vftable @ 0x556b14, scanning slots 60..200 for purecall ===");
        for (int slot = 60; slot < 200; slot++) {
            Address a = toAddr(base + slot * 4);
            try {
                long v = getInt(a) & 0xFFFFFFFFL;
                if (v == PURECALL) {
                    println(String.format("  slot[%3d] +0x%03x = PURECALL", slot, slot * 4));
                }
            } catch (Exception e) { println("end at slot " + slot); break; }
        }
        // Also: where does the 0x007b27d8 ret address point? Find nearest function above it.
        Address rip = toAddr(0x007b27d8L);
        // Walk backward to find a function start
        for (int delta = 0; delta < 0x2000; delta += 1) {
            Address probe = rip.subtract(delta);
            var f = getFunctionAt(probe);
            if (f != null) {
                println("\n0x007b27d8 is inside " + f.getName() + " @ " + probe + " (offset +0x" + Long.toHexString(delta) + ")");
                break;
            }
        }
        // Sweep .text for any function whose body contains an `mov eax, [ecx+0x94]; call eax`
        // or similar that calls vt[+0x94] on `this`.
        println("\n--- All purecall references (vtables across image) ---");
        long start = currentProgram.getMinAddress().getOffset();
        long end = Math.min(start + 0x800000, currentProgram.getMaxAddress().getOffset());
        int count = 0;
        for (long a = start; a + 4 < end; a += 4) {
            try {
                long v = getInt(toAddr(a)) & 0xFFFFFFFFL;
                if (v == PURECALL) {
                    if (++count <= 50) println(String.format("  at 0x%08x", a));
                }
            } catch (Exception e) {}
        }
        println("total: " + count + " purecall pointers in image");
    }
}
