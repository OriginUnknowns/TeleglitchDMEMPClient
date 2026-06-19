import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompRaycast extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_laser_dmg.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        long[] addrs = {
            0x0044db40L,   // raycast helper inside vt[22]
            0x004c3bb0L,   // setup on +0xCC sub-object (visual)
        };
        String[] names = { "FUN_0044db40 (raycast)", "FUN_004c3bb0 (visual setup)" };
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
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_laser_dmg.txt");
    }
}
