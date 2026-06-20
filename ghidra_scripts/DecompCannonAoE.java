import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompCannonAoE extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_cannon_aoe.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        long[] addrs = {
            0x0048e9b0L,   // AoE entity / explosion damage ctor (operator_new(0x7c) target)
            0x004c5100L,   // helper called after FUN_0040e750 in boom (screen shake?)
            0x004c49b0L    // companion called with x/y
        };
        String[] names = { "AoE_48e9b0", "FX_4c5100", "FX_4c49b0" };
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
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_cannon_aoe.txt");
    }
}
