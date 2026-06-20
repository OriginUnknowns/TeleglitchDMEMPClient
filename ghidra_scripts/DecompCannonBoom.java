import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

/** Decompile the cannon explosion routine (called from vt[22] on impact)
 *  to find what's AVing on the firer. */
public class DecompCannonBoom extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_cannon_boom.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        long[] addrs = {
            0x00497770L,   // cannon impact handler called from vt[22]
            0x004ae2f0L,   // common AoE-scan helpers we may need to gate
            0x004afc10L,   // (rand check used in vt[11])
        };
        String[] names = { "cannon_boom_497770", "AoE_helper_4ae2f0", "rand_4afc10" };
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
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_cannon_boom.txt");
    }
}
