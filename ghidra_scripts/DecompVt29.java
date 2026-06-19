import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompVt29 extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_vt29.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        Memory mem = currentProgram.getMemory();
        long[] vts = { 0x00556b14L, 0x00556594L };  // TPlayer, TActor
        String[] names = { "TPlayer", "TActor" };
        int slot = 29;  // +0x74 — case 0x100 (laser) dispatch
        for (int i = 0; i < vts.length; i++) {
            long addr = mem.getInt(toAddr(vts[i] + slot * 4)) & 0xFFFFFFFFL;
            w.println("\n=== " + names[i] + "::vt[" + slot + "] @ 0x" + Long.toHexString(addr) + " ===");
            Function f = getFunctionAt(toAddr(addr));
            if (f == null) {
                try { f = createFunction(toAddr(addr), names[i] + "_vt" + slot); }
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
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_vt29.txt");
    }
}
