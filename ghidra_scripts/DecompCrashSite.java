import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompCrashSite extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_crash_site.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // Crash site EIP + nearby callers from receiver-side AV.
        long[] addrs = {
            0x004CCD5CL,   // EIP (faulting insn)
            0x004B2E60L,   // EBP chain [0]
            0x00419134L,   // [1]
            0x0047C3EAL,   // [2]
            0x004C0526L,   // [4]
            0x004B3770L,   // TBullet vt[9] (register-with-world) — for context
        };
        for (long a : addrs) {
            Address addr = toAddr(a);
            Function f = getFunctionContaining(addr);
            if (f == null) {
                w.println("\n=== 0x" + Long.toHexString(a) + " — no containing function ===");
                continue;
            }
            w.println("\n=== 0x" + Long.toHexString(a) + " in " + f.getName() +
                      "@0x" + Long.toHexString(f.getEntryPoint().getOffset()) + " ===");
            DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
            if (dr != null && dr.getDecompiledFunction() != null) {
                w.println(dr.getDecompiledFunction().getC());
            }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_crash_site.txt");
    }
}
