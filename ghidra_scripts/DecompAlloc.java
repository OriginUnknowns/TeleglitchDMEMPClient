import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class DecompAlloc extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;
    Set<Long> seen = new HashSet<>();

    void dumpFn(long fa, int depth, int maxDepth) throws Exception {
        if (seen.contains(fa)) { w.println("[already dumped 0x" + Long.toHexString(fa) + "]"); return; }
        seen.add(fa);
        Function f = getFunctionContaining(toAddr(fa));
        if (f == null) f = getFunctionAt(toAddr(fa));
        if (f == null) { w.println("[no fn at 0x" + Long.toHexString(fa) + "]"); return; }
        long entry = f.getEntryPoint().getOffset();
        w.println("\n========== FN " + f.getName() + " @ 0x" + Long.toHexString(entry) + " (depth " + depth + ") ==========");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed: " + res.getErrorMessage() + "]");
            return;
        }
        if (depth >= maxDepth) return;
        for (Address a : f.getBody().getAddresses(true)) {
            Instruction inst = getInstructionAt(a);
            if (inst == null) continue;
            String m = inst.getMnemonicString().toLowerCase();
            if (!m.startsWith("call") && !m.startsWith("jmp")) continue;
            for (Address tgt : inst.getFlows()) {
                Function tf = getFunctionContaining(tgt);
                if (tf == null) continue;
                long toff = tf.getEntryPoint().getOffset();
                if (!seen.contains(toff)) {
                    dumpFn(toff, depth + 1, maxDepth);
                }
            }
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_alloc.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        w.println("##### operator_new 0x50d144 #####");
        dumpFn(0x0050d144L, 0, 2);
        w.println("\n\n##### operator_delete 0x50d0f4 #####");
        dumpFn(0x0050d0f4L, 0, 2);
        w.println("\n\n##### malloc 0x50d4ae #####");
        dumpFn(0x0050d4aeL, 0, 2);
        w.println("\n\n##### free 0x50d4a8 #####");
        dumpFn(0x0050d4a8L, 0, 2);
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_alloc.txt");
    }
}
