import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;

public class FindAllPurecall extends GhidraScript {
    @Override
    public void run() throws Exception {
        long PURECALL = 0x0050d0eeL;
        long[] vtables = { 0x00556594L, 0x00556b14L, 0x00556d6cL, 0x005566e4L,
                           0x005583ecL, 0x00558454L, 0x0055831cL, 0x00558384L };
        String[] names = { "TActor", "TPlayer", "TNewLiving", "TEnemy",
                           "TBullet", "TCannonBullet", "TNail", "TExplodingBullet" };
        // Scan first 64 slots (256 bytes) of each vtable for purecall.
        for (int i = 0; i < vtables.length; i++) {
            println("=== " + names[i] + " @ 0x" + Long.toHexString(vtables[i]) + " ===");
            for (int slot = 0; slot < 64; slot++) {
                Address a = toAddr(vtables[i] + slot * 4);
                try {
                    long v = getInt(a) & 0xFFFFFFFFL;
                    if (v == PURECALL) {
                        println(String.format("  slot[%d] +0x%02x = PURECALL", slot, slot * 4));
                    }
                } catch (Exception e) { break; }
            }
        }
        // Also: the new stack return 0x007b27d8 — what function?
        Address a = toAddr(0x007b27d8L);
        var f = getFunctionContaining(a);
        if (f != null) {
            println("\nNew stack ret 0x007b27d8 -> " + f.getName() + " @ " + f.getEntryPoint() +
                    " (offset +0x" + Long.toHexString(a.subtract(f.getEntryPoint())) + ")");
        } else {
            println("\nNew stack ret 0x007b27d8 -> no function");
        }
    }
}
