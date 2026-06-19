import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.Symbol;
import java.io.FileWriter;
import java.io.PrintWriter;

// Resolve a handful of mystery DAT/PTR globals used in the bullet ctor
// arg-prep code (laser uses [0x573e00]/[0x573e04] as fake "constants",
// cannon also references some). Print as float, int, and symbol name so
// we can tell what they actually represent.
public class DumpDats extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_dats.txt"));
        long[] addrs = {
            0x00573e00L, 0x00573e04L,           // TLaser ctor sites
            0x00558a40L,                          // TLaser ctor internal const (PTR_00558a40)
            0x00558f30L,                          // TCannon ctor internal const
            0x00558f00L,                          // TBullet ctor internal const (DAT_00558f00)
            0x00558e18L,                          // CreateBullet binding speed divisor
            0x00558d58L,                          // TLaser sub-object init arg
            0x00558ea0L,                          // TLaser sub-object init arg
            0x00558b04L,                          // vt[22] threshold check
            0x00558bb0L,                          // vt[22] FUN_004c38f0 arg
            0x00559044L,                          // vt[22] beam extension scale
        };
        Memory mem = currentProgram.getMemory();
        for (long a : addrs) {
            Address addr = toAddr(a);
            int v = 0;
            try { v = mem.getInt(addr); } catch (Exception e) {
                w.println(String.format("0x%08x  <unreadable>", a));
                continue;
            }
            float fv = Float.intBitsToFloat(v);
            Symbol s = getSymbolAt(addr);
            String name = s != null ? s.getName() : "<no-symbol>";
            // If it looks like a pointer, dereference one level and show too.
            String derefStr = "";
            if ((v & 0xFFFFFFFFL) >= 0x400000L && (v & 0xFFFFFFFFL) <= 0x600000L) {
                try {
                    int d = mem.getInt(toAddr(v & 0xFFFFFFFFL));
                    derefStr = String.format("  → 0x%08x (float %f)", d, Float.intBitsToFloat(d));
                } catch (Exception e) { derefStr = "  → <unreadable>"; }
            }
            w.println(String.format("0x%08x  int=0x%08x  float=%f  sym=%s%s",
                a, v & 0xFFFFFFFFL, fv, name, derefStr));
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_dats.txt");
    }
}
