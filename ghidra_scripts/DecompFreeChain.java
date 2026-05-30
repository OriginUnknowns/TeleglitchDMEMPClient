import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompFreeChain extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f = getFunctionContaining(toAddr(a));
        if (f == null) f = getFunctionAt(toAddr(a));
        if (f == null) { w.println("\n[no fn containing 0x" + Long.toHexString(a) + "]"); return; }
        w.println("\n========== " + tag + " (ret addr 0x" + Long.toHexString(a) + ") -> " + f.getName()
            + " @ 0x" + Long.toHexString(f.getEntryPoint().getOffset()) + " ==========");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null)
            w.println(res.getDecompiledFunction().getC());
        else w.println("[decomp failed]");
    }
    @Override public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_freechain.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // Ghidra addr = 0x400000 + RVA (RVAs from the crash stack)
        d(0x401e5bL, "free-wrapper");
        d(0x401bceL, "caller-of-free");
        d(0x4085bfL, "destructor?");
        d(0x407846L, "frame");
        d(0x40dcd9L, "frame");
        d(0x419173L, "frame");
        d(0x47c3eaL, "frame");
        d(0x47c93dL, "frame");
        d(0x4c0526L, "frame");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_freechain.txt");
    }
}
