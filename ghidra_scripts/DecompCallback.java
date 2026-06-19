import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompCallback extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_callback.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        Memory mem = currentProgram.getMemory();

        // 1) FUN_004c4760 — creates the +0xCC sub-object in TLaser ctor
        // 2) Dump the TRayCastBulletCallback vtable (0x5587f4) — slots
        //    relevant for damage:
        //    - vtable[0] is usually scalar deleting dtor
        //    - Box2D's RayCastCallback has `ReportFixture` at a known slot
        // 3) Dump first 8 vtable slots
        long[] callees = { 0x004c4760L };
        String[] cnames = { "FUN_004c4760 (sub-object ctor)" };
        for (int i = 0; i < callees.length; i++) {
            Address addr = toAddr(callees[i]);
            Function f = getFunctionAt(addr);
            if (f == null) f = createFunction(addr, cnames[i]);
            w.println("\n=== " + cnames[i] + " @ 0x" + Long.toHexString(callees[i]) + " ===");
            DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
            if (dr != null && dr.getDecompiledFunction() != null) {
                w.println(dr.getDecompiledFunction().getC());
            }
        }

        w.println("\n=== TRayCastBulletCallback::vftable @ 0x5587f4 — first 8 slots ===");
        for (int i = 0; i < 8; i++) {
            long off = 0x005587f4L + i * 4;
            long fa = mem.getInt(toAddr(off)) & 0xFFFFFFFFL;
            Function f = getFunctionAt(toAddr(fa));
            String fname = (f != null) ? f.getName() : "<no-fn>";
            w.println(String.format("  [%d] 0x%08x  %s", i, fa, fname));
            if (f == null) {
                try { f = createFunction(toAddr(fa), "RayCastVt" + i); }
                catch (Exception e) { w.println("    (could not create function: " + e.getMessage() + ")"); continue; }
            }
            if (f == null) { w.println("    (createFunction returned null)"); continue; }
            try {
                DecompileResults dr = decomp.decompileFunction(f, 30, monitor);
                if (dr != null && dr.getDecompiledFunction() != null) {
                    w.println(dr.getDecompiledFunction().getC());
                }
            } catch (Exception e) {
                w.println("    (decomp error: " + e.getMessage() + ")");
            }
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_callback.txt");
    }
}
