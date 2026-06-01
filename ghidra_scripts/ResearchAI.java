import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.mem.Memory;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class ResearchAI extends GhidraScript {
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
        DecompileResults res = decomp.decompileFunction(f, 90, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed]");
        }
        w.flush();
    }

    void listXrefs(long target, String tag) throws Exception {
        w.println("\n### Xrefs to " + tag + " @ 0x" + Long.toHexString(target));
        Address a = toAddr(target);
        ReferenceIterator it = currentProgram.getReferenceManager().getReferencesTo(a);
        Set<Long> fns = new HashSet<>();
        while (it.hasNext()) {
            Reference r = it.next();
            Address from = r.getFromAddress();
            Function f = currentProgram.getFunctionManager().getFunctionContaining(from);
            String fname = (f != null) ? f.getName() + "@0x" + Long.toHexString(f.getEntryPoint().getOffset()) : "<no-fn>";
            w.println(String.format("  from 0x%08x  type=%s  in %s", from.getOffset(), r.getReferenceType(), fname));
            if (f != null) fns.add(f.getEntryPoint().getOffset());
        }
        w.println("  -> " + fns.size() + " distinct functions");
    }

    // find addresses where a string literal appears, list functions referencing them
    void findStringRefs(String needle) throws Exception {
        w.println("\n### Strings containing \"" + needle + "\" and their xrefs");
        Memory mem = currentProgram.getMemory();
        // brute search in .rdata range
        Address start = toAddr(0x00500000L);
        Address end = toAddr(0x00580000L);
        byte[] target = needle.getBytes();
        Address cur = start;
        int found = 0;
        while (cur.compareTo(end) < 0 && found < 30) {
            try {
                boolean match = true;
                for (int i = 0; i < target.length; i++) {
                    if (mem.getByte(cur.add(i)) != target[i]) { match = false; break; }
                }
                if (match) {
                    // is it null-terminated-ish?
                    byte nxt = mem.getByte(cur.add(target.length));
                    if (nxt == 0 || (nxt >= 0x20 && nxt < 0x7f)) {
                        StringBuilder sb = new StringBuilder();
                        for (int i = 0; i < 40; i++) {
                            byte b = mem.getByte(cur.add(i));
                            if (b == 0) break;
                            sb.append((char) b);
                        }
                        w.println("  str@0x" + Long.toHexString(cur.getOffset()) + " = \"" + sb + "\"");
                        ReferenceIterator it = currentProgram.getReferenceManager().getReferencesTo(cur);
                        while (it.hasNext()) {
                            Reference r = it.next();
                            Function f = currentProgram.getFunctionManager().getFunctionContaining(r.getFromAddress());
                            String fname = (f != null) ? f.getName() + "@0x" + Long.toHexString(f.getEntryPoint().getOffset()) : "<no-fn>";
                            w.println("    xref from 0x" + Long.toHexString(r.getFromAddress().getOffset()) + " in " + fname);
                        }
                        found++;
                    }
                }
            } catch (Exception e) { /* skip uninit */ }
            cur = cur.add(1);
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_ai_research.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // ========= 1. Dump TActor vtable in full so we can ID think/update slots =========
        w.println("=== TActor::vftable @ 0x556594 (full) ===");
        long base = 0x00556594L;
        for (int i = 0; i < 40; i++) {
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
        w.flush();

        // ========= 2. Xrefs to active-player global DAT_005747a4 =========
        listXrefs(0x005747a4L, "DAT_005747a4 (active player global)");

        // ========= 3. Strings - hunt AI tags and related =========
        findStringRefs("basic");
        findStringRefs("aitype");
        findStringRefs("alertradius");
        findStringRefs("shootfrequency");
        findStringRefs("meleecooldown");
        findStringRefs("meleedamage");
        findStringRefs("seeplayersound");
        findStringRefs("lostplayersound");
        findStringRefs("huntsound");
        findStringRefs("movertype");
        findStringRefs("turnspeed");

        // ========= 4. Decompile TActor vtable slots that look like think/update =========
        // From existing notes: [24] +0x60 = TakeDamage @0x44e3e0; [28] +0x70 = ApplyBulletDamage @0x44ee80
        // Per TPlayer convention slot [10]+[11] are think1/think2.
        // Dump slots [9]..[14] for TActor.
        for (int i = 9; i <= 17; i++) {
            long slot = base + i * 4;
            long fa = currentProgram.getMemory().getInt(toAddr(slot)) & 0xFFFFFFFFL;
            if (fa < 0x400000 || fa > 0x600000) continue;
            d(fa, "TActor::vftable[" + i + "] (+0x" + Integer.toHexString(i*4) + ")");
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_ai_research.txt");
    }
}
