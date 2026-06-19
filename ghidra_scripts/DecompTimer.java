import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompTimer extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_timer.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        long[] addrs = {
            0x004b00b0L,   // read timer (vt[22] gate)
            0x0040e7c0L,   // init timer (called with 30)
            0x004c38f0L,   // render-beam call inside vt[22]
        };
        String[] names = { "FUN_004b00b0 (timer read)",
                           "FUN_0040e7c0 (timer init)",
                           "FUN_004c38f0 (render beam)" };
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
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_timer.txt");
    }
}
