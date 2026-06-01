import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DisasmAlloc extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    void disasm(long start, int count, String tag) throws Exception {
        w.println("\n========== DISASM " + tag + " @ 0x" + Long.toHexString(start) + " ==========");
        Address a = toAddr(start);
        for (int i = 0; i < count; i++) {
            Instruction inst = getInstructionAt(a);
            if (inst == null) { w.println("  0x" + Long.toHexString(a.getOffset()) + "  [no instruction]"); break; }
            StringBuilder refs = new StringBuilder();
            for (Address tgt : inst.getFlows()) {
                Function tf = getFunctionContaining(tgt);
                refs.append("  -> 0x").append(Long.toHexString(tgt.getOffset()));
                if (tf != null) refs.append(" (").append(tf.getName()).append(")");
            }
            // also data refs (for jmp dword ptr [IAT])
            for (ghidra.program.model.symbol.Reference r : inst.getReferencesFrom()) {
                if (r.getReferenceType().isData() || r.getReferenceType().isIndirect()) {
                    refs.append("  [ref ").append(r.getReferenceType()).append(" -> 0x")
                        .append(Long.toHexString(r.getToAddress().getOffset()));
                    ghidra.program.model.symbol.Symbol s = getSymbolAt(r.getToAddress());
                    if (s != null) refs.append(" ").append(s.getName());
                    refs.append("]");
                }
            }
            w.println("  0x" + Long.toHexString(a.getOffset()) + "  " + inst.toString() + refs);
            a = inst.getNext() == null ? a.add(inst.getLength()) : inst.getNext().getAddress();
        }
    }

    void decompFn(long fa, String tag) throws Exception {
        Function f = getFunctionContaining(toAddr(fa));
        if (f == null) f = getFunctionAt(toAddr(fa));
        if (f == null) { w.println("\n[no fn at 0x" + Long.toHexString(fa) + " for " + tag + "]"); return; }
        w.println("\n========== DECOMP " + tag + " -> " + f.getName() + " @ 0x"
            + Long.toHexString(f.getEntryPoint().getOffset()) + " ==========");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null)
            w.println(res.getDecompiledFunction().getC());
        else w.println("[decomp failed]");
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_alloc2.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        // Raw disasm of the thunks to find their real jump targets
        disasm(0x0050d144L, 3, "operator_new thunk");
        disasm(0x0050d0f4L, 3, "operator_delete thunk");
        disasm(0x0050d4aeL, 6, "malloc thunk/body");
        disasm(0x0050d4a8L, 6, "free thunk/body");
        // The internal heap routine cluster lives around here in MSVC CRT.
        // Decompile what's at the well-known _heap_alloc/_nh_malloc range if present.
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_alloc2.txt");
    }
}
