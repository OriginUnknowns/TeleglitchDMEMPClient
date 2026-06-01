import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.mem.Memory;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class ResearchAI3 extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;
    Set<Long> dumped = new HashSet<>();

    void d(long a, String tag) throws Exception {
        if (dumped.contains(a)) { w.println("(already dumped: " + tag + " @ 0x" + Long.toHexString(a) + ")"); return; }
        dumped.add(a);
        Function f = getFunctionAt(toAddr(a));
        if (f == null) f = createFunction(toAddr(a), null);
        if (f == null) { w.println("[no fn at 0x" + Long.toHexString(a) + "]"); return; }
        w.println("\n========== " + tag + " " + f.getName() + " @ 0x" + Long.toHexString(a) + " ==========");
        DecompileResults res = decomp.decompileFunction(f, 120, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed]");
        }
        w.flush();
    }

    void dumpVtable(long base, int slots, String tag) throws Exception {
        w.println("\n=== " + tag + " vftable @ 0x" + Long.toHexString(base) + " (" + slots + " slots) ===");
        for (int i = 0; i < slots; i++) {
            long slot = base + i * 4;
            long fa;
            try { fa = currentProgram.getMemory().getInt(toAddr(slot)) & 0xFFFFFFFFL; }
            catch (Exception e) { break; }
            if (fa < 0x400000 || fa > 0x600000) break;
            Function f = getFunctionAt(toAddr(fa));
            if (f == null) f = createFunction(toAddr(fa), null);
            String fname = (f != null) ? f.getName() : "<no-fn>";
            w.println(String.format("  [%2d] (+0x%02x) 0x%08x %s", i, i*4, fa, fname));
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_ai_research3.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // 1. aibasic ctor at FUN_00461820 — vtable is set here.
        d(0x00461820L, "aibasic::ctor (allocates 0x40 bytes, sets vftable)");

        // 2. FUN_00463660 - attacktype (TNewLiving spawn branch)
        d(0x00463660L, "attacktype config branch");
        // 3. FUN_00463960 - sibling of df0 (called from ctor)
        d(0x00463960L, "TNewLiving ctor sub (called alongside aitype dispatch)");
        d(0x00463c80L, "TNewLiving ctor sub");

        // 4. find TNewLiving vftable - search symbol table
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        long tnewlivingVT = 0, tenemyVT = 0;
        while (it.hasNext()) {
            Symbol s = it.next();
            String pname = s.getParentNamespace() != null ? s.getParentNamespace().getName() : "";
            if (s.getName().equals("vftable")) {
                if (pname.equals("TNewLiving")) tnewlivingVT = s.getAddress().getOffset();
                else if (pname.equals("TEnemy")) tenemyVT = s.getAddress().getOffset();
            }
        }
        w.println("TNewLiving::vftable @ 0x" + Long.toHexString(tnewlivingVT));
        w.println("TEnemy::vftable @ 0x" + Long.toHexString(tenemyVT));

        if (tnewlivingVT > 0) dumpVtable(tnewlivingVT, 40, "TNewLiving");
        if (tenemyVT > 0) dumpVtable(tenemyVT, 40, "TEnemy");

        // 5. find xrefs to the aibasic vtable that gets set in FUN_00461820 — actually let's find xrefs from FUN_00461820 to identify vtable used.
        // Read FUN_00461820's first few bytes to find the mov [ecx], <vftable_addr> pattern
        // Simpler: just look at FUN_00461820 decomp above and follow up programmatically by scanning its disasm
        Address fa = toAddr(0x00461820L);
        Function f = currentProgram.getFunctionManager().getFunctionAt(fa);
        if (f != null) {
            InstructionIterator iit = currentProgram.getListing().getInstructions(f.getBody(), true);
            int cnt = 0;
            while (iit.hasNext() && cnt < 60) {
                Instruction ins = iit.next();
                String s = ins.toString();
                if (s.contains("MOV") && (s.contains("0x55") || s.contains("0x40"))) {
                    w.println("  ctor insn: " + ins.getAddressString(false,true) + "  " + s);
                }
                cnt++;
            }
        }

        // 6. Find TNewLiving think — likely a vtable slot pointing into FUN_004[56]xxxx range, that reads
        // *(this+0x6c) (AI module ptr) and calls its think slot.
        // Also: search for "alertradius" string xref at 0x4670a3 (in FUN_00467060) — that fn is the alert-radius config
        // but the actual READER of (this+0x20) — i.e. aibasic vtable[?] = think — should be nearby.
        // List functions that reference 0x4670a3-adjacent (the aibasic class likely lives at 0x467000-0x468000)
        // Decompile FUN_00467290 (which reads DAT_005747a4 per earlier list) — likely aibasic::think
        d(0x00467290L, "aibasic? reads DAT_005747a4 + near alertradius config");
        d(0x00466060L, "Reads DAT_005747a4");

        // 7. The other DAT_005747a4 readers near the AI range — sample to spot per-frame patterns
        d(0x00464fe0L, "Reads DAT_005747a4");
        d(0x00466ea0L, "near 467060");  // gamble
        // Actually try a range — the AI module's per-frame think
        // FUN_00467060 reads alertradius (load), so the *reader* of (this+0x20) is the think; find it via xref
        // Print xrefs to FUN_00467060 — its caller is likely the aibasic ctor init / a vtable slot dispatcher
        w.println("\n### Xrefs TO FUN_00467060 (alertradius config) ###");
        ReferenceIterator rit = currentProgram.getReferenceManager().getReferencesTo(toAddr(0x00467060L));
        while (rit.hasNext()) {
            Reference r = rit.next();
            Function ff = currentProgram.getFunctionManager().getFunctionContaining(r.getFromAddress());
            String fname = (ff != null) ? ff.getName() + "@0x" + Long.toHexString(ff.getEntryPoint().getOffset()) : "<no-fn>";
            w.println("  from 0x" + Long.toHexString(r.getFromAddress().getOffset()) + " in " + fname);
        }
        w.println("\n### Xrefs TO FUN_00461820 (aibasic ctor) ###");
        rit = currentProgram.getReferenceManager().getReferencesTo(toAddr(0x00461820L));
        while (rit.hasNext()) {
            Reference r = rit.next();
            Function ff = currentProgram.getFunctionManager().getFunctionContaining(r.getFromAddress());
            String fname = (ff != null) ? ff.getName() + "@0x" + Long.toHexString(ff.getEntryPoint().getOffset()) : "<no-fn>";
            w.println("  from 0x" + Long.toHexString(r.getFromAddress().getOffset()) + " in " + fname);
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_ai_research3.txt");
    }
}
