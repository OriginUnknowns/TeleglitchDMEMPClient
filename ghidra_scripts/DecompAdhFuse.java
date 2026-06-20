import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

/** Find what gates the AGL fuse — vt[23] calls FUN_00498f50 first; vt[11]
 *  movement handler may toggle the gate flag. Looking for the "is stuck"
 *  / "impacted" predicate so the receiver can defer its fuse the same way. */
public class DecompAdhFuse extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_adh_fuse.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        long[] addrs = {
            0x00498f50L,  // gate called at start of vt[23]
            0x004afc10L,  // FUN_004afc10 used in vt[11] (random bit check?)
            0x0040e750L,  // mark-dead pattern (also TLaser uses it)
            0x00415ee0L,  // FUN_00415ee0 used in vt[22] — "bulletshit" sound gate
        };
        String[] names = { "fuse_gate_498f50", "rand_check_afc10",
                           "mark_dead_40e750", "is_alive_415ee0" };
        for (int i = 0; i < addrs.length; i++) {
            w.println("\n=== " + names[i] + " @ 0x" + Long.toHexString(addrs[i]) + " ===");
            Function f = getFunctionAt(toAddr(addrs[i]));
            if (f == null) {
                try { f = createFunction(toAddr(addrs[i]), names[i]); }
                catch (Exception e) { w.println("  err: " + e.getMessage()); continue; }
            }
            if (f == null) continue;
            try {
                DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
                if (dr != null && dr.getDecompiledFunction() != null) {
                    w.println(dr.getDecompiledFunction().getC());
                }
            } catch (Exception e) { w.println("  err: " + e.getMessage()); }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_adh_fuse.txt");
    }
}
