import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;
import java.util.LinkedList;
import java.util.Queue;

public class DecompAddr extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;
    Set<Long> seen = new HashSet<>();

    void dumpFn(long fa, int depth, int maxDepth) throws Exception {
        if (seen.contains(fa)) { w.println("[already dumped 0x" + Long.toHexString(fa) + "]"); return; }
        seen.add(fa);
        Function f = getFunctionAt(toAddr(fa));
        if (f == null) { w.println("[no fn at 0x" + Long.toHexString(fa) + "]"); return; }
        w.println("\n========== FN " + f.getName() + " @ 0x" + Long.toHexString(fa) + " (depth " + depth + ") ==========");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        String body = "";
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            body = res.getDecompiledFunction().getC();
            w.println(body);
        } else {
            w.println("[decomp failed: " + res.getErrorMessage() + "]");
            return;
        }
        if (depth >= maxDepth) return;
        // Find called FUN_xxx and recurse into them (limit recursion)
        // Use call references from this function
        for (Reference r : currentProgram.getReferenceManager().getReferencesFrom(f.getEntryPoint())) {}
        // Simpler: walk instructions in function body for CALL targets
        for (Address a : f.getBody().getAddresses(true)) {
            ghidra.program.model.listing.Instruction inst = getInstructionAt(a);
            if (inst == null) continue;
            if (!inst.getMnemonicString().toLowerCase().startsWith("call")) continue;
            for (Address tgt : inst.getFlows()) {
                Function tf = getFunctionAt(tgt);
                if (tf == null) continue;
                String name = tf.getName();
                if (name.startsWith("FUN_") && !seen.contains(tgt.getOffset())) {
                    dumpFn(tgt.getOffset(), depth + 1, maxDepth);
                }
            }
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_createbullet.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // CreateBullet Lua binding
        dumpFn(0x00425ca0L, 0, 2);
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_createbullet.txt");
    }
}
