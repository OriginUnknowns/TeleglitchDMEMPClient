// Find the TBullet vtable: TypeDescriptor is at 0x005738a8.
// In MSVC RTTI: COL points to TD at offset 0xC. Vftable is referenced near COL.
// Walk references TO the TypeDescriptor → that's the COL.
// Then find references TO the COL → that's the vftable's -4 slot.
// Print the vftable contents (vtable funcs) and decompile each.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.mem.Memory;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class FindVtable extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    int readPtr(long a) throws Exception {
        return currentProgram.getMemory().getInt(toAddr(a));
    }

    Set<Long> dumped = new HashSet<>();
    void dumpFn(long fa, String tag) throws Exception {
        if (dumped.contains(fa)) return;
        dumped.add(fa);
        Function f = getFunctionAt(toAddr(fa));
        if (f == null) {
            // try create
            f = createFunction(toAddr(fa), null);
        }
        if (f == null) { w.println("[" + tag + " no fn at 0x" + Long.toHexString(fa) + "]"); return; }
        w.println("\n--- " + tag + " " + f.getName() + " @ 0x" + Long.toHexString(fa) + " ---");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed]");
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_vtable.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        long td = 0x005738a8L;
        w.println("TBullet TypeDescriptor at 0x" + Long.toHexString(td));

        // Refs to TD → that's the COL field at +0xC
        Set<Long> cols = new HashSet<>();
        for (Reference r : currentProgram.getReferenceManager().getReferencesTo(toAddr(td))) {
            long from = r.getFromAddress().getOffset();
            // COL has TD pointer at offset 0xC, so this ref's from-address minus 0xC = COL base
            cols.add(from - 0xC);
        }
        w.println("Possible COLs: " + cols.size());

        for (long col : cols) {
            w.println("\n=== COL @ 0x" + Long.toHexString(col) + " ===");
            // refs TO the COL → that's the vftable[-1] slot.
            for (Reference r : currentProgram.getReferenceManager().getReferencesTo(toAddr(col))) {
                long fromAddr = r.getFromAddress().getOffset();
                long vftableBase = fromAddr + 4;
                w.println("Vftable starts at 0x" + Long.toHexString(vftableBase));
                // Read vtable slots (up to 32). Stop when slot is not in code segment.
                for (int i = 0; i < 64; i++) {
                    long slotAddr = vftableBase + i * 4;
                    long fnAddr;
                    try {
                        fnAddr = readPtr(slotAddr) & 0xFFFFFFFFL;
                    } catch (Exception e) { break; }
                    if (fnAddr < 0x400000 || fnAddr > 0x600000) break;
                    Function f = getFunctionAt(toAddr(fnAddr));
                    String fname = (f != null) ? f.getName() : "<no-fn>";
                    w.println(String.format("  [%2d] 0x%08x %s", i, fnAddr, fname));
                }
            }
        }

        // Also: refs to the TBullet ctor address 0x497040 (other callers besides Lua CreateBullet)
        w.println("\n=== Callers of TBullet ctor (0x497040) ===");
        for (Reference r : currentProgram.getReferenceManager().getReferencesTo(toAddr(0x497040L))) {
            Address from = r.getFromAddress();
            Function f = getFunctionContaining(from);
            w.println(String.format("  from 0x%08x in %s", from.getOffset(),
                f != null ? f.getName() : "<no fn>"));
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_vtable.txt");
    }
}
