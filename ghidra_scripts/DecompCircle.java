import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class DecompCircle extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;
    Set<Long> seen = new HashSet<>();

    void dumpFn(long fa, int depth, int maxDepth) throws Exception {
        if (seen.contains(fa)) { w.println("[already dumped 0x" + Long.toHexString(fa) + "]"); return; }
        seen.add(fa);
        Function f = getFunctionAt(toAddr(fa));
        if (f == null) {
            // try to create one
            f = createFunction(toAddr(fa), null);
        }
        if (f == null) { w.println("[no fn at 0x" + Long.toHexString(fa) + "]"); return; }
        w.println("\n========== FN " + f.getName() + " @ 0x" + Long.toHexString(fa) + " (depth " + depth + ") ==========");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed: " + res.getErrorMessage() + "]");
            return;
        }
        if (depth >= maxDepth) return;
        for (Address a : f.getBody().getAddresses(true)) {
            ghidra.program.model.listing.Instruction inst = getInstructionAt(a);
            if (inst == null) continue;
            if (!inst.getMnemonicString().toLowerCase().startsWith("call")) continue;
            for (Address tgt : inst.getFlows()) {
                Function tf = getFunctionAt(tgt);
                if (tf == null) tf = createFunction(tgt, null);
                if (tf == null) continue;
                if (!seen.contains(tgt.getOffset())) {
                    dumpFn(tgt.getOffset(), depth + 1, maxDepth);
                }
            }
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_circle.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // GetObjectsInCircle ACTUAL C closure @ 0x42a9c0, recurse 3 deep into the query impl
        dumpFn(0x0042a9c0L, 0, 3);
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_circle.txt");
    }
}
