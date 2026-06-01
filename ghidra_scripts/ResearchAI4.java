import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class ResearchAI4 extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;
    Set<Long> dumped = new HashSet<>();

    void d(long a, String tag) throws Exception {
        if (dumped.contains(a)) return;
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
        w.println("\n=== " + tag + " vftable @ 0x" + Long.toHexString(base) + " ===");
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
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_ai_research4.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        dumpVtable(0x00556bf0L, 24, "TBasicAI");

        long base = 0x00556bf0L;
        for (int i = 0; i < 20; i++) {
            long slot = base + i * 4;
            long fa = currentProgram.getMemory().getInt(toAddr(slot)) & 0xFFFFFFFFL;
            if (fa < 0x400000 || fa > 0x600000) continue;
            d(fa, "TBasicAI::vftable[" + i + "]");
        }

        d(0x00466870L, "TBasicAI base ctor");
        d(0x00464040L, "TNewLiving::vftable[10] (think1)");
        d(0x00464810L, "TNewLiving::vftable[11] (think2)");
        d(0x00467aa0L, "TNewLiving::vftable[9]");
        d(0x004551f0L, "TEnemy::vftable[10] (think1)");
        d(0x004534e0L, "TEnemy::vftable[14]");
        d(0x00453e80L, "TEnemy::vftable[33]");
        d(0x004547c0L, "TEnemy::vftable[35]");

        w.println("\n### DAT_005747a4 readers in AI range 0x460000-0x46a000 ###");
        ReferenceIterator it = currentProgram.getReferenceManager().getReferencesTo(toAddr(0x005747a4L));
        Set<Long> seen = new HashSet<>();
        while (it.hasNext()) {
            Reference r = it.next();
            Function f = currentProgram.getFunctionManager().getFunctionContaining(r.getFromAddress());
            if (f == null) continue;
            long fe = f.getEntryPoint().getOffset();
            if (fe >= 0x460000L && fe < 0x46a000L) seen.add(fe);
        }
        for (Long fe : seen) w.println("  AI fn @ 0x" + Long.toHexString(fe));

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_ai_research4.txt");
    }
}
