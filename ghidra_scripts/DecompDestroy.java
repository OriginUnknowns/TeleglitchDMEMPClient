import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompDestroy extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_destroy.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        long[] addrs = {
            0x0040e750L,   // FUN_0040e750 — self-destroy called from vt[22]
            0x0040e770L,   // FUN_0040e770 — early-bail check at start of vt[22]
            0x004b3770L,   // vt[9] register — what does FUN_004b3a90's last call do?
        };
        String[] names = { "FUN_0040e750 (destroy)", "FUN_0040e770 (bail-check)", "vt[9] register" };
        for (int i = 0; i < addrs.length; i++) {
            Address addr = toAddr(addrs[i]);
            Function f = getFunctionAt(addr);
            if (f == null) f = createFunction(addr, names[i]);
            w.println("\n=== " + names[i] + " @ 0x" + Long.toHexString(addrs[i]) + " ===");
            DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
            if (dr != null && dr.getDecompiledFunction() != null) {
                w.println(dr.getDecompiledFunction().getC());
            }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_destroy.txt");
    }
}
